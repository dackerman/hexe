//! The witch's tools (docs/07-tech-demo.md "Tools"; keys 1-0, LMB primary,
//! RMB secondary, wheel = brush size or the painter's material). Every tool
//! is a few calls into the command list, the bodies layer or the projectile
//! list (docs/decisions/127-gameplay-key-map.md).
const std = @import("std");
const world = @import("world.zig");
const physics = @import("physics.zig");
const projectiles = @import("projectiles.zig");
const enemies_mod = @import("enemies.zig");
const player_mod = @import("player.zig");
const Input = @import("input.zig").Input;
const commands = @import("../sim/commands.zig");

pub const Tool = enum(u8) {
    fire_bolt = 0,
    blast_charge = 1,
    water = 2,
    lava = 3,
    acid = 4,
    dig = 5,
    lightning = 6,
    cutter = 7,
    gunpowder = 8,
    painter = 9,
};

pub const Info = struct {
    key: []const u8,
    name: []const u8,
    primary: []const u8,
    secondary: []const u8,
    /// Ticks between uses while the button is held (0 = once per click).
    primary_every: u32,
    secondary_every: u32,
};

/// The tool table (docs/07). Held buttons repeat every `*_every` ticks;
/// 0 = one use per click, limited by the cooldown in `cooldown_ticks`.
pub const table = [_]Info{
    .{ .key = "1", .name = "fire bolt", .primary = "bolt: ignites, heats", .secondary = "flame spray (hold)", .primary_every = 0, .secondary_every = 2 },
    .{ .key = "2", .name = "blast charge", .primary = "throw charge (1.6 s fuse)", .secondary = "blast at cursor", .primary_every = 0, .secondary_every = 0 },
    .{ .key = "3", .name = "water spray", .primary = "spray water (hold)", .secondary = "water column", .primary_every = 1, .secondary_every = 0 },
    .{ .key = "4", .name = "lava spray", .primary = "spray lava (hold)", .secondary = "lava blob", .primary_every = 1, .secondary_every = 0 },
    .{ .key = "5", .name = "acid spray", .primary = "spray acid (hold)", .secondary = "acid blob", .primary_every = 1, .secondary_every = 0 },
    .{ .key = "6", .name = "dig", .primary = "carve circle (hold)", .secondary = "fill dirt (hold)", .primary_every = 2, .secondary_every = 3 },
    .{ .key = "7", .name = "lightning", .primary = "bolt: charges conductors", .secondary = "continuous arc (hold)", .primary_every = 0, .secondary_every = 4 },
    .{ .key = "8", .name = "cutter", .primary = "drag: cut a line", .secondary = "2 clicks: steel beam", .primary_every = 0, .secondary_every = 0 },
    .{ .key = "9", .name = "gunpowder", .primary = "pour gunpowder (hold)", .secondary = "wooden box", .primary_every = 3, .secondary_every = 0 },
    .{ .key = "0", .name = "painter", .primary = "paint material (hold)", .secondary = "erase (hold)", .primary_every = 1, .secondary_every = 1 },
};

/// Minimum ticks between two clicks of a tool's primary / secondary.
pub const cooldown_ticks = [table.len][2]u32{
    .{ 15, 0 }, // fire bolt
    .{ 30, 24 }, // blast charge
    .{ 0, 20 }, // water column
    .{ 0, 20 },
    .{ 0, 20 },
    .{ 0, 0 },
    .{ 20, 0 }, // lightning bolt
    .{ 0, 0 },
    .{ 0, 20 }, // box
    .{ 0, 0 },
};

/// A lightning arc being drawn.
pub const Arc = struct { x0: f32, y0: f32, x1: f32, y1: f32, ttl: u32, seed: u32 };

pub const Tools = struct {
    current: Tool = .fire_bolt,
    brush: i32 = 8,
    /// Painter material (library id) and the ids it cycles through.
    paint: u8 = 0,
    paint_ids: [64]u8 = undefined,
    paint_len: u32 = 0,
    /// Ticks until the next use, per button.
    cool: [2]u32 = .{ 0, 0 },
    /// Ticks the button has been held (repeat timing).
    held: [2]u32 = .{ 0, 0 },
    cut_start: ?[2]f32 = null,
    beam_start: ?[2]f32 = null,
    last_paint: ?[2]i32 = null,
    /// Lightning bolt: ticks of charge left at its hit point.
    bolt_ticks: u32 = 0,
    bolt_at: [2]i32 = .{ 0, 0 },
    arcs: [8]Arc = undefined,
    arc_len: u32 = 0,
    uses: u32 = 0,

    pub fn setPalette(self: *Tools, ids: []const u8, first: u8) void {
        self.paint_len = @intCast(@min(ids.len, self.paint_ids.len));
        @memcpy(self.paint_ids[0..self.paint_len], ids[0..self.paint_len]);
        self.paint = first;
    }

    pub fn info(self: *const Tools) Info {
        return table[@backingInt(self.current)];
    }

    pub fn select(self: *Tools, slot: u8) void {
        if (slot >= table.len) return;
        self.current = @fromBackingInt(@intCast(slot));
        self.cut_start = null;
        self.beam_start = null;
        self.held = .{ 0, 0 };
    }

    /// Should a button fire this tick? Click tools: on press, if cooled
    /// down. Hold tools: on press and then every `every` ticks.
    pub fn trigger(self: *Tools, button: u1, down: bool, pressed: bool) bool {
        const inf = self.info();
        const every = if (button == 0) inf.primary_every else inf.secondary_every;
        if (self.cool[button] > 0) self.cool[button] -= 1;
        if (!down) {
            self.held[button] = 0;
            return false;
        }
        defer self.held[button] += 1;
        if (every == 0) {
            if (!pressed or self.cool[button] > 0) return false;
            self.cool[button] = cooldown_ticks[@backingInt(self.current)][button];
            return true;
        }
        if (self.held[button] % every != 0) return false;
        if (self.cool[button] > 0) return false;
        return true;
    }

    /// One tick of tool use.
    pub fn update(self: *Tools, ctx: *const world.Ctx, in: *const Input, p: *player_mod.Player, shots: *projectiles.Projectiles, enemies: *enemies_mod.Enemies, blasts: *projectiles.BlastList) void {
        if (in.select) |s| self.select(s);
        if (in.wheel != 0) {
            if (self.current == .painter and self.paint_len > 0) {
                var idx: i32 = 0;
                for (self.paint_ids[0..self.paint_len], 0..) |id, k| {
                    if (id == self.paint) idx = @intCast(k);
                }
                idx = @mod(idx + (if (in.wheel > 0) @as(i32, 1) else -1), @as(i32, @intCast(self.paint_len)));
                self.paint = self.paint_ids[@intCast(idx)];
            } else self.brush = std.math.clamp(self.brush + (if (in.wheel > 0) @as(i32, 1) else -1) * @max(1, @divTrunc(self.brush, 4)), 2, 48);
        }
        // Arcs fade.
        var k: u32 = 0;
        while (k < self.arc_len) {
            if (self.arcs[k].ttl <= 1) {
                self.arcs[k] = self.arcs[self.arc_len - 1];
                self.arc_len -= 1;
            } else {
                self.arcs[k].ttl -= 1;
                k += 1;
            }
        }
        // A lightning bolt keeps pulsing at its hit point for a few ticks.
        if (self.bolt_ticks > 0) {
            self.bolt_ticks -= 1;
            ctx.list.chargeCircle(self.bolt_at[0], self.bolt_at[1], 3);
        }
        const can_act = p.alive() and p.actor.status.stunned == 0;
        const prim = self.trigger(0, in.primary and can_act, in.primary_pressed);
        const sec = self.trigger(1, in.secondary and can_act, in.secondary_pressed);
        const wand = p.wand();
        const ax: i32 = @intFromFloat(@floor(in.aim[0]));
        const ay: i32 = @intFromFloat(@floor(in.aim[1]));
        const wx: i32 = @intFromFloat(@floor(wand[0]));
        const wy: i32 = @intFromFloat(@floor(wand[1]));
        const dir = [2]f32{ in.aim[0] - wand[0], in.aim[1] - wand[1] };
        const ids = ctx.ids;
        var used = prim or sec;
        switch (self.current) {
            .fire_bolt => {
                if (prim) _ = shots.fire(.fire_bolt, wand[0], wand[1], dir[0], dir[1], true);
                if (sec) ctx.list.spray(.{ .x = wx, .y = wy, .material = ids.flame, .count = 8, .speed = 210, .spread = 60, .direction = turns(dir), .cone = 0.045 });
            },
            .blast_charge => {
                if (prim) _ = shots.fire(.charge, wand[0], wand[1], dir[0], dir[1] - 0.25 * @abs(dir[0]), true);
                if (sec) {
                    projectiles.detonate(ctx, in.aim[0], in.aim[1], 10, 1.2, blasts);
                    ctx.log.add("blast at cursor {d},{d}", .{ ax, ay });
                }
            },
            .water, .lava, .acid => {
                const m = switch (self.current) {
                    .water => ids.water,
                    .lava => ids.lava,
                    else => ids.acid,
                };
                if (prim) {
                    ctx.list.spray(.{ .x = wx, .y = wy, .material = m, .count = 10, .speed = 300, .spread = 60, .direction = turns(dir), .cone = 0.03 });
                    // The water jet douses what it hits: a few water cells
                    // where its line meets the first surface, and any
                    // burning enemy in its way (decision 127).
                    if (self.current == .water and self.held[0] % 3 == 1) self.douse(ctx, wand, in.aim, enemies, &p.actor);
                }
                if (sec) {
                    if (self.current == .water) {
                        ctx.list.fillRect(ax - 6, ay - 40, ax + 6, ay, m, .{ .only_air = true });
                        if (ctx.liquid_on) ctx.list.wakeLiquid(ax, ay - 20, 26, 2);
                    } else ctx.list.fillCircle(ax, ay, 8, m, .{ .only_air = true });
                }
            },
            .dig => {
                if (prim) ctx.list.fillCircle(ax, ay, self.brush, ids.air, .{});
                if (sec) ctx.list.fillCircle(ax, ay, self.brush, ids.dirt, .{ .only_air = true });
                if ((prim or sec) and ctx.liquid_on) ctx.list.wakeLiquid(ax, ay, self.brush + 4, 2);
            },
            .lightning => {
                if (prim) {
                    const hit = self.zap(ctx, wand, in.aim, enemies, 12);
                    self.bolt_at = hit;
                    self.bolt_ticks = 10;
                    ctx.list.chargeCircle(hit[0], hit[1], 3);
                    ctx.list.igniteCircle(hit[0], hit[1], 2);
                    ctx.log.add("lightning bolt at {d},{d}", .{ hit[0], hit[1] });
                }
                if (sec) {
                    const hit = self.zap(ctx, wand, in.aim, enemies, 4);
                    // A line of charge along the arc (conductors on it pulse).
                    ctx.list.fillLine(wx, wy, hit[0], hit[1], 1, 0, .{ .action = .charge });
                    ctx.list.chargeCircle(hit[0], hit[1], 2);
                }
            },
            .cutter => {
                used = false;
                if (in.primary_pressed and can_act) self.cut_start = in.aim;
                if (in.primary_released) {
                    if (self.cut_start) |s| {
                        cut(ctx, s, in.aim);
                        used = true;
                        ctx.log.add("cut from {d:.0},{d:.0} to {d},{d}", .{ s[0], s[1], ax, ay });
                    }
                    self.cut_start = null;
                }
                if (in.secondary_pressed and can_act) {
                    if (self.beam_start) |s| {
                        if (ctx.bodies) |b| b.placeBeam(s[0], s[1], in.aim[0], in.aim[1], null, 6);
                        self.beam_start = null;
                        used = true;
                        ctx.log.add("steel beam placed", .{});
                    } else self.beam_start = in.aim;
                }
            },
            .gunpowder => {
                if (prim) ctx.list.fillCircle(ax, ay, @max(2, @divTrunc(self.brush, 2)), ids.gunpowder, .{ .only_air = true });
                if (sec) if (ctx.bodies) |b| {
                    _ = b.spawnCrate(in.aim[0], in.aim[1], 18, ids.wood) catch {};
                };
            },
            .painter => {
                if (prim or sec) {
                    const m = if (sec) ids.air else self.paint;
                    const from = self.last_paint orelse [2]i32{ ax, ay };
                    strokeLine(ctx.list, from, .{ ax, ay }, self.brush, m);
                    self.last_paint = .{ ax, ay };
                } else if (!in.primary and !in.secondary) self.last_paint = null;
            },
        }
        if (used) {
            p.cast_time = 0.25;
            self.uses += 1;
        }
    }

    fn douse(self: *Tools, ctx: *const world.Ctx, from: [2]f32, to: [2]f32, enemies: *enemies_mod.Enemies, witch: *world.Actor) void {
        _ = self;
        _ = witch;
        var dx = to[0] - from[0];
        var dy = to[1] - from[1];
        const len = @sqrt(dx * dx + dy * dy);
        const reach: f32 = 220;
        if (len > reach) {
            dx *= reach / len;
            dy *= reach / len;
        }
        const n: u32 = @intFromFloat(@max(1, @ceil(@max(@abs(dx), @abs(dy)))));
        var hit: ?[2]i32 = null;
        var prev = [2]i32{ @intFromFloat(@floor(from[0])), @intFromFloat(@floor(from[1])) };
        for (1..n + 1) |i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
            const x: i32 = @intFromFloat(@floor(from[0] + dx * t));
            const y: i32 = @intFromFloat(@floor(from[1] + dy * t));
            for (enemies.items[0..enemies.len]) |*e| {
                if (e.actor.body.overlaps(x - 2, y - 2, 5, 5)) e.actor.status.extinguish(e.actor.tuning);
            }
            if (ctx.mirror.isSolid(x, y) or ctx.mirror.isLiquid(x, y) or ctx.mirror.info(x, y) != null and (ctx.mirror.info(x, y).? & 0x2) != 0) {
                hit = prev;
                break;
            }
            prev = .{ x, y };
        }
        const h = hit orelse return;
        // Into the air, flame and smoke around a fire (not over solids).
        ctx.list.fillCircle(h[0], h[1], 4, ctx.ids.water, .{ .only_air = true, .coverage = 110 });
        ctx.list.fillCircle(h[0], h[1], 4, ctx.ids.water, .{ .only = ctx.ids.flame, .coverage = 160 });
        ctx.list.fillCircle(h[0], h[1], 4, ctx.ids.water, .{ .only = ctx.ids.smoke, .coverage = 110 });
    }

    /// Ray from the wand toward the aim (at most 320 px): the first enemy
    /// or solid/liquid cell it meets takes the arc. Enemies are shocked
    /// directly. Returns the hit point.
    fn zap(self: *Tools, ctx: *const world.Ctx, from: [2]f32, to: [2]f32, enemies: *enemies_mod.Enemies, ttl: u32) [2]i32 {
        var dx = to[0] - from[0];
        var dy = to[1] - from[1];
        const len = @sqrt(dx * dx + dy * dy);
        const max_len: f32 = 320;
        if (len > max_len) {
            dx *= max_len / len;
            dy *= max_len / len;
        }
        const n: u32 = @intFromFloat(@max(1, @ceil(@max(@abs(dx), @abs(dy)))));
        var hit = [2]i32{ @intFromFloat(@floor(from[0] + dx)), @intFromFloat(@floor(from[1] + dy)) };
        outer: for (1..n + 1) |i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
            const x: i32 = @intFromFloat(@floor(from[0] + dx * t));
            const y: i32 = @intFromFloat(@floor(from[1] + dy * t));
            for (enemies.items[0..enemies.len]) |*e| {
                if (e.actor.body.overlaps(x, y, 1, 1)) {
                    const wet = e.actor.status.wet > 0 or e.actor.liquid > 0.2;
                    e.actor.damage(e.actor.tuning.shock_damage * (if (wet) e.actor.tuning.wet_shock_factor else 1));
                    e.actor.status.stunned = @max(e.actor.status.stunned, e.actor.tuning.shock_stun);
                    e.actor.status.shocked = true;
                    hit = .{ x, y };
                    break :outer;
                }
            }
            if (ctx.mirror.isSolid(x, y) or ctx.mirror.isLiquid(x, y)) {
                hit = .{ x, y };
                break;
            }
        }
        if (self.arc_len < self.arcs.len) {
            self.arcs[self.arc_len] = .{ .x0 = from[0], .y0 = from[1], .x1 = @floatFromInt(hit[0]), .y1 = @floatFromInt(hit[1]), .ttl = ttl, .seed = ctx.tick *% 2654435761 };
            self.arc_len += 1;
        }
        return hit;
    }
};

/// Remove a thin line of cells and tell the bodies layer (cuts beams and
/// bodies, runs connectivity on what was cut loose).
pub fn cut(ctx: *const world.Ctx, a: [2]f32, b: [2]f32) void {
    var dx = b[0] - a[0];
    var dy = b[1] - a[1];
    const len = @sqrt(dx * dx + dy * dy);
    const max_len: f32 = 240;
    if (len > max_len) {
        dx *= max_len / len;
        dy *= max_len / len;
    }
    const x0: i32 = @intFromFloat(@floor(a[0]));
    const y0: i32 = @intFromFloat(@floor(a[1]));
    const x1: i32 = @intFromFloat(@floor(a[0] + dx));
    const y1: i32 = @intFromFloat(@floor(a[1] + dy));
    ctx.list.fillLine(x0, y0, x1, y1, 1, ctx.ids.air, .{});
    if (ctx.bodies) |bodies| {
        const n: i32 = @max(1, @as(i32, @intFromFloat(@min(len, max_len) / 6)));
        var i: i32 = 0;
        while (i <= n) : (i += 1) {
            bodies.notifyDestruction(x0 + @divTrunc((x1 - x0) * i, n), y0 + @divTrunc((y1 - y0) * i, n), 3);
        }
    }
}

/// Direction in turns (0 = +x, 0.25 = down) for `commands.Spray`.
pub fn turns(d: [2]f32) f32 {
    const a = std.math.atan2(d[1], d[0]) / (2 * std.math.pi);
    return if (a < 0) a + 1 else a;
}

/// Circles every radius/2 pixels from `a` to `b` (at least one).
pub fn strokeLine(list: *commands.CommandList, a: [2]i32, b: [2]i32, radius: i32, material: u8) void {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const len: i32 = @intFromFloat(@sqrt(@as(f32, @floatFromInt(dx * dx + dy * dy))));
    const step = @max(1, @divTrunc(radius, 2));
    const n = @min(@divTrunc(len, step) + 1, 32);
    var i: i32 = 0;
    while (i < n) : (i += 1) {
        const x = a[0] + if (n > 1) @divTrunc(dx * i, n - 1) else 0;
        const y = a[1] + if (n > 1) @divTrunc(dy * i, n - 1) else 0;
        list.fillCircle(x, y, radius, material, .{});
    }
}

test "click tools respect their cooldown, hold tools repeat" {
    var t: Tools = .{};
    t.select(@backingInt(Tool.fire_bolt));
    // Clicking every tick: fires on the first press, then once per 15 ticks.
    var fired: u32 = 0;
    for (0..60) |_| {
        if (t.trigger(0, true, true)) fired += 1;
    }
    try std.testing.expectEqual(@as(u32, 4), fired);
    // Holding without new presses fires nothing more.
    t = .{};
    t.select(@backingInt(Tool.fire_bolt));
    fired = 0;
    for (0..60) |i| {
        if (t.trigger(0, true, i == 0)) fired += 1;
    }
    try std.testing.expectEqual(@as(u32, 1), fired);
    // Dig repeats every 2 ticks while held.
    t.select(@backingInt(Tool.dig));
    fired = 0;
    for (0..20) |i| {
        if (t.trigger(0, true, i == 0)) fired += 1;
    }
    try std.testing.expectEqual(@as(u32, 10), fired);
    // Releasing resets the repeat phase.
    try std.testing.expect(!t.trigger(0, false, false));
    try std.testing.expect(t.trigger(0, true, true));
}

test "spray direction in turns" {
    try std.testing.expectApproxEqAbs(@as(f32, 0), turns(.{ 1, 0 }), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), turns(.{ 0, 1 }), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), turns(.{ 0, -1 }), 1e-6);
}
