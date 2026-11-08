//! Fixed, seeded scenes expressed as command lists. Every scene is a pure
//! function of (tick, seed): the GPU run and the CPU reference call `emit`
//! with the same arguments and get the same commands.
const std = @import("std");
const cell = @import("cell.zig");
const commands = @import("commands.zig");
const m = @import("materials_builtin.zig");

pub const Scene = enum {
    /// Nothing; paint with the mouse.
    empty,
    /// Default interactive world: stone terrain, platforms, piles and pours.
    sandbox,
    /// Seeded regression scenario for the CPU/GPU determinism check.
    determinism,
    /// Bench: settled world (stone, flat sand, flat water); sleeps after tick 0.
    bench_static,
    /// Bench: the whole world half full of falling sand, no floor (torus).
    bench_active,
    /// Bench: sand, water and smoke scattered over the whole torus; they
    /// fall, sink, rise and spread forever (divergent rules, all tiles).
    bench_mixed,
    /// Debug noise (pipeline Config.noise); emits nothing.
    noise,
    /// M4: sand sprayed as particles onto a floor, then an interim explosion
    /// (eject) throws a dirt hill; debris arcs, chips a stone pillar,
    /// ricochets off steel, splashes a pool, lands and piles.
    particles_demo,
    /// M4 bench: 100K sand particles falling forever (no floor, torus).
    bench_particles,
    /// M4 bench: a steady sand rain onto a stone floor (spawn, fall, land).
    bench_particles_rain,
    /// M4 determinism: fill line, set temperature, ignite and the cell side
    /// of eject, compared before any particle lands (verify.zig).
    determinism_commands,
};

pub fn emit(scene: Scene, tick: u32, seed: u32, list: *commands.CommandList) void {
    switch (scene) {
        .empty, .noise => {},
        .sandbox => sandbox(tick, seed, list),
        .determinism => determinism(tick, seed, list),
        .bench_static => if (tick == 0) benchStatic(list),
        .bench_active => if (tick == 0) list.fillRect(0, 0, cell.world_size, cell.world_size, m.sand, .{ .coverage = 128 }),
        .bench_mixed => if (tick == 0) {
            list.fillRect(0, 0, W, W, m.water, .{ .coverage = 80 });
            list.fillRect(0, 0, W, W, m.sand, .{ .coverage = 80, .only_air = true });
            list.fillRect(0, 0, W, W, m.smoke, .{ .coverage = 90, .only_air = true });
        },
        .particles_demo => particlesDemo(tick, list),
        .bench_particles => if (tick == 0) {
            var i: i32 = 0;
            while (i < 16) : (i += 1) {
                list.spray(.{ .x = 64 + i * 128, .y = 300, .material = m.sand, .count = 6250, .speed = 400, .spread = 200, .direction = 0.75, .cone = 0.25 });
            }
        },
        .bench_particles_rain => {
            if (tick == 0) list.fillRect(0, 1900, W, W, m.stone, .{});
            var i: i32 = 0;
            while (i < 8) : (i += 1) {
                list.spray(.{ .x = 128 + i * 256, .y = 1200, .material = m.sand, .count = 75, .speed = 150, .spread = 100, .direction = 0.25, .cone = 0.2 });
            }
        },
        .determinism_commands => determinismCommands(tick, list),
    }
}

/// Last tick of `determinism_commands` that edits cells; compare after it.
pub const determinism_commands_ticks = 8;

fn particlesDemo(tick: u32, list: *commands.CommandList) void {
    if (tick == 0) {
        // A closed cave, so debris thrown high does not wrap the torus.
        list.fillRect(500, 560, 1560, 600, m.stone, .{}); // ceiling
        list.fillRect(500, 560, 540, 1300, m.stone, .{});
        list.fillRect(1520, 560, 1560, 1300, m.stone, .{});
        list.fillRect(500, 1240, 1560, 1300, m.stone, .{}); // floor
        list.fillRect(560, 1100, 580, 1240, m.stone, .{}); // basin wall
        list.fillRect(720, 1180, 740, 1240, m.stone, .{});
        list.fillRect(580, 1200, 720, 1240, m.water, .{}); // pool
        list.fillCircle(1000, 1240, 90, m.dirt, .{ .only_air = true }); // dirt hill
        list.fillRect(1180, 1080, 1210, 1240, m.stone, .{}); // pillar to chip
        list.fillLine(1300, 1060, 1420, 1000, 4, m.steel, .{}); // ricochet plate
    }
    // Sand sprayed up and to the right for two seconds.
    if (tick < 120) list.spray(.{ .x = 660, .y = 1080, .material = m.sand, .count = 60, .speed = 330, .spread = 90, .direction = 0.86, .cone = 0.04 });
    // The interim explosion at the foot of the hill.
    if (tick == 180) list.eject(1000, 1236, 110, 950);
}

fn determinismCommands(tick: u32, list: *commands.CommandList) void {
    const ox: i32 = 900;
    const oy: i32 = 900;
    switch (tick) {
        0 => {
            list.fillRect(ox, oy + 200, ox + 300, oy + 220, m.stone, .{});
            list.fillCircle(ox + 150, oy + 200, 40, m.sand, .{ .only_air = true });
            list.fillRect(ox + 20, oy + 150, ox + 60, oy + 200, m.water, .{});
            list.fillRect(ox + 240, oy + 120, ox + 260, oy + 200, m.stone, .{});
            list.fillCircle(ox + 200, oy + 100, 10, m.smoke, .{});
        },
        2 => {
            list.fillLine(ox + 10, oy + 50, ox + 290, oy + 140, 3, m.dirt, .{});
            list.fillLine(-30, 40, 30, -20, 5, m.stone, .{ .coverage = 128 }); // across the seam
        },
        4 => {
            list.setTemperature(ox + 150, oy + 190, 30, 600);
            list.setTemperature(0, 0, 12, -30);
        },
        5 => list.ignite(ox + 150, oy + 190, 20),
        7 => {
            list.eject(ox + 150, oy + 200, 30, 900); // sand pile and the floor under it
            list.eject(ox + 250, oy + 160, 18, 2000); // through the stone post
            list.eject(ox + 40, oy + 175, 12, 300); // into the water
        },
        else => {},
    }
}

const W: i32 = cell.world_size;

fn sandbox(tick: u32, seed: u32, list: *commands.CommandList) void {
    if (tick == 0) {
        var prng = std.Random.DefaultPrng.init(seed);
        const r = prng.random();
        // Frame: the torus is walled off so the sandbox is a closed box.
        list.fillRect(0, 0, W, 24, m.stone, .{});
        list.fillRect(0, W - 24, W, W, m.stone, .{});
        list.fillRect(0, 0, 24, W, m.stone, .{});
        list.fillRect(W - 24, 0, W, W, m.stone, .{});
        // Rolling stone floor: a random walk of column heights, rounded.
        var x: i32 = 0;
        var h: i32 = 120;
        while (x < W) : (x += 32) {
            h = std.math.clamp(h + r.intRangeAtMost(i32, -40, 40), 40, 260);
            list.fillRect(x, W - 24 - h, x + 32, W - 24, m.stone, .{});
            list.fillCircle(x + 16, W - 24 - h, 22, m.stone, .{});
        }
        // Basin in the middle for a lake.
        list.fillRect(760, 1500, 1290, 1540, m.stone, .{});
        list.fillRect(760, 1180, 800, 1540, m.stone, .{});
        list.fillRect(1250, 1180, 1290, 1540, m.stone, .{});
        list.fillRect(800, 1260, 1250, 1500, m.water, .{});
        // Staggered platforms with gaps.
        var i: i32 = 0;
        while (i < 9) : (i += 1) {
            const px = 120 + @mod(i * 211, 1700);
            const py = 300 + i * 95;
            list.fillRect(px, py, px + r.intRangeAtMost(i32, 120, 320), py + 14, m.stone, .{});
        }
        // Sand mounds and loose water up high.
        i = 0;
        while (i < 14) : (i += 1) {
            list.fillCircle(r.intRangeAtMost(i32, 100, W - 100), r.intRangeAtMost(i32, 80, 700), r.intRangeAtMost(i32, 20, 60), m.sand, .{ .only_air = true });
        }
        i = 0;
        while (i < 6) : (i += 1) {
            const wx = r.intRangeAtMost(i32, 100, W - 300);
            const wy = r.intRangeAtMost(i32, 100, 600);
            list.fillRect(wx, wy, wx + 160, wy + 50, m.water, .{ .only_air = true });
        }
        // Smoke pockets low down.
        list.fillCircle(400, 1650, 60, m.smoke, .{ .only_air = true });
        list.fillCircle(1650, 1600, 50, m.smoke, .{ .only_air = true });
    }
    if (tick < 1800) {
        // Pours: a sand stream, a water stream, a smoke chimney.
        list.fillCircle(560, 60, 6, m.sand, .{ .only_air = true });
        if (tick % 2 == 0) list.fillCircle(1500, 60, 5, m.water, .{ .only_air = true });
        if (tick % 4 == 0) list.fillCircle(1024, 1800, 8, m.smoke, .{ .only_air = true, .coverage = 160 });
    }
}

/// Small enough for the CPU reference, busy enough to hit every rule: powder
/// falls and slides, liquid falls, flows and spreads, sand sinks in water,
/// smoke rises and drifts, statics hold, commands overwrite, fill only air,
/// cover partially, and things cross the torus seam in both axes.
fn determinism(tick: u32, seed: u32, list: *commands.CommandList) void {
    const ox: i32 = 768;
    const oy: i32 = 640;
    if (tick == 0) {
        var prng = std.Random.DefaultPrng.init(seed);
        const r = prng.random();
        list.fillRect(ox, oy + 440, ox + 512, oy + 470, m.stone, .{});
        list.fillRect(ox, oy + 60, ox + 16, oy + 470, m.stone, .{});
        list.fillRect(ox + 496, oy + 60, ox + 512, oy + 470, m.stone, .{});
        list.fillRect(ox + 60, oy + 240, ox + 220, oy + 252, m.stone, .{});
        list.fillRect(ox + 300, oy + 300, ox + 470, oy + 312, m.stone, .{});
        list.fillRect(ox + 40, oy + 360, ox + 300, oy + 430, m.water, .{});
        var i: i32 = 0;
        while (i < 8) : (i += 1) {
            list.fillCircle(ox + r.intRangeAtMost(i32, 40, 470), oy + r.intRangeAtMost(i32, 70, 200), r.intRangeAtMost(i32, 6, 24), m.sand, .{ .only_air = true });
        }
        list.fillCircle(ox + 380, oy + 400, 30, m.smoke, .{ .only_air = true });
        list.fillRect(ox + 100, oy + 100, ox + 400, oy + 180, m.sand, .{ .only_air = true, .coverage = 40 });
        // Torus seam: sand and water falling across y = 2047 -> 0 at x = 0,
        // smoke rising across y = 0 -> 2047, water spreading across x = 0.
        list.fillRect(W - 8, W - 40, W + 8, W - 8, m.sand, .{});
        list.fillRect(-20, W - 70, 20, W - 50, m.water, .{});
        list.fillCircle(300, 6, 5, m.smoke, .{});
        list.fillRect(-60, 200, 60, 210, m.stone, .{});
        list.fillRect(-10, 150, 10, 199, m.water, .{});
    }
    if (tick < 200) {
        if (tick % 3 == 0) list.fillCircle(ox + 130, oy + 70, 4, m.sand, .{ .only_air = true });
        if (tick % 3 == 1) list.fillCircle(ox + 400, oy + 70, 4, m.water, .{ .only_air = true });
        if (tick % 7 == 0) list.fillCircle(ox + 250, oy + 420, 5, m.smoke, .{ .only_air = true });
        if (tick % 50 == 25) list.fillCircle(ox + 140, oy + 245, 10, m.air, .{});
    }
}

fn benchStatic(list: *commands.CommandList) void {
    list.fillRect(0, 1024, W, W, m.stone, .{});
    list.fillRect(0, 900, W, 1024, m.sand, .{});
    list.fillRect(200, 400, 1800, 420, m.stone, .{});
    list.fillRect(200, 300, 220, 400, m.stone, .{});
    list.fillRect(1780, 300, 1800, 400, m.stone, .{});
    list.fillRect(220, 340, 1780, 400, m.water, .{});
}

test "scenes are deterministic" {
    var a: commands.CommandList = .{};
    var b: commands.CommandList = .{};
    for ([_]u32{ 0, 1, 25, 199, 200 }) |t| {
        a.begin(t);
        b.begin(t);
        emit(.determinism, t, 7, &a);
        emit(.determinism, t, 7, &b);
        try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(a.slice()), std.mem.sliceAsBytes(b.slice()));
    }
}
