//! Headless drivers for the Proving Grounds (docs/07-tech-demo.md):
//!
//!   hexe --headless --demo-script PREFIX   the scripted showcase
//!        (`proving_grounds_auto`): fires the events of level.auto_schedule
//!        and writes a view screenshot (zoom 2, 1920x1080, lit, signs) of
//!        each one at set ticks: PREFIX-<shot>-<tick>.png
//!   hexe --headless --bench-demo           every event inside 5 s
//!        (`proving_grounds_burst`), rendered at 1920x1080 each tick; prints
//!        per-pass GPU ms and the wall time per tick over the burst window.
//!
//! Both run the windowed app's per-tick loop: readback poll, gunpowder
//! explosions drained from the event queue (game/explode.zig), one tick per
//! frame.
const std = @import("std");
const builtin = @import("builtin");
const Cli = @import("../main.zig").Cli;
const Engine = @import("../engine.zig").Engine;
const materials = @import("../sim/materials.zig");
const commands = @import("../sim/commands.zig");
const scenes = @import("../sim/scenes.zig");
const bodies_scenes = @import("../sim/bodies_scenes.zig");
const View = @import("../render/world.zig").View;
const demo = @import("../render/demo.zig");
const Profile = @import("../profile.zig").Profile;
const game_explode = @import("explode.zig");
const level = @import("level.zig");
const overlay = @import("../render/overlay.zig");

pub const Shot = struct { name: []const u8, tick: u32, center: [2]i32, zoom: u32 = 2, overlay: overlay.Mode = .none };

const a = level.auto_schedule;
const anchors = level.anchors;

/// What the showcase photographs, in tick order per event.
pub const shots = [_]Shot{
    .{ .name = "hub", .tick = 200, .center = anchors.get(.hub) },
    .{ .name = "powder-yard", .tick = 200, .center = anchors.get(.powder_yard) },
    .{ .name = "dam", .tick = a.dam - 2, .center = anchors.get(.waterworks) },
    .{ .name = "dam", .tick = a.dam + 20, .center = anchors.get(.waterworks) },
    .{ .name = "dam", .tick = a.dam + 45, .center = anchors.get(.waterworks) },
    .{ .name = "dam", .tick = a.dam + 90, .center = anchors.get(.waterworks) },
    .{ .name = "dam", .tick = a.dam + 400, .center = anchors.get(.waterworks) },
    .{ .name = "steam", .tick = a.steam_plug - 2, .center = steam_cam, .zoom = 4 },
    .{ .name = "steam", .tick = a.steam_plug + 60, .center = steam_cam, .zoom = 4 },
    .{ .name = "steam", .tick = a.steam_plug + 110, .center = steam_cam, .zoom = 4 },
    .{ .name = "steam", .tick = a.steam_plug + 160, .center = steam_cam, .zoom = 4 },
    .{ .name = "steam", .tick = a.steam_plug + 220, .center = steam_cam, .zoom = 4 },
    .{ .name = "steam-pressure", .tick = a.steam_plug + 110, .center = steam_cam, .zoom = 4, .overlay = .air_pressure },
    .{ .name = "steam-pressure", .tick = a.steam_plug + 160, .center = steam_cam, .zoom = 4, .overlay = .air_pressure },
    .{ .name = "steam-pressure", .tick = a.steam_plug + 220, .center = steam_cam, .zoom = 4, .overlay = .air_pressure },
    .{ .name = "corridor", .tick = a.corridor - 2, .center = anchors.get(.corridor) },
    .{ .name = "corridor", .tick = a.corridor + 6, .center = anchors.get(.corridor) },
    .{ .name = "corridor-pressure", .tick = a.corridor + 6, .center = anchors.get(.corridor), .overlay = .air_pressure },
    .{ .name = "corridor", .tick = a.corridor + 50, .center = anchors.get(.corridor) },
    .{ .name = "corridor", .tick = a.field + 6, .center = anchors.get(.corridor) },
    .{ .name = "corridor-pressure", .tick = a.field + 6, .center = anchors.get(.corridor), .overlay = .air_pressure },
    .{ .name = "corridor", .tick = a.field + 140, .center = anchors.get(.corridor) },
    .{ .name = "village", .tick = a.village - 2, .center = village_cam, .zoom = 3 },
    .{ .name = "village", .tick = a.village + 120, .center = village_cam, .zoom = 3 },
    .{ .name = "village", .tick = a.village + 400, .center = village_cam, .zoom = 3 },
    .{ .name = "village", .tick = a.village + 900, .center = village_cam, .zoom = 3 },
    .{ .name = "glass", .tick = a.gate - 2, .center = anchors.get(.glassworks) },
    .{ .name = "glass", .tick = a.gate + 60, .center = anchors.get(.glassworks) },
    .{ .name = "glass", .tick = a.gate + 300, .center = anchors.get(.glassworks) },
    .{ .name = "glass", .tick = a.gate + 900, .center = anchors.get(.glassworks) },
    .{ .name = "ruin", .tick = a.beam_cuts[0] - 2, .center = anchors.get(.ruin) },
    .{ .name = "ruin", .tick = a.pillar + 10, .center = anchors.get(.ruin) },
    .{ .name = "ruin", .tick = a.pillar + 40, .center = anchors.get(.ruin) },
    .{ .name = "ruin", .tick = a.beam_cuts[1] + 200, .center = anchors.get(.ruin) },
    .{ .name = "ruin", .tick = a.beam_cuts[2] + 150, .center = anchors.get(.ruin) },
    .{ .name = "ruin", .tick = a.beam_cuts[3] + 20, .center = anchors.get(.ruin) },
    .{ .name = "ruin", .tick = a.beam_cuts[4] + 30, .center = anchors.get(.ruin) },
    .{ .name = "ruin", .tick = a.beam_cuts[4] + 150, .center = anchors.get(.ruin) },
    .{ .name = "pool", .tick = 300, .center = anchors.get(.electric_pool) },
    .{ .name = "arena", .tick = 300, .center = anchors.get(.arena) },
    .{ .name = "acid", .tick = 300, .center = anchors.get(.acid_pit) },
};

const steam_cam = [2]i32{ 770, 706 };
const village_cam = [2]i32{ 1060, 340 };

fn lastShotTick() u32 {
    var t: u32 = 0;
    for (shots) |s| t = @max(t, s.tick);
    return t;
}

fn newEngine(gpa: std.mem.Allocator, cli: Cli, lib: *const materials.Library) !*Engine {
    const engine = try gpa.create(Engine);
    errdefer gpa.destroy(engine);
    try engine.init(gpa, .{
        .library = lib,
        .validation = cli.validation orelse (builtin.mode == .debug),
        .pipeline = .{ .sleep = cli.sleep, .air = cli.air, .air_sleep = cli.air_sleep, .bodies = true, .liquid = true, .liquid_params = cli.liquid_params },
        .overlap = cli.overlap,
    });
    return engine;
}

fn viewAt(center: [2]i32, zoom: u32, w: u32, h: u32) View {
    return .{
        .scale = zoom,
        .camera_x = center[0] - @as(i32, @intCast(w / 2 / zoom)),
        .camera_y = center[1] - @as(i32, @intCast(h / 2 / zoom)),
    };
}

/// `--demo-script PREFIX`.
pub fn runScript(gpa: std.mem.Allocator, io: std.Io, cli: Cli, lib: *const materials.Library, prefix: []const u8) !u8 {
    const engine = try newEngine(gpa, cli, lib);
    defer gpa.destroy(engine);
    defer engine.deinit();
    @import("../main.zig").applyRenderCli(&engine.renderer.settings, cli);
    var profile: Profile = .{};
    engine.profile = &profile;
    const scene: scenes.Scene = .proving_grounds_auto;
    const ticks = @max(cli.ticks, lastShotTick() + 1);
    var explosions: game_explode.Explosions = .{};
    var extra: commands.CommandList = .{};
    const blast_opts: game_explode.Options = .{ .air = engine.pipeline.config.air, .liquid = true };
    std.debug.print("demo-script: {d} ticks of {s}, {d} shots\n", .{ ticks, @tagName(scene), shots.len });
    var t: u32 = 0;
    while (t < ticks) : (t += 1) {
        try engine.poll();
        extra.begin(engine.tick);
        const n = explosions.drain(engine.mirror(), &extra, blast_opts);
        if (n > 0) std.debug.print("  tick {d}: {d} gunpowder explosions\n", .{ engine.tick, n });
        // Overlays are written by the passes during the tick: switch the
        // overlay on for the tick before a shot that wants one.
        engine.renderer.settings.overlay = .none;
        for (shots) |s| {
            if (s.tick == engine.tick + 1 and s.overlay != .none) engine.renderer.settings.overlay = s.overlay;
        }
        try engine.frame(1, .{ .scene = scene, .seed = cli.seed, .extra = extra.slice() }, null);
        for (shots) |s| {
            if (s.tick != engine.tick) continue;
            var buf: [256]u8 = undefined;
            const path = try std.fmt.bufPrint(&buf, "{s}-{s}-{d:0>4}.png", .{ prefix, s.name, s.tick });
            const view = viewAt(s.center, s.zoom, cli.width, cli.height);
            engine.hud.clear();
            demo.decorate(scene, engine.tick, &engine.renderer, &engine.hud);
            if (cli.hud) engine.hud.print("{s}  tick {d}", .{ s.name, s.tick });
            engine.renderer.settings.overlay = s.overlay;
            try engine.screenshotView(io, path, view, cli.width, cli.height);
            engine.renderer.clearDraws();
        }
    }
    try engine.finish();
    try bodies_scenes.report(engine, gpa);
    return 0;
}

/// `--bench-demo`: the burst scene at 1920x1080, every tick rendered.
pub fn runBench(gpa: std.mem.Allocator, io: std.Io, cli: Cli, lib: *const materials.Library) !u8 {
    const engine = try newEngine(gpa, cli, lib);
    defer gpa.destroy(engine);
    defer engine.deinit();
    @import("../main.zig").applyRenderCli(&engine.renderer.settings, cli);
    engine.renderer.settings.overlay = .none;
    const scene: scenes.Scene = .proving_grounds_burst;
    const s = level.burst_schedule;
    // The burst window: first event to 5 s after it.
    const t0 = s.dam;
    const t1 = t0 + 300;
    var settle: Profile = .{};
    var burst: Profile = .{};
    engine.profile = &settle;
    var explosions: game_explode.Explosions = .{};
    var extra: commands.CommandList = .{};
    const blast_opts: game_explode.Options = .{ .air = engine.pipeline.config.air, .liquid = true };
    // The camera follows the events (zones of the burst, half a second each).
    const cams = [_][2]i32{ anchors.get(.waterworks), anchors.get(.steam_room), anchors.get(.corridor), anchors.get(.village), anchors.get(.glassworks), anchors.get(.ruin) };
    var frame_ns_max: u64 = 0;
    var frame_ns_sum: u64 = 0;
    var over_16: u32 = 0;
    var start_burst: ?std.Io.Timestamp = null;
    var burst_wall_ms: f64 = 0;
    var bodies_cpu_max: f64 = 0;
    const end = t1 + 4; // + frames in flight
    var t: u32 = 0;
    while (t < end) : (t += 1) {
        if (t == t0) {
            try engine.finish();
            engine.profile = &burst;
            start_burst = std.Io.Timestamp.now(io, .awake);
        }
        const f_start = std.Io.Timestamp.now(io, .awake);
        try engine.poll();
        extra.begin(engine.tick);
        _ = explosions.drain(engine.mirror(), &extra, blast_opts);
        const cam = if (t < t0) anchors.get(.hub) else cams[@min((t - t0) / 50, cams.len - 1)];
        const view = viewAt(cam, 2, 1920, 1080);
        engine.hud.clear();
        demo.decorate(scene, engine.tick, &engine.renderer, &engine.hud);
        try engine.frame(1, .{ .scene = scene, .seed = cli.seed, .extra = extra.slice() }, view);
        if (t >= t0 and t < t1) {
            const ns: u64 = @intCast(f_start.untilNow(io, .awake).nanoseconds);
            frame_ns_sum += ns;
            frame_ns_max = @max(frame_ns_max, ns);
            if (ns > 16_666_667) over_16 += 1;
            bodies_cpu_max = @max(bodies_cpu_max, engine.pipeline.bodies.sim.stats.cpu_ms);
            if (t == t1 - 1) {
                try engine.finish();
                burst_wall_ms = @as(f64, @floatFromInt(start_burst.?.untilNow(io, .awake).nanoseconds)) / 1e6;
                engine.profile = null;
            }
        }
    }
    try engine.finish();
    const n: f64 = @floatFromInt(t1 - t0);
    std.debug.print("bench-demo ({s}): proving_grounds_burst, events at ticks {d}-{d}, burst window ticks {d}-{d} (5 s), 1920x1080 zoom 2, lit\n", .{ @tagName(builtin.mode), s.dam, @max(s.pillar, s.beam_cuts[4]), t0, t1 });
    std.debug.print("  wall: {d:.3} ms/tick mean over the window ({d:.1} ms for {d} ticks), worst frame {d:.3} ms, {d} frames over 16.7 ms\n", .{ burst_wall_ms / n, burst_wall_ms, t1 - t0, @as(f64, @floatFromInt(frame_ns_max)) / 1e6, over_16 });
    std.debug.print("  cpu frame (record + submit, waits included): mean {d:.3} ms; bodies cpu max {d:.3} ms/tick\n", .{ @as(f64, @floatFromInt(frame_ns_sum)) / 1e6 / n, bodies_cpu_max });
    var total: f64 = 0;
    var total_max: f64 = 0;
    std.debug.print("  gpu ms per tick over the burst (mean / max):\n", .{});
    for (0..engine.names.count) |i| {
        if (burst.sum[i] == 0) continue;
        std.debug.print("    {s:<12} {d:7.3} / {d:7.3}\n", .{ engine.names.get(i), burst.mean(i), burst.max[i] });
        total += burst.mean(i);
        total_max += burst.max[i];
    }
    std.debug.print("    {s:<12} {d:7.3} (sum of means; sum of maxes {d:.3})\n", .{ "total", total, total_max });
    std.debug.print("  before the burst (settled level, ticks 0-{d}): ", .{t0});
    var settle_total: f64 = 0;
    for (0..engine.names.count) |i| settle_total += settle.mean(i);
    std.debug.print("gpu {d:.3} ms/tick\n", .{settle_total});
    try bodies_scenes.report(engine, gpa);
    return 0;
}
