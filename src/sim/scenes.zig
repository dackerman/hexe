//! Fixed, seeded scenes expressed as command lists. Every scene is a pure
//! function of (tick, seed): the GPU run and the CPU reference call `emit`
//! with the same arguments and get the same commands.
const std = @import("std");
const cell = @import("cell.zig");
const commands = @import("commands.zig");
const materials = @import("materials.zig");
const Ids = materials.Ids;

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
};

/// `m` holds the material ids, looked up by name from the loaded set.
pub fn emit(scene: Scene, tick: u32, seed: u32, m: *const Ids, list: *commands.CommandList) void {
    switch (scene) {
        .empty, .noise => {},
        .sandbox => sandbox(tick, seed, m, list),
        .determinism => determinism(tick, seed, m, list),
        .bench_static => if (tick == 0) benchStatic(m, list),
        .bench_active => if (tick == 0) list.fillRect(0, 0, cell.world_size, cell.world_size, m.sand, .{ .coverage = 128 }),
        .bench_fire => benchFire(tick, m, list),
        .fire_demo => fireDemo(tick, m, list),
        .bench_mixed => if (tick == 0) {
            list.fillRect(0, 0, W, W, m.water, .{ .coverage = 80 });
            list.fillRect(0, 0, W, W, m.sand, .{ .coverage = 80, .only_air = true });
            list.fillRect(0, 0, W, W, m.smoke, .{ .coverage = 90, .only_air = true });
        },
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
