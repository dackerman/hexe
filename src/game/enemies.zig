//! Enemies (docs/07-tech-demo.md "Enemies", docs/decisions/126-gameplay-enemy-ai.md).
//!
//! - Walker: ground enemy, 20 x 28 sprite, 14 x 26 box. Patrols and turns
//!   at walls and ledges; chases the witch when she is within 200 px and
//!   visible (ray through the solid mask); melee on contact; jumps small
//!   obstacles while chasing.
//! - Flyer: 14 x 14, hovers at a distance with a sine bob, spits a small
//!   fire bolt every 2 s when it sees the witch; light, so blasts throw it;
//!   falls while stunned.
//! Both share the witch's contact effects (`world.Actor`). Death turns the
//! sprite into a pixel body of flesh and bone (bodies layer) moving at the
//! enemy's velocity, and blood is sprayed and pooled.
//!
//! `Enemies.spawn(kind, x, y)` (feet / bottom center at x, y) is the level's
//! API. Fixed capacity; enemies farther than `active_range` from the witch
//! are frozen and request no readback.
const std = @import("std");
const physics = @import("physics.zig");
const world = @import("world.zig");
const art = @import("art.zig");
const projectiles = @import("projectiles.zig");
const player_mod = @import("player.zig");
const readback = @import("../sim/readback.zig");
const air_mod = @import("../sim/air.zig");

pub const Kind = enum { walker, flyer };

pub const capacity = 32;
/// Enemies farther than this from the witch do not think, move or read back.
pub const active_range: f32 = 700;

pub const WalkerTuning = struct {
    health: f32 = 60,
    patrol_speed: f32 = 40,
    chase_speed: f32 = 82,
    accel: f32 = 900,
    gravity: f32 = 760,
    jump_speed: f32 = 250,
    sight: f32 = 200,
    melee_damage: f32 = 12,
    melee_cooldown: f32 = 0.8,
    melee_knock: f32 = 220,
};

pub const FlyerTuning = struct {
    health: f32 = 25,
    max_speed: f32 = 150,
    spring: f32 = 5,
    damping: f32 = 2.6,
    keep_x: f32 = 110,
    keep_y: f32 = -70,
    bob: f32 = 7,
    sight: f32 = 280,
    spit_every: f32 = 2,
    gravity: f32 = 600,
};

pub const Enemy = struct {
    kind: Kind,
    actor: world.Actor,
    /// Walker: patrol direction; flyer: side it keeps.
    dir: f32 = 1,
    chasing: bool = false,
    cooldown: f32 = 0,
    timer: f32 = 0,
    home: [2]f32,
    grounded: bool = false,
    anim: f32 = 0,
    active: bool = true,
};

pub const Enemies = struct {
    items: [capacity]Enemy = undefined,
    len: u32 = 0,
    walker: WalkerTuning = .{},
    flyer: FlyerTuning = .{},
    kills: u32 = 0,
    /// Corpse bitmaps (ids filled at spawn time from the game's ids).
    corpse_px: [art.walker_w * art.walker_h]u8 = undefined,

    pub fn clear(self: *Enemies) void {
        self.len = 0;
    }

    /// Spawn an enemy standing (walker) or hovering (flyer) with its bottom
    /// center at (x, y). Returns false when full.
    pub fn spawn(self: *Enemies, kind: Kind, x: f32, y: f32) bool {
        if (self.len >= capacity) return false;
        const w: i32, const h: i32, const hp = switch (kind) {
            .walker => .{ 14, 26, self.walker.health },
            .flyer => .{ 12, 12, self.flyer.health },
        };
        var e: Enemy = .{
            .kind = kind,
            .actor = .{ .body = .{ .x = 0, .y = 0, .w = w, .h = h }, .health = hp, .max_health = hp, .blast_factor = if (kind == .flyer) 3 else 0.8 },
            .home = .{ x, y - @as(f32, @floatFromInt(h)) * 0.5 },
            .dir = if (@mod(x, 2) < 1) -1 else 1,
        };
        e.actor.body.setCenter(x, y - @as(f32, @floatFromInt(h)) * 0.5);
        e.actor.facing = e.dir;
        self.items[self.len] = e;
        self.len += 1;
        return true;
    }

    pub fn requestReadback(self: *Enemies, mirror: *readback.Mirror, air: ?*air_mod.Air) void {
        for (self.items[0..self.len]) |*e| if (e.active) e.actor.requestReadback(mirror, air);
    }

    /// Think and move every active enemy; dead ones become corpses.
    pub fn update(self: *Enemies, ctx: *const world.Ctx, player: *player_mod.Player, shots: *projectiles.Projectiles) void {
        const px = player.actor.cx();
        const py = player.actor.cy();
        var i: u32 = 0;
        while (i < self.len) {
            const e = &self.items[i];
            const dx = e.actor.cx() - px;
            const dy = e.actor.cy() - py;
            e.active = dx * dx + dy * dy < active_range * active_range;
            if (e.active) {
                switch (e.kind) {
                    .walker => self.updateWalker(ctx, e, player),
                    .flyer => self.updateFlyer(ctx, e, player, shots),
                }
            }
            if (!e.actor.alive) {
                self.die(ctx, e);
                self.items[i] = self.items[self.len - 1];
                self.len -= 1;
            } else i += 1;
        }
    }

    fn sees(ctx: *const world.Ctx, e: *const Enemy, player: *const player_mod.Player, range: f32) bool {
        if (!player.alive()) return false;
        const dx = player.actor.cx() - e.actor.cx();
        const dy = player.actor.cy() - e.actor.cy();
        if (dx * dx + dy * dy > range * range) return false;
        const eye_y = @as(f32, @floatFromInt(e.actor.body.y)) + 5;
        return !physics.rayBlocked(ctx, @intFromFloat(e.actor.cx()), @intFromFloat(eye_y), @intFromFloat(player.actor.cx()), @intFromFloat(player.actor.cy() - 6));
    }

    fn common(ctx: *const world.Ctx, e: *Enemy) world.EntityWorld {
        const a = &e.actor;
        a.hurt_flash = @max(0, a.hurt_flash - world.dt);
        var w = a.world(ctx);
        a.stuck = !physics.pushOut(&w, &a.body, 8);
        a.scan(ctx, &w);
        _ = a.applyStatus(ctx);
        a.blast(ctx);
        e.cooldown = @max(0, e.cooldown - world.dt);
        return w;
    }

    fn updateWalker(self: *Enemies, ctx: *const world.Ctx, e: *Enemy, player: *player_mod.Player) void {
        const t = self.walker;
        const w = common(ctx, e);
        const a = &e.actor;
        const b = &a.body;
        const stunned = a.status.stunned > 0;
        const swimming = a.liquid > 0.35;
        e.chasing = sees(ctx, e, player, if (e.chasing) t.sight * 1.5 else t.sight);
        var target: f32 = 0;
        if (!stunned) {
            if (e.chasing) {
                const dx = player.actor.cx() - a.cx();
                e.dir = if (dx < 0) -1 else 1;
                target = if (@abs(dx) > 4) e.dir * t.chase_speed else 0;
            } else {
                // Patrol: turn at walls and ledges.
                const ahead_x = if (e.dir > 0) b.x + b.w + 2 else b.x - 3;
                var ledge = true;
                var d: i32 = 0;
                while (d < 10) : (d += 1) {
                    if (w.solid(ahead_x, b.y + b.h + d)) {
                        ledge = false;
                        break;
                    }
                }
                if (e.grounded and ledge) e.dir = -e.dir;
                target = e.dir * t.patrol_speed;
            }
        }
        const slow = a.touch.slow;
        target *= (1 - slow);
        a.knock = @max(0, a.knock - world.dt);
        b.vx = player_mod.approach(b.vx, target, t.accel * world.dt * (if (a.knock > 0) @as(f32, 0.15) else 1));
        if (swimming) {
            b.vy += t.gravity * 0.3 * world.dt; // heavy: sinks and walks the bottom
            const drag = @exp(-3 * world.dt);
            b.vx *= drag;
            b.vy *= drag;
        } else b.vy = @min(b.vy + t.gravity * world.dt, 540);
        const r = physics.move(&w, b, world.dt, .{ .step_up = 3, .snap_down = e.grounded });
        if (r.hit_x) {
            if (e.chasing and e.grounded and !stunned) b.vy = -t.jump_speed else if (!e.chasing) e.dir = -e.dir;
        }
        e.grounded = physics.grounded(&w, b.*);
        a.facing = e.dir;
        if (@abs(b.vx) > 5) e.anim += world.dt;
        // Melee.
        if (!stunned and player.alive() and e.cooldown == 0 and b.overlaps(player.actor.body.x - 3, player.actor.body.y - 2, player.actor.body.w + 6, player.actor.body.h + 4)) {
            player.actor.damage(t.melee_damage);
            player.actor.body.vx += e.dir * t.melee_knock;
            player.actor.body.vy -= 140;
            e.cooldown = t.melee_cooldown;
            ctx.log.add("walker hit the witch ({d:.0} hp left)", .{player.actor.health});
        }
    }

    fn updateFlyer(self: *Enemies, ctx: *const world.Ctx, e: *Enemy, player: *player_mod.Player, shots: *projectiles.Projectiles) void {
        const t = self.flyer;
        const w = common(ctx, e);
        const a = &e.actor;
        const b = &a.body;
        e.timer += world.dt;
        const stunned = a.status.stunned > 0;
        const sees_player = sees(ctx, e, player, t.sight);
        e.chasing = sees_player;
        a.knock = @max(0, a.knock - world.dt);
        if (a.knock > 0) {
            // Tumbling from a blast: no steering, a little gravity.
            b.vy += t.gravity * 0.3 * world.dt;
            b.vx *= @exp(-0.8 * world.dt);
        } else if (stunned or a.liquid > 0.3) {
            // Falls (and flounders in liquid).
            b.vy = @min(b.vy + t.gravity * world.dt, 400);
            b.vx *= @exp(-1.5 * world.dt);
        } else {
            var tx = e.home[0];
            var ty = e.home[1];
            if (sees_player) {
                // Keep to the side it is on, at a distance, above.
                e.dir = if (a.cx() < player.actor.cx()) -1 else 1;
                tx = player.actor.cx() + e.dir * t.keep_x;
                ty = player.actor.cy() + t.keep_y;
            }
            ty += @sin(e.timer * 3.1) * t.bob;
            b.vx += ((tx - a.cx()) * t.spring - b.vx * t.damping) * world.dt;
            b.vy += ((ty - a.cy()) * t.spring - b.vy * t.damping) * world.dt;
            const sp = @sqrt(b.vx * b.vx + b.vy * b.vy);
            // Blasts may exceed the cruise speed; steering does not.
            if (sp > t.max_speed and sp < t.max_speed * 1.3) {
                b.vx *= t.max_speed / sp;
                b.vy *= t.max_speed / sp;
            }
            if (sees_player and e.cooldown == 0) {
                const mx = a.cx() - e.dir * 4;
                const my = a.cy() + 3;
                _ = shots.fire(.spit, mx, my, player.actor.cx() - mx, player.actor.cy() - 4 - my, false);
                e.cooldown = t.spit_every;
            }
        }
        _ = physics.move(&w, b, world.dt, .{});
        a.facing = -e.dir;
        e.anim += world.dt;
    }

    /// A dead enemy becomes a flesh-and-bone pixel body and bleeds.
    fn die(self: *Enemies, ctx: *const world.Ctx, e: *Enemy) void {
        self.kills += 1;
        const a = &e.actor;
        const b = a.body;
        const cause = player_mod.causeOf(a);
        const sw: u16, const sh: u16 = switch (e.kind) {
            .walker => .{ art.walker_w, art.walker_h },
            .flyer => .{ art.flyer_w, art.flyer_h },
        };
        const pixels = self.corpse_px[0 .. @as(usize, sw) * sh];
        switch (e.kind) {
            .walker => art.corpseBitmap(art.walker_w, art.walker_h, &art.walker_a, .walker, ctx.ids.flesh, ctx.ids.bone, pixels[0 .. art.walker_w * art.walker_h]),
            .flyer => art.corpseBitmap(art.flyer_w, art.flyer_h, &art.flyer_a, .flyer, ctx.ids.flesh, ctx.ids.bone, pixels[0 .. art.flyer_w * art.flyer_h]),
        }
        // Mirror the bitmap to the sprite's facing.
        if (a.facing < 0) {
            for (0..sh) |y| std.mem.reverse(u8, pixels[y * sw ..][0..sw]);
        }
        const cx = a.cx();
        const cy = a.cy();
        var spawned = false;
        if (ctx.bodies) |bodies| {
            if (ctx.ids.flesh != 0) {
                _ = bodies.spawnBody(.{
                    .pixels = pixels,
                    .w = sw,
                    .h = sh,
                    .x = cx,
                    .y = cy - 1,
                    .origin_x = @as(f32, @floatFromInt(sw)) * 0.5,
                    .origin_y = @as(f32, @floatFromInt(sh)) * 0.5,
                    .vx = b.vx,
                    .vy = b.vy,
                    .angular_velocity = (if (b.vx < 0) -1.5 else 1.5),
                }) catch |err| {
                    ctx.log.add("corpse body refused: {s}", .{@errorName(err)});
                };
                spawned = true;
            }
        }
        // Blood: a spray from the wound and a small pool.
        const ix: i32 = @intFromFloat(cx);
        const iy: i32 = @intFromFloat(cy);
        ctx.list.spray(.{ .x = ix, .y = iy - 4, .material = ctx.ids.blood, .count = 60, .speed = 150, .spread = 90, .direction = 0.75, .cone = 0.22 });
        ctx.list.fillCircle(ix, b.y + b.h - 2, 3, ctx.ids.blood, .{ .only_air = true });
        ctx.log.add("{s} died ({s}) at {d},{d}; corpse body {s}", .{ @tagName(e.kind), cause, ix, iy, if (spawned) "spawned" else "skipped (bodies off)" });
    }
};
