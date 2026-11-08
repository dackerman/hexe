//! hexe entry point: argument parsing and mode dispatch.
//!
//!   hexe                                   windowed sandbox
//!   hexe --headless --ticks N [--screenshot out.png] [--crop x,y,w,h]
//!        [--scene name] [--seed n] [--profile out.csv] [--no-sleep]
//!   hexe --headless --bench                (zig build bench)
//!   hexe --headless --verify-determinism   (zig build verify-determinism)
//!   hexe --headless --gpu-tests            (zig build gpu-test)
const std = @import("std");
const builtin = @import("builtin");
const Engine = @import("engine.zig").Engine;
const Crop = @import("engine.zig").Crop;
const scenes = @import("sim/scenes.zig");
const materials_builtin = @import("sim/materials_builtin.zig");
const Profile = @import("profile.zig").Profile;
const app = @import("app.zig");
const cell = @import("sim/cell.zig");
const View = @import("render/world.zig").View;
const bench = @import("bench.zig");
const verify = @import("verify.zig");
const gpu_tests = @import("gpu_tests.zig");

pub const std_options: std.Options = .{
    .log_level = if (builtin.mode == .debug) .info else .info,
};

pub const Cli = struct {
    headless: bool = false,
    ticks: u32 = 300,
    screenshot: ?[]const u8 = null,
    crop: ?Crop = null,
    profile: ?[]const u8 = null,
    scene: scenes.Scene = .sandbox,
    seed: u32 = 1,
    sleep: bool = true,
    vsync: bool = true,
    validation: ?bool = null,
    bench: bool = false,
    verify: bool = false,
    gpu_tests: bool = false,
    width: u32 = 1600,
    height: u32 = 900,
    /// Headless: also write the window view (camera, zoom, HUD) as PNG.
    view_screenshot: ?[]const u8 = null,
    zoom: u32 = 2,
    /// World pixel at the center of the view (default: world center).
    center: ?[2]i32 = null,
};

fn usage() void {
    std.debug.print(
        \\usage: hexe [options]
        \\  --headless              no window, no swapchain
        \\  --ticks N               ticks to run headless (default 300)
        \\  --screenshot PATH       write the world as PNG after the run
        \\  --crop X,Y,W,H          crop the screenshot (world pixels)
        \\  --view-screenshot PATH  headless: write the window view with HUD (--size, --zoom, --center)
        \\  --zoom N                integer zoom (default 2)
        \\  --center X,Y            world pixel at the view center
        \\  --scene NAME            empty|sandbox|determinism|bench_static|bench_active|bench_mixed|noise
        \\                          particles_demo|bench_particles|bench_particles_rain|determinism_commands
        \\  --seed N                scene seed (default 1)
        \\  --profile PATH          per-tick per-pass GPU ms as CSV (tick,pass,ms)
        \\  --no-sleep              disable activity tiles (simulate every tile)
        \\  --no-vsync              present without vsync (windowed)
        \\  --validation / --no-validation
        \\  --size WxH              window size (default 1600x900)
        \\  --bench                 run the benchmark scenes (with --headless)
        \\  --verify-determinism    CPU reference vs GPU, bit for bit
        \\  --gpu-tests             particle, readback mirror and event queue tests on the GPU
        \\
    , .{});
}

fn parseCli(args: []const [:0]const u8) !Cli {
    var cli: Cli = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const next = struct {
            fn f(list: []const [:0]const u8, idx: *usize) ![]const u8 {
                idx.* += 1;
                if (idx.* >= list.len) return error.MissingArgument;
                return list[idx.*];
            }
        }.f;
        if (std.mem.eql(u8, a, "--headless")) {
            cli.headless = true;
        } else if (std.mem.eql(u8, a, "--ticks")) {
            cli.ticks = try std.fmt.parseInt(u32, try next(args, &i), 10);
        } else if (std.mem.eql(u8, a, "--screenshot")) {
            cli.screenshot = try next(args, &i);
        } else if (std.mem.eql(u8, a, "--crop")) {
            var it = std.mem.splitScalar(u8, try next(args, &i), ',');
            var v: [4]u32 = undefined;
            for (&v) |*x| x.* = try std.fmt.parseInt(u32, it.next() orelse return error.BadCrop, 10);
            cli.crop = .{ .x = v[0], .y = v[1], .w = v[2], .h = v[3] };
        } else if (std.mem.eql(u8, a, "--view-screenshot")) {
            cli.view_screenshot = try next(args, &i);
        } else if (std.mem.eql(u8, a, "--zoom")) {
            cli.zoom = std.math.clamp(try std.fmt.parseInt(u32, try next(args, &i), 10), 1, 16);
        } else if (std.mem.eql(u8, a, "--center")) {
            var it = std.mem.splitScalar(u8, try next(args, &i), ',');
            const x = try std.fmt.parseInt(i32, it.next() orelse return error.BadCenter, 10);
            const y = try std.fmt.parseInt(i32, it.next() orelse return error.BadCenter, 10);
            cli.center = .{ x, y };
        } else if (std.mem.eql(u8, a, "--profile")) {
            cli.profile = try next(args, &i);
        } else if (std.mem.eql(u8, a, "--scene")) {
            cli.scene = std.meta.stringToEnum(scenes.Scene, try next(args, &i)) orelse return error.UnknownScene;
        } else if (std.mem.eql(u8, a, "--seed")) {
            cli.seed = try std.fmt.parseInt(u32, try next(args, &i), 10);
        } else if (std.mem.eql(u8, a, "--no-sleep")) {
            cli.sleep = false;
        } else if (std.mem.eql(u8, a, "--no-vsync")) {
            cli.vsync = false;
        } else if (std.mem.eql(u8, a, "--validation")) {
            cli.validation = true;
        } else if (std.mem.eql(u8, a, "--no-validation")) {
            cli.validation = false;
        } else if (std.mem.eql(u8, a, "--size")) {
            const s = try next(args, &i);
            const x = std.mem.indexOfScalar(u8, s, 'x') orelse return error.BadSize;
            cli.width = try std.fmt.parseInt(u32, s[0..x], 10);
            cli.height = try std.fmt.parseInt(u32, s[x + 1 ..], 10);
        } else if (std.mem.eql(u8, a, "--bench")) {
            cli.bench = true;
        } else if (std.mem.eql(u8, a, "--verify-determinism")) {
            cli.verify = true;
        } else if (std.mem.eql(u8, a, "--gpu-tests")) {
            cli.gpu_tests = true;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            usage();
            std.process.exit(0);
        } else {
            std.debug.print("unknown argument: {s}\n", .{a});
            usage();
            return error.BadArgument;
        }
    }
    return cli;
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const cli = parseCli(args) catch return 2;

    if (cli.verify) return verify.run(gpa, io, cli);
    if (cli.gpu_tests) return gpu_tests.run(gpa, io, cli);
    if (cli.bench) return bench.run(gpa, io, cli);
    if (!cli.headless) return app.run(gpa, io, cli);
    return runHeadless(gpa, io, cli);
}

fn runHeadless(gpa: std.mem.Allocator, io: std.Io, cli: Cli) !u8 {
    const table = materials_builtin.table();
    const engine = try gpa.create(Engine);
    defer gpa.destroy(engine);
    try engine.init(gpa, .{
        .table = &table,
        .validation = cli.validation orelse (builtin.mode == .debug),
        .pipeline = .{ .sleep = cli.sleep, .noise = cli.scene == .noise },
    });
    defer engine.deinit();

    var profile: Profile = .{};
    var file_buf: [64 * 1024]u8 = undefined;
    var file: ?std.Io.File = null;
    var file_writer: std.Io.File.Writer = undefined;
    if (cli.profile) |path| {
        file = try std.Io.Dir.cwd().createFile(io, path, .{});
        file_writer = file.?.writer(io, &file_buf);
        try file_writer.interface.writeAll("tick,pass,ms\n");
        profile.out = &file_writer.interface;
    }
    defer if (file) |f| {
        file_writer.interface.flush() catch {};
        f.close(io);
    };
    engine.profile = &profile;

    const start = std.Io.Timestamp.now(io, .awake);
    var peak_particles: u32 = 0;
    for (0..cli.ticks) |_| {
        try engine.frame(1, .{ .scene = cli.scene, .seed = cli.seed }, null);
        peak_particles = @max(peak_particles, engine.mirror().particles.live);
    }
    try engine.finish();
    const elapsed_ms = @as(f64, @floatFromInt(start.untilNow(io, .awake).nanoseconds)) / 1e6;

    std.debug.print("headless: {d} ticks of {s} in {d:.1} ms wall ({d:.3} ms/tick)\n", .{ cli.ticks, @tagName(cli.scene), elapsed_ms, elapsed_ms / @as(f64, @floatFromInt(@max(cli.ticks, 1))) });
    for (0..engine.names.count) |i| {
        std.debug.print("  {s:<10} {d:8.4} ms/tick (min {d:.4}, max {d:.4})\n", .{ engine.names.get(i), profile.mean(i), profile.min[i], profile.max[i] });
    }
    std.debug.print("  {s:<10} {d:8.4} ms/tick, active tiles at end: {d}\n", .{ "grid", profile.gridMean(), engine.last.active_tiles });
    const ps = engine.mirror().particles;
    std.debug.print("  particles: {d} live at end (tick {d}), peak {d}; last tick spawned {d} landed {d} refused {d} lost {d} impacts {d}\n", .{ ps.live, engine.mirror().tick, peak_particles, ps.spawned, ps.landed, ps.refused, ps.lost, ps.impacts });
    if (cli.screenshot) |path| try engine.screenshot(io, path, cli.crop);
    if (cli.view_screenshot) |path| {
        const center = cli.center orelse .{ cell.world_size / 2, cell.world_size / 2 };
        const view: View = .{
            .scale = cli.zoom,
            .camera_x = center[0] - @as(i32, @intCast(cli.width / 2 / cli.zoom)),
            .camera_y = center[1] - @as(i32, @intCast(cli.height / 2 / cli.zoom)),
        };
        engine.hud.clear();
        app.fillHud(engine, &profile, .{
            .frame_ms = elapsed_ms / @as(f64, @floatFromInt(@max(cli.ticks, 1))),
            .material = "sand",
            .radius = 8,
            .view = view,
            .cursor = center,
            .material_count = table.len,
        });
        try engine.screenshotView(io, path, view, cli.width, cli.height);
    }
    return 0;
}

test {
    _ = @import("gpu/gpu.zig");
    _ = @import("sim/cell.zig");
    _ = @import("sim/materials.zig");
    _ = @import("sim/materials_builtin.zig");
    _ = @import("sim/commands.zig");
    _ = @import("sim/scenes.zig");
    _ = @import("sim/reference/grid.zig");
    _ = @import("sim/particles.zig");
    _ = @import("sim/readback.zig");
    _ = @import("render/font.zig");
    _ = @import("util/png.zig");
}
