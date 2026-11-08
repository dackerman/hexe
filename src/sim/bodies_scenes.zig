//! Scripted M7 scenes: terrain as commands (`terrain`, called from
//! scenes.emit) plus body actions (`script`, called by the engine each tick
//! when bodies are on), and the headless report printed after a run.
//!
//!   zig build run -- --headless --scene bodies_crate --ticks 300 --screenshot crate.png
//!
//! bodies_crate  a 40x40 concrete crate falls 180 px onto stone and rests
//! bodies_slab   a stone slab on one pillar; the pillar is ejected at tick 40;
//!               the slab comes loose, falls and shatters
//! bodies_beam   a steel beam spans a gap between two cliffs with a crate on
//!               it; a torch (eject circles) cuts it from below from tick 120;
//!               it sags, then snaps; at tick 900 the right weld's rock is
//!               ejected and that half falls
//! bodies_water  a concrete and a wood crate dropped into a cellular pool
//! bodies_bench  200 crates (wood and steel, 20-40 px, some spinning) falling
//!               onto a floor (performance)
const std = @import("std");
const commands = @import("commands.zig");
const cell = @import("cell.zig");
const scenes = @import("scenes.zig");
const m = @import("materials_builtin.zig");
const materials = @import("materials.zig");
const BodySim = @import("bodies_sim.zig").BodySim;
const bodies = @import("bodies");

const Scene = scenes.Scene;

pub fn isBodiesScene(s: Scene) bool {
    return switch (s) {
        .bodies_crate, .bodies_slab, .bodies_beam, .bodies_water, .bodies_bench => true,
        else => false,
    };
}

/// Grid part of the scene (pure function of tick, like every scene).
pub fn terrain(scene: Scene, tick: u32, list: *commands.CommandList) void {
    if (tick != 0) return;
    switch (scene) {
        .bodies_crate => {
            list.fillRect(700, 1200, 1350, 1260, m.stone, .{});
            // A floor across the torus seam x = 2047 | 0.
            list.fillRect(1950, 1200, 2150, 1260, m.stone, .{});
        },
        .bodies_slab => {
            list.fillRect(600, 1200, 1450, 1300, m.stone, .{});
            list.fillRect(1014, 1100, 1034, 1200, m.stone, .{}); // pillar 20 x 100
            list.fillRect(924, 1084, 1124, 1100, m.stone, .{}); // slab 200 x 16
        },
        .bodies_beam => {
            list.fillRect(700, 1000, 900, 1300, m.stone, .{});
            list.fillRect(1140, 1000, 1340, 1300, m.stone, .{});
            list.fillRect(600, 1300, 1450, 1360, m.stone, .{});
        },
        .bodies_water => {
            list.fillRect(780, 1250, 1270, 1280, m.stone, .{});
            list.fillRect(780, 1030, 800, 1250, m.stone, .{});
            list.fillRect(1250, 1030, 1270, 1250, m.stone, .{});
            list.fillRect(800, 1130, 1250, 1250, m.water, .{});
        },
        .bodies_bench => {
            list.fillRect(60, 1600, 1988, 1700, m.stone, .{});
            list.fillRect(40, 900, 60, 1700, m.stone, .{});
            list.fillRect(1988, 900, 2008, 1700, m.stone, .{});
        },
        else => {},
    }
}

/// Body part of the scene, run before the bodies tick. Commands pushed here
/// (ejects) are applied this tick and seen as destruction events.
pub fn script(scene: Scene, tick: u32, sim: *BodySim, list: *commands.CommandList) void {
    if (!isBodiesScene(scene)) return;
    const r = sim.mats.roles;
    switch (scene) {
        .bodies_crate => {
            if (tick == 5) {
                _ = sim.spawnCrate(1024, 1000, 40, r.concrete) catch {};
                // Lands straddling the seam (unwrapped x 2028..2068).
                _ = sim.spawnCrate(2048, 1000, 40, r.concrete) catch {};
            }
            if (tick % 50 == 0 and tick > 0) poseReport(sim, tick);
        },
        .bodies_slab => if (tick == 40) {
            var y: i32 = 1114;
            while (y <= 1196) : (y += 16) list.fillCircle(1024, y, 14, materials.air, .{});
        },
        .bodies_beam => {
            if (tick == 2) sim.placeBeam(880, 1010, 1160, 1010, r.steel, 4);
            if (tick == 30) _ = sim.spawnCrate(1020, 981, 50, r.concrete) catch {};
            // Torch from below at x = 1025, following the beam: removes
            // `depth` rows up from its current bottom edge (4 px thick).
            const cuts = [_]struct { t: u32, depth: i32 }{ .{ .t = 120, .depth = 1 }, .{ .t = 360, .depth = 2 }, .{ .t = 600, .depth = 3 }, .{ .t = 780, .depth = 5 } };
            for (cuts) |c| {
                if (tick != c.t) continue;
                const bottom = beamBottomAt(sim, 1025) orelse continue;
                list.fillRect(1023, bottom - c.depth, 1028, bottom + 3, materials.air, .{});
            }
            // Then blow away the right cliff's edge where the beam is welded:
            // the anchor lets go and the right half falls.
            if (tick == 900) list.fillCircle(1152, 1010, 12, materials.air, .{});
            if (tick % 40 == 0 and tick > 0) beamReport(sim, tick);
        },
        .bodies_water => if (tick == 10) {
            _ = sim.spawnCrate(940, 1000, 40, r.concrete) catch {};
            _ = sim.spawnCrate(1110, 1000, 40, r.wood) catch {};
        },
        .bodies_bench => if (tick == 2) {
            var prng = std.Random.DefaultPrng.init(200);
            const rand = prng.random();
            var i: u32 = 0;
            while (i < 200) : (i += 1) {
                const col: f32 = @floatFromInt(i % 25);
                const row: f32 = @floatFromInt(i / 25);
                const size = rand.intRangeAtMost(u16, 20, 40);
                const mat = if (i % 2 == 0) r.wood else r.steel;
                const h = sim.spawnCrate(120 + col * 74, 1180 + row * 50, size, mat) catch continue;
                _ = h;
            }
        },
        else => {},
    }
}

/// Pose of every body and what the GPU rewrote in the last completed tick.
fn poseReport(sim: *BodySim, tick: u32) void {
    var it = sim.world.rasterIterator();
    std.debug.print("tick {d}:", .{tick});
    while (it.next()) |rb| {
        std.debug.print(" body {d} at ({d:.3}, {d:.3}) angle {d:.4} {s};", .{ rb.handle.index + 1, rb.transform.x, rb.transform.y, rb.transform.angle, if (rb.awake) "awake" else "asleep" });
    }
    std.debug.print(" cpu rastered {d}, cleared {d}\n", .{ sim.stats.rastered, sim.stats.cleared });
}

/// World row just below the beam's bottom edge at column x (the first beam's
/// segment covering x).
fn beamBottomAt(sim: *BodySim, x: f32) ?i32 {
    const world = &sim.world;
    for (world.beams, 0..) |b, bi| {
        if (!b.live) continue;
        const h: bodies.BeamHandle = .{ .index = @intCast(bi), .gen = b.gen };
        const info = world.beamInfo(h).?;
        for (world.beamSegments(h)) |seg| {
            const t = world.getTransform(seg) orelse continue;
            const l = t.applyInverse(x, t.y);
            if (l.x < 0 or l.x >= @as(f32, @floatFromInt(info.seg_len))) continue;
            const p = t.apply(l.x, @as(f32, @floatFromInt(info.thickness)) * 0.5);
            return @intFromFloat(@round(p.y));
        }
    }
    return null;
}

/// Sag of the scene's beam: lowest segment center below the line it was
/// placed on, joints alive, largest plastic bend.
fn beamReport(sim: *BodySim, tick: u32) void {
    const world = &sim.world;
    for (world.beams, 0..) |b, bi| {
        if (!b.live) continue;
        const h: bodies.BeamHandle = .{ .index = @intCast(bi), .gen = b.gen };
        const info = world.beamInfo(h).?;
        var sag: f32 = 0;
        for (world.beamSegments(h)) |seg| {
            const t = world.getTransform(seg) orelse continue;
            const mid = t.apply(@as(f32, @floatFromInt(info.seg_len)) * 0.5, 0);
            sag = @max(sag, mid.y - b.y0);
        }
        var plastic: f32 = 0;
        var weakest: f32 = 1;
        for (0..@as(usize, info.segments) + 1) |ji| {
            const l = world.beamJointLoad(h, ji) orelse continue;
            if (!l.alive) continue;
            plastic = @max(plastic, @abs(l.plastic_angle));
            weakest = @min(weakest, l.strength);
        }
        std.debug.print("tick {d}: beam sag {d:.1} px, joints {d}/{d}, max plastic bend {d:.3} rad, weakest joint strength {d:.2}\n", .{
            tick, sag, world.beamJointCount(h), @as(usize, info.segments) + 1, plastic, weakest,
        });
    }
}

/// After a headless run: bodies, their poses, and a census of the cells.
pub fn report(engine: anytype, gpa: std.mem.Allocator) !void {
    const b = &engine.pipeline.bodies;
    const sim = b.sim;
    const t = sim.totals;
    std.debug.print("bodies: {d} live, {d} beams placed ({d} rejected), {d} destruction events, {d} loose components -> bodies, {d} -> rubble\n", .{
        sim.bodyCount(), t.beams_placed, t.beams_rejected, t.events, t.extracted, t.rubble_components,
    });
    std.debug.print("  breakup: {d} bodies broken, {d} dissolved, {d} rubble cells, {d} joint breaks, {d} sparks, {d} anchors released, {d} capacity drops\n", .{
        t.broken, t.dissolved, t.rubble_points, t.joint_breaks, t.sparks, t.anchors_released, t.dropped,
    });
    const ticks: f64 = @floatFromInt(@max(t.ticks, 1));
    std.debug.print("  cpu per tick (terrain readback excluded): mean {d:.3} ms, max {d:.3} ms; readback mean {d:.3} ms; connectivity {d} runs, mean {d:.3} ms, max {d:.3} ms\n", .{
        t.cpu_ms / ticks,                                                                                     t.cpu_ms_max,          t.readback_ms / ticks, t.connectivity_runs,
        if (t.connectivity_runs > 0) t.connectivity_ms / @as(f64, @floatFromInt(t.connectivity_runs)) else 0, t.connectivity_ms_max,
    });
    std.debug.print("  cpu phases per tick: static collision {d:.3}, fluid {d:.3}, box2d step {d:.3}, impacts/breaks {d:.3}, gpu upload {d:.3} ms\n", .{
        t.static_ms / ticks, t.fluid_ms / ticks, t.step_ms / ticks, t.events_ms / ticks, t.upload_ms / ticks,
    });
    const ls = b.gpu_.last_stats;
    std.debug.print("  last gpu stats (tick {d}): written {d}, overlap static {d}, overlap body {d}, displaced {d}, cleared {d}, extracted {d}, points {d}, fallback placed {d} dropped {d}\n", .{
        ls.tick,            ls.get(.written), ls.get(.overlap_static),  ls.get(.overlap_body),     ls.get(.displaced), ls.get(.cleared),
        ls.get(.extracted), ls.get(.points),  ls.get(.fallback_placed), ls.get(.fallback_dropped),
    });
    var it = sim.world.rasterIterator();
    var shown: u32 = 0;
    while (it.next()) |rb| {
        if (shown == 12) {
            std.debug.print("  ...\n", .{});
            break;
        }
        shown += 1;
        const v = sim.world.getVelocity(rb.handle).?;
        std.debug.print("  body {d}: {d}x{d} px {d} at ({d:.2}, {d:.2}) angle {d:.3} v ({d:.1}, {d:.1}) {s}{s}\n", .{
            rb.handle.index + 1, rb.w,                                rb.h,                                           sim.world.getPixelCount(rb.handle).?,
            rb.transform.x,      rb.transform.y,                      rb.transform.angle,                             v.x,
            v.y,                 if (rb.awake) "awake" else "asleep", if (rb.beam != null) " (beam segment)" else "",
        });
    }
    // Cell census over the whole world.
    const cells = try gpa.alloc(u32, cell.world_size * cell.world_size);
    defer gpa.free(cells);
    try engine.readbackCells(cells);
    var owned: u32 = 0;
    var by_mat: [256]u32 = @splat(0);
    var owned_by_mat: [256]u32 = @splat(0);
    for (cells) |c| {
        const mat = c & 0xff;
        if (c & cell.flag_body != 0) {
            owned += 1;
            owned_by_mat[mat] += 1;
        } else by_mat[mat] += 1;
    }
    var body_px: u32 = 0;
    var it2 = sim.world.rasterIterator();
    while (it2.next()) |rb| body_px += sim.world.getPixelCount(rb.handle).?;
    std.debug.print("  cells: {d} body-owned (bodies hold {d} bitmap px)", .{ owned, body_px });
    const table_names = engine.pipeline.bodies.sim.mats.roles;
    _ = table_names;
    for (by_mat, 0..) |n, i| {
        if (i == 0 or (n == 0 and owned_by_mat[i] == 0)) continue;
        std.debug.print(", mat{d}: {d} free / {d} owned", .{ i, n, owned_by_mat[i] });
    }
    std.debug.print("\n", .{});
}
