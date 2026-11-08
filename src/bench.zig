//! `zig build bench`: fixed scenes headless for 300 ticks each, per-pass GPU
//! ms. Built ReleaseFast by build.zig regardless of -Doptimize.
const std = @import("std");
const builtin = @import("builtin");
const Cli = @import("main.zig").Cli;
const Engine = @import("engine.zig").Engine;
const scenes = @import("sim/scenes.zig");
const materials = @import("sim/materials.zig");
const Profile = @import("profile.zig").Profile;
const cell = @import("sim/cell.zig");

const Case = struct { name: []const u8, scene: scenes.Scene, sleep: bool, budget_ms: f64 };

const cases = [_]Case{
    .{ .name = "static world (sleep)", .scene = .bench_static, .sleep = true, .budget_ms = 0.2 },
    .{ .name = "falling sand, fully active (sleep)", .scene = .bench_active, .sleep = true, .budget_ms = 2.5 },
    .{ .name = "falling sand, sleep disabled", .scene = .bench_active, .sleep = false, .budget_ms = 2.5 },
    .{ .name = "sand + water + smoke mixing, fully active", .scene = .bench_mixed, .sleep = true, .budget_ms = 2.5 },
};

pub fn run(gpa: std.mem.Allocator, io: std.Io, cli: Cli, lib: *const materials.Library) !u8 {
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
            .tables = lib.tables,
            .ids = lib.ids(),
            .validation = cli.validation orelse false,
            .pipeline = .{ .sleep = case.sleep },
        });
        defer engine.deinit();
        var profile: Profile = .{ .skip_frames = 10 };
        if (file != null) {
            file_writer.interface.print("# {s}\n", .{case.name}) catch {};
            profile.out = &file_writer.interface;
        }
        engine.profile = &profile;

        const start = std.Io.Timestamp.now(io, .awake);
        for (0..ticks) |_| try engine.frame(1, .{ .scene = case.scene, .seed = cli.seed }, null);
        try engine.finish();
        const wall = @as(f64, @floatFromInt(start.untilNow(io, .awake).nanoseconds)) / 1e6;

        const grid = profile.gridMean();
        const ok = grid < case.budget_ms;
        if (!ok) failed = true;
        std.debug.print("\n== {s}  ({s}, {d} ticks, wall {d:.1} ms)\n", .{ case.name, @tagName(case.scene), ticks, wall });
        std.debug.print("  {s:<10} {s:>9} {s:>9} {s:>9}\n", .{ "pass", "mean ms", "min", "max" });
        for (0..engine.names.count) |i| {
            if (profile.sum[i] == 0 and profile.max[i] == 0) continue;
            std.debug.print("  {s:<10} {d:9.4} {d:9.4} {d:9.4}\n", .{ engine.names.get(i), profile.mean(i), profile.min[i], profile.max[i] });
        }
        const mean_tiles = @as(f64, @floatFromInt(profile.active_tiles_sum)) / @as(f64, @floatFromInt(@max(profile.frames, 1)));
        std.debug.print("  {s:<10} {d:9.4} {d:9.4} {d:9.4}   budget {d:.1} ms: {s}\n", .{ "grid", grid, profile.grid_min, profile.grid_max, case.budget_ms, if (ok) "PASS" else "FAIL" });
        std.debug.print("  active tiles: mean {d:.0} of {d}, last {d}\n", .{ mean_tiles, cell.tile_count, engine.last.active_tiles });
    }
    return if (failed) 1 else 0;
}
