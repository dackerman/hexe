//! Pixel-perfect AABB movement against the world's solid cells
//! (docs/decisions/121-gameplay-collision.md).
//!
//! An entity is an axis-aligned box of whole pixels with a sub-pixel
//! remainder. Each tick it moves along x, then along y, one pixel at a time;
//! a pixel step into a solid cell stops that axis. Walking (x) may climb a
//! step of up to `step_up` pixels (slopes and rubble), and walking off a
//! slope snaps down by as much so the entity does not hop down stairs.
//! Terrain changes under the entity (a sand pour, a slab, a body moving into
//! it) can leave it embedded: `pushOut` searches the nearest free position
//! and never fails hard; a fully buried entity just stays where it is.
//!
//! The world is any value with `fn solid(self, x: i32, y: i32) bool`
//! (`MirrorWorld` in game.zig for the readback mirror, a bitmap in tests).
const std = @import("std");

pub const Body = struct {
    /// Top-left pixel of the box (world pixels, unwrapped).
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    /// Sub-pixel remainder of the position, in (-1, 1).
    rx: f32 = 0,
    ry: f32 = 0,
    /// Velocity, pixels per second.
    vx: f32 = 0,
    vy: f32 = 0,

    pub fn centerX(self: Body) f32 {
        return @as(f32, @floatFromInt(self.x)) + self.rx + @as(f32, @floatFromInt(self.w)) * 0.5;
    }
    pub fn centerY(self: Body) f32 {
        return @as(f32, @floatFromInt(self.y)) + self.ry + @as(f32, @floatFromInt(self.h)) * 0.5;
    }
    pub fn setCenter(self: *Body, cx: f32, cy: f32) void {
        const fx = cx - @as(f32, @floatFromInt(self.w)) * 0.5;
        const fy = cy - @as(f32, @floatFromInt(self.h)) * 0.5;
        self.x = @intFromFloat(@floor(fx));
        self.y = @intFromFloat(@floor(fy));
        self.rx = 0;
        self.ry = 0;
    }
    /// Does the box overlap the (x, y, w, h) rectangle?
    pub fn overlaps(self: Body, x: i32, y: i32, w: i32, h: i32) bool {
        return self.x < x + w and x < self.x + self.w and self.y < y + h and y < self.y + self.h;
    }
};

/// Every cell of the box at (x, y) is free.
pub fn boxFree(world: anytype, x: i32, y: i32, w: i32, h: i32) bool {
    var j: i32 = 0;
    while (j < h) : (j += 1) {
        var i: i32 = 0;
        while (i < w) : (i += 1) if (world.solid(x + i, y + j)) return false;
    }
    return true;
}

fn columnFree(world: anytype, x: i32, y: i32, h: i32) bool {
    var j: i32 = 0;
    while (j < h) : (j += 1) if (world.solid(x, y + j)) return false;
    return true;
}

fn rowFree(world: anytype, x: i32, y: i32, w: i32) bool {
    var i: i32 = 0;
    while (i < w) : (i += 1) if (world.solid(x + i, y)) return false;
    return true;
}

/// Solid ground directly under the box.
pub fn grounded(world: anytype, b: Body) bool {
    return !rowFree(world, b.x, b.y + b.h, b.w);
}

pub const Options = struct {
    /// Highest step climbed while walking (0 = none).
    step_up: i32 = 0,
    /// Snap down onto ground up to `step_up` below after walking (only when
    /// the entity was on the ground and is not moving up).
    snap_down: bool = false,
    /// Most pixel steps per axis per call (tunnelling guard for huge
    /// velocities; the rest of the motion is dropped).
    max_steps: i32 = 64,
};

pub const Result = struct {
    hit_x: bool = false,
    hit_y: bool = false,
    /// Pixels climbed by steps this move.
    stepped: i32 = 0,
    /// The y move stopped on ground (moving down).
    landed: bool = false,
    /// The y move stopped against a ceiling (moving up).
    bumped: bool = false,
};

/// Move by the velocity over `dt` seconds: x first (with steps), then y.
/// A blocked axis zeroes its velocity and remainder.
pub fn move(world: anytype, b: *Body, dt: f32, opts: Options) Result {
    var r: Result = .{};
    const was_grounded = grounded(world, b.*);
    // ---- x ----
    b.rx += b.vx * dt;
    var nx: i32 = @intFromFloat(@trunc(b.rx));
    b.rx -= @floatFromInt(nx);
    nx = std.math.clamp(nx, -opts.max_steps, opts.max_steps);
    const sx: i32 = if (nx > 0) 1 else -1;
    while (nx != 0) : (nx -= sx) {
        const edge = if (sx > 0) b.x + b.w else b.x - 1;
        if (columnFree(world, edge, b.y, b.h)) {
            b.x += sx;
            continue;
        }
        // Try to climb.
        var climbed = false;
        var up: i32 = 1;
        while (up <= opts.step_up) : (up += 1) {
            if (boxFree(world, b.x + sx, b.y - up, b.w, b.h)) {
                b.x += sx;
                b.y -= up;
                r.stepped += up;
                climbed = true;
                break;
            }
        }
        if (!climbed) {
            r.hit_x = true;
            b.vx = 0;
            b.rx = 0;
            break;
        }
    }
    // Slope descent.
    if (opts.snap_down and was_grounded and b.vy >= 0 and !grounded(world, b.*)) {
        var d: i32 = 1;
        while (d <= opts.step_up) : (d += 1) {
            if (!rowFree(world, b.x, b.y + b.h + d, b.w)) {
                if (boxFree(world, b.x, b.y + d, b.w, b.h)) b.y += d;
                break;
            }
        }
    }
    // ---- y ----
    // Resting on ground: no fall speed builds up between pixel steps.
    if (b.vy > 0 and !rowFree(world, b.x, b.y + b.h, b.w)) {
        b.vy = 0;
        b.ry = 0;
        r.landed = true;
    }
    b.ry += b.vy * dt;
    var ny: i32 = @intFromFloat(@trunc(b.ry));
    b.ry -= @floatFromInt(ny);
    ny = std.math.clamp(ny, -opts.max_steps, opts.max_steps);
    const sy: i32 = if (ny > 0) 1 else -1;
    while (ny != 0) : (ny -= sy) {
        const edge = if (sy > 0) b.y + b.h else b.y - 1;
        if (rowFree(world, b.x, edge, b.w)) {
            b.y += sy;
            continue;
        }
        r.hit_y = true;
        if (sy > 0) r.landed = true else r.bumped = true;
        b.vy = 0;
        b.ry = 0;
        break;
    }
    return r;
}

/// If the box overlaps solid cells, move it to the nearest free position
/// within `max` pixels (up first, then sideways, then down, then the
/// diagonals). Returns false when it stays embedded (no position found).
pub fn pushOut(world: anytype, b: *Body, max: i32) bool {
    if (boxFree(world, b.x, b.y, b.w, b.h)) return true;
    var d: i32 = 1;
    while (d <= max) : (d += 1) {
        const offsets = [_][2]i32{ .{ 0, -d }, .{ -d, 0 }, .{ d, 0 }, .{ 0, d }, .{ -d, -d }, .{ d, -d }, .{ -d, d }, .{ d, d } };
        for (offsets) |o| {
            if (boxFree(world, b.x + o[0], b.y + o[1], b.w, b.h)) {
                b.x += o[0];
                b.y += o[1];
                if (o[0] != 0) {
                    b.vx = 0;
                    b.rx = 0;
                }
                if (o[1] != 0) {
                    b.vy = @min(b.vy, 0);
                    b.ry = 0;
                }
                return true;
            }
        }
    }
    return false;
}

/// Is any cell on the segment (x0, y0)-(x1, y1) solid? Integer DDA, both
/// ends included.
pub fn rayBlocked(world: anytype, x0: i32, y0: i32, x1: i32, y1: i32) bool {
    return rayHit(world, x0, y0, x1, y1) != null;
}

/// First solid cell on the segment from (x0, y0) to (x1, y1), with the
/// last free cell before it.
pub fn rayHit(world: anytype, x0: i32, y0: i32, x1: i32, y1: i32) ?struct { hit: [2]i32, before: [2]i32 } {
    const dx: f32 = @floatFromInt(x1 - x0);
    const dy: f32 = @floatFromInt(y1 - y0);
    const n: i32 = @intCast(@max(@abs(x1 - x0), @abs(y1 - y0)));
    const inv: f32 = if (n == 0) 0 else 1.0 / @as(f32, @floatFromInt(n));
    var prev = [2]i32{ x0, y0 };
    var i: i32 = 0;
    while (i <= n) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) * inv;
        const x = x0 + @as(i32, @intFromFloat(@round(dx * t)));
        const y = y0 + @as(i32, @intFromFloat(@round(dy * t)));
        if (world.solid(x, y)) return .{ .hit = .{ x, y }, .before = prev };
        prev = .{ x, y };
    }
    return null;
}

// ---------------------------------------------------------------- tests

/// A small bitmap world for tests: '#' solid, anything else free; outside
/// the bitmap is solid.
pub const TestWorld = struct {
    rows: []const []const u8,

    pub fn solid(self: TestWorld, x: i32, y: i32) bool {
        if (y < 0 or y >= self.rows.len) return true;
        const row = self.rows[@intCast(y)];
        if (x < 0 or x >= row.len) return true;
        return row[@intCast(x)] == '#';
    }
};

test "falls, lands and stays on the floor" {
    const w: TestWorld = .{ .rows = &.{
        "..........",
        "..........",
        "..........",
        "..........",
        "..........",
        "##########",
    } };
    var b: Body = .{ .x = 2, .y = 0, .w = 2, .h = 2 };
    b.vy = 600; // 10 px per tick, more than the gap
    const r = move(w, &b, 1.0 / 60.0, .{});
    try std.testing.expect(r.landed);
    try std.testing.expectEqual(@as(i32, 3), b.y);
    try std.testing.expectEqual(@as(f32, 0), b.vy);
    try std.testing.expect(grounded(w, b));
}

test "walking climbs steps up to step_up and stops at walls" {
    const w: TestWorld = .{ .rows = &.{
        "............",
        "............",
        "........####",
        "......######",
        "....########",
        "############",
    } };
    // 2 px steps: climbs with step_up 3.
    var b: Body = .{ .x = 0, .y = 3, .w = 2, .h = 2, .vx = 60 * 6 };
    var r = move(w, &b, 1.0 / 60.0, .{ .step_up = 3 });
    try std.testing.expect(!r.hit_x);
    try std.testing.expectEqual(@as(i32, 6), b.x);
    try std.testing.expectEqual(@as(i32, 1), b.y);
    try std.testing.expectEqual(@as(i32, 2), r.stepped);
    // Without step-up the first step blocks.
    var c: Body = .{ .x = 0, .y = 3, .w = 2, .h = 2, .vx = 60 * 6 };
    r = move(w, &c, 1.0 / 60.0, .{});
    try std.testing.expect(r.hit_x);
    try std.testing.expectEqual(@as(i32, 2), c.x);
    try std.testing.expectEqual(@as(f32, 0), c.vx);
}

test "walking down a slope snaps to the ground" {
    const w: TestWorld = .{ .rows = &.{
        "............",
        "............",
        "####........",
        "######......",
        "########....",
        "############",
    } };
    var b: Body = .{ .x = 2, .y = 0, .w = 2, .h = 2, .vx = 60 * 6 };
    _ = move(w, &b, 1.0 / 60.0, .{ .step_up = 3, .snap_down = true });
    try std.testing.expectEqual(@as(i32, 8), b.x);
    try std.testing.expect(grounded(w, b));
    try std.testing.expectEqual(@as(i32, 3), b.y);
}

test "push-out from terrain that appeared inside the box" {
    const w: TestWorld = .{ .rows = &.{
        "..........",
        "..........",
        "..........",
        "..........",
        "...####...",
        "##########",
    } };
    // Embedded in the lump: pushed up onto it.
    var b: Body = .{ .x = 4, .y = 3, .w = 2, .h = 2, .vy = 100 };
    try std.testing.expect(pushOut(w, &b, 4));
    try std.testing.expectEqual(@as(i32, 2), b.y);
    try std.testing.expectEqual(@as(i32, 4), b.x);
    try std.testing.expectEqual(@as(f32, 0), b.vy);
    // Completely buried with no free spot in range: stays, reports false.
    const solid_world: TestWorld = .{ .rows = &.{ "####", "####", "####" } };
    var c: Body = .{ .x = 1, .y = 1, .w = 2, .h = 1 };
    try std.testing.expect(!pushOut(solid_world, &c, 3));
    try std.testing.expectEqual(@as(i32, 1), c.x);
}

test "ray hits the first solid cell" {
    const w: TestWorld = .{ .rows = &.{
        "..........",
        ".....#....",
        "..........",
    } };
    const h = rayHit(w, 0, 1, 9, 1).?;
    try std.testing.expectEqual([2]i32{ 5, 1 }, h.hit);
    try std.testing.expectEqual([2]i32{ 4, 1 }, h.before);
    try std.testing.expect(!rayBlocked(w, 0, 0, 9, 0));
}
