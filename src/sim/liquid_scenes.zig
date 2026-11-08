//! Liquid solver scenes (M6): the fluid scenarios of docs/04-fluids.md, with
//! the geometry of scenarios/{u_tube,dam_break,pool_sleep}.zon placed in a
//! 256 x 256 box at `origin` (walled with stone: the scenario world is not a
//! torus), plus the bench and showcase scenes. Pure functions of (tick,
//! seed), like every scene. Material stand-ins until the ZON table is wired
//! into the sim: bedrock -> stone, gravel -> sand.
const std = @import("std");
const cell = @import("cell.zig");
const commands = @import("commands.zig");
const Ids = @import("materials.zig").Ids;

/// Top-left of the scenario box in world pixels.
pub const origin = [2]i32{ 896, 896 };
pub const box = 256;

pub const Kind = enum { utube, dam, pool, slosh, slosh_1m, basin };

const List = commands.CommandList;

fn rect(list: *List, x: i32, y: i32, w: i32, h: i32, mat: u8, opts: commands.Options) void {
    list.fillRect(origin[0] + x, origin[1] + y, origin[0] + x + w, origin[1] + y + h, mat, opts);
}

fn circle(list: *List, x: i32, y: i32, r: i32, mat: u8) void {
    list.fillCircle(origin[0] + x, origin[1] + y, r, mat, .{});
}

/// The scenario world's edge: a stone frame around the 256 x 256 box.
fn frame(m: *const Ids, list: *List) void {
    rect(list, -16, -16, box + 32, 16, m.stone, .{});
    rect(list, -16, box, box + 32, 16, m.stone, .{});
    rect(list, -16, 0, 16, box, m.stone, .{});
    rect(list, box, 0, 16, box, m.stone, .{});
}

pub fn emit(kind: Kind, tick: u32, seed: u32, m: *const Ids, list: *List) void {
    _ = seed;
    switch (kind) {
        .utube => utube(tick, m, list),
        .dam => dam(tick, m, list),
        .pool => pool(tick, m, list),
        .slosh => slosh(tick, m, list),
        .slosh_1m => slosh1m(tick, m, list),
        .basin => basin(tick, m, list),
    }
}

/// scenarios/u_tube.zon
fn utube(tick: u32, m: *const Ids, list: *List) void {
    if (tick == 0) {
        frame(m, list);
        rect(list, 40, 40, 176, 200, m.stone, .{});
        rect(list, 60, 40, 20, 180, m.air, .{});
        rect(list, 176, 40, 20, 180, m.air, .{});
        rect(list, 60, 200, 136, 20, m.air, .{});
    }
    // Pour from tick 1: the setup fills of tick 0 would wake the first pour
    // at rest (command boxes wake liquid), throttling the stream.
    if (tick >= 1 and tick <= 60) rect(list, 60, 42, 20, 4, m.water, .{ .only_air = true });
}

/// scenarios/dam_break.zon
fn dam(tick: u32, m: *const Ids, list: *List) void {
    if (tick == 0) {
        frame(m, list);
        rect(list, 16, 232, 224, 8, m.stone, .{});
        rect(list, 16, 120, 4, 112, m.stone, .{});
        rect(list, 236, 120, 4, 112, m.stone, .{});
        rect(list, 128, 120, 1, 112, m.wood, .{});
        rect(list, 20, 150, 108, 82, m.water, .{});
    }
    if (tick == 60) rect(list, 128, 120, 1, 112, m.air, .{});
}

/// scenarios/pool_sleep.zon
fn pool(tick: u32, m: *const Ids, list: *List) void {
    if (tick == 0) {
        frame(m, list);
        rect(list, 16, 240, 224, 8, m.stone, .{});
        rect(list, 16, 180, 4, 60, m.stone, .{});
        rect(list, 236, 180, 4, 60, m.stone, .{});
    }
    if (tick >= 1 and tick <= 60) rect(list, 100, 120, 56, 1, m.water, .{ .only_air = true });
    if (tick == 400) circle(list, 40, 200, 3, m.sand);
}

/// Bench: a 1024 x 512 water body released into a 1600-wide tank; it
/// sloshes from wall to wall for the whole run (about 500K particles awake).
fn slosh(tick: u32, m: *const Ids, list: *List) void {
    if (tick != 0) return;
    const x0: i32 = 224;
    const y0: i32 = 1000;
    list.fillRect(x0 - 16, y0 + 600, x0 + 1616, y0 + 632, m.stone, .{});
    list.fillRect(x0 - 16, y0 - 200, x0, y0 + 600, m.stone, .{});
    list.fillRect(x0 + 1600, y0 - 200, x0 + 1616, y0 + 600, m.stone, .{});
    list.fillRect(x0, y0 + 88, x0 + 1024, y0 + 600, m.water, .{});
    // Filled water starts asleep; wake all of it (the budget spreads the
    // wake over the first ticks).
    list.wakeLiquid(x0 + 512, y0 + 344, 600, 1);
}

/// Bench at the budget's particle count: 1400 x 740 water (1.04M cells,
/// capacity 1M: the last few hundred stay cellular) in a 1900-wide tank.
fn slosh1m(tick: u32, m: *const Ids, list: *List) void {
    if (tick != 0) return;
    const x0: i32 = 64;
    const y0: i32 = 1000;
    list.fillRect(x0 - 16, y0 + 800, x0 + 1916, y0 + 832, m.stone, .{});
    list.fillRect(x0 - 16, y0 - 100, x0, y0 + 800, m.stone, .{});
    list.fillRect(x0 + 1900, y0 - 100, x0 + 1916, y0 + 800, m.stone, .{});
    list.fillRect(x0, y0 + 60, x0 + 1400, y0 + 800, m.water, .{});
    list.wakeLiquid(x0 + 700, y0 + 430, 800, 1);
}

/// Showcase: a stone basin with a raised water block that falls and sloshes,
/// a dam of wood in a second basin removed at tick 90, a pour.
fn basin(tick: u32, m: *const Ids, list: *List) void {
    if (tick == 0) {
        list.fillRect(600, 1400, 1500, 1420, m.stone, .{});
        list.fillRect(600, 1100, 616, 1400, m.stone, .{});
        list.fillRect(1484, 1100, 1500, 1400, m.stone, .{});
        list.fillRect(1000, 1340, 1040, 1400, m.stone, .{});
        list.fillCircle(1250, 1360, 30, m.stone, .{});
        list.fillRect(616, 1200, 820, 1400, m.water, .{});
        list.fillRect(840, 1300, 1000, 1400, m.water, .{});
        list.fillRect(1040, 1330, 1484, 1400, m.water, .{});
    }
    if (tick >= 30 and tick < 400 and tick % 2 == 0) list.fillCircle(1400, 1000, 6, m.water, .{ .only_air = true });
}
