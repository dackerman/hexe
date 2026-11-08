//! Per-pass GPU timing aggregation: feeds the HUD, `--profile <file>` dumps
//! and `zig build bench`. Fed once per completed frame by the engine.
const std = @import("std");
const gpu = @import("gpu/gpu.zig");
const timestamps = gpu.timestamps;
const FrameStats = @import("engine.zig").FrameStats;

/// Passes that make up "grid time" (the M2 budget).
pub const grid_passes = [_][]const u8{ "commands", "activity", "reactions", "movement" };

pub const Profile = struct {
    sum: [timestamps.max_names]f64 = @splat(0),
    min: [timestamps.max_names]f64 = @splat(std.math.inf(f64)),
    max: [timestamps.max_names]f64 = @splat(0),
    grid_sum: f64 = 0,
    grid_min: f64 = std.math.inf(f64),
    grid_max: f64 = 0,
    frames: u32 = 0,
    ticks: u64 = 0,
    active_tiles_sum: u64 = 0,
    /// Frames before this count are not aggregated (warm-up).
    skip_frames: u32 = 0,
    seen: u32 = 0,
    /// Smoothed per-name ms for display.
    smooth: [timestamps.max_names]f64 = @splat(0),
    out: ?*std.Io.Writer = null,

    pub fn record(self: *Profile, stats: *const FrameStats, names: *const timestamps.Names) void {
        for (0..names.count) |i| {
            const v = stats.timings.ms[i];
            self.smooth[i] = if (self.seen == 0) v else self.smooth[i] * 0.9 + v * 0.1;
        }
        self.seen += 1;
        if (self.out) |w| {
            for (0..names.count) |i| {
                if (stats.timings.count[i] == 0) continue;
                w.print("{d},{s},{d:.4}\n", .{ stats.first_tick, names.get(i), stats.timings.ms[i] }) catch {};
            }
            w.print("{d},active_tiles,{d}\n", .{ stats.first_tick, stats.active_tiles }) catch {};
        }
        if (self.seen <= self.skip_frames) return;
        self.frames += 1;
        self.ticks += stats.ticks;
        self.active_tiles_sum += stats.active_tiles;
        var grid: f64 = 0;
        for (0..names.count) |i| {
            const v = stats.timings.ms[i];
            self.sum[i] += v;
            self.min[i] = @min(self.min[i], v);
            self.max[i] = @max(self.max[i], v);
            for (grid_passes) |g| {
                if (std.mem.eql(u8, names.get(i), g)) grid += v;
            }
        }
        self.grid_sum += grid;
        self.grid_min = @min(self.grid_min, grid);
        self.grid_max = @max(self.grid_max, grid);
    }

    pub fn mean(self: *const Profile, i: usize) f64 {
        if (self.frames == 0) return 0;
        return self.sum[i] / @as(f64, @floatFromInt(self.frames));
    }

    pub fn gridMean(self: *const Profile) f64 {
        if (self.frames == 0) return 0;
        return self.grid_sum / @as(f64, @floatFromInt(self.frames));
    }

    /// Smoothed grid ms for the HUD.
    pub fn gridSmooth(self: *const Profile, names: *const timestamps.Names) f64 {
        var g: f64 = 0;
        for (0..names.count) |i| {
            for (grid_passes) |p| {
                if (std.mem.eql(u8, names.get(i), p)) g += self.smooth[i];
            }
        }
        return g;
    }
};
