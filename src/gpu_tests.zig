//! `zig build gpu-test`: GPU checks of the M4 engine half (particles,
//! readback mirror, event queue). Each test builds a fresh engine, drives it
//! headless and compares against synchronous readbacks of the cell image.
const std = @import("std");
const Cli = @import("main.zig").Cli;
const Engine = @import("engine.zig").Engine;
const cell = @import("sim/cell.zig");
const commands = @import("sim/commands.zig");
const scenes = @import("sim/scenes.zig");
const readback = @import("sim/readback.zig");
const m = @import("sim/materials_builtin.zig");
const materials = @import("sim/materials.zig");

const Test = struct { name: []const u8, func: *const fn (std.mem.Allocator, *Engine, *const materials.Table) anyerror!void };

const tests = [_]Test{
    .{ .name = "mirror masks and regions match a synchronous readback", .func = mirrorMatchesReadback },
    .{ .name = "events arrive one tick late, without a stall", .func = eventsOneTickLate },
    .{ .name = "sprayed sand lands and is conserved", .func = sprayLandsConserved },
    .{ .name = "eject throws a dirt hill; debris lands, count returns to 0", .func = ejectHill },
    .{ .name = "CPU spawn API", .func = cpuSpawn },
    .{ .name = "material budget refuses spawns beyond it", .func = budget },
};

pub fn run(gpa: std.mem.Allocator, io: std.Io, cli: Cli) !u8 {
    _ = io;
    const table = m.table();
    var failed: u32 = 0;
    for (tests) |t| {
        const engine = try gpa.create(Engine);
        defer gpa.destroy(engine);
        try engine.init(gpa, .{ .table = &table, .validation = cli.validation orelse false, .pipeline = .{ .sleep = cli.sleep } });
        defer engine.deinit();
        if (t.func(gpa, engine, &table)) |_| {
            std.debug.print("PASS  {s}\n", .{t.name});
        } else |err| {
            std.debug.print("FAIL  {s}: {s}\n", .{ t.name, @errorName(err) });
            failed += 1;
        }
    }
    std.debug.print("gpu-test: {d}/{d} passed\n", .{ tests.len - failed, tests.len });
    return if (failed == 0) 0 else 1;
}

fn check(ok: bool, comptime fmt: []const u8, args: anytype) !void {
    if (ok) return;
    std.debug.print("      " ++ fmt ++ "\n", args);
    return error.CheckFailed;
}

/// Run one tick with `list` (begun for engine.tick) and wait for it.
fn tickWith(engine: *Engine, list: *const commands.CommandList) !void {
    try engine.frame(1, .{ .extra = list.slice() }, null);
}

fn countMaterial(cells: []const u32, mat: u32) usize {
    var n: usize = 0;
    for (cells) |c| n += @intFromBool(cell.material(c) == mat);
    return n;
}

fn mirrorMatchesReadback(gpa: std.mem.Allocator, engine: *Engine, table: *const materials.Table) !void {
    // The demo scene to just after the explosion: debris in flight, sand
    // piles, a pool, steel and stone. Regions requested every frame,
    // including one across the torus seam.
    const ticks = 200;
    for (0..ticks) |_| {
        try engine.mirror().requestRegion(940, 1150, 123, 90);
        try engine.mirror().requestRegion(-10, -6, 30, 20);
        try engine.frame(1, .{ .scene = .particles_demo }, null);
    }
    try engine.finish();
    const mirror = engine.mirror();
    try check(mirror.valid and mirror.tick == ticks - 1, "mirror tick {d}, want {d}", .{ mirror.tick, ticks - 1 });
    try check(mirror.particles.live > 0, "expected debris in flight at tick {d}", .{mirror.tick});

    const cells = try gpa.alloc(u32, cell.world_size * cell.world_size);
    defer gpa.free(cells);
    try engine.readbackCells(cells);
    const solid = try gpa.alloc(u32, readback.mask_words);
    defer gpa.free(solid);
    const liquid = try gpa.alloc(u32, readback.mask_words);
    defer gpa.free(liquid);
    readback.computeMasks(cells, table, solid, liquid);
    var bad: usize = 0;
    var solid_bits: usize = 0;
    var liquid_bits: usize = 0;
    for (solid, mirror.solid, liquid, mirror.liquid) |a, b, c, d| {
        bad += @popCount(a ^ b) + @popCount(c ^ d);
        solid_bits += @popCount(b);
        liquid_bits += @popCount(d);
    }
    try check(bad == 0, "{d} mask bits differ", .{bad});
    try check(solid_bits > 50_000 and liquid_bits > 1000, "masks look empty: {d} solid, {d} liquid", .{ solid_bits, liquid_bits });
    // isSolid / material agree with the cells.
    var region_bad: usize = 0;
    var y: i32 = 1150;
    while (y < 1240) : (y += 1) {
        var x: i32 = 940;
        while (x < 940 + 123) : (x += 1) {
            const c = cells[cell.index(@intCast(x), @intCast(y))];
            const want: u8 = @intCast(cell.material(c));
            if ((mirror.material(x, y) orelse 255) != want) region_bad += 1;
            if (mirror.isSolid(x, y) != (table.gpu[want].phase == 0)) region_bad += 1;
        }
    }
    y = -6;
    while (y < 14) : (y += 1) {
        var x: i32 = -10;
        while (x < 20) : (x += 1) {
            const c = cells[cell.index(cell.wrap(x), cell.wrap(y))];
            if ((mirror.material(x, y) orelse 255) != cell.material(c)) region_bad += 1;
        }
    }
    try check(region_bad == 0, "{d} region/isSolid lookups differ", .{region_bad});
    try check(mirror.material(500, 500) == null, "material outside regions must be null", .{});
    std.debug.print("      tick {d}: {d} solid bits, {d} liquid bits, 2 regions, {d} particles live\n", .{ mirror.tick, solid_bits, liquid_bits, mirror.particles.live });
}

fn eventsOneTickLate(gpa: std.mem.Allocator, engine: *Engine, table: *const materials.Table) !void {
    _ = gpa;
    _ = table;
    var list: commands.CommandList = .{};
    for (0..3) |_| {
        list.begin(engine.tick);
        try tickWith(engine, &list);
    }
    try engine.finish();
    const t0 = engine.tick;
    list.begin(t0);
    list.eject(300, 400, 25, 500);
    list.eject(-5, 7, 9, 500); // wraps: the event position is wrapped too
    try tickWith(engine, &list);
    // Recorded and submitted, not yet read back.
    try check(engine.mirror().eventsAt(t0) == null, "events of tick {d} visible before it ran", .{t0});
    // The GPU finishes tick t0 while the CPU does other work...
    engine.ctx.waitIdle();
    // ...and the CPU picks it up before building tick t0 + 1, without waiting.
    try engine.poll();
    const mirror = engine.mirror();
    try check(mirror.tick == t0, "mirror at tick {d}, want {d}", .{ mirror.tick, t0 });
    const evs = mirror.eventsAt(t0) orelse return error.NoEvents;
    try check(evs.len == 2, "{d} events, want 2", .{evs.len});
    var seen: u32 = 0;
    for (evs) |e| {
        try check(e.kind == .eject, "kind {d}", .{@backingInt(e.kind)});
        if (e.x == 300 and e.y == 400 and e.payload == 25) seen |= 1;
        if (e.x == cell.world_size - 5 and e.y == 7 and e.payload == 9) seen |= 2;
    }
    try check(seen == 3, "events at the wrong place: {any}", .{evs});
    // The next tick has its own (empty) queue.
    list.begin(engine.tick);
    try tickWith(engine, &list);
    try engine.finish();
    try check((engine.mirror().eventsAt(t0 + 1) orelse return error.NoEvents).len == 0, "queue not reset", .{});
    try check((engine.mirror().eventsAt(t0) orelse return error.NoEvents).len == 2, "history lost", .{});
}

fn sprayLandsConserved(gpa: std.mem.Allocator, engine: *Engine, table: *const materials.Table) !void {
    _ = table;
    var list: commands.CommandList = .{};
    list.begin(engine.tick);
    closedWorld(&list);
    list.fillRect(700, 1200, 720, 1400, m.stone, .{});
    list.fillRect(1280, 1200, 1300, 1400, m.stone, .{});
    try tickWith(engine, &list);
    const sprayed = 5000;
    list.begin(engine.tick);
    list.spray(.{ .x = 1000, .y = 1100, .material = m.sand, .count = sprayed, .speed = 160, .spread = 60, .direction = 0.75, .cone = 0.05 });
    try tickWith(engine, &list);
    var lost: u64 = 0;
    var refused: u64 = 0;
    var landed: u64 = 0;
    var peak: u32 = 0;
    var empty_tick: ?u32 = null;
    for (0..400) |_| {
        list.begin(engine.tick);
        try tickWith(engine, &list);
        try engine.finish(); // serialize so every tick's counters are seen
        const ps = engine.mirror().particles;
        lost += ps.lost;
        refused += ps.refused;
        landed += ps.landed;
        peak = @max(peak, ps.live);
        if (ps.live == 0 and empty_tick == null and landed > 0) empty_tick = engine.mirror().tick;
    }
    const cells = try gpa.alloc(u32, cell.world_size * cell.world_size);
    defer gpa.free(cells);
    try engine.readbackCells(cells);
    const sand = countMaterial(cells, m.sand);
    std.debug.print("      peak {d} live, landed {d}, lost {d}, refused {d}; {d} sand cells; empty at tick {?d}\n", .{ peak, landed, lost, refused, sand, empty_tick });
    try check(peak >= sprayed - 10, "only {d} of {d} spawned", .{ peak, sprayed });
    try check(engine.mirror().particles.live == 0, "{d} particles still live", .{engine.mirror().particles.live});
    try check(sand + lost == sprayed, "sand {d} + lost {d} != {d}", .{ sand, lost, sprayed });
    try check(lost * 100 < sprayed, "lost {d} of {d}", .{ lost, sprayed });
    // The cone was narrow: everything landed between the walls.
    var outside: usize = 0;
    for (cells, 0..) |c, i| {
        const x = i % cell.world_size;
        if (cell.material(c) == m.sand and (x < 700 or x >= 1300)) outside += 1;
    }
    try check(outside == 0, "{d} sand cells outside the box", .{outside});
}

/// Full-width stone floor (y 1400-1460) and ceiling (y 560-600): nothing
/// can fall around the torus forever.
fn closedWorld(list: *commands.CommandList) void {
    list.fillRect(0, 1400, cell.world_size, 1460, m.stone, .{});
    list.fillRect(0, 560, cell.world_size, 600, m.stone, .{});
}

fn ejectHill(gpa: std.mem.Allocator, engine: *Engine, table: *const materials.Table) !void {
    _ = table;
    var list: commands.CommandList = .{};
    list.begin(engine.tick);
    closedWorld(&list);
    list.fillRect(470, 560, 500, 1460, m.stone, .{}); // a 1060-wide cave
    list.fillRect(1530, 560, 1560, 1460, m.stone, .{});
    list.fillCircle(1000, 1400, 90, m.dirt, .{ .only_air = true });
    try tickWith(engine, &list);
    for (0..10) |_| {
        list.begin(engine.tick);
        try tickWith(engine, &list);
    }
    const cells = try gpa.alloc(u32, cell.world_size * cell.world_size);
    defer gpa.free(cells);
    try engine.readbackCells(cells);
    const dirt0 = countMaterial(cells, m.dirt);
    list.begin(engine.tick);
    list.eject(1000, 1396, 110, 950);
    try tickWith(engine, &list);
    var lost: u64 = 0;
    var peak: u32 = 0;
    var empty_after: ?u32 = null;
    const start = engine.tick;
    for (0..600) |_| {
        list.begin(engine.tick);
        try tickWith(engine, &list);
        try engine.finish();
        const ps = engine.mirror().particles;
        lost += ps.lost;
        peak = @max(peak, ps.live);
        if (ps.live == 0 and empty_after == null) empty_after = engine.mirror().tick - start;
        const age = engine.mirror().tick - start;
        if (age % 60 == 0) std.debug.print("      t+{d}: {d} live, spawned {d} landed {d}\n", .{ age, ps.live, ps.spawned, ps.landed });
    }
    try engine.readbackCells(cells);
    const dirt1 = countMaterial(cells, m.dirt);
    var spread_left: usize = 0;
    var spread_right: usize = 0;
    for (cells, 0..) |c, i| {
        if (cell.material(c) != m.dirt) continue;
        const x = i % cell.world_size;
        if (x < 880) spread_left += 1;
        if (x > 1120) spread_right += 1;
    }
    std.debug.print("      dirt {d} -> {d}, lost {d}, peak {d} live, empty {?d} ticks after the eject; {d} cells landed left of x=880, {d} right of x=1120\n", .{ dirt0, dirt1, lost, peak, empty_after, spread_left, spread_right });
    try check(peak > 5000, "the eject threw only {d} particles", .{peak});
    try check(empty_after != null and empty_after.? < 600, "particles still flying 10 s later", .{});
    // `lost` counts every material (gravel chips too).
    try check(dirt1 <= dirt0 and dirt0 - dirt1 <= lost, "dirt {d} -> {d} with {d} lost", .{ dirt0, dirt1, lost });
    try check(lost * 100 < dirt0, "lost {d} of {d}", .{ lost, dirt0 });
    try check(spread_left > 500 and spread_right > 500, "debris did not fly out: {d} left, {d} right", .{ spread_left, spread_right });
}

fn cpuSpawn(gpa: std.mem.Allocator, engine: *Engine, table: *const materials.Table) !void {
    _ = gpa;
    _ = table;
    var list: commands.CommandList = .{};
    for (0..100) |i| {
        const fi: f32 = @floatFromInt(i);
        try check(engine.pipeline.particles.spawn(500 + fi, 300, 40, -100, m.water, null), "spawn refused", .{});
    }
    list.begin(engine.tick);
    try tickWith(engine, &list);
    try engine.finish();
    try check(engine.mirror().particles.live == 100 and engine.mirror().particles.spawned == 100, "live {d} spawned {d}", .{ engine.mirror().particles.live, engine.mirror().particles.spawned });
}

fn budget(gpa: std.mem.Allocator, engine: *Engine, table: *const materials.Table) !void {
    _ = gpa;
    _ = table;
    engine.pipeline.particles.setBudget(m.sand, 1000);
    var list: commands.CommandList = .{};
    list.begin(engine.tick);
    list.spray(.{ .x = 1000, .y = 1000, .material = m.sand, .count = 3000, .speed = 10 });
    list.spray(.{ .x = 1000, .y = 1000, .material = m.dirt, .count = 500, .speed = 10 });
    try tickWith(engine, &list);
    try engine.finish();
    const ps = engine.mirror().particles;
    try check(ps.live == 1500 and ps.refused == 2000, "live {d} refused {d}, want 1500 / 2000", .{ ps.live, ps.refused });
}
