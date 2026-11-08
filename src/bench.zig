//! `zig build bench`: fixed scenes headless for 300 ticks each, per-pass GPU
//! ms. Built ReleaseFast by build.zig regardless of -Doptimize.
const std = @import("std");
const builtin = @import("builtin");
const Cli = @import("main.zig").Cli;
const Engine = @import("engine.zig").Engine;
const scenes = @import("sim/scenes.zig");
const materials_builtin = @import("sim/materials_builtin.zig");
const Profile = @import("profile.zig").Profile;
const cell = @import("sim/cell.zig");

/// What the budget applies to: grid time (commands + activity + movement)
/// or the "particles" pass (M4: ballistic + spawn).
const Metric = enum { grid, particles };
const Case = struct {
    name: []const u8,
    scene: scenes.Scene,
    sleep: bool,
    budget_ms: f64,
    metric: Metric = .grid,
    /// Air field cases (M5): budget applies to air time, not grid time.
    air: bool = false,
    air_sleep: bool = true,
};

const cases = [_]Case{
    .{ .name = "static world (sleep)", .scene = .bench_static, .sleep = true, .budget_ms = 0.2 },
    .{ .name = "falling sand, fully active (sleep)", .scene = .bench_active, .sleep = true, .budget_ms = 2.5 },
    .{ .name = "falling sand, sleep disabled", .scene = .bench_active, .sleep = false, .budget_ms = 2.5 },
    .{ .name = "sand + water + smoke mixing, fully active", .scene = .bench_mixed, .sleep = true, .budget_ms = 2.5 },
    // ---- air field (M5) ----
    .{ .name = "air field, every air tile every step, explosion every 20 ticks", .scene = .bench_air, .sleep = true, .budget_ms = 1.5, .air = true, .air_sleep = false },
    .{ .name = "air field, active air tiles, explosion every 20 ticks", .scene = .bench_air, .sleep = true, .budget_ms = 1.5, .air = true },
    .{ .name = "air field, active air tiles, static world", .scene = .bench_static, .sleep = true, .budget_ms = 0.2, .air = true },
    .{ .name = "particles: 100K sand falling, no floor", .scene = .bench_particles, .sleep = true, .budget_ms = 1.0, .metric = .particles },
    .{ .name = "particles: sand rain landing on a floor", .scene = .bench_particles_rain, .sleep = true, .budget_ms = 1.0, .metric = .particles },
};

/// Passes that make up "air time" (the M5 budget): coarsening and every
/// air.* pass, gas advection included.
fn isAirPass(name: []const u8) bool {
    return std.mem.eql(u8, name, "coarsen") or std.mem.startsWith(u8, name, "air.");
}

pub fn run(gpa: std.mem.Allocator, io: std.Io, cli: Cli) !u8 {
    const table = materials_builtin.table();
    const ticks = if (cli.ticks == 0) 300 else cli.ticks;
    std.debug.print("hexe bench: {d} ticks per scene, {s} build, warm-up 10 ticks excluded\n", .{ ticks, @tagName(builtin.mode) });
    var failed = false;

    var file_buf: [64 * 1024]u8 = undefined;
    var file: ?std.Io.File = null;
    var file_writer: std.Io.File.Writer = undefined;
    if (cli.profile) |path| {
        file = try std.Io.Dir.cwd().createFile(io, path, .{});
        file_writer = file.?.writer(io, &file_buf);
        try file_writer.interface.writeAll("tick,pass,ms\n");
    }
    defer if (file) |f| {
        file_writer.interface.flush() catch {};
        f.close(io);
    };

    for (cases) |case| {
        const engine = try gpa.create(Engine);
        defer gpa.destroy(engine);
        try engine.init(gpa, .{
            .table = &table,
            .validation = cli.validation orelse false,
            .pipeline = .{ .sleep = case.sleep, .air = case.air, .air_sleep = case.air_sleep },
        });
        defer engine.deinit();
        var profile: Profile = .{ .skip_frames = 10 };
        if (file != null) {
            file_writer.interface.print("# {s}\n", .{case.name}) catch {};
            profile.out = &file_writer.interface;
        }
        engine.profile = &profile;

        const start = std.Io.Timestamp.now(io, .awake);
        var live_sum: u64 = 0;
        var live_n: u64 = 0;
        var landed: u64 = 0;
        for (0..ticks) |t| {
            try engine.frame(1, .{ .scene = case.scene, .seed = cli.seed }, null);
            if (t >= 10) {
                live_sum += engine.mirror().particles.live;
                landed += engine.mirror().particles.landed;
                live_n += 1;
            }
        }
        try engine.finish();
        const wall = @as(f64, @floatFromInt(start.untilNow(io, .awake).nanoseconds)) / 1e6;

        const grid = profile.gridMean();
        var air_ms: f64 = 0;
        for (0..engine.names.count) |i| {
            if (isAirPass(engine.names.get(i))) air_ms += profile.mean(i);
        }
        var particles_ms: f64 = 0;
        for (0..engine.names.count) |i| {
            if (std.mem.eql(u8, engine.names.get(i), "particles")) particles_ms = profile.mean(i);
        }
        const measured = if (case.air) air_ms else if (case.metric == .grid) grid else particles_ms;
        const ok = measured < case.budget_ms;
        if (!ok) failed = true;
        std.debug.print("\n== {s}  ({s}, {d} ticks, wall {d:.1} ms)\n", .{ case.name, @tagName(case.scene), ticks, wall });
        std.debug.print("  {s:<10} {s:>9} {s:>9} {s:>9}\n", .{ "pass", "mean ms", "min", "max" });
        for (0..engine.names.count) |i| {
            if (profile.sum[i] == 0 and profile.max[i] == 0) continue;
            std.debug.print("  {s:<10} {d:9.4} {d:9.4} {d:9.4}\n", .{ engine.names.get(i), profile.mean(i), profile.min[i], profile.max[i] });
        }
        const mean_tiles = @as(f64, @floatFromInt(profile.active_tiles_sum)) / @as(f64, @floatFromInt(@max(profile.frames, 1)));
        if (case.air) {
            std.debug.print("  {s:<10} {d:9.4}\n", .{ "grid", grid });
            std.debug.print("  {s:<10} {d:9.4}   budget {d:.1} ms: {s}\n", .{ "air", air_ms, case.budget_ms, if (ok) "PASS" else "FAIL" });
            std.debug.print("  air tiles active at end: {d} of {d}\n", .{ engine.pipeline.air.stats.active_tiles, cell.tile_count });
        } else if (case.metric == .grid) {
            std.debug.print("  {s:<10} {d:9.4} {d:9.4} {d:9.4}   budget {d:.1} ms: {s}\n", .{ "grid", grid, profile.grid_min, profile.grid_max, case.budget_ms, if (ok) "PASS" else "FAIL" });
        } else {
            std.debug.print("  {s:<10} {d:9.4}   budget {d:.1} ms: {s}\n", .{ "particles", particles_ms, case.budget_ms, if (ok) "PASS" else "FAIL" });
            std.debug.print("  live particles: mean {d:.0}, last {d}; landed per tick (sampled) {d:.0}\n", .{ @as(f64, @floatFromInt(live_sum)) / @as(f64, @floatFromInt(@max(live_n, 1))), engine.mirror().particles.live, @as(f64, @floatFromInt(landed)) / @as(f64, @floatFromInt(@max(live_n, 1))) });
        }
        std.debug.print("  active tiles: mean {d:.0} of {d}, last {d}\n", .{ mean_tiles, cell.tile_count, engine.last.active_tiles });
    }
    return if (failed) 1 else 0;
}
