//! The witch (docs/07-tech-demo.md "Controls", docs/decisions/122-gameplay-feel.md).
//!
//! A 8 x 27 px collision box under a 12 x 30 sprite. Runs, jumps with
//! variable height, coyote time and a jump buffer, steps up 3 px, drops
//! through thin platforms (S), swims (reduced gravity, buoyancy, strokes,
//! drag) and drowns after 5 s submerged. Contact effects, burning, shocks
//! and blasts come from `world.Actor`, shared with the enemies.
const std = @import("std");
const physics = @import("physics.zig");
const world = @import("world.zig");
const Input = @import("input.zig").Input;

pub const box_w = 8;
pub const box_h = 27;
/// Sprite offset from the box's top-left.
pub const sprite_dx = -2;
pub const sprite_dy = -3;

pub const Tuning = struct {
    /// px/s^2. Real gravity at 1 px = 5 cm is 196; 3.9x feels like a
    /// platformer (a 0.35 s rise to a 48 px apex).
    gravity: f32 = 760,
    run_speed: f32 = 120,
    ground_accel: f32 = 1500,
    air_accel: f32 = 900,
    /// Ground deceleration with no input.
    friction: f32 = 1800,
    jump_speed: f32 = 270,
    /// Velocity kept when the jump key is released while rising.
    jump_cut: f32 = 0.45,
    coyote: f32 = 0.10,
    jump_buffer: f32 = 0.12,
    terminal: f32 = 540,
    step_up: i32 = 3,
    // Liquid.
    swim_gravity: f32 = 0.25,
    /// Upward acceleration at full submersion in a buoyant liquid.
    buoyancy: f32 = 330,
    swim_accel: f32 = 700,
    swim_speed: f32 = 110,
    /// Velocity damping per second in liquid.
    liquid_drag: f32 = 4,
    liquid_terminal: f32 = 150,
    /// Seconds of fade before respawning.
    respawn_delay: f32 = 1.5,
};

pub const Player = struct {
    actor: world.Actor,
    tun: Tuning = .{},
    spawn: [2]f32 = .{ 0, 0 },
    grounded: bool = false,
    coyote: f32 = 0,
    buffer: f32 = 0,
    /// Rising from a jump (variable height cut applies once).
    jumping: bool = false,
    /// Ticks left dropping through a platform, and its top row.
    drop_ticks: u32 = 0,
    drop_y: i32 = 0,
    /// Animation.
    walk_time: f32 = 0,
    cast_time: f32 = 0,
    dead_time: f32 = 0,
    deaths: u32 = 0,

    pub fn init(x: f32, y: f32) Player {
        var p: Player = .{ .actor = .{ .body = .{ .x = 0, .y = 0, .w = box_w, .h = box_h }, .health = 100, .max_health = 100 } };
        p.spawnAt(x, y);
        return p;
    }

    /// Put the witch with her feet at (x, y), alive and unhurt.
    pub fn spawnAt(self: *Player, x: f32, y: f32) void {
        self.spawn = .{ x, y };
        self.actor = .{ .body = .{ .x = 0, .y = 0, .w = box_w, .h = box_h }, .health = 100, .max_health = 100 };
        self.actor.body.setCenter(x, y - box_h * 0.5);
        self.grounded = false;
        self.coyote = 0;
        self.buffer = 0;
        self.jumping = false;
        self.dead_time = 0;
        self.cast_time = 0;
        self.drop_ticks = 0;
    }

    pub fn feet(self: *const Player) [2]f32 {
        return .{ self.actor.cx(), @floatFromInt(self.actor.body.y + self.actor.body.h) };
    }

    /// The wand tip, where spells leave from.
    pub fn wand(self: *const Player) [2]f32 {
        const b = self.actor.body;
        return .{ self.actor.cx() + self.actor.facing * 6, @as(f32, @floatFromInt(b.y)) + 11 };
    }

    pub fn alive(self: *const Player) bool {
        return self.actor.alive;
    }

    /// One tick. Returns true when the witch died this tick.
    pub fn update(self: *Player, ctx: *const world.Ctx, in: *const Input) bool {
        const dt = world.dt;
        const a = &self.actor;
        if (!a.alive) {
            self.dead_time += dt;
            if (self.dead_time >= self.tun.respawn_delay) {
                self.spawnAt(self.spawn[0], self.spawn[1]);
                ctx.log.add("witch respawned", .{});
            }
            return false;
        }
        a.hurt_flash = @max(0, a.hurt_flash - dt);
        self.cast_time = @max(0, self.cast_time - dt);
        var w = a.world(ctx);
        if (self.drop_ticks > 0) {
            self.drop_ticks -= 1;
            w.ignore_y0 = self.drop_y;
            w.ignore_y1 = self.drop_y + 3;
        }
        a.stuck = !physics.pushOut(&w, &a.body, 10);
        a.scan(ctx, &w);
        _ = a.applyStatus(ctx);
        a.blast(ctx);

        const b = &a.body;
        const t = self.tun;
        const swimming = a.liquid > 0.35;
        const stunned = a.status.stunned > 0;
        const slow = a.touch.slow;
        const slippery = a.touch.slippery or a.status.oily > 0;

        // Facing follows the aim.
        a.facing = if (in.aim[0] < a.cx()) -1 else 1;

        // ---- horizontal ----
        var dir: f32 = 0;
        if (!stunned) {
            if (in.left) dir -= 1;
            if (in.right) dir += 1;
        }
        const max_speed = (if (swimming) t.swim_speed else t.run_speed) * (1 - slow);
        const target = dir * max_speed;
        var accel = if (self.grounded) t.ground_accel else t.air_accel;
        if (dir == 0 and self.grounded) accel = t.friction;
        // Thrown by a blast: little control until it wears off.
        a.knock = @max(0, a.knock - dt);
        if (a.knock > 0) accel *= 0.15;
        if (slippery and self.grounded) accel *= 0.2;
        b.vx = approach(b.vx, target, accel * dt);

        // ---- jump, swim ----
        self.buffer = if (in.jump_pressed and !stunned) t.jump_buffer else @max(0, self.buffer - dt);
        self.coyote = if (self.grounded) t.coyote else @max(0, self.coyote - dt);
        if (swimming) {
            var sy: f32 = 0;
            if (!stunned and (in.jump or in.up)) sy -= 1;
            if (!stunned and in.down) sy += 1;
            swim(b, a.liquid, a.touch.buoyant or !a.touch.known, sy, t);
            // Leaping out at the surface.
            if (self.buffer > 0 and !a.touch.head_drown and a.liquid < 0.8) {
                b.vy = -t.jump_speed * 0.85;
                self.buffer = 0;
                self.jumping = true;
            }
        } else {
            if (self.buffer > 0 and self.coyote > 0) {
                b.vy = -t.jump_speed;
                self.buffer = 0;
                self.coyote = 0;
                self.jumping = true;
            }
            if (self.jumping and !in.jump and b.vy < 0) {
                b.vy *= t.jump_cut;
                self.jumping = false;
            }
            if (b.vy >= 0) self.jumping = false;
            b.vy = @min(b.vy + t.gravity * dt, t.terminal);
        }

        // ---- drop through a thin platform ----
        if (in.down_pressed and self.grounded and !stunned and thinBelow(&w, b.*)) {
            self.drop_y = b.y + b.h;
            self.drop_ticks = 10;
            w.ignore_y0 = self.drop_y;
            w.ignore_y1 = self.drop_y + 3;
            b.vy = @max(b.vy, 60);
        }

        // ---- move ----
        const r = physics.move(&w, b, dt, .{ .step_up = t.step_up, .snap_down = self.grounded and !self.jumping });
        _ = r;
        self.grounded = physics.grounded(&w, b.*);
        if (self.grounded and @abs(b.vx) > 8) self.walk_time += dt else self.walk_time = 0;

        if (!a.alive) {
            self.deaths += 1;
            self.dead_time = 0;
            ctx.log.add("witch died ({s})", .{causeOf(a)});
            const fx: i32 = @intFromFloat(a.cx());
            const fy: i32 = @intFromFloat(a.cy());
            ctx.list.spray(.{ .x = fx, .y = fy, .material = ctx.ids.blood, .count = 40, .speed = 140, .spread = 80, .direction = 0.75, .cone = 0.3 });
            return true;
        }
        return false;
    }
};

/// One tick of swimming: reduced gravity, buoyancy in proportion to the
/// submerged fraction, strokes (`stroke` -1 up, +1 down), drag, a lower
/// terminal speed.
pub fn swim(b: *physics.Body, submerged: f32, buoyant: bool, stroke: f32, t: Tuning) void {
    const dt = world.dt;
    b.vy += (t.gravity * t.swim_gravity - (if (buoyant) t.buoyancy * submerged else 0)) * dt;
    b.vy += stroke * t.swim_accel * dt;
    const drag = @exp(-t.liquid_drag * dt);
    b.vx *= drag;
    b.vy *= drag;
    b.vy = std.math.clamp(b.vy, -t.liquid_terminal * 1.6, t.liquid_terminal);
}

pub fn causeOf(a: *const world.Actor) []const u8 {
    if (a.status.breath == 0) return "drowned";
    if (a.touch.burn > 0) return "burnt";
    if (a.status.burning > 0) return "burning";
    if (a.touch.corrode > 0) return "corroded";
    if (a.status.shocked) return "electrocuted";
    return "hit";
}

/// The ground under the box is at most 3 px thick with air below it.
fn thinBelow(w: anytype, b: physics.Body) bool {
    var x = b.x;
    while (x < b.x + b.w) : (x += 1) {
        var depth: i32 = 0;
        while (depth < 5 and w.solid(x, b.y + b.h + depth)) depth += 1;
        if (depth > 3) return false;
    }
    return true;
}

pub fn approach(v: f32, target: f32, step: f32) f32 {
    if (v < target) return @min(v + step, target);
    return @max(v - step, target);
}

// ---------------------------------------------------------------- tests

const TestWorld = physics.TestWorld;

test "jump feel: apex height, and landing back on the ground" {
    // Ground at row 100; open above.
    var rows: [104][]const u8 = undefined;
    const open: [200]u8 = @splat('.');
    const floor: [200]u8 = @splat('#');
    for (&rows, 0..) |*r, i| r.* = if (i >= 100) &floor else &open;
    const w: TestWorld = .{ .rows = &rows };
    var b: physics.Body = .{ .x = 20, .y = 100 - box_h, .w = box_w, .h = box_h };
    const t: Tuning = .{};
    // Jump: integrate as Player.update does, holding the key.
    b.vy = -t.jump_speed;
    var apex: i32 = b.y;
    for (0..120) |_| {
        b.vy = @min(b.vy + t.gravity * world.dt, t.terminal);
        _ = physics.move(w, &b, world.dt, .{ .step_up = t.step_up });
        apex = @min(apex, b.y);
    }
    const height = (100 - box_h) - apex;
    if (height < 42 or height > 52) std.debug.print("jump apex {d} px\n", .{height});
    try std.testing.expect(height >= 42 and height <= 52);
    try std.testing.expect(physics.grounded(w, b));
}

test "swimming: a still witch floats up, strokes dive, speed stays bounded" {
    const t: Tuning = .{};
    // Fully submerged, no input: buoyancy beats the reduced gravity.
    var b: physics.Body = .{ .x = 0, .y = 0, .w = box_w, .h = box_h, .vy = 200 };
    for (0..120) |_| swim(&b, 1.0, true, 0, t);
    try std.testing.expect(b.vy < 0);
    try std.testing.expect(b.vy > -t.liquid_terminal * 1.6 - 0.01);
    // Diving (S) sinks against buoyancy.
    var d: physics.Body = .{ .x = 0, .y = 0, .w = box_w, .h = box_h };
    for (0..120) |_| swim(&d, 1.0, true, 1, t);
    try std.testing.expect(d.vy > 0 and d.vy <= t.liquid_terminal);
    // A non-buoyant liquid (lava, mud) lets her sink slowly.
    var s: physics.Body = .{ .x = 0, .y = 0, .w = box_w, .h = box_h };
    for (0..120) |_| swim(&s, 1.0, false, 0, t);
    try std.testing.expect(s.vy > 0 and s.vy < t.gravity * 0.5);
    // Drag: horizontal speed bleeds off.
    var h: physics.Body = .{ .x = 0, .y = 0, .w = box_w, .h = box_h, .vx = 200 };
    for (0..60) |_| swim(&h, 1.0, true, 0, t);
    try std.testing.expect(h.vx < 200 * 0.1);
}

test "swimming against a pool: the witch surfaces and stays in the box" {
    // A 30 px deep pool walled by '#'; the liquid fraction comes from the rows.
    var rows: [70][]const u8 = undefined;
    const air: [40]u8 = blk: {
        var r: [40]u8 = @splat('.');
        r[0] = '#';
        r[39] = '#';
        break :blk r;
    };
    const floor: [40]u8 = @splat('#');
    for (&rows, 0..) |*r, i| r.* = if (i >= 66) &floor else &air;
    const w: physics.TestWorld = .{ .rows = &rows };
    const surface: i32 = 36; // water from row 36 down
    var b: physics.Body = .{ .x = 10, .y = 38, .w = box_w, .h = box_h };
    const t: Tuning = .{};
    for (0..240) |_| {
        const top = b.y;
        const wet_rows = std.math.clamp(b.y + b.h - surface, 0, b.h);
        _ = top;
        const frac = @as(f32, @floatFromInt(wet_rows)) / @as(f32, @floatFromInt(b.h));
        if (frac > 0.35) swim(&b, frac, true, 0, t) else b.vy = @min(b.vy + t.gravity * world.dt, t.terminal);
        _ = physics.move(w, &b, world.dt, .{ .step_up = t.step_up });
    }
    // Floats with its head out: bobbing around the surface.
    try std.testing.expect(b.y < surface);
    try std.testing.expect(b.y + b.h > surface);
}
