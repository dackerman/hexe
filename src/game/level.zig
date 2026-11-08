//! The Proving Grounds (docs/07-tech-demo.md): the handcrafted tech-demo
//! level. A 2048 x 1536 map with open sky above (sunlight) and bedrock below
//! and at the torus seam, three tiers of zones joined by stone corridors and
//! shafts with ledges (rises of at most 30 px, the player jumps ~40 px):
//!
//!   surface (ground y 400)  powder yard | hub (spawn) | burning village | ruin
//!   tier 2  (y 470-880)     waterworks | shaft | steam room | walkway | pressure corridor over an open field
//!   tier 3  (y 1200-1500)   glassworks | electric pool | arena (lava, flooded, glass) | acid pit
//!
//! Scenes (src/sim/scenes.zig): `proving_grounds` builds the level (tick
//! 0, beams at tick 4) and leaves it to the player; `proving_grounds_auto`
//! also fires the showcase events on `auto_schedule`; `proving_grounds_burst`
//! fires all of them inside 5 s (`burst_schedule`, `--bench-demo`). Every
//! function here is a pure function of (tick, seed), like every scene.
//! Decisions: docs/decisions/130-level-layout.md, 131-level-handcrafted-map.md,
//! 132-level-steam-room.md, 133-level-showcase.md.
const std = @import("std");
const commands = @import("../sim/commands.zig");
const materials = @import("../sim/materials.zig");
const cell = @import("../sim/cell.zig");
const BodySim = @import("../sim/bodies_sim.zig").BodySim;
const bodies = @import("bodies");
const Hud = @import("../render/hud.zig").Hud;
const Renderer = @import("../render/renderer.zig").Renderer;

const Ids = materials.Ids;
const List = commands.CommandList;
const air = materials.air;

pub const Variant = enum { play, auto, burst };

/// Map size; below `height` is bedrock to the bottom of the 2048 torus.
pub const width = 2048;
pub const height = 1536;
/// Surface ground level (top of the stone).
pub const ground = 400;

// ===========================================================================
// Gameplay API

/// Player spawn: feet on the hub floor.
pub const spawn_point = [2]i32{ 700, ground - 2 };

pub const EnemyKind = enum { walker, flyer };
pub const EnemySpawn = struct { x: i32, y: i32, kind: EnemyKind };

/// Enemy spawn points (feet position for walkers, center for flyers).
pub const enemy_spawns = [_]EnemySpawn{
    .{ .x = 760, .y = 1478, .kind = .walker }, // standing in the electric pool
    .{ .x = 1180, .y = 1398, .kind = .walker }, // on the wooden floor over the lava pit
    .{ .x = 1380, .y = 1296, .kind = .flyer }, // in the flooded room's air pocket
    .{ .x = 1612, .y = 1478, .kind = .walker }, // behind the glass, by the barrels
    .{ .x = 1712, .y = 1478, .kind = .walker },
    .{ .x = 1260, .y = ground - 8, .kind = .walker }, // patrolling the village (on the moss)
};

/// Zone anchors (world pixels), for cameras, signs and the report.
pub const Zone = enum { hub, powder_yard, waterworks, steam_room, corridor, village, glassworks, ruin, electric_pool, arena, acid_pit };
pub const anchors = std.enums.EnumArray(Zone, [2]i32).init(.{
    .hub = .{ 680, 360 },
    .powder_yard = .{ 500, 330 },
    .waterworks = .{ 480, 650 },
    .steam_room = .{ 760, 700 },
    .corridor = .{ 1440, 740 },
    .village = .{ 1050, 340 },
    .glassworks = .{ 480, 1370 },
    .ruin = .{ 1564, 300 },
    .electric_pool = .{ 780, 1390 },
    .arena = .{ 1390, 1360 },
    .acid_pit = .{ 1875, 1360 },
});

pub const Sign = struct { x: i32, y: i32, text: []const u8, color: [4]f32 = .{ 1.0, 0.92, 0.6, 1.0 } };

const title_color = [4]f32{ 1.0, 0.75, 0.35, 1.0 };
const hint_color = [4]f32{ 0.75, 0.9, 1.0, 1.0 };

/// Floating labels (docs/07): zone names and what to try.
pub const signs = [_]Sign{
    .{ .x = 680, .y = 300, .text = "PROVING GROUNDS", .color = title_color },
    .{ .x = 600, .y = 334, .text = "TOOL RACK", .color = title_color },
    .{ .x = 600, .y = 344, .text = "1 FIRE  2 BLAST  3 WATER  4 LAVA  5 ACID", .color = hint_color },
    .{ .x = 600, .y = 354, .text = "6 DIG  7 LIGHTNING  8 CUTTER  9 POWDER  0 PAINT", .color = hint_color },
    .{ .x = 620, .y = 392, .text = "SHAFT DOWN", .color = hint_color },
    .{ .x = 260, .y = 290, .text = "POWDER YARD: SPRAY, PILE, BLAST" },
    .{ .x = 150, .y = 514, .text = "PIPE VALVE: OPEN IT" },
    .{ .x = 250, .y = 560, .text = "DAM: SHOOT THE WOODEN GATE" },
    .{ .x = 480, .y = 594, .text = "U-TUBE: BREAK THE PLUG" },
    .{ .x = 714, .y = 626, .text = "STEAM ROOM: BREAK THE PLUG" },
    .{ .x = 714, .y = 637, .text = "WOOD WALL VS CONCRETE WALL", .color = hint_color },
    .{ .x = 1440, .y = 606, .text = "PRESSURE CORRIDOR: LIGHT THE POWDER" },
    .{ .x = 1440, .y = 760, .text = "OPEN FIELD: SAME CHARGE, NO WALLS" },
    .{ .x = 1050, .y = 300, .text = "BURNING VILLAGE: MIND THE LAVA" },
    .{ .x = 330, .y = 1290, .text = "GLASSWORKS: CUT THE GATE" },
    .{ .x = 206, .y = 1222, .text = "SAND SILO", .color = hint_color },
    .{ .x = 1660, .y = 236, .text = "RUIN: CUT THE BEAM" },
    .{ .x = 1900, .y = 300, .text = "SHOOT ME", .color = .{ 1.0, 0.45, 0.35, 1.0 } },
    .{ .x = 760, .y = 1378, .text = "ELECTRIC POOL: ZAP THE RAIL" },
    .{ .x = 1160, .y = 1300, .text = "ARENA: LAVA PIT" },
    .{ .x = 1380, .y = 1280, .text = "FLOODED ROOM" },
    .{ .x = 1655, .y = 1330, .text = "BARRELS BEHIND GLASS" },
    .{ .x = 1875, .y = 1310, .text = "ACID PIT: MIND THE BRIDGE" },
};

/// Floating signs through the HUD. Signs farther than about two screens
/// from the camera center are skipped (the HUD holds 64 world texts).
pub fn drawSignsHud(hud: *Hud, cam_x: i32, cam_y: i32) void {
    for (signs) |s| {
        if (@abs(s.x - cam_x) > 1400 or @abs(s.y - cam_y) > 900) continue;
        hud.printWorldColor(s.x, s.y, s.color, "{s}", .{s.text});
    }
}

/// The per-frame hook for the app: `cam_x, cam_y` is the view center.
pub fn drawSigns(engine: anytype, cam_x: i32, cam_y: i32) void {
    drawSignsHud(&engine.hud, cam_x, cam_y);
}

pub const Light = struct { x: f32, y: f32, radius: f32, color: [3]f32 };
const torch = [3]f32{ 1.0, 0.62, 0.3 };
const cold = [3]f32{ 0.45, 0.7, 1.0 };

/// Placed lights: torches at the hub, the shafts and the corridors (lava,
/// flame and molten glass light themselves).
pub const lights = [_]Light{
    .{ .x = 566, .y = 372, .radius = 70, .color = torch }, // hub
    .{ .x = 778, .y = 372, .radius = 70, .color = torch },
    .{ .x = 620, .y = 560, .radius = 60, .color = torch }, // S1
    .{ .x = 560, .y = 690, .radius = 50, .color = torch },
    .{ .x = 620, .y = 840, .radius = 60, .color = torch }, // walkway
    .{ .x = 930, .y = 840, .radius = 70, .color = torch },
    .{ .x = 1050, .y = 600, .radius = 50, .color = torch }, // fuse alcove
    .{ .x = 1010, .y = 1030, .radius = 60, .color = torch }, // S2
    .{ .x = 1100, .y = 860, .radius = 60, .color = torch }, // field
    .{ .x = 300, .y = 1228, .radius = 70, .color = torch }, // hallway
    .{ .x = 640, .y = 1228, .radius = 70, .color = torch },
    .{ .x = 1300, .y = 1228, .radius = 70, .color = torch },
    .{ .x = 1720, .y = 1228, .radius = 70, .color = torch },
    .{ .x = 760, .y = 1320, .radius = 90, .color = cold }, // pool
    .{ .x = 300, .y = 760, .radius = 80, .color = cold }, // waterworks
    .{ .x = 1500, .y = 300, .radius = 60, .color = torch }, // ruin
};

pub fn drawLights(r: *Renderer) void {
    for (lights) |l| r.addLight(l.x, l.y, l.radius, l.color);
}

/// Lights and every sign (render/demo.zig calls this for the level scenes;
/// there are fewer signs than HUD world-text slots).
pub fn decorate(r: *Renderer, hud: *Hud) void {
    drawLights(r);
    for (signs) |s| hud.printWorldColor(s.x, s.y, s.color, "{s}", .{s.text});
}

// ===========================================================================
// Showcase schedule

pub const Schedule = struct {
    dam: u32,
    steam_plug: u32,
    corridor: u32,
    field: u32,
    village: u32,
    gate: u32,
    pillar: u32,
    /// Beam: the crate lands, then the torch takes 1/3, 2/3, then the rest.
    beam_cuts: [5]u32,
};

/// `proving_grounds_auto`: one event at a time, seconds apart.
pub const auto_schedule: Schedule = .{
    .dam = 300,
    .steam_plug = 330,
    .corridor = 420,
    .field = 480,
    .village = 480,
    .gate = 540,
    .pillar = 600,
    .beam_cuts = .{ 360, 600, 840, 1000, 1040 },
};

/// `proving_grounds_burst` (`--bench-demo`): everything inside 5 s.
pub const burst_schedule: Schedule = .{
    .dam = 300,
    .steam_plug = 310,
    .corridor = 330,
    .field = 340,
    .village = 360,
    .gate = 380,
    .pillar = 420,
    .beam_cuts = .{ 320, 400, 480, 560, 580 },
};

pub fn schedule(v: Variant) ?Schedule {
    return switch (v) {
        .play => null,
        .auto => auto_schedule,
        .burst => burst_schedule,
    };
}

// ===========================================================================
// Geometry (kept in one place: the scripted events refer to it)

// Waterworks
const cave = .{ .x0 = 40, .y0 = 470, .x1 = 540, .floor = 830 };
const res_x0 = 60;
const res_x1 = 250; // the dam's column
const res_top = 584;
const res_floor = 700;
const basin_x1 = 520;
const header = .{ .x0 = 44, .y0 = 474, .x1 = 120, .y1 = 532 };
const pipe_y = 520; // bore 520..526
const valve_x = 120;
const utube = .{ .x0 = 442, .y0 = 600, .x1 = 518, .y1 = 688 };
const utube_plug_x = 472;

// Steam room (sealed volume interior)
const steam = .{ .x0 = 664, .y0 = 652, .x1 = 764, .y1 = 760 };
const steam_plug = .{ .x0 = 708, .y0 = 694, .x1 = 716, .y1 = 698 };
/// Width of the open lava strip by the wood wall.
const steam_strip = 16;
/// State byte (health) of the wood wall: weathered planks.
const steam_wall_health = 12;

// Shafts
const s1 = .{ .x0 = 600, .x1 = 640 };
const s2 = .{ .x0 = 990, .x1 = 1030, .y0 = 586 };
const walk = .{ .x0 = 540, .x1 = 1040, .y0 = 812, .floor = 860 };

// Pressure corridor and open field
const corr_y = 616; // corridor rows 616..619
const corr_x0 = 1060;
const corr_x1 = 1800;
const field = .{ .x0 = 1040, .y0 = 650, .x1 = 2004, .floor = 880 };
const plug_x0 = 1096;
const plug_step = 32;
const plug_count = 20;
const plug_w = 2;
const powder_x0 = 1060;
const powder_x1 = 1070; // 10 x 3 cells at the corridor's closed end
const field_powder_x0 = 1058;
const field_powder_x1 = 1073; // 15 x 2 cells on the field floor

// Village
const hut1 = .{ .x0 = 832, .x1 = 912 };
const hut2 = .{ .x0 = 966, .x1 = 1046 };
const hut3 = .{ .x0 = 1110, .x1 = 1210 };

// Tier 3
const hall = .{ .y0 = 1200, .floor = 1260 };
const lava_tank = .{ .x0 = 80, .x1 = 300, .y0 = 1312, .y1 = 1340 };
const gate = .{ .x0 = 150, .x1 = 270, .y0 = 1340, .y1 = 1348 };
const sand_pit = .{ .x0 = 154, .x1 = 470, .y0 = 1424, .y1 = 1500 };
/// A sand silo over the lava tank; its wooden floor gate drops sand into the lava.
const silo = .{ .x0 = 176, .x1 = 236, .y0 = 1226, .y1 = 1286 };

// Ruin
const ruin_left = .{ .x0 = 1360, .x1 = 1540 };
const ruin_right = .{ .x0 = 1780, .x1 = 2010 };
const beam_y = 300;
const pillar = .{ .x0 = 1892, .x1 = 1908, .y0 = 212 };
const slab = .{ .x0 = 1812, .x1 = 1990, .y0 = 200, .y1 = 212 };
/// Where the torch cuts the lower beam: under the crate, mid-span.
const beam_cut_x = 1660;

// ===========================================================================
// Scene: cells

pub fn emit(v: Variant, tick: u32, seed: u32, m: *const Ids, list: *List) void {
    var b: B = .{ .l = list, .m = m };
    // Everything at tick 0: the air field reads the first tick's walls
    // without its mass-conservation transfers; walls built later push their
    // air out as blasts (docs/decisions/131-level-handcrafted-map.md).
    if (tick == 0) {
        shell(&b);
        veins(&b, seed);
        surface(&b);
        tier2(&b, seed);
        tier3(&b);
        details(&b);
        liquids(&b);
    }
    if (tick % magma_period == magma_period / 2) magma(&b, tick, schedule(v));
    if (schedule(v)) |s| events(&b, s, tick);
}

/// 1256 C as a temperature byte (C = 8 t - 40).
const glass_magma_temp: u8 = 162;
/// Ticks between refreshes of the level's lava bodies.
const magma_period = 20;

/// Lava enclosed by cold rock gives its heat away and freezes to stone in a
/// few seconds. The level's lava is fed from below: every `magma_period`
/// ticks each lava body's lava cells are repainted as fresh lava (fill only
/// over lava, so crust that already froze and lava that flowed out stay as
/// they are; docs/decisions/132-level-steam-room.md).
fn magma(b: *B, tick: u32, sched: ?Schedule) void {
    const m = b.m;
    const o: commands.Options = .{ .only = m.lava };
    b.rectO(steam.x0, steam.y1 - 18, steam.x1, steam.y1, m.lava, o);
    // The steam room's open strip: the crust that water leaves on it melts
    // again, so it keeps flashing water to steam while water arrives.
    b.rectO(steam.x1 - steam_strip - 4, steam.y1 - 20, steam.x1 - 4, steam.y1, m.lava, .{ .only = m.stone });
    // The glassworks is fed hotter magma, past sand's melting point (1200 C)
    // and short of stone's (1300 C): sand it touches or falls into melts to
    // molten glass, not only where the lava + sand reaction picks.
    b.rectO(lava_tank.x0, lava_tank.y0 - 8, lava_tank.x1, lava_tank.y1, m.lava, .{ .only = m.lava, .temperature = glass_magma_temp });
    // The lava that poured into the sand pit stays hot too: the pit melts
    // into a pool of molten glass. The showcase lets it go after a while so
    // the melt cools and glass shows.
    const pit_hot = if (sched) |s| tick < s.gate + 420 else true;
    if (pit_hot) b.rectO(sand_pit.x0, lava_tank.y1 + 8, sand_pit.x1, sand_pit.y1, m.lava, .{ .only = m.lava, .temperature = glass_magma_temp });
    b.rectO(814, ground - 40, hut1.x0 - 4, ground - 6, m.lava, o);
    b.rectO(1070, 1430, 1280, 1470, m.lava, o);
}

const B = struct {
    l: *List,
    m: *const Ids,

    fn rect(b: *B, x0: i32, y0: i32, x1: i32, y1: i32, mat: u8) void {
        b.l.fillRect(x0, y0, x1, y1, mat, .{});
    }
    fn rectO(b: *B, x0: i32, y0: i32, x1: i32, y1: i32, mat: u8, o: commands.Options) void {
        b.l.fillRect(x0, y0, x1, y1, mat, o);
    }
    fn clear(b: *B, x0: i32, y0: i32, x1: i32, y1: i32) void {
        b.l.fillRect(x0, y0, x1, y1, air, .{});
    }
    fn circle(b: *B, x: i32, y: i32, r: i32, mat: u8) void {
        b.l.fillCircle(x, y, r, mat, .{});
    }
    fn line(b: *B, x0: i32, y0: i32, x1: i32, y1: i32, r: i32, mat: u8) void {
        b.l.fillLine(x0, y0, x1, y1, r, mat, .{});
    }
    /// A box of `mat` walls `t` thick around the interior [x0,x1)x[y0,y1).
    fn box(b: *B, x0: i32, y0: i32, x1: i32, y1: i32, t: i32, mat: u8) void {
        b.rect(x0 - t, y0 - t, x1 + t, y1 + t, mat);
        b.clear(x0, y0, x1, y1);
    }
    /// Stone ledges in a walled shaft [x0, x1): the first at `y_first`,
    /// then every `rise` px up while below `y_top`, alternating sides
    /// (a ladder of platforms; there is no ladder mechanic). Every ledge
    /// touches a wall, so none comes loose as a body.
    fn ledges(b: *B, x0: i32, x1: i32, y_top: i32, y_first: i32, rise: i32, first_left: bool) void {
        const w = @divTrunc(x1 - x0, 2) + 4;
        var y = y_first;
        var left = first_left;
        while (y > y_top + 8) : (y -= rise) {
            if (left) b.rect(x0, y, x0 + w, y + 5, b.m.stone) else b.rect(x1 - w, y, x1, y + 5, b.m.stone);
            left = !left;
        }
    }
    /// Lumpy ceiling: stone bumps hanging from row `y` (only into air).
    fn bumps(b: *B, x0: i32, x1: i32, y: i32, max_r: i32, seed: u32) void {
        var x = x0 + 8;
        var k: u32 = seed;
        while (x < x1 - 8) {
            k = cell.hashU32(k +% @as(u32, @bitCast(x)));
            const r: i32 = 3 + @as(i32, @intCast(k % @as(u32, @intCast(max_r - 2))));
            b.l.fillCircle(x, y, r, b.m.stone, .{ .only_air = true });
            x += 10 + @as(i32, @intCast((k >> 8) % 22));
        }
    }
};

/// Bedrock frame and the rock mass under the sky.
fn shell(b: *B) void {
    const m = b.m;
    b.rect(0, height, width, cell.world_size, m.bedrock);
    b.rect(0, 0, 24, height, m.bedrock);
    b.rect(width - 24, 0, width, height, m.bedrock);
    b.rect(24, ground, width - 24, height, m.stone);
    // Bedrock lumps along the floor so it is not a ruler line.
    var x: i32 = 40;
    while (x < width - 40) : (x += 96) b.circle(x, height + 4, 30 + @mod(x * 7, 23), m.bedrock);
}

/// Dirt and gravel pockets in the rock (only over stone), clustered into
/// veins. The zones are carved afterwards, so pockets only show in rock
/// faces, where a little loose material trickles out.
fn veins(b: *B, seed: u32) void {
    const m = b.m;
    var prng = std.Random.DefaultPrng.init(@as(u64, seed) *% 0x9e3779b97f4a7c15 +% 130);
    const r = prng.random();
    var i: u32 = 0;
    while (i < 70) : (i += 1) {
        var x = r.intRangeAtMost(i32, 40, width - 40);
        var y = r.intRangeAtMost(i32, ground + 24, height - 20);
        const mat = switch (i % 4) {
            0, 1 => m.gravel,
            2 => m.dirt,
            else => m.bedrock,
        };
        const blobs = r.intRangeAtMost(u32, 3, 7);
        var k: u32 = 0;
        while (k < blobs) : (k += 1) {
            const rad = if (mat == m.bedrock) r.intRangeAtMost(i32, 3, 7) else r.intRangeAtMost(i32, 4, 11);
            // Full coverage: speckled powder would leave stone crumbs that the
            // connectivity pass turns into bodies.
            b.l.fillCircle(x, y, rad, mat, .{ .only = m.stone });
            x += r.intRangeAtMost(i32, -18, 18);
            y += r.intRangeAtMost(i32, -9, 9);
        }
    }
}

// ---------------------------------------------------------------------------
// Surface: powder yard, hub, village, ruin

fn surface(b: *B) void {
    const m = b.m;
    // ---- powder yard (x 24-560): a stone hump under sand dunes, a dirt
    // hill, a gravel pile, a wooden corral fence.
    b.circle(130, ground + 40, 70, m.stone);
    b.l.fillCircle(130, ground + 30, 105, m.sand, .{ .only_air = true });
    b.l.fillCircle(250, ground + 20, 60, m.sand, .{ .only_air = true });
    b.l.fillCircle(430, ground + 40, 72, m.dirt, .{ .only_air = true });
    b.l.fillCircle(530, ground + 6, 30, m.gravel, .{ .only_air = true });
    var px: i32 = 300;
    while (px <= 356) : (px += 14) b.rect(px, ground - 26, px + 3, ground, m.wood);
    b.rect(300, ground - 22, 359, ground - 20, m.wood);
    b.rect(300, ground - 12, 359, ground - 10, m.wood);

    // ---- hub (x 560-780): flat floor, tool rack plinth, the shaft down.
    b.rect(560, ground - 4, 780, ground, m.stone);
    b.rect(566, ground - 22, 596, ground, m.stone); // tool rack plinth
    var rx: i32 = 568;
    while (rx < 596) : (rx += 7) b.rect(rx, ground - 34 + @mod(rx, 3) * 2, rx + 2, ground - 22, m.steel);
    b.rect(566, ground - 36, 596, ground - 34, m.wood);
    b.rect(776, ground - 30, 780, ground - 4, m.stone);

    village(b);
    ruin(b);
}

fn hut(b: *B, x0: i32, x1: i32, h: i32, door_right: bool) void {
    const m = b.m;
    const top = ground - h;
    b.rect(x0, top, x0 + 4, ground, m.wood);
    b.rect(x1 - 4, top, x1, ground, m.wood);
    b.rect(x0 - 4, top - 4, x1 + 4, top, m.wood); // ceiling beam
    const mid = @divTrunc(x0 + x1, 2);
    b.line(x0 - 6, top - 4, mid, top - 26, 2, m.wood); // roof
    b.line(mid, top - 26, x1 + 6, top - 4, 2, m.wood);
    if (door_right) b.clear(x1 - 4, ground - 30, x1, ground) else b.clear(x0, ground - 30, x0 + 4, ground);
    // Interior: a table, a bed, a shelf on the wall.
    b.rect(x0 + 12, ground - 14, x0 + 34, ground - 12, m.wood);
    b.rect(x0 + 13, ground - 12, x0 + 15, ground, m.wood);
    b.rect(x0 + 31, ground - 12, x0 + 33, ground, m.wood);
    b.rect(x1 - 30, ground - 8, x1 - 6, ground, m.wood);
    b.rect(x0 + 4, top + 10, x0 + 26, top + 12, m.wood);
}

/// A barrel: a wood box (2 px walls) full of `fill`.
fn barrel(b: *B, x0: i32, y1: i32, w: i32, h: i32, fill: u8) void {
    b.rect(x0, y1 - h, x0 + w, y1, b.m.wood);
    b.rect(x0 + 2, y1 - h + 2, x0 + w - 2, y1 - 2, fill);
}

fn village(b: *B) void {
    const m = b.m;
    // A rock outcrop with a lava seep; the first hut leans on it, 4 px of
    // stone from the lava: the heat creeps through and lights it.
    b.rect(790, ground - 44, hut1.x0, ground, m.stone);
    b.circle(806, ground - 44, 18, m.stone);
    b.rect(814, ground - 40, hut1.x0 - 4, ground - 6, m.lava);
    b.clear(814, ground - 56, hut1.x0 - 4, ground - 40); // the seep's mouth
    hut(b, hut1.x0, hut1.x1, 56, true);
    hut(b, hut2.x0, hut2.x1, 50, false);
    hut(b, hut3.x0, hut3.x1, 64, false);
    b.rect(hut3.x0 + 4, ground - 36, hut3.x0 + 60, ground - 34, m.wood); // loft
    // Oil barrels between the huts and in hut 2.
    barrel(b, 922, ground, 16, 20, m.oil);
    barrel(b, 940, ground, 16, 20, m.oil);
    barrel(b, hut2.x1, ground, 18, 22, m.oil); // against hut 2's wall
    barrel(b, hut2.x1 + 18, ground, 14, 18, m.oil);
    barrel(b, hut2.x0 + 40, ground - 8, 12, 12, m.oil);
    // An oil puddle in a stone dip past hut 2.
    // ... and a spill from them to hut 3's wall.
    b.clear(hut2.x1 + 32, ground - 1, hut3.x0 + 1, ground + 3);
    b.rect(hut2.x1 + 32, ground, hut3.x0 + 1, ground + 3, m.oil);
    // Moss patch (hay) past the last hut.
    b.rect(1220, ground - 6, 1310, ground, m.moss);
    b.circle(1240, ground - 6, 6, m.moss);
    b.circle(1270, ground - 5, 7, m.moss);
    b.circle(1296, ground - 6, 5, m.moss);
    b.rect(1316, ground - 10, 1336, ground, m.wood); // woodpile
}

fn ruin(b: *B) void {
    const m = b.m;
    // Left block: two storeys of concrete, glass windows, a stair hole.
    const L = ruin_left;
    b.rect(L.x0, 240, L.x1, 248, m.concrete); // roof
    b.rect(L.x0, 248, L.x0 + 8, ground, m.concrete);
    b.rect(L.x1 - 8, 248, L.x1, ground, m.concrete);
    b.rect(L.x0, 320, L.x1, 328, m.concrete); // second floor
    b.clear(L.x0, ground - 34, L.x0 + 8, ground); // door
    b.clear(L.x0 + 20, 320, L.x0 + 52, 328); // stair hole
    b.rect(L.x0 + 60, ground - 26, L.x0 + 90, ground, m.concrete); // steps
    b.rect(L.x0 + 30, ground - 52, L.x0 + 60, ground, m.concrete);
    b.rect(L.x0, 262, L.x0 + 8, 296, m.glass); // windows
    b.rect(L.x1 - 8, 340, L.x1, 376, m.glass);
    b.rect(L.x0 + 110, 340, L.x0 + 114, ground, m.glass); // glass partition
    b.clear(L.x1 - 40, 240, L.x1 - 24, 244); // a notch in the roof
    b.l.fillCircle(L.x0 + 150, ground - 4, 6, m.rubble, .{ .only_air = true });
    // Right block: wall, a hall whose roof slab stands on one pillar.
    const R = ruin_right;
    b.rect(R.x0, 160, R.x0 + 8, ground, m.concrete);
    b.rect(R.x0, 160, R.x0 + 30, 168, m.concrete);
    b.rect(R.x0, 330, R.x0 + 8, 364, m.glass);
    b.rect(R.x1 - 8, 190, R.x1, ground, m.concrete);
    // The watchtower: a roof slab on a single tall pillar (shoot me).
    b.rect(slab.x0, slab.y0, slab.x1, slab.y1, m.concrete);
    b.rect(pillar.x0, pillar.y0, pillar.x1, ground, m.concrete);
    // (Nothing on top: the whole tower must lie inside the connectivity
    // region of the charge, 256 px around it, or it counts as anchored.)
    // The courtyard between the blocks: gravel and a steel plate standing
    // on the ground (ricochet).
    b.rect(1560, ground - 2, 1760, ground, m.gravel);
    b.line(1570, ground - 2, 1590, ground - 30, 2, m.steel);
}

// ---------------------------------------------------------------------------
// Tier 2: waterworks, shaft S1, steam room, walkway, shaft S2, corridor and field

fn tier2(b: *B, seed: u32) void {
    const m = b.m;
    // Shaft S1 from the hub down to the walkway; a side passage at its
    // middle leads onto the waterworks rim.
    b.clear(s1.x0, ground - 4, s1.x1, walk.floor);
    b.clear(basin_x1, 668, s1.x0, 704);
    b.ledges(s1.x0, s1.x1, ground, 832, 28, true);
    b.box(walk.x0, walk.y0, walk.x1, walk.floor, 4, m.stone);
    b.bumps(walk.x0 + 110, 760, walk.y0, 7, seed);
    b.bumps(910, s2.x0 - 4, walk.y0, 7, seed);

    // ---- waterworks cave.
    b.box(cave.x0, cave.y0, cave.x1, cave.floor, 6, m.stone);
    b.bumps(cave.x0 + 90, cave.x1, cave.y0, 12, seed +% 1);
    b.rect(cave.x0, res_floor, res_x1 + 1, res_floor + 12, m.stone); // reservoir floor
    b.rect(cave.x0, res_top - 30, res_x0, res_floor, m.stone); // its back wall
    b.rect(res_x1, res_top - 10, res_x1 + 1, res_floor, m.wood); // the 1-px dam
    b.rect(res_x1 - 3, res_top - 14, res_x1 + 4, res_top - 10, m.stone); // dam cap
    b.rect(basin_x1, 704, cave.x1, cave.floor, m.stone); // basin rim
    b.circle(340, cave.floor, 14, m.stone); // boulders: the wave flows around them
    b.circle(410, cave.floor - 4, 9, m.stone);
    // Header tank, valve and the long pipe along the ceiling, dropping
    // into the basin.
    b.box(header.x0, header.y0, header.x1, header.y1, 4, m.stone);
    b.rect(header.x1, pipe_y - 4, 404, pipe_y + 10, m.stone);
    b.clear(header.x1, pipe_y, 400, pipe_y + 6);
    b.rect(394, pipe_y - 4, 410, 640, m.stone);
    b.clear(398, pipe_y, 404, 640);
    b.rect(valve_x, pipe_y, valve_x + 1, pipe_y + 6, m.wood); // valve
    b.rect(200, pipe_y + 3, 206, pipe_y + 6, m.stone); // baffles in the bore
    b.rect(300, pipe_y, 306, pipe_y + 3, m.stone);
    // Glass U-tube on a shelf on a stone post.
    b.rect(utube.x0 - 4, utube.y1, basin_x1, utube.y1 + 8, m.stone);
    b.rect(474, utube.y1 + 8, 490, cave.floor, m.stone);
    b.rect(utube.x0, utube.y0, utube.x1, utube.y1, m.glass);
    b.clear(utube.x0 + 2, utube.y0, utube.x0 + 12, utube.y1 - 2); // left arm
    b.clear(utube.x1 - 12, utube.y0, utube.x1 - 2, utube.y1 - 2); // right arm
    b.clear(utube.x0 + 2, utube.y1 - 12, utube.x1 - 2, utube.y1 - 2); // bend
    b.clear(utube.x0 + 14, utube.y0 - 1, utube.x1 - 14, utube.y1 - 14); // between the arms
    b.rect(utube_plug_x, utube.y1 - 12, utube_plug_x + 2, utube.y1 - 2, m.wood); // plug
    // In 2D the tube's inner wall is an island: hang it from the ceiling
    // by a steel rod, or it comes loose when the plug goes.
    b.rect(utube.x0 + 36, cave.y0, utube.x0 + 38, utube.y1 - 13, m.steel);

    // ---- steam room: sealed stone room, concrete left wall, wood right
    // wall above the lava, lava floor under a 2 px stone divider, water
    // tank with a wooden plug hung from the ceiling.
    const s = steam;
    b.rect(s.x0 - 10, s.y0 - 10, s.x1 + 10, s.y1 + 10, m.stone);
    b.rect(s.x0 - 10, s.y0, s.x0, s.y1 - 24, m.concrete);
    b.clear(s.x0, s.y0, s.x1, s.y1);
    b.clear(s.x1 + 2, s.y0 - 10, 900, walk.y0); // gallery beyond the wood wall
    b.rectO(s.x1, s.y0, s.x1 + 2, s.y1 - 44, m.wood, .{ .state = steam_wall_health });
    b.rect(s.x0, s.y1 - 18, s.x1, s.y1, m.lava);
    b.rect(s.x0, s.y1 - 20, s.x1, s.y1 - 18, m.stone); // divider
    // The divider stops short of the wood wall: a strip of open lava where
    // the water that spreads over the divider runs off and flashes to
    // steam, at the rate it arrives (docs/decisions/132-level-steam-room.md).
    b.clear(s.x1 - steam_strip - 4, s.y1 - 20, s.x1 - 4, s.y1 - 18);
    b.rect(s.x0 + 20, s.y0, s.x0 + 24, steam_plug.y1, m.stone); // tank
    b.rect(s.x1 - 24, s.y0, s.x1 - 20, steam_plug.y1, m.stone);
    b.rect(s.x0 + 20, steam_plug.y0, s.x1 - 20, steam_plug.y1, m.stone);
    b.rect(steam_plug.x0, steam_plug.y0, steam_plug.x1, steam_plug.y1, m.wood);

    // ---- shaft S2: from the corridor's fuse alcove down through the
    // walkway to the tier 3 hallway.
    b.clear(s2.x0, s2.y0, s2.x1, hall.y0);
    b.rect(s2.x0 - 20, walk.floor - 24, s2.x0, walk.floor, m.stone); // step on the walkway
    b.ledges(s2.x0, s2.x1, s2.y0, 804, 28, true);
    b.ledges(s2.x0, s2.x1, walk.floor, 1190, 28, true);

    // ---- pressure corridor over an open field, carved in bedrock (like
    // the air-test harness): a confined charge cracks stone around it, and
    // broken stone near a fresh crater keeps breaking (decision 133).
    b.rect(s2.x1, corr_y - 40, field.x1 + 6, field.floor + 8, m.bedrock);
    b.box(field.x0, field.y0, field.x1, field.floor, 6, m.bedrock);
    b.bumps(field.x0 + 20, field.x1, field.y0, 10, seed +% 2);
    b.clear(s2.x1, walk.y0, field.x0 + 6, walk.floor); // walkway into the field
    // The corridor, 3 px tall, closed at its west end under the fuse
    // alcove off S2 (a 2 px fuse slot drops onto the powder) and ending in
    // a chamber with a vent up to the ruin courtyard (the breach).
    b.clear(s2.x1, corr_y - 30, corr_x0 + 20, corr_y - 4);
    b.clear(corr_x0 + 4, corr_y - 4, corr_x0 + 6, corr_y);
    b.clear(corr_x0, corr_y, corr_x1, corr_y + 3);
    b.box(corr_x1, corr_y - 30, corr_x1 + 40, corr_y + 20, 4, m.stone);
    b.clear(corr_x1 + 16, ground - 2, corr_x1 + 24, corr_y - 30);
    var k: i32 = 0;
    while (k < plug_count) : (k += 1) {
        const x = plug_x0 + k * plug_step;
        b.rect(x, corr_y, x + plug_w, corr_y + 3, m.sand);
        b.rect(x, field.floor - 3, x + plug_w, field.floor, m.sand);
    }
}

// ---------------------------------------------------------------------------
// Tier 3: hallway, glassworks, electric pool, arena, acid pit

fn tier3(b: *B) void {
    const m = b.m;
    // Hallway along the tier; the rooms hang below its 4 px floor, entered
    // by shafts with ledges.
    b.box(40, hall.y0, 2004, hall.floor, 4, m.stone);
    b.bumps(120, 1990, hall.y0, 8, 77);
    // Hallway step blocks under S2.
    b.rect(s2.x0, hall.floor - 20, s2.x0 + 20, hall.floor, m.stone);
    b.rect(s2.x0 + 20, hall.floor - 42, s2.x1, hall.floor, m.stone);

    // ---- glassworks (x 40-496): the hall's west end opens into it. Lava
    // tank on a ledge, its floor gate (steel) over the sand pit.
    b.clear(40, hall.floor, 496, 1500);
    b.clear(40, hall.y0, 496, hall.floor + 4);
    b.rect(36, 1500, 544, 1504, m.stone);
    b.rect(496, hall.floor + 4, 500, 1460, m.stone); // ledge shaft wall, door at the bottom
    b.clear(500, hall.floor, 540, 1500);
    b.ledges(500, 540, hall.floor, 1472, 28, false);
    b.rect(sand_pit.x0 - 4, sand_pit.y0, sand_pit.x0, 1500, m.stone);
    b.rect(sand_pit.x1, sand_pit.y0, sand_pit.x1 + 4, 1500, m.stone);
    b.rect(40, lava_tank.y1, lava_tank.x1 + 6, lava_tank.y1 + 8, m.stone); // tank floor
    b.rect(lava_tank.x1, lava_tank.y0 - 16, lava_tank.x1 + 6, lava_tank.y1, m.stone);
    b.rect(gate.x0, gate.y0, gate.x1, gate.y1, m.steel); // the gate
    // Sand silo hung from the ceiling over the tank, wooden floor gate.
    b.rect(silo.x0 - 3, hall.y0, silo.x0, silo.y1 + 3, m.wood);
    b.rect(silo.x1, hall.y0, silo.x1 + 3, silo.y1 + 3, m.wood);
    b.rect(silo.x0, silo.y1, silo.x1, silo.y1 + 3, m.wood);
    // The tank's east end would hang on the gate alone: a rod to the ceiling.
    b.rect(lava_tank.x1 + 2, hall.y0, lava_tank.x1 + 4, lava_tank.y0 - 16, m.steel);

    // ---- electric pool (x 560-980): shallow water, steel grate and rails
    // up through the hallway floor to a contact plate.
    b.clear(560, hall.floor + 4, 980, 1480);
    b.rect(560, 1480, 980, 1490, m.stone);
    b.rect(580, 1440, 584, 1480, m.stone); // pool lip
    b.rect(600, hall.floor, 604, 1480, m.steel); // rails
    b.rect(916, hall.floor, 920, 1480, m.steel);
    b.rect(604, 1436, 916, 1438, m.steel); // grate
    var gx: i32 = 610;
    while (gx < 916) : (gx += 10) b.rect(gx, 1438, gx + 2, 1446, m.steel);
    b.rect(590, hall.floor - 4, 620, hall.floor, m.steel); // contact plate
    // Ledge shaft on the east side; the water reaches under its wall.
    b.rect(936, hall.floor + 4, 940, 1452, m.stone);
    b.clear(940, hall.floor, 980, hall.floor + 4);
    b.ledges(940, 980, hall.floor, 1424, 28, true);

    // ---- arena: three rooms under the hallway.
    // Room A: wooden floor over a lava pit; ledge shaft on the east wall.
    b.clear(1060, hall.floor + 4, 1290, 1470);
    b.rect(1060, 1470, 1290, 1480, m.stone);
    b.rect(1060, 1400, 1290, 1406, m.wood);
    b.rect(1070, 1440, 1280, 1470, m.lava);
    b.rect(1246, hall.floor + 4, 1250, 1376, m.stone);
    b.clear(1250, hall.floor, 1290, hall.floor + 4);
    b.ledges(1250, 1290, hall.floor, 1372, 28, true);
    // Room B: flooded (water in `liquids`); ledges up to the hallway.
    b.clear(1300, hall.floor + 4, 1500, 1480);
    b.rect(1300, 1480, 1500, 1490, m.stone);
    b.rect(1456, hall.floor + 4, 1460, 1312, m.stone);
    b.clear(1460, hall.floor, 1500, hall.floor + 4);
    b.ledges(1460, 1500, hall.floor, 1306, 28, true);
    // Room C: a glass wall between the player and the barrels.
    b.clear(1510, hall.floor + 4, 1730, 1480);
    b.rect(1510, 1480, 1730, 1490, m.stone);
    b.rect(1596, hall.floor + 4, 1600, 1480, m.glass);
    b.clear(1514, hall.floor, 1592, hall.floor + 4);
    b.ledges(1510, 1596, hall.floor, 1452, 28, true);

    // ---- acid pit under a stone bridge (the hallway floor), bedrock lined.
    b.rect(1740, hall.floor + 4, 2004, 1500, m.bedrock);
    b.clear(1760, hall.floor + 4, 1990, 1480);
    b.rect(1760, hall.floor, 1990, hall.floor + 8, m.stone); // the bridge
    b.rect(1760, hall.floor + 8, 1768, 1300, m.stone); // its piers
    b.rect(1982, hall.floor + 8, 1990, 1300, m.stone);
}

/// Second pass over the carved rooms: things that sit inside them.
fn details(b: *B) void {
    const m = b.m;
    b.rect(sand_pit.x0, sand_pit.y0, sand_pit.x1, sand_pit.y1, m.sand);
    b.rect(silo.x0, silo.y0, silo.x1, silo.y1, m.sand);
    b.l.fillCircle(560, hall.floor, 8, m.gravel, .{ .only_air = true });
    // Arena room C: gunpowder barrels behind the glass.
    barrel(b, 1620, 1480, 20, 24, m.gunpowder);
    barrel(b, 1650, 1480, 20, 24, m.gunpowder);
    barrel(b, 1680, 1480, 16, 30, m.gunpowder);
    // Pressure corridor: gunpowder at both mouths, smoke in the corridor.
    b.rect(powder_x0, corr_y, powder_x1, corr_y + 3, m.gunpowder);
    b.rect(field_powder_x0, field.floor - 2, field_powder_x1, field.floor, m.gunpowder);
    b.rectO(powder_x1 + 4, corr_y, corr_x1, corr_y + 3, m.smoke, .{ .only_air = true, .coverage = 110 });
    b.l.fillCircle(880, walk.floor, 12, m.gravel, .{ .only_air = true });
}

/// Liquids last: filled liquid starts asleep (the solver wakes it when a
/// solid next to it is removed).
fn liquids(b: *B) void {
    const m = b.m;
    b.rect(res_x0, res_top, res_x1, res_floor, m.water);
    b.rect(header.x0, header.y0 + 8, header.x1, header.y1, m.water);
    b.rect(utube.x0 + 2, utube.y0 + 6, utube.x0 + 12, utube.y1 - 2, m.water);
    b.rect(utube.x0 + 12, utube.y1 - 12, utube_plug_x, utube.y1 - 2, m.water);
    b.rect(steam.x0 + 24, steam.y0 + 6, steam.x1 - 24, steam_plug.y0, m.water);
    b.rect(584, 1452, 980, 1480, m.water); // electric pool
    b.rect(1300, 1330, 1456, 1480, m.water); // flooded room
    b.rect(1460, 1330, 1500, 1480, m.water);
    b.rect(1760, 1420, 1990, 1480, m.acid);
    b.rectO(lava_tank.x0, lava_tank.y0, lava_tank.x1, lava_tank.y1, m.lava, .{ .temperature = glass_magma_temp });
}

// ---------------------------------------------------------------------------
// Scripted events (cell side)

fn events(b: *B, s: Schedule, tick: u32) void {
    if (tick == s.dam) {
        b.clear(res_x1, res_top - 10, res_x1 + 1, res_floor); // dam
        b.clear(valve_x, pipe_y, valve_x + 1, pipe_y + 6); // pipe valve
        b.clear(utube_plug_x, utube.y1 - 12, utube_plug_x + 2, utube.y1 - 2); // U-tube plug
    }
    if (tick == s.steam_plug) b.clear(steam_plug.x0, steam_plug.y0, steam_plug.x1, steam_plug.y1);
    // The same charge at each mouth: a standard blast (the player's blast
    // charge) on the powder, which lights it (an ignite command lights cells
    // without the ignition event, so the powder is heated past 200 C).
    if (tick == s.corridor) {
        b.l.explosion(powder_x0 + 5, corr_y + 1, 6, 1.0);
        b.l.heatRect(powder_x0, corr_y, powder_x1, corr_y + 3, @intCast(cell.celsiusToTemp(400)));
    }
    if (tick == s.field) {
        b.l.explosion(field_powder_x0 + 7, field.floor - 2, 6, 1.0);
        b.l.heatRect(field_powder_x0, field.floor - 2, field_powder_x1, field.floor, @intCast(cell.celsiusToTemp(400)));
    }
    if (tick == s.village) {
        b.l.igniteRect(hut2.x0, ground - 20, hut2.x0 + 4, ground);
        b.l.igniteRect(922, ground - 20, 956, ground - 18);
    }
    if (tick == s.gate) b.clear(gate.x0, gate.y0, gate.x1, gate.y1);
    if (tick == s.gate + 50) b.clear(silo.x0 + 16, silo.y1, silo.x1 - 16, silo.y1 + 3); // the silo
    if (tick == s.pillar) {
        // The charge on the pillar: blast plus the blown-out middle.
        b.l.explosion(pillar.x0 + 8, ground - 40, 10, 2.0);
        b.clear(pillar.x0, pillar.y0 + 24, pillar.x1, ground - 2);
    }
}

// ===========================================================================
// Scene: bodies (called from bodies_scenes.script)

pub fn script(v: Variant, tick: u32, sim: *BodySim, list: *List) void {
    const r = sim.mats.roles;
    // The tick-0 build carves every room with air fills, which the bodies
    // layer reads as destruction events. The level is built anchored (no
    // loose piece; checked when it was laid out), and those events span
    // the map: they would keep connectivity clusters queued forever and
    // starve the real ones (a blown pillar would never come loose).
    // Building is not destruction: drop them (decision 131).
    if (tick == 1) {
        sim.event_len = 0;
        sim.incoming_len = 0;
    }
    // Beams across the ruin's gap, welded into both blocks' concrete.
    if (tick == 4) {
        sim.placeBeam(ruin_left.x1 - 4, beam_y, ruin_right.x0 + 4, beam_y, r.steel, 4);
        sim.placeBeam(ruin_left.x1 - 4, 360, ruin_right.x0 + 4, 360, r.steel, 4);
    }
    // A concrete crate on the lower beam, and a wooden crate in the hub.
    if (tick == 30) {
        _ = sim.spawnCrate(beam_cut_x, beam_y - 28, 50, r.concrete) catch {};
        _ = sim.spawnCrate(740, ground - 30, 16, r.wood) catch {};
    }
    const s = schedule(v) orelse return;
    // The torch from below at mid-span, under the crate (as in
    // bodies_beam): `depth` rows up from the beam's bottom edge, 4 px
    // thick: 3/4 left (holds), 2/4 (yields, sags), 1/4 (sags deep); then
    // it cuts through next to the west weld, and the east weld has to
    // carry the whole span and the crate as a cantilever; last, through
    // next to the east weld, in case that one held.
    const depths = [5]i32{ 1, 2, 3, 5, 5 };
    const xs = [5]i32{ beam_cut_x, beam_cut_x, beam_cut_x, ruin_left.x1 + 14, ruin_right.x0 - 14 };
    for (s.beam_cuts, depths, xs) |t, depth, cx| {
        if (tick != t) continue;
        // (Mid-segment: segments are 10 px from the weld, so a segment
        // boundary falls on round x and float error could miss both.)
        const bottom = beamBottomAt(sim, @as(f32, @floatFromInt(cx)) + 0.5) orelse continue;
        list.fillRect(cx - 2, bottom - depth, cx + 3, bottom + 3, air, .{});
    }
}

/// World row just below the lower beam's bottom edge at column x.
fn beamBottomAt(sim: *BodySim, x: f32) ?i32 {
    const world = &sim.world;
    var best: ?i32 = null;
    for (world.beams, 0..) |bm, bi| {
        if (!bm.live) continue;
        const h: bodies.BeamHandle = .{ .index = @intCast(bi), .gen = bm.gen };
        const info = world.beamInfo(h).?;
        for (world.beamSegments(h)) |seg| {
            const t = world.getTransform(seg) orelse continue;
            const l = t.applyInverse(x, t.y);
            if (l.x < 0 or l.x >= @as(f32, @floatFromInt(info.seg_len))) continue;
            const p = t.apply(l.x, @as(f32, @floatFromInt(info.thickness)) * 0.5);
            const y: i32 = @intFromFloat(@round(p.y));
            if (y > beam_y - 20 and y < beam_y + 40) best = @max(best orelse y, y);
        }
    }
    return best;
}

test "level emits within the command budget" {
    const ids: Ids = .{ .stone = 1, .sand = 2, .water = 3, .smoke = 4, .bedrock = 5, .wood = 6, .lava = 7, .oil = 8, .steel = 9, .gunpowder = 10, .dirt = 11, .glass = 12, .concrete = 13, .gravel = 14, .acid = 15, .moss = 16 };
    var list: List = .{};
    for (0..1000) |t| {
        list.begin(@intCast(t));
        emit(.auto, @intCast(t), 1, &ids, &list);
        try std.testing.expectEqual(@as(u32, 0), list.dropped);
    }
    var a: List = .{};
    var b2: List = .{};
    a.begin(1);
    b2.begin(1);
    emit(.play, 1, 7, &ids, &a);
    emit(.play, 1, 7, &ids, &b2);
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(a.slice()), std.mem.sliceAsBytes(b2.slice()));
}
