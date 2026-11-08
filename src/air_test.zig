//! `hexe --headless --air-test` (also `zig build air-test`): the air-field
//! halves of docs/04-fluids.md scenarios 3 and 4, built in code, run on the
//! GPU, measured and asserted, with stricter measurements than the scenario
//! files (which the scenario runner also runs since the integration).
//!
//! 3. Sealed room: a 64 x 64 room in a 4 px stone shell whose left wall is
//!    wood at health 1 (a non-flammable fixture), lava on the floor. The
//!    steam a lava + water interface makes is emulated at a controlled rate:
//!    each tick a steam puff is painted there and the same mass a reaction
//!    calling `air_gas_created` would add is injected (CommandList.
//!    injectPressure with zero momentum). The real lava + water reaction
//!    (much faster: a steam explosion) runs in scenarios/sealed_steam_room.zon
//!    through the scenario runner (docs/decisions/118-integrate-harnesses.md). Asserts: room
//!    pressure (mean density over the room from the 256^2 field readback)
//!    rises monotonically for 2 s (120 ticks); the wood wall is gone before
//!    any stone of the opposite wall; the stone wall stands at the end.
//! 4. Corridor blast: the same explosion in a 3 px corridor carved in bedrock
//!    (closed 8 px behind the blast) and on an open bedrock floor, 2 x 3 sand
//!    plugs every 8 px. Asserts the farthest destroyed plug in the corridor
//!    is at least twice as far as in the open. Also reports the plugs at the
//!    scenario file's distances 40, 80, 120, 160.
const std = @import("std");
const builtin = @import("builtin");
const Cli = @import("main.zig").Cli;
const Engine = @import("engine.zig").Engine;
const cell = @import("sim/cell.zig");
const commands = @import("sim/commands.zig");
const materials = @import("sim/materials.zig");
const data = @import("data");
const abi = @import("sim/air_abi.zig");

const W = cell.world_size;

/// The shipped materials plus two test fixtures: `wood_weak` (wood at
/// health 1 and not flammable, so the wall fails by pressure, not by the
/// lava's heat) and `pressure_plate` (glass's pressure_event, 30 = 0.03
/// overpressure, immune to blasts so it keeps reporting).
const Ids = struct { stone: u8, sand: u8, water: u8, wood_weak: u8, lava: u8, steam: u8, bedrock: u8, sensor: u8 };

const fixtures = [_]data.materials.Source{
    .{ .path = "<air-test>/wood_weak.zon", .text =
    \\.{ .name = "wood_weak", .phase = .static, .density = 60, .health = 1, .conductivity = 10, .impact = .chip,
    \\   .blast_threshold = 80, .blast_response = .@"break", .drag = 80, .ramp = .{ 0x6b4a2b, 0x5e4026, 0x775333, 0x543a22 } }
    },
    .{ .path = "<air-test>/pressure_plate.zon", .text =
    \\.{ .name = "pressure_plate", .phase = .static, .density = 250, .pressure_event = 30,
    \\   .ramp = .{ 0x9fd8e8, 0x8fc8d8, 0xafe8f8, 0x7fb8c8 } }
    },
};

fn testLibrary(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) !materials.Library {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const shipped = try data.materials.readZonDir(io, scratch.allocator(), dir);
    const all = try std.mem.concat(scratch.allocator(), data.materials.Source, &.{ shipped, &fixtures });
    var diag: materials.Diagnostics = .init(gpa);
    defer diag.deinit();
    var set = data.materials.loadSources(gpa, all, &diag) catch |err| {
        std.debug.print("air-test materials: {f}\n", .{diag});
        return err;
    };
    errdefer set.deinit();
    return .{ .set = set, .tables = try materials.gpu_tables.build(gpa, &set) };
}

fn resolveIds(lib: *const materials.Library) Ids {
    var ids: Ids = undefined;
    inline for (@typeInfo(Ids).@"struct".field_names) |f| {
        const name = if (comptime std.mem.eql(u8, f, "sensor")) "pressure_plate" else f;
        @field(ids, f) = lib.id(name) orelse @panic("air-test: material " ++ name ++ " missing");
    }
    return ids;
}

const Ctx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    cli: Cli,
    lib: materials.Library,
    ids: Ids,
    cells: []u32,
    shots: ?[]const u8,

    fn newEngine(self: *Ctx) !*Engine {
        const engine = try self.gpa.create(Engine);
        errdefer self.gpa.destroy(engine);
        try engine.init(self.gpa, .{
            .library = &self.lib,
            .validation = self.cli.validation orelse false,
            .pipeline = .{ .sleep = self.cli.sleep, .air = true, .air_sleep = self.cli.air_sleep },
        });
        engine.pipeline.air.overlay = self.shots != null;
        engine.capture_overlay = true;
        return engine;
    }

    fn freeEngine(self: *Ctx, engine: *Engine) void {
        engine.deinit();
        self.gpa.destroy(engine);
    }

    fn count(self: *const Ctx, material: u8, x: i32, y: i32, w: i32, h: i32) u32 {
        var n: u32 = 0;
        var yy = y;
        while (yy < y + h) : (yy += 1) {
            var xx = x;
            while (xx < x + w) : (xx += 1) {
                const c = self.cells[@as(usize, cell.wrap(yy)) * W + cell.wrap(xx)];
                if (cell.material(c) == material) n += 1;
            }
        }
        return n;
    }

    fn shot(self: *Ctx, engine: *Engine, name: []const u8, tick: u32, crop: @import("engine.zig").Crop) !void {
        const dir = self.shots orelse return;
        var buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "{s}/{s}-{d:0>4}.png", .{ dir, name, tick });
        try engine.screenshot(self.io, path, crop);
    }
};

pub fn run(gpa: std.mem.Allocator, io: std.Io, cli: Cli, shipped: *const materials.Library) !u8 {
    _ = shipped; // the fixtures are added to the same directory's files
    var ctx: Ctx = .{
        .gpa = gpa,
        .io = io,
        .cli = cli,
        .lib = try testLibrary(gpa, io, cli.materials),
        .ids = undefined,
        .cells = try gpa.alloc(u32, W * W),
        .shots = cli.screenshot,
    };
    defer gpa.free(ctx.cells);
    defer ctx.lib.deinit(gpa);
    ctx.ids = resolveIds(&ctx.lib);
    std.debug.print("hexe air-test ({s}, air sleep {s})\n", .{ @tagName(builtin.mode), if (cli.air_sleep) "on" else "off" });
    var failures: u32 = 0;
    failures += try sealedRoom(&ctx);
    failures += try corridorBlast(&ctx);
    if (failures == 0) {
        std.debug.print("air-test: PASS\n", .{});
        return 0;
    }
    std.debug.print("air-test: FAIL ({d} failed checks)\n", .{failures});
    return 1;
}

fn check(ok: bool, comptime fmt: []const u8, args: anytype) u32 {
    std.debug.print("  [{s}] " ++ fmt ++ "\n", .{if (ok) "ok" else "FAIL"} ++ args);
    return if (ok) 0 else 1;
}

// ---------------------------------------------------------------------------
// Scenario 3: sealed steam room
// ---------------------------------------------------------------------------

/// Steam mass emulated per tick at the lava/water interface: mean density
/// added over the open disc of `source_radius` px (CommandList units).
const source_density: f32 = 0.006;
const source_radius = 16;

fn sealedRoom(ctx: *Ctx) !u32 {
    const ids = ctx.ids;
    const ox: i32 = 960;
    const oy: i32 = 960;
    const engine = try ctx.newEngine();
    defer ctx.freeEngine(engine);
    const air = &engine.pipeline.air;
    air.field_readback = true;

    std.debug.print("\n== scenario 3: sealed 64x64 room, lava + water, wood wall (health 1) vs stone wall\n", .{});
    const ticks: u32 = 600;
    var list: commands.CommandList = .{};
    var pressure: [ticks]f32 = @splat(0);
    var center: [ticks]f32 = @splat(0);
    var wood_gone: ?u32 = null;
    var wood_hit: ?u32 = null;
    var stone_hit: ?u32 = null;
    var first_event: ?u32 = null;
    var t: u32 = 0;
    while (t < ticks) : (t += 1) {
        list.begin(t);
        if (t == 0) {
            list.fillRect(ox, oy, ox + 72, oy + 72, ids.stone, .{});
            list.fillRect(ox + 4, oy + 4, ox + 68, oy + 68, materials.air, .{});
            list.fillRect(ox, oy + 4, ox + 4, oy + 68, ids.wood_weak, .{});
            list.fillRect(ox + 4, oy + 52, ox + 36, oy + 68, ids.lava, .{});
            list.fillRect(ox + 38, oy + 52, ox + 68, oy + 68, ids.water, .{});
            // A stone divider: since the integration the reactions pass would
            // turn touching lava + water into a steam explosion on its own
            // (the scenario runner's sealed_steam_room); this harness
            // measures the air field under the controlled, emulated source.
            list.fillRect(ox + 36, oy + 44, ox + 38, oy + 68, ids.stone, .{});
            list.fillRect(ox + 60, oy + 2, ox + 64, oy + 4, ids.sensor, .{});
        } else {
            // The lava + water reaction, emulated: steam puff + its air mass.
            list.fillCircle(ox + 36, oy + 48, 3, ids.steam, .{ .only_air = true, .coverage = 8 });
            list.injectPressure(ox + 36, oy + 28, source_radius, source_density, 0, 4);
        }
        _ = air.requestSample(ox + 36, oy + 24);
        try engine.frame(1, .{ .scene = .empty, .extra = list.slice() }, null);
        try engine.finish(); // collect this tick's samples and field now
        if (air.field()) |f| {
            const ft = air.field_tick;
            if (ft < ticks) pressure[ft] = roomMean(f, ox + 4, oy + 4, 64, 48);
        }
        if (first_event == null and air.events().len > 0) first_event = air.stats.first_tick;
        if (air.samples().len > 0 and air.sample_tick < ticks) center[air.sample_tick] = air.samples()[0].sample.density;
        if (t % 4 == 3 or t + 1 == ticks) {
            try engine.readbackCells(ctx.cells);
            // Breached: a quarter of the wall blown out. The pieces left
            // between the holes are islands for the M7 connectivity pass.
            const wood_n = ctx.count(ids.wood_weak, ox, oy + 4, 4, 64);
            if (wood_hit == null and wood_n < 256) wood_hit = t;
            if (wood_gone == null and wood_n <= 192) wood_gone = t;
            if (stone_hit == null and ctx.count(ids.stone, ox + 68, oy + 4, 4, 64) < 256) stone_hit = t;
            if (t < 24 or t == 119 or t == 199 or (wood_gone != null and wood_gone.? == t)) try ctx.shot(engine, "sealed", t + 1, .{ .x = ox - 64, .y = oy - 40, .w = 200, .h = 152 });
        }
    }
    try engine.finish();
    if (air.field()) |f| pressure[air.field_tick] = roomMean(f, ox + 4, oy + 4, 64, 48);

    // Monotonic rise over the first 2 s (ticks 1..120) or until the wall
    // starts to give (first wood pixel lost; the wall is checked every 4
    // ticks and the field readback trails the cells, so the window ends two
    // checks before the first loss). Since the integration the water behind the divider really
    // boils (reactions pass, air_gas_created) and steam condenses on the
    // cooler shell (air_gas_removed): bursts and condensation move the room
    // mean by a few thousandths, so dips below 5e-3 of ambient are not a
    // falling pressure (docs/decisions/118-integrate-harnesses.md).
    const rise_end: u32 = @min(120, if (wood_hit) |w| w -| 8 else 120);
    var monotonic = true;
    var first_dip: u32 = 0;
    var k: u32 = 2;
    while (k <= rise_end) : (k += 1) {
        if (pressure[k] + 5e-3 < pressure[k - 1]) {
            monotonic = false;
            first_dip = k;
            break;
        }
    }
    var peak: f32 = 0;
    var peak_tick: u32 = 0;
    for (pressure, 0..) |p, i| if (p > peak) {
        peak = p;
        peak_tick = @intCast(i);
    };
    std.debug.print("  room mean density (ambient 1.0): t=30 {d:.4}  t=60 {d:.4}  t=120 {d:.4}  t=180 {d:.4}  peak {d:.4} at t={d}  t={d} {d:.4}\n", .{
        pressure[30], pressure[60], pressure[120], pressure[180], peak, peak_tick, ticks - 1, pressure[ticks - 1],
    });
    std.debug.print("  room center sample: t=60 {d:.4}  t=120 {d:.4}  t=240 {d:.4}\n", .{ center[60], center[120], center[240] });
    var fails: u32 = 0;
    fails += check(monotonic, "pressure rises monotonically over 2 s or until the wall gives (ticks 1..{d}){s}", .{ rise_end, if (monotonic) "" else " -- dip" });
    if (!monotonic) std.debug.print("        first dip at tick {d}: {d:.5} -> {d:.5}\n", .{ first_dip, pressure[first_dip - 1], pressure[first_dip] });
    fails += check(pressure[rise_end] > 1.02, "pressure rose: {d:.4} at t={d} (> 1.02)", .{ pressure[rise_end], rise_end });
    fails += check(center[240] > 1.02 or (wood_gone != null and wood_gone.? < 240), "scenario assertion: pressure at (128,110) at t=240 {d:.4} > 1.02, or the wall already failed", .{center[240]});
    fails += check(wood_gone != null, "wood wall (health 1) breached (>= 1/4 blown out) by tick {?d}", .{wood_gone});
    std.debug.print("        wood left at the end: {d}/256 pixels (pieces between the holes; detached ones are M7 connectivity's)\n", .{ctx.count(ids.wood_weak, ox, oy + 4, 4, 64)});
    const stone_ok = stone_hit == null or (wood_gone != null and wood_gone.? < stone_hit.?);
    fails += check(stone_ok, "stone wall untouched when the wood failed (first stone loss: {?d})", .{stone_hit});
    const stone_left = ctx.count(ids.stone, ox + 68, oy + 4, 4, 64);
    fails += check(stone_left >= 240, "stone wall stands at the end: {d}/256 cells", .{stone_left});
    std.debug.print("  blast ejects {d}, pressure events {d} over the run\n", .{ air.total_ejects, air.total_events });
    fails += check(first_event != null and pressure[first_event.?] > 1.025, "pressure plate in the ceiling (event at 0.03 overpressure) first reported at tick {?d}, room {d:.4}", .{ first_event, if (first_event) |e| pressure[e] else 0 });
    return fails;
}

/// Mean density over the fluid part of a pixel rect, from the field readback.
fn roomMean(f: []const abi.FieldCell, x: i32, y: i32, w: i32, h: i32) f32 {
    var sum: f32 = 0;
    var n: f32 = 0;
    var fy = @divFloor(y, 8);
    while (fy < @divFloor(y + h, 8)) : (fy += 1) {
        var fx = @divFloor(x, 8);
        while (fx < @divFloor(x + w, 8)) : (fx += 1) {
            const c = f[@as(usize, @intCast(fy)) * abi.field_size + @as(usize, @intCast(fx))];
            sum += c.density * c.open;
            n += c.open;
        }
    }
    return if (n > 0) sum / n else 1.0;
}

// ---------------------------------------------------------------------------
// Scenario 4: corridor blast
// ---------------------------------------------------------------------------

const plug_step = 8;
const plug_first = 16;
const plug_count = 48;

const BlastResult = struct {
    destroyed: [plug_count]bool,
    remaining: [plug_count]u32,
    farthest: i32,
    first_intact: i32,
};

fn corridorBlast(ctx: *Ctx) !u32 {
    std.debug.print("\n== scenario 4: explosion in a 3 px corridor vs on an open floor, 2x3 sand plugs every {d} px\n", .{plug_step});
    const corridor = try blastRun(ctx, true);
    const open = try blastRun(ctx, false);
    printPlugs("corridor", corridor);
    printPlugs("open    ", open);
    var fails: u32 = 0;
    const ratio = @as(f32, @floatFromInt(corridor.farthest)) / @as(f32, @floatFromInt(@max(open.farthest, 1)));
    std.debug.print("  farthest destroyed plug: corridor {d} px, open {d} px, ratio {d:.2}\n", .{ corridor.farthest, open.farthest, ratio });
    fails += check(open.farthest > 0, "the open blast destroys the nearest plugs", .{});
    fails += check(ratio >= 2.0, "corridor reaches at least twice as far as the open ({d:.2}x)", .{ratio});
    // The scenario file's own distances (plug x offsets from x=24): a plug
    // is "disturbed" when any of its sand moved. Since M4 the sand lands
    // again nearby, so the file's reach is checked on disturbance, not on
    // total removal (docs/decisions/77-air-blast-scaling.md).
    const disturbed = struct {
        fn f(r: BlastResult, d: i32) bool {
            return r.remaining[@intCast(@divExact(d - plug_first, plug_step))] < 6;
        }
    }.f;
    std.debug.print("  scenario distances (disturbed): corridor 40:{s} 80:{s} 160:{s}; open 40:{s} 80:{s} 120:{s}\n", .{
        yn(disturbed(corridor, 40)), yn(disturbed(corridor, 80)), yn(disturbed(corridor, 160)), yn(disturbed(open, 40)), yn(disturbed(open, 80)), yn(disturbed(open, 120)),
    });
    // Individual plugs near the charge are noisy (blown sand lands on a
    // neighbor), so the file's reach is checked on the farthest blown plug.
    const file_ok = corridor.farthest >= 80 and open.farthest <= 64 and !disturbed(open, 120);
    fails += check(file_ok, "corridor_blast.zon reach (corridor blown to >= 80 px, open <= 64 px, open 120 untouched)", .{});
    return fails;
}

fn yn(b: bool) []const u8 {
    return if (b) "destroyed" else "intact";
}

fn printPlugs(name: []const u8, r: BlastResult) void {
    var line: [plug_count + 1]u8 = undefined;
    for (r.destroyed, 0..) |d, i| line[i] = if (d) 'x' else if (r.remaining[i] < 6) '+' else '.';
    // x = blown (< half left), + = some sand gone, . = intact
    line[plug_count] = 0;
    std.debug.print("  {s} plugs at {d}..{d} px (x destroyed, + damaged, . intact): {s}\n", .{ name, plug_first, plug_first + plug_step * (plug_count - 1), line[0..plug_count] });
}

fn blastRun(ctx: *Ctx, in_corridor: bool) !BlastResult {
    const ids = ctx.ids;
    const engine = try ctx.newEngine();
    defer ctx.freeEngine(engine);
    // Blast center; plugs at bx + d for d = plug_first + k * plug_step.
    const bx: i32 = 600;
    const by: i32 = if (in_corridor) 1031 else 1046;
    const plug_y: i32 = by - 1;
    var list: commands.CommandList = .{};
    const ticks: u32 = 150;
    var t: u32 = 0;
    while (t < ticks) : (t += 1) {
        list.begin(t);
        if (t == 0) {
            if (in_corridor) {
                // Bedrock block, corridor rows by-1..by+1 from bx-8 to bx+500.
                list.fillRect(bx - 100, by - 160, bx + 600, by + 160, ids.bedrock, .{});
                list.fillRect(bx - 8, by - 1, bx + 500, by + 2, materials.air, .{});
            } else {
                // Open floor: bedrock below by+2, open air above.
                list.fillRect(bx - 600, by + 2, bx + 700, by + 40, ids.bedrock, .{});
            }
            var k: i32 = 0;
            while (k < plug_count) : (k += 1) {
                const x = bx + plug_first + k * plug_step;
                list.fillRect(x, plug_y, x + 2, plug_y + 3, ids.sand, .{});
            }
        }
        if (t == 10) list.explosion(bx, by, 6, 1.0);
        try engine.frame(1, .{ .scene = .empty, .extra = list.slice() }, null);
        if (t == 14 or t == 24 or t == 44) try ctx.shot(engine, if (in_corridor) "corridor" else "open", t + 1, .{ .x = @intCast(bx - 120), .y = @intCast(by - 160), .w = 560, .h = 240 });
    }
    try engine.readbackCells(ctx.cells);
    var r: BlastResult = .{ .destroyed = undefined, .remaining = undefined, .farthest = 0, .first_intact = 0 };
    var k: usize = 0;
    var seen_intact = false;
    while (k < plug_count) : (k += 1) {
        const d: i32 = plug_first + @as(i32, @intCast(k)) * plug_step;
        // Sand that settles drops at most a pixel or two; count a taller box.
        const n = ctx.count(ids.sand, bx + d - 1, plug_y - 2, 4, 6);
        r.remaining[k] = n;
        // Blown: more than half the plug's 6 sand pixels left (as particles
        // since M4; before, ejected sand vanished and "destroyed" meant 0).
        r.destroyed[k] = n < 3;
        if (n < 3) r.farthest = d;
        if (n >= 3 and !seen_intact) {
            seen_intact = true;
            r.first_intact = d;
        }
    }
    return r;
}
