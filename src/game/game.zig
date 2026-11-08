//! The playable layer (docs/07-tech-demo.md): the witch, her tools,
//! projectiles, enemies and their contact effects, on top of the engine.
//!
//! Driven by the windowed app (src/app.zig) and by headless playtests
//! (src/game/playtest.zig) the same way, once per recorded frame:
//!
//!     game.requestReadback();            // regions + air samples for the next frame
//!     for each tick of the frame: game.tick(&input, &list);
//!     game.draw(view, extent, &input);   // sprites, lights, primitives
//!     game.hudLines(&engine.hud);
//!
//! Everything goes through the command list, the bodies layer and the
//! readback mirror (docs/08-engineering.md); no GPU calls, no allocation
//! per tick (fixed-capacity arrays).
//!
//! Level API (src/game/level.zig): `game.reset(spawn)`,
//! `game.player.spawnAt(x, y)`, `game.enemies.spawn(kind, x, y)`, all in
//! world pixels with (x, y) the feet / bottom center.
const std = @import("std");
const Engine = @import("../engine.zig").Engine;
const materials = @import("../sim/materials.zig");
const commands = @import("../sim/commands.zig");
const View = @import("../render/world.zig").View;
const Hud = @import("../render/hud.zig").Hud;
const Renderer = @import("../render/renderer.zig").Renderer;
const world = @import("world.zig");
const nowNs = @import("../sim/bodies_sim.zig").nowNs;
const status = @import("status.zig");
const physics = @import("physics.zig");
const art_mod = @import("art.zig");
pub const player_mod = @import("player.zig");
pub const enemies_mod = @import("enemies.zig");
pub const projectiles = @import("projectiles.zig");
pub const tools_mod = @import("tools.zig");
pub const explode = @import("explode.zig");
pub const Input = @import("input.zig").Input;

pub const Player = player_mod.Player;
pub const Enemies = enemies_mod.Enemies;
pub const EnemyKind = enemies_mod.Kind;

pub const Game = struct {
    engine: *Engine,
    lib: *const materials.Library,
    table: status.ContactTable,
    ids: world.Ids,
    art: art_mod.Art = .{},
    player: Player,
    enemies: Enemies = .{},
    shots: projectiles.Projectiles = .{},
    tools: tools_mod.Tools = .{},
    blasts: projectiles.BlastList = .{},
    prev_blasts: projectiles.BlastList = .{},
    explosions: explode.Explosions = .{},
    log: world.Log = .{},
    prng: std.Random.DefaultPrng,
    /// Engine tick the level started at; the game waits for the readback
    /// of that tick before anything moves.
    start_tick: u32 = 0,
    ready: bool = false,
    /// Drop a few enemies near the witch once the world is read back
    /// (`--spawn-enemies`).
    debug_spawn: u32 = 0,
    hits: [16]projectiles.Hit = undefined,
    ticks: u32 = 0,
    /// The renderer's vignette before smoke blindness strengthens it.
    base_vignette: f32 = 0.35,
    /// CPU time of gameplay ticks (ms): last, smoothed, total.
    tick_ms: f32 = 0,
    tick_ms_smooth: f32 = 0,
    tick_ms_total: f64 = 0,

    /// In place. Uploads the sprites into the renderer's atlas.
    pub fn init(self: *Game, engine: *Engine, lib: *const materials.Library, spawn: [2]f32) !void {
        self.* = .{
            .engine = engine,
            .lib = lib,
            .table = status.ContactTable.build(&lib.set),
            .ids = world.Ids.resolve(&lib.set),
            .player = Player.init(spawn[0], spawn[1]),
            .prng = std.Random.DefaultPrng.init(0x5eed_9a3e),
        };
        try self.art.upload(&engine.ctx, &engine.renderer.atlas);
        self.base_vignette = engine.renderer.settings.vignette_strength;
        // Painter palette: every material but air, starting at sand.
        var ids: [64]u8 = undefined;
        var n: usize = 0;
        for (lib.set.materials) |m| {
            if (m.id == 0 or n == ids.len) continue;
            ids[n] = m.id;
            n += 1;
        }
        std.mem.sort(u8, ids[0..n], {}, std.sort.asc(u8));
        self.tools.setPalette(ids[0..n], lib.id("sand") orelse ids[0]);
        self.reset(spawn);
    }

    /// After the engine was re-created (level reset): upload the sprites
    /// again into the new atlas.
    pub fn rebind(self: *Game, engine: *Engine) !void {
        self.engine = engine;
        try self.art.upload(&engine.ctx, &engine.renderer.atlas);
    }

    /// Start the level over: no enemies, no projectiles, the witch at
    /// `spawn` (feet). The level then spawns its enemies.
    pub fn reset(self: *Game, spawn: [2]f32) void {
        self.player.spawnAt(spawn[0], spawn[1]);
        self.player.deaths = 0;
        self.enemies.clear();
        self.enemies.kills = 0;
        self.shots.clear();
        self.blasts = .{};
        self.prev_blasts = .{};
        self.explosions = .{};
        self.start_tick = self.engine.tick;
        self.ready = false;
        self.tools.arc_len = 0;
        self.tools.bolt_ticks = 0;
    }

    /// The witch's feet position (for the camera and the level).
    pub fn spawnAt(self: *Game, x: f32, y: f32) void {
        self.player.spawnAt(x, y);
    }

    fn airPtr(self: *Game) ?*@import("../sim/air.zig").Air {
        return if (self.engine.pipeline.config.air) &self.engine.pipeline.air else null;
    }

    /// Readback for the next recorded frame: the region and air sample
    /// around each entity. Call once per frame that records ticks.
    pub fn requestReadback(self: *Game) void {
        const m = self.engine.mirror();
        const a = self.airPtr();
        self.player.actor.requestReadback(m, a);
        self.enemies.requestReadback(m, a);
        self.shots.requestReadback(m);
    }

    fn ctxFor(self: *Game, list: *commands.CommandList) world.Ctx {
        const e = self.engine;
        return .{
            .mirror = e.mirror(),
            .table = &self.table,
            .list = list,
            .bodies = if (e.pipeline.config.bodies) e.pipeline.bodies.sim else null,
            .air = self.airPtr(),
            .liquid_on = e.pipeline.config.liquid,
            .ids = &self.ids,
            .rng = self.prng.random(),
            .tick = e.tick,
            .log = &self.log,
            .blasts = self.prev_blasts.slice(),
        };
    }

    /// One simulation tick of gameplay; commands go into `list`.
    pub fn tick(self: *Game, in: *const Input, list: *commands.CommandList) void {
        const m = self.engine.mirror();
        self.log.tick = self.engine.tick;
        if (!self.ready) {
            const since = m.tick -% self.start_tick;
            if (!m.valid or since < 2 or since > 1 << 30) return;
            self.ready = true;
        }
        self.ticks += 1;
        const t0 = nowNs();
        defer {
            self.tick_ms = @as(f32, @floatFromInt(nowNs() - t0)) / 1e6;
            self.tick_ms_smooth = self.tick_ms_smooth * 0.95 + self.tick_ms * 0.05;
            self.tick_ms_total += self.tick_ms;
        }
        var ctx = self.ctxFor(list);
        // Gunpowder (and any material event) explosions, one tick late.
        _ = self.explosions.drain(m, list, ctx.explodeOpts());
        if (ctx.bodies) |b| b.setCenter(self.player.actor.cx(), self.player.actor.cy());
        self.tools.update(&ctx, in, &self.player, &self.shots, &self.enemies, &self.blasts);
        _ = self.player.update(&ctx, in);
        self.enemies.update(&ctx, &self.player, &self.shots);
        // Projectiles against the witch and the enemies.
        var targets: [enemies_mod.capacity + 1]projectiles.Target = undefined;
        var nt: u32 = 0;
        if (self.player.alive()) {
            targets[nt] = .{ .box = self.player.actor.body, .player = true, .index = 0 };
            nt += 1;
        }
        for (self.enemies.items[0..self.enemies.len], 0..) |*e, i| {
            targets[nt] = .{ .box = e.actor.body, .player = false, .index = @intCast(i) };
            nt += 1;
        }
        const n_hits = self.shots.update(&ctx, targets[0..nt], &self.hits, &self.blasts);
        for (self.hits[0..n_hits]) |h| {
            const actor = if (h.target.player) &self.player.actor else &self.enemies.items[h.target.index].actor;
            switch (h.kind) {
                .fire_bolt => {
                    actor.damage(self.shots.tun.fire_bolt_damage);
                    actor.status.ignite(actor.tuning);
                    actor.body.vx += if (h.x < actor.cx()) 60 else -60;
                },
                .spit => {
                    actor.damage(self.shots.tun.spit_damage);
                    actor.status.ignite(actor.tuning);
                },
                .charge => {},
            }
        }
        if (self.debug_spawn > 0) self.spawnDebugEnemies(&ctx);
        self.prev_blasts = self.blasts;
        self.blasts = .{};
    }

    /// Walkers on both sides of the witch and a flyer above, on the ground
    /// found below each spot.
    fn spawnDebugEnemies(self: *Game, ctx: *const world.Ctx) void {
        const n = self.debug_spawn;
        self.debug_spawn = 0;
        const px = self.player.actor.cx();
        const py = self.player.actor.cy();
        const offsets = [_]f32{ 110, -130, 190, -210, 260, -280 };
        for (0..@min(n, offsets.len)) |i| {
            const x = px + offsets[i];
            if (i == 2) {
                _ = self.enemies.spawn(.flyer, x, py - 70);
                continue;
            }
            const y = groundBelow(ctx, x, py - 40) orelse continue;
            _ = self.enemies.spawn(.walker, x, y);
        }
        ctx.log.add("spawned {d} debug enemies", .{self.enemies.len});
    }

    // ------------------------------------------------------------ drawing

    /// Sprites, lights, projectiles, arcs, previews, screen bars. Call once
    /// per rendered frame (after the frame's ticks).
    pub fn draw(self: *Game, view: View, extent: [2]u32, in: *const Input) void {
        const r = &self.engine.renderer;
        const t: f32 = @floatFromInt(self.engine.tick);
        // Enemies.
        for (self.enemies.items[0..self.enemies.len]) |*e| {
            const b = e.actor.body;
            const frame: usize = @intFromFloat(@mod(e.anim * 6, 2));
            const tint = actorTint(&e.actor, t);
            switch (e.kind) {
                .walker => r.drawSprite(@floatFromInt(b.x - 3), @floatFromInt(b.y - 2), art_mod.walker_w, art_mod.walker_h, self.art.walker[frame], e.actor.facing < 0, tint),
                .flyer => r.drawSprite(@floatFromInt(b.x - 1), @floatFromInt(b.y - 1), art_mod.flyer_w, art_mod.flyer_h, self.art.flyer[@as(usize, @intFromFloat(@mod(e.anim * 8, 2)))], e.actor.facing < 0, tint),
            }
            if (e.actor.health < e.actor.max_health) healthBar(r, @floatFromInt(b.x + @divTrunc(b.w, 2) - 8), @floatFromInt(b.y - 6), 16, e.actor.health / e.actor.max_health);
            burnLight(r, &e.actor, t);
        }
        // The witch.
        const p = &self.player;
        const pa = &p.actor;
        if (pa.alive) {
            const walking = p.walk_time > 0 and @mod(p.walk_time, 0.3) > 0.15;
            const rect = if (p.cast_time > 0) (if (walking) self.art.witch_cast_walk else self.art.witch_cast) else if (walking) self.art.witch_walk else self.art.witch_idle;
            r.drawSprite(@floatFromInt(pa.body.x + player_mod.sprite_dx), @floatFromInt(pa.body.y + player_mod.sprite_dy), art_mod.witch_w, art_mod.witch_h, rect, pa.facing < 0, actorTint(pa, t));
            const wand = p.wand();
            const glow: f32 = if (p.cast_time > 0) 1.6 else 0.7;
            r.addLight(wand[0], wand[1] - (if (p.cast_time > 0) @as(f32, 1) else 2), 45, .{ 0.4 * glow, 0.9 * glow, 1.0 * glow });
            burnLight(r, pa, t);
        }
        // Projectiles.
        for (self.shots.items[0..self.shots.len]) |s| {
            switch (s.kind) {
                .fire_bolt => {
                    r.drawRect(s.x - 1.5, s.y - 1.5, 3, 3, .{ 1.0, 0.75, 0.3, 1 }, true);
                    r.drawLine(s.x, s.y, s.x - s.vx * 0.012, s.y - s.vy * 0.012, .{ 1.0, 0.45, 0.1, 0.8 });
                    r.addLight(s.x, s.y, 50, .{ 1.6, 0.8, 0.3 });
                },
                .spit => {
                    r.drawRect(s.x - 1, s.y - 1, 2, 2, .{ 1.0, 0.5, 0.2, 1 }, true);
                    r.addLight(s.x, s.y, 30, .{ 1.2, 0.5, 0.2 });
                },
                .charge => {
                    r.drawRect(s.x - 2, s.y - 2, 4, 4, .{ 0.18, 0.16, 0.15, 1 }, true);
                    const blink = @mod(s.fuse, if (s.fuse < 0.5) @as(f32, 0.1) else 0.3) < 0.06;
                    if (blink) {
                        r.drawRect(s.x - 0.5, s.y - 2.5, 1, 1, .{ 1, 0.15, 0.1, 1 }, true);
                        r.addLight(s.x, s.y - 2, 16, .{ 1.5, 0.2, 0.1 });
                    }
                },
            }
        }
        // Lightning arcs: jagged lines with light along them.
        for (self.tools.arcs[0..self.tools.arc_len]) |arc| drawArc(r, arc, self.engine.tick);
        // Cursor and tool previews.
        const ax = @floor(in.aim[0]);
        const ay = @floor(in.aim[1]);
        const cursor_color = [4]f32{ 0.9, 0.95, 1.0, 0.7 };
        r.drawLine(ax - 4, ay, ax - 2, ay, cursor_color);
        r.drawLine(ax + 2, ay, ax + 4, ay, cursor_color);
        r.drawLine(ax, ay - 4, ax, ay - 2, cursor_color);
        r.drawLine(ax, ay + 2, ax, ay + 4, cursor_color);
        switch (self.tools.current) {
            .dig, .painter, .gunpowder => {
                const br: f32 = @floatFromInt(if (self.tools.current == .gunpowder) @max(2, @divTrunc(self.tools.brush, 2)) else self.tools.brush);
                r.drawRect(ax - br, ay - br, 2 * br + 1, 2 * br + 1, .{ 0.9, 0.9, 0.6, 0.35 }, false);
            },
            .cutter => {
                if (self.tools.cut_start) |s| r.drawLine(s[0], s[1], ax, ay, .{ 1.0, 0.25, 0.2, 0.8 });
                if (self.tools.beam_start) |s| r.drawLine(s[0], s[1], ax, ay, .{ 0.7, 0.75, 0.8, 0.8 });
            },
            else => {},
        }
        self.drawScreen(view, extent);
    }

    /// Screen-fixed bars, blindness and the death fade, as world-space
    /// rectangles placed relative to the camera.
    fn drawScreen(self: *Game, view: View, extent: [2]u32) void {
        const r = &self.engine.renderer;
        const s: f32 = @floatFromInt(@max(view.scale, 1));
        const cx: f32 = @floatFromInt(view.camera_x);
        const cy: f32 = @floatFromInt(view.camera_y);
        const vw = @as(f32, @floatFromInt(extent[0])) / s;
        const vh = @as(f32, @floatFromInt(extent[1])) / s;
        const pa = &self.player.actor;
        // Health and breath, bottom left.
        const bw = @min(90, vw * 0.25);
        const by = cy + vh - 12;
        r.drawRect(cx + 5, by - 1, bw + 2, 6, .{ 0, 0, 0, 0.6 }, true);
        r.drawRect(cx + 6, by, bw * pa.health / pa.max_health, 4, .{ 0.85, 0.15, 0.2, 0.95 }, true);
        if (pa.status.breath < pa.tuning.max_breath) {
            r.drawRect(cx + 5, by - 8, bw + 2, 5, .{ 0, 0, 0, 0.6 }, true);
            r.drawRect(cx + 6, by - 7, bw * pa.status.breath / pa.tuning.max_breath, 3, .{ 0.4, 0.75, 1.0, 0.95 }, true);
        }
        // Smoke blinds: darkened edges closing in, plus a stronger vignette.
        const blind_k = @min(1, pa.status.blind * 2);
        r.settings.vignette_strength = self.base_vignette + 0.9 * blind_k;
        if (pa.status.blind > 0) {
            const k = blind_k;
            var ring: f32 = 0;
            while (ring < 12) : (ring += 1) {
                const m = ring * vw * 0.022;
                const a = 0.075 * k;
                r.drawRect(cx, cy, vw, m + vh * 0.04, .{ 0, 0, 0, a }, true);
                r.drawRect(cx, cy + vh - m - vh * 0.04, vw, m + vh * 0.04, .{ 0, 0, 0, a }, true);
                r.drawRect(cx, cy, m + vw * 0.04, vh, .{ 0, 0, 0, a }, true);
                r.drawRect(cx + vw - m - vw * 0.04, cy, m + vw * 0.04, vh, .{ 0, 0, 0, a }, true);
            }
        }
        if (!pa.alive) {
            const a = @min(1, self.player.dead_time / self.player.tun.respawn_delay * 1.3);
            r.drawRect(cx, cy, vw, vh, .{ 0.05, 0, 0, a }, true);
        } else if (pa.hurt_flash > 0) {
            r.drawRect(cx, cy, vw, vh, .{ 0.6, 0, 0, pa.hurt_flash * 0.8 }, true);
        }
    }

    /// The game's HUD block (top left).
    pub fn hudLines(self: *const Game, hud: *Hud) void {
        const pa = &self.player.actor;
        var bar: [20]u8 = undefined;
        const filled: usize = @intFromFloat(@round(20 * std.math.clamp(pa.health / pa.max_health, 0, 1)));
        for (&bar, 0..) |*c, i| c.* = if (i < filled) '#' else '-';
        var sbuf: [64]u8 = undefined;
        const st = pa.status.describe(&sbuf);
        if (pa.alive) {
            hud.print("HP {d:3.0}/{d:.0} [{s}]{s}{s}", .{ pa.health, pa.max_health, &bar, if (st.len > 0) "  " else "", st });
        } else hud.print("HP   0 [{s}]  DEAD - respawning", .{&bar});
        if (pa.status.breath < pa.tuning.max_breath) {
            var bb: [10]u8 = undefined;
            const bf: usize = @intFromFloat(@round(10 * pa.status.breath / pa.tuning.max_breath));
            for (&bb, 0..) |*c, i| c.* = if (i < bf) 'o' else '.';
            hud.print("BREATH [{s}]", .{&bb});
        }
        const ti = self.tools.info();
        if (self.tools.current == .painter) {
            hud.print("[{s}] {s}: {s} (wheel: material) | RMB {s}   material {s}  brush {d}", .{ ti.key, ti.name, ti.primary, ti.secondary, self.lib.name(self.tools.paint), self.tools.brush });
        } else {
            hud.print("[{s}] {s}: LMB {s} | RMB {s}   brush {d}", .{ ti.key, ti.name, ti.primary, ti.secondary, self.tools.brush });
        }
        hud.print("enemies {d}  kills {d}  deaths {d}  gameplay {d:.3} ms   F1 help  F3 timings  R reset  P pause  Esc quit", .{ self.enemies.len, self.enemies.kills, self.player.deaths, self.tick_ms_smooth });
        var k: u32 = 0;
        while (self.log.recent(3, k)) |line| : (k += 1) hud.print("> {s}", .{line});
    }

    /// F1: the tool table and the controls (docs/07).
    pub fn helpLines(hud: *Hud) void {
        hud.print("HEXE - the proving grounds                         F1 closes this help", .{});
        hud.print("key  tool           LMB (primary)                RMB (secondary)", .{});
        for (tools_mod.table) |t| hud.print(" {s}   {s:<14} {s:<28} {s}", .{ t.key, t.name, t.primary, t.secondary });
        hud.print("", .{});
        hud.print("A/D move   Space/W jump (hold: higher, in water: swim up)   S drop through / dive", .{});
        hud.print("mouse aim   wheel brush size (painter: material)   =/- zoom", .{});
        hud.print("R reset level   P pause   . single step   Tab overlays   F3 timings   Esc quit", .{});
        hud.print("E explosion at cursor   X eject   C/Z/V concrete crate / wood crate / slab   L liquid solver", .{});
        hud.print("F4 light mode  F6 quality  F7 bloom  F8 vignette  F12 screenshot", .{});
    }
};

/// First ground (solid mask) below (x, y), within 300 px: the y of its top.
pub fn groundBelow(ctx: *const world.Ctx, x: f32, y: f32) ?f32 {
    const ix: i32 = @intFromFloat(x);
    var iy: i32 = @intFromFloat(y);
    // Out of solid first (a spot inside a wall searches upward).
    var up: i32 = 0;
    while (ctx.mirror.isSolid(ix, iy) and up < 200) : (up += 1) iy -= 1;
    var d: i32 = 0;
    while (d < 300) : (d += 1) {
        if (ctx.mirror.isSolid(ix, iy + d)) return @floatFromInt(iy + d);
    }
    return null;
}

fn actorTint(a: *const world.Actor, t: f32) [4]f32 {
    if (a.hurt_flash > 0) return .{ 1.0, 0.45, 0.45, 1 };
    if (a.status.stunned > 0 and @mod(t, 6) < 3) return .{ 0.75, 0.9, 1.4, 1 };
    if (a.status.burning > 0) return .{ 1.3, 0.85, 0.6, 1 };
    if (a.status.wet > 0) return .{ 0.85, 0.92, 1.1, 1 };
    if (a.status.oily > 0) return .{ 0.75, 0.7, 0.6, 1 };
    if (a.status.bloody > 0) return .{ 1.05, 0.8, 0.8, 1 };
    return .{ 1, 1, 1, 1 };
}

fn burnLight(r: *Renderer, a: *const world.Actor, t: f32) void {
    if (a.status.burning <= 0) return;
    const flicker = 0.8 + 0.2 * @sin(t * 0.9) * @sin(t * 0.37);
    r.addLight(a.cx(), a.cy() - 4, 55, .{ 1.6 * flicker, 0.7 * flicker, 0.25 * flicker });
}

fn healthBar(r: *Renderer, x: f32, y: f32, w: f32, frac: f32) void {
    r.drawRect(x - 1, y - 1, w + 2, 4, .{ 0, 0, 0, 0.7 }, true);
    r.drawRect(x, y, w * std.math.clamp(frac, 0, 1), 2, .{ 0.9, 0.2, 0.15, 1 }, true);
}

fn drawArc(r: *Renderer, arc: tools_mod.Arc, tick: u32) void {
    const segs = 8;
    var px = arc.x0;
    var py = arc.y0;
    const dx = arc.x1 - arc.x0;
    const dy = arc.y1 - arc.y0;
    const len = @max(1, @sqrt(dx * dx + dy * dy));
    const nx = -dy / len;
    const ny = dx / len;
    for (1..segs + 1) |i| {
        const t = @as(f32, @floatFromInt(i)) / segs;
        const h = @import("../sim/cell.zig").hashU32(arc.seed +% @as(u32, @intCast(i)) *% 7919 +% tick / 2);
        const off: f32 = if (i == segs) 0 else (@as(f32, @floatFromInt(h % 13)) - 6) * @min(1, len / 60);
        const x = arc.x0 + dx * t + nx * off;
        const y = arc.y0 + dy * t + ny * off;
        // A violet glow either side of a white core.
        r.drawLine(px + nx, py + ny, x + nx, y + ny, .{ 0.55, 0.45, 1.0, 0.8 });
        r.drawLine(px - nx, py - ny, x - nx, y - ny, .{ 0.55, 0.45, 1.0, 0.8 });
        r.drawLine(px, py, x, y, .{ 1.0, 1.0, 1.0, 1 });
        if (i % 3 == 0) r.addLight(x, y, 60, .{ 0.8, 1.0, 1.6 });
        px = x;
        py = y;
    }
    r.addLight(arc.x1, arc.y1, 70, .{ 1.0, 1.2, 2.0 });
}

test {
    _ = @import("physics.zig");
    _ = @import("status.zig");
    _ = @import("player.zig");
    _ = @import("tools.zig");
    _ = @import("art.zig");
    _ = @import("world.zig");
}
