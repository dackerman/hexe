//! Light region and radiance cascade parameters (pure, CPU side).
//!
//! The light region is the view plus a margin (so lights just off screen
//! still reach it), snapped to a world-aligned grid of the top cascade's
//! probe spacing so probes do not swim as the camera moves. Cascade i has
//! probes every `spacing << i` world pixels, 4^(i+1) directions, and the ray
//! interval [interval0 * (4^i - 1) / 3, interval0 * (4^(i+1) - 1) / 3).
//! Each interval is marched at the coarsest light-scene mip whose texel
//! keeps about `samples` steps in it (docs/decisions/102-radiance-cascades.md).
const std = @import("std");

pub const max_cascades = 6;
pub const scene_mips = 5;
/// Light scene mip 0 capacity (world pixels) and cascade-0 probe capacity.
pub const max_region = 2048;
pub const max_probes = 1536;

pub const Cascade = struct {
    t_start: f32,
    t_end: f32,
    mip: u32,
};

pub const Options = struct {
    margin: u32 = 64,
    /// Desired cascade-0 probe spacing in world pixels (power of two, 1-16);
    /// raised when the region would exceed the probe capacity.
    spacing: u32 = 2,
    /// Cascade-0 interval length in multiples of the probe spacing.
    interval_scale: f32 = 2.0,
    /// Target march steps per interval.
    samples: u32 = 16,
    /// Rays reach at least this fraction of the region diagonal.
    reach: f32 = 1.0,
};

pub const Plan = struct {
    origin: [2]i32,
    size: [2]u32,
    spacing: u32,
    shift: u32,
    probes: [2]u32,
    count: u32,
    cascades: [max_cascades]Cascade,

    /// Highest scene mip any pass reads.
    pub fn maxMip(self: *const Plan) u32 {
        var m: u32 = @max(self.shift, 1);
        for (self.cascades[0..self.count]) |c| m = @max(m, c.mip);
        return m;
    }

    /// Width and height of every cascade image used (2 * probes).
    pub fn cascadeSize(self: *const Plan) [2]u32 {
        return .{ self.probes[0] * 2, self.probes[1] * 2 };
    }
};

fn floorTo(v: i32, a: u32) i32 {
    return @divFloor(v, @as(i32, @intCast(a))) * @as(i32, @intCast(a));
}

fn ceilTo(v: i32, a: u32) i32 {
    return -floorTo(-v, a);
}

pub fn plan(view_origin: [2]i32, view_size: [2]u32, opts: Options) Plan {
    std.debug.assert(std.math.isPowerOfTwo(opts.spacing));
    var spacing: u32 = @min(opts.spacing, 16);
    var p: Plan = undefined;
    while (true) {
        const alignment = spacing << (max_cascades - 1);
        for (0..2) |a| {
            const m: i32 = @intCast(opts.margin);
            const lo = floorTo(view_origin[a] - m, alignment);
            const hi = ceilTo(view_origin[a] + @as(i32, @intCast(view_size[a])) + m, alignment);
            p.origin[a] = lo;
            p.size[a] = @min(@as(u32, @intCast(hi - lo)), max_region);
            p.probes[a] = p.size[a] / spacing;
        }
        if ((p.probes[0] <= max_probes and p.probes[1] <= max_probes) or spacing >= 16) break;
        spacing *= 2;
    }
    p.spacing = spacing;
    p.shift = std.math.log2_int(u32, spacing);
    p.probes = .{ @min(p.probes[0], max_probes), @min(p.probes[1], max_probes) };

    const interval0 = opts.interval_scale * @as(f32, @floatFromInt(spacing));
    const w: f32 = @floatFromInt(p.size[0]);
    const h: f32 = @floatFromInt(p.size[1]);
    const diag = @sqrt(w * w + h * h) * opts.reach;
    var n: u32 = 1;
    while (n < max_cascades and interval0 * (std.math.pow(f32, 4, @floatFromInt(n)) - 1) / 3 < diag) n += 1;
    p.count = n;
    var i: u32 = 0;
    while (i < max_cascades) : (i += 1) {
        const fi: f32 = @floatFromInt(i);
        const t0 = interval0 * (std.math.pow(f32, 4, fi) - 1) / 3;
        const t1 = interval0 * (std.math.pow(f32, 4, fi + 1) - 1) / 3;
        const step = (t1 - t0) / @as(f32, @floatFromInt(@max(opts.samples, 1)));
        var mip: u32 = 0;
        while (mip + 1 < scene_mips and @as(f32, @floatFromInt(@as(u32, 2) << @intCast(mip))) <= step) mip += 1;
        p.cascades[i] = .{ .t_start = t0, .t_end = t1, .mip = mip };
    }
    return p;
}

test "plan covers the view and stays aligned" {
    const p = plan(.{ 1000, 700 }, .{ 960, 540 }, .{});
    try std.testing.expectEqual(@as(u32, 2), p.spacing);
    try std.testing.expect(p.origin[0] <= 1000 - 64 and p.origin[1] <= 700 - 64);
    try std.testing.expect(p.origin[0] + @as(i32, @intCast(p.size[0])) >= 1000 + 960 + 64);
    try std.testing.expect(p.origin[1] + @as(i32, @intCast(p.size[1])) >= 700 + 540 + 64);
    try std.testing.expectEqual(@as(i32, 0), @mod(p.origin[0], 64));
    try std.testing.expectEqual(@as(u32, 0), p.size[0] % 64);
    try std.testing.expectEqual(p.size[0] / 2, p.probes[0]);
    try std.testing.expect(p.count >= 4 and p.count <= max_cascades);
    // Intervals are contiguous.
    for (1..p.count) |i| try std.testing.expectEqual(p.cascades[i - 1].t_end, p.cascades[i].t_start);
    // Moving the camera by a pixel does not move the probe grid.
    const q = plan(.{ 1001, 701 }, .{ 960, 540 }, .{});
    try std.testing.expectEqual(p.origin, q.origin);
}

test "plan raises spacing to fit the probe capacity" {
    const p = plan(.{ 0, 0 }, .{ 1920, 1080 }, .{ .spacing = 1 });
    try std.testing.expect(p.probes[0] <= max_probes and p.probes[1] <= max_probes);
    try std.testing.expectEqual(@as(u32, 2), p.spacing);
    const full = plan(.{ 0, 0 }, .{ 2048, 2048 }, .{});
    try std.testing.expect(full.size[0] <= max_region and full.probes[0] <= max_probes);
}
