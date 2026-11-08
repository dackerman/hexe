//! Fixed, seeded scenes expressed as command lists. Every scene is a pure
//! function of (tick, seed): the GPU run and the CPU reference call `emit`
//! with the same arguments and get the same commands.
const std = @import("std");
const cell = @import("cell.zig");
const commands = @import("commands.zig");
const materials = @import("materials.zig");
const Ids = materials.Ids;
const bodies_scenes = @import("bodies_scenes.zig");
const liquid_scenes = @import("liquid_scenes.zig");

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
    /// Bench: lava, water, oil and burning wood scattered over the whole
    /// torus (every reaction rule busy, all tiles active).
    bench_fire,
    /// Reactions showcase around the world center: lava meeting water, a
    /// burning wood hut, oil burning on a pond, sand pouring into lava.
    fire_demo,
    /// Debug noise (pipeline Config.noise); emits nothing.
    noise,
    /// Air field demo (M5): an explosion in the open beside a wall and one
    /// in a corridor ending in a room, sand piles and smoke to throw.
    air_demo,
    /// Bench (M5): stone terrain with rooms and corridors, an explosion
    /// every 20 ticks at rotating spots, heat sources; the air field stays
    /// fully active.
    bench_air,
    // ---- bodies (M7), src/sim/bodies_scenes.zig; these turn bodies on ----
    bodies_crate,
    bodies_slab,
    bodies_beam,
    bodies_water,
    bodies_bench,
    // ---- end bodies ----
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
    /// Render test (M8): a cave around (1024, 1040) with a lava pool, stone
    /// pillars, a glass tank of water, a smoke vent, a brazier flame and a
    /// skylight shaft with a glass pane.
    lighting,
    // ---- liquid solver (M6), src/sim/liquid_scenes.zig ----
    liquid_utube,
    liquid_dam,
    liquid_pool,
    liquid_slosh,
    liquid_slosh_1m,
    liquid_basin,
    // ---- end liquid solver ----
};

/// `m` holds the material ids, looked up by name from the loaded set.
pub fn emit(scene: Scene, tick: u32, seed: u32, m: *const Ids, list: *commands.CommandList) void {
    switch (scene) {
        .empty, .noise => {},
        .sandbox => sandbox(tick, seed, m, list),
        .determinism => determinism(tick, seed, m, list),
        .bench_static => if (tick == 0) benchStatic(m, list),
        .bench_active => if (tick == 0) list.fillRect(0, 0, cell.world_size, cell.world_size, m.sand, .{ .coverage = 128 }),
        .air_demo => airDemo(tick, m, list),
        .bench_air => benchAir(tick, m, list),
        .bodies_crate, .bodies_slab, .bodies_beam, .bodies_water, .bodies_bench => bodies_scenes.terrain(scene, tick, m, list),
        .bench_fire => benchFire(tick, m, list),
        .fire_demo => fireDemo(tick, m, list),
        .lighting => lighting(tick, seed, m, list),
        .liquid_utube => liquid_scenes.emit(.utube, tick, seed, m, list),
        .liquid_dam => liquid_scenes.emit(.dam, tick, seed, m, list),
        .liquid_pool => liquid_scenes.emit(.pool, tick, seed, m, list),
        .liquid_slosh => liquid_scenes.emit(.slosh, tick, seed, m, list),
        .liquid_slosh_1m => liquid_scenes.emit(.slosh_1m, tick, seed, m, list),
        .liquid_basin => liquid_scenes.emit(.basin, tick, seed, m, list),
        .bench_mixed => if (tick == 0) {
            list.fillRect(0, 0, W, W, m.water, .{ .coverage = 80 });
            list.fillRect(0, 0, W, W, m.sand, .{ .coverage = 80, .only_air = true });
            list.fillRect(0, 0, W, W, m.smoke, .{ .coverage = 90, .only_air = true });
        },
        .particles_demo => particlesDemo(tick, m, list),
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
        .determinism_commands => determinismCommands(tick, m, list),
    }
}

/// Last tick of `determinism_commands` that edits cells; compare after it.
pub const determinism_commands_ticks = 8;

fn particlesDemo(tick: u32, m: *const Ids, list: *commands.CommandList) void {
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

fn determinismCommands(tick: u32, m: *const Ids, list: *commands.CommandList) void {
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
        5 => list.igniteCircle(ox + 150, oy + 190, 20),
        7 => {
            list.eject(ox + 150, oy + 200, 30, 900); // sand pile and the floor under it
            list.eject(ox + 250, oy + 160, 18, 2000); // through the stone post
            list.eject(ox + 40, oy + 175, 12, 300); // into the water
        },
        else => {},
    }
}

const W: i32 = cell.world_size;

fn sandbox(tick: u32, seed: u32, m: *const Ids, list: *commands.CommandList) void {
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
fn determinism(tick: u32, seed: u32, m: *const Ids, list: *commands.CommandList) void {
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
    reactionArena(tick, m, list);
    if (tick < 200) {
        if (tick % 3 == 0) list.fillCircle(ox + 130, oy + 70, 4, m.sand, .{ .only_air = true });
        if (tick % 3 == 1) list.fillCircle(ox + 400, oy + 70, 4, m.water, .{ .only_air = true });
        if (tick % 7 == 0) list.fillCircle(ox + 250, oy + 420, 5, m.smoke, .{ .only_air = true });
        if (tick % 50 == 25) list.fillCircle(ox + 140, oy + 245, 10, m.air, .{});
    }
}

fn airDemo(tick: u32, m: *const Ids, list: *commands.CommandList) void {
    if (tick == 0) {
        // Floor across the window and a free-standing wall right of the
        // open-air blast.
        list.fillRect(0, 1400, W, W, m.stone, .{});
        list.fillRect(680, 1000, 720, 1400, m.stone, .{});
        // A stone massif with a 10 px corridor ending in a room.
        list.fillRect(900, 1000, 1900, 1400, m.stone, .{});
        list.fillRect(900, 1190, 1780, 1200, m.air, .{});
        list.fillRect(1780, 1120, 1860, 1280, m.air, .{});
        // Sand piles on the floor in the open, sand plugs in the corridor.
        var x: i32 = 380;
        while (x < 680) : (x += 60) list.fillRect(x, 1392, x + 6, 1400, m.sand, .{});
        x = 1000;
        while (x < 1780) : (x += 80) list.fillRect(x, 1190, x + 4, 1200, m.sand, .{});
        x = 760;
        while (x < 900) : (x += 50) list.fillRect(x, 1392, x + 6, 1400, m.sand, .{});
        // Smoke clouds to show the flow.
        list.fillCircle(560, 1250, 40, m.smoke, .{ .only_air = true, .coverage = 120 });
        list.fillCircle(800, 1300, 30, m.smoke, .{ .only_air = true, .coverage = 120 });
        list.fillRect(1790, 1130, 1850, 1270, m.smoke, .{ .only_air = true, .coverage = 60 });
    }
    if (tick == 30) {
        list.explosion(560, 1380, 12, 1.0);
        list.explosion(930, 1195, 12, 1.0);
    }
}

fn benchAir(tick: u32, m: *const Ids, list: *commands.CommandList) void {
    if (tick == 0) {
        list.fillRect(0, 1500, W, W, m.stone, .{});
        var i: i32 = 0;
        while (i < 8) : (i += 1) {
            const x0 = 64 + i * 250;
            list.fillRect(x0, 200, x0 + 30, 1500, m.stone, .{});
            list.fillRect(x0 + 30, 700 + @mod(i * 37, 300), x0 + 200, 720 + @mod(i * 37, 300), m.stone, .{});
        }
        list.fillRect(0, 100, W, 130, m.stone, .{});
        list.fillRect(0, 1460, W, 1500, m.sand, .{ .coverage = 128 });
    }
    if (tick % 20 == 0) {
        const k: i32 = @intCast((tick / 20) % 16);
        list.explosion(150 + @mod(k * 523, 1800), 300 + @mod(k * 311, 1100), 16, 1.0);
    }
}

/// The determinism scene's reactions half: a bedrock basin where lava meets
/// water (stone, steam), sand falls into lava (molten glass), oil floats on
/// the water and is lit by flame, a wood block and a gunpowder heap burn
/// (smoke, flame, charcoal, an explode event), ice melts, a heated spot
/// boils, and a charged steel rod pulses through the water.
fn reactionArena(tick: u32, m: *const Ids, list: *commands.CommandList) void {
    const ax: i32 = 200;
    const ay: i32 = 1300;
    if (tick == 0) {
        list.fillRect(ax, ay + 180, ax + 300, ay + 192, m.bedrock, .{});
        list.fillRect(ax, ay + 60, ax + 8, ay + 180, m.bedrock, .{});
        list.fillRect(ax + 292, ay + 60, ax + 300, ay + 180, m.bedrock, .{});
        list.fillRect(ax + 10, ay + 150, ax + 90, ay + 180, m.lava, .{});
        list.fillRect(ax + 100, ay + 140, ax + 180, ay + 180, m.water, .{});
        list.fillRect(ax + 100, ay + 177, ax + 180, ay + 179, m.steel, .{});
        list.fillRect(ax + 120, ay + 120, ax + 160, ay + 128, m.oil, .{});
        list.fillRect(ax + 30, ay + 100, ax + 60, ay + 110, m.sand, .{});
        list.fillRect(ax + 200, ay + 150, ax + 240, ay + 180, m.wood, .{});
        list.fillRect(ax + 246, ay + 172, ax + 256, ay + 180, m.gunpowder, .{});
        list.fillRect(ax + 260, ay + 120, ax + 284, ay + 124, m.stone, .{});
        list.fillRect(ax + 262, ay + 110, ax + 282, ay + 120, m.ice, .{});
    }
    if (tick == 5) list.igniteRect(ax + 200, ay + 150, ax + 240, ay + 153);
    if (tick == 40) list.fillCircle(ax + 140, ay + 112, 3, m.flame, .{ .only_air = true });
    if (tick == 60) list.heatCircle(ax + 170, ay + 150, 4, 40); // 280 C: boils
    if (tick % 10 == 0) list.chargeCircle(ax + 101, ay + 178, 1);
}

fn benchFire(tick: u32, m: *const Ids, list: *commands.CommandList) void {
    if (tick == 0) {
        list.fillRect(0, 0, W, W, m.wood, .{ .coverage = 40 });
        list.fillRect(0, 0, W, W, m.lava, .{ .coverage = 30, .only_air = true });
        list.fillRect(0, 0, W, W, m.water, .{ .coverage = 30, .only_air = true });
        list.fillRect(0, 0, W, W, m.oil, .{ .coverage = 30, .only_air = true });
    }
    if (tick == 1) list.igniteRect(0, 0, W, W);
}

fn fireDemo(tick: u32, m: *const Ids, list: *commands.CommandList) void {
    const cx: i32 = 1024;
    const cy: i32 = 1024;
    if (tick == 0) {
        // Ground and a basin on the left for the lava, a pond on the right.
        list.fillRect(cx - 300, cy + 120, cx + 300, cy + 160, m.stone, .{});
        list.fillRect(cx - 300, cy + 40, cx - 290, cy + 120, m.stone, .{});
        list.fillRect(cx + 290, cy + 40, cx + 300, cy + 120, m.stone, .{});
        list.fillRect(cx - 40, cy + 70, cx - 30, cy + 120, m.stone, .{});
        list.fillRect(cx - 290, cy + 85, cx - 40, cy + 120, m.lava, .{});
        list.fillRect(cx + 120, cy + 70, cx + 130, cy + 120, m.stone, .{});
        list.fillRect(cx + 130, cy + 80, cx + 290, cy + 120, m.water, .{});
        list.fillRect(cx + 150, cy + 70, cx + 270, cy + 76, m.oil, .{});
        // A wood hut between them, on the ground.
        list.fillRect(cx - 10, cy + 40, cx + 100, cy + 46, m.wood, .{});
        list.fillRect(cx - 10, cy + 46, cx - 2, cy + 120, m.wood, .{});
        list.fillRect(cx + 92, cy + 46, cx + 100, cy + 120, m.wood, .{});
        list.fillRect(cx + 20, cy + 100, cx + 70, cy + 120, m.wood, .{});
        // A steel rod into the pond and an ice block on a ledge.
        list.fillRect(cx + 130, cy + 116, cx + 290, cy + 118, m.steel, .{});
        list.fillRect(cx - 200, cy - 20, cx - 140, cy - 14, m.stone, .{});
        list.fillRect(cx - 190, cy - 40, cx - 150, cy - 20, m.ice, .{});
    }
    if (tick == 10) list.igniteRect(cx + 20, cy + 100, cx + 70, cy + 104);
    if (tick == 30) list.igniteRect(cx + 150, cy + 60, cx + 160, cy + 80); // oil on the pond
    if (tick >= 20 and tick < 200 and tick % 2 == 0) list.fillCircle(cx - 120, cy - 60, 4, m.water, .{ .only_air = true });
    if (tick >= 20 and tick < 300 and tick % 3 == 0) list.fillCircle(cx - 230, cy - 60, 3, m.sand, .{ .only_air = true });
    if (tick % 30 == 0) list.chargeCircle(cx + 131, cy + 117, 1);
}

pub const lighting_center = [2]i32{ 1024, 1040 };

fn lighting(tick: u32, seed: u32, m: *const Ids, list: *commands.CommandList) void {
    if (tick == 0) {
        var prng = std.Random.DefaultPrng.init(seed);
        const r = prng.random();
        // Rock mass with the cave carved out of it; open sky above y = 700.
        list.fillRect(560, 700, 1490, 1340, m.stone, .{});
        list.fillRect(700, 880, 1350, 1180, m.air, .{});
        // Rough ceiling and walls.
        var i: i32 = 0;
        while (i < 22) : (i += 1) {
            const cx = 700 + @mod(i * 31, 650);
            list.fillCircle(cx, 880 + r.intRangeAtMost(i32, -10, 6), r.intRangeAtMost(i32, 12, 30), m.air, .{});
        }
        list.fillCircle(705, 1000, 50, m.air, .{});
        list.fillCircle(1345, 1040, 45, m.air, .{});
        // Stalactites.
        i = 0;
        while (i < 9) : (i += 1) {
            const sx = 760 + i * 67 + r.intRangeAtMost(i32, -10, 10);
            list.fillCircle(sx, 880, r.intRangeAtMost(i32, 5, 9), m.stone, .{});
            list.fillCircle(sx, 892, 3, m.stone, .{});
        }
        // Skylight shaft to the surface with a glass pane.
        list.fillRect(1230, 700, 1270, 900, m.air, .{});
        list.fillRect(1230, 770, 1270, 776, m.glass, .{});
        // Lava pool sunk into the floor on the left.
        list.fillRect(740, 1180, 880, 1206, m.air, .{});
        list.fillRect(740, 1186, 880, 1206, m.lava, .{});
        // Stone pillars between the lava and the rest of the cave.
        list.fillRect(925, 930, 941, 1180, m.stone, .{});
        list.fillRect(1000, 1060, 1012, 1180, m.stone, .{});
        list.fillRect(988, 1052, 1024, 1062, m.stone, .{});
        // Glass tank of water.
        list.fillRect(1100, 1174, 1220, 1180, m.glass, .{});
        list.fillRect(1100, 1090, 1104, 1180, m.glass, .{});
        list.fillRect(1216, 1090, 1220, 1180, m.glass, .{});
        list.fillRect(1104, 1110, 1216, 1174, m.water, .{});
        // Freestanding glass pane in front of the right wall.
        list.fillRect(1300, 1080, 1306, 1180, m.glass, .{});
        // Brazier: a wooden stand under a flame.
        list.fillRect(1268, 1166, 1292, 1180, m.wood, .{});
        // A little molten glass dripping into a cup on the far left wall.
        list.fillRect(712, 1060, 740, 1066, m.stone, .{});
        list.fillRect(714, 1054, 738, 1060, m.molten_glass, .{});
        // Steam pocket rising out of the shaft.
        list.fillCircle(1250, 930, 10, m.steam, .{ .only_air = true, .coverage = 150 });
    }
    // Brazier flame: fed on the stand every few ticks; flame has a lifetime
    // (M3), so it rises a little and dies, flickering in place.
    if (tick % 3 == 0) list.fillCircle(1280, 1161, 4, m.flame, .{ .only_air = true, .coverage = 160 });
    // Smoke vent beside the lava, rising through its light.
    list.fillCircle(902, 1175, 4, m.smoke, .{ .only_air = true });
}

fn benchStatic(m: *const Ids, list: *commands.CommandList) void {
    list.fillRect(0, 1024, W, W, m.stone, .{});
    list.fillRect(0, 900, W, 1024, m.sand, .{});
    list.fillRect(200, 400, 1800, 420, m.stone, .{});
    list.fillRect(200, 300, 220, 400, m.stone, .{});
    list.fillRect(1780, 300, 1800, 400, m.stone, .{});
    list.fillRect(220, 340, 1780, 400, m.water, .{});
}

test "scenes are deterministic" {
    const ids: Ids = .{ .stone = 1, .sand = 2, .water = 3, .smoke = 4 };
    var a: commands.CommandList = .{};
    var b: commands.CommandList = .{};
    for ([_]u32{ 0, 1, 25, 199, 200 }) |t| {
        a.begin(t);
        b.begin(t);
        emit(.determinism, t, 7, &ids, &a);
        emit(.determinism, t, 7, &ids, &b);
        try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(a.slice()), std.mem.sliceAsBytes(b.slice()));
    }
}
