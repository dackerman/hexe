//! `hexe --headless --bench-render`: per-pass render GPU ms at a 1920x1080
//! view (rendered headless into the capture image, exactly the windowed
//! path minus present), for several lighting configurations and zooms, then
//! wall time per frame with the simulation overlapped and serial.
//! Build with -Doptimize=ReleaseFast for budget numbers.
const std = @import("std");
const builtin = @import("builtin");
const Cli = @import("main.zig").Cli;
const Engine = @import("engine.zig").Engine;
const scenes = @import("sim/scenes.zig");
const materials = @import("sim/materials.zig");
const Profile = @import("profile.zig").Profile;
const View = @import("render/world.zig").View;
const renderer_mod = @import("render/renderer.zig");
const demo = @import("render/demo.zig");
const app = @import("app.zig");

const render_passes = [_][]const u8{ "light_build", "cascades", "merge", "world", "sprites", "post", "hud" };

const Case = struct {
    name: []const u8,
    zoom: u32,
    mode: renderer_mod.LightMode = .cascades,
    spacing: u32 = 2,
    bloom: bool = true,
};

const cases = [_]Case{
    .{ .name = "cascades, spacing 2 (default)", .zoom = 2 },
    .{ .name = "cascades, spacing 1 (full res)", .zoom = 2, .spacing = 1 },
    .{ .name = "cascades, spacing 4 (low)", .zoom = 2, .spacing = 4 },
    .{ .name = "cascades, spacing 2, zoom 1 (1920x1080 world px)", .zoom = 1 },
    .{ .name = "cascades, spacing 2, zoom 3", .zoom = 3 },
    .{ .name = "simple lights", .zoom = 2, .mode = .simple },
    .{ .name = "lighting off, no bloom", .zoom = 2, .mode = .off, .bloom = false },
};

fn viewAt(center: [2]i32, zoom: u32, w: u32, h: u32) View {
    return .{
        .scale = zoom,
        .camera_x = center[0] - @as(i32, @intCast(w / 2 / zoom)),
        .camera_y = center[1] - @as(i32, @intCast(h / 2 / zoom)),
    };
}

pub fn run(gpa: std.mem.Allocator, io: std.Io, cli: Cli, lib: *const materials.Library) !u8 {
    const frames: u32 = if (cli.ticks == 300) 240 else @max(cli.ticks, 20);
    const scene: scenes.Scene = if (cli.scene_set) cli.scene else .lighting;
    const w: u32 = 1920;
    const h: u32 = 1080;
    std.debug.print("hexe bench-render: {s} scene, {d}x{d} view, {d} frames per case, {s} build, warm-up 20 frames excluded\n", .{ @tagName(scene), w, h, frames, @tagName(builtin.mode) });
    const center: [2]i32 = cli.center orelse if (scene == .lighting) scenes.lighting_center else .{ 1024, 1024 };

    const engine = try gpa.create(Engine);
    defer gpa.destroy(engine);
    try engine.init(gpa, .{ .library = lib, .validation = cli.validation orelse false });
    defer engine.deinit();
    engine.headless_extent = .{ .width = w, .height = h };
    demo.configure(scene, &engine.renderer.settings);
    // Let the scene settle a little.
    for (0..120) |_| try engine.frame(1, .{ .scene = scene, .seed = cli.seed }, null);
    try engine.finish();

    var failed = false;
    for (cases) |case| {
        var profile: Profile = .{ .skip_frames = 20 };
        engine.profile = &profile;
        const s = &engine.renderer.settings;
        s.light_mode = case.mode;
        s.probe_spacing = case.spacing;
        s.bloom = case.bloom;
        const view = viewAt(center, case.zoom, w, h);
        const start = std.Io.Timestamp.now(io, .awake);
        for (0..frames) |_| {
            engine.hud.clear();
            demo.decorate(scene, engine.tick, &engine.renderer, &engine.hud);
            app.fillHud(engine, &profile, .{ .frame_ms = 0, .view = view, .material_count = app.palette.len });
            try engine.frame(1, .{ .scene = scene, .seed = cli.seed }, view);
        }
        try engine.finish();
        const wall = @as(f64, @floatFromInt(start.untilNow(io, .awake).nanoseconds)) / 1e6 / @as(f64, @floatFromInt(frames));
        const plan = engine.renderer.last_plan;
        std.debug.print("\n== {s}: zoom {d}, region {d}x{d}, spacing {d}, cascades {d}, probes {d}x{d}\n", .{ case.name, case.zoom, plan.size[0], plan.size[1], plan.spacing, plan.count, plan.probes[0], plan.probes[1] });
        var total: f64 = 0;
        for (render_passes) |rp| {
            for (0..engine.names.count) |i| {
                if (!std.mem.eql(u8, engine.names.get(i), rp)) continue;
                std.debug.print("  {s:<12} {d:8.4} ms (min {d:.4}, max {d:.4})\n", .{ rp, profile.mean(i), profile.min[i], profile.max[i] });
                total += profile.mean(i);
            }
        }
        for (0..engine.names.count) |i| {
            const n = engine.names.get(i);
            if (std.mem.eql(u8, n, "render") or std.mem.eql(u8, n, "snapshot")) std.debug.print("  {s:<12} {d:8.4} ms\n", .{ n, profile.mean(i) });
        }
        const ok = total <= 3.0;
        if (!ok) failed = true;
        std.debug.print("  {s:<12} {d:8.4} ms  budget 3.0 ms: {s}   (wall {d:.3} ms/frame)\n", .{ "sum", total, if (ok) "PASS" else "FAIL", wall });
        engine.profile = null;
    }

    // Overlap: the same frames with the sim overlapping the render and
    // strictly serial. GPU-bound on purpose: 4 ticks of the fully active
    // mixing scene per frame and a zoom-1 view (the largest light region).
    const sim_ticks = 4;
    std.debug.print("\n== sim/render overlap: bench_mixed, {d} ticks per frame, zoom 1, {d} frames\n", .{ sim_ticks, frames });
    for ([_]bool{ false, true, false, true }) |overlap| {
        engine.overlap = overlap;
        demo.configure(.lighting, &engine.renderer.settings);
        engine.renderer.settings.light_mode = .cascades;
        engine.renderer.settings.probe_spacing = 2;
        engine.renderer.settings.bloom = true;
        var profile: Profile = .{ .skip_frames = 20 };
        engine.profile = &profile;
        const view = viewAt(center, 1, w, h);
        // Re-run the mixing scene from its first tick (fills the world).
        engine.tick = 0;
        var start = std.Io.Timestamp.now(io, .awake);
        for (0..frames + 20) |f| {
            if (f == 20) start = std.Io.Timestamp.now(io, .awake);
            engine.hud.clear();
            try engine.frame(sim_ticks, .{ .scene = .bench_mixed, .seed = cli.seed }, view);
        }
        try engine.finish();
        const wall = @as(f64, @floatFromInt(start.untilNow(io, .awake).nanoseconds)) / 1e6 / @as(f64, @floatFromInt(frames));
        var render_ms: f64 = 0;
        var snap_ms: f64 = 0;
        for (0..engine.names.count) |i| {
            if (std.mem.eql(u8, engine.names.get(i), "render")) render_ms = profile.mean(i);
            if (std.mem.eql(u8, engine.names.get(i), "snapshot")) snap_ms = profile.mean(i);
        }
        std.debug.print("  overlap {s:<3}  wall {d:7.3} ms/frame   sim (grid, {d} ticks) {d:.3} ms   render {d:.3} ms   snapshot {d:.3} ms   serial sum {d:.3} ms\n", .{
            if (overlap) "on" else "off", wall, sim_ticks, profile.gridMean(), render_ms, snap_ms, profile.gridMean() + render_ms + snap_ms,
        });
        engine.profile = null;
    }
    return if (failed) 1 else 0;
}
