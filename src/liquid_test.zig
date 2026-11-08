//! `hexe --headless --liquid-test [utube|dam|pool|determinism|all]`: the
//! liquid solver scenarios of docs/04-fluids.md (1, 2, 5, 6), run on the GPU
//! with the assertions of scenarios/{u_tube,dam_break,pool_sleep}.zon. A
//! stand-in until `zig build scenarios` runs those files directly.
const std = @import("std");
const Cli = @import("main.zig").Cli;
const Engine = @import("engine.zig").Engine;
const cell = @import("sim/cell.zig");
const scenes = @import("sim/scenes.zig");
const liquid_scenes = @import("sim/liquid_scenes.zig");
const materials = @import("sim/materials.zig");
const readback = @import("sim/readback.zig");
/// Material ids of the loaded set, resolved by name in `run`.
var m: materials.Ids = .{};

const Rect = struct { x: i32, y: i32, w: i32, h: i32 };
const whole: Rect = .{ .x = 0, .y = 0, .w = liquid_scenes.box, .h = liquid_scenes.box };

const Ctx = struct {
    gpa: std.mem.Allocator,
    cli: Cli,
    cells: []u32,
    failures: u32 = 0,
    lib: *const materials.Library,

    fn check(self: *Ctx, ok: bool, comptime fmt: []const u8, args: anytype) void {
        std.debug.print("  [{s}] " ++ fmt ++ "\n", .{if (ok) "PASS" else "FAIL"} ++ args);
        if (!ok) self.failures += 1;
    }

    /// The solver in isolation: no air field (float, and its blasts throw
    /// particles), and `handoff` decides whether splashes fly in the shared
    /// ballistic pass (the default) or in the solver's own ballistic mode
    /// (the determinism check: the shared pass is not order-deterministic).
    fn engineWith(self: *Ctx, handoff: bool) !*Engine {
        const e = try self.gpa.create(Engine);
        errdefer self.gpa.destroy(e);
        try e.init(self.gpa, .{
            .library = self.lib,
            .validation = self.cli.validation orelse false,
            .pipeline = .{ .sleep = self.cli.sleep, .air = false, .liquid = true, .liquid_handoff = handoff, .liquid_params = self.cli.liquid_params },
        });
        return e;
    }

    fn engine(self: *Ctx) !*Engine {
        return self.engineWith(true);
    }

    fn destroy(self: *Ctx, e: *Engine) void {
        e.deinit();
        self.gpa.destroy(e);
    }
};

fn advance(e: *Engine, scene: scenes.Scene, seed: u32, to_tick: u32) !void {
    while (e.tick < to_tick) try e.frame(1, .{ .scene = scene, .seed = seed }, null);
}

fn snapshot(c: *Ctx, e: *Engine) !void {
    try e.readbackCells(c.cells);
}

fn at(c: *const Ctx, x: i32, y: i32) u32 {
    const wx = cell.wrap(liquid_scenes.origin[0] + x);
    const wy = cell.wrap(liquid_scenes.origin[1] + y);
    return c.cells[cell.index(wx, wy)];
}

fn count(c: *const Ctx, material: u8, r: Rect) u32 {
    var n: u32 = 0;
    var y = r.y;
    while (y < r.y + r.h) : (y += 1) {
        var x = r.x;
        while (x < r.x + r.w) : (x += 1) n += @intFromBool(cell.material(at(c, x, y)) == material);
    }
    return n;
}

fn particleCells(c: *const Ctx, r: Rect) u32 {
    var n: u32 = 0;
    var y = r.y;
    while (y < r.y + r.h) : (y += 1) {
        var x = r.x;
        while (x < r.x + r.w) : (x += 1) n += @intFromBool(cell.has(at(c, x, y), cell.flag_particle));
    }
    return n;
}

/// Topmost row in `r` holding at least `min_run` water cells, or r.y + r.h.
fn surface(c: *const Ctx, r: Rect, min_run: u32) i32 {
    var y = r.y;
    while (y < r.y + r.h) : (y += 1) {
        if (count(c, m.water, .{ .x = r.x, .y = y, .w = r.w, .h = 1 }) >= min_run) return y;
    }
    return r.y + r.h;
}

pub fn run(gpa: std.mem.Allocator, io: std.Io, cli: Cli, name: []const u8, lib: *const materials.Library) !u8 {
    _ = io;
    m = lib.ids();
    const cells = try gpa.alloc(u32, cell.world_size * cell.world_size);
    defer gpa.free(cells);
    var c: Ctx = .{ .gpa = gpa, .cli = cli, .cells = cells, .lib = lib };
    const all = std.mem.eql(u8, name, "all");
    var ran = false;
    if (all or std.mem.eql(u8, name, "utube")) {
        try utube(&c);
        ran = true;
    }
    if (all or std.mem.eql(u8, name, "dam")) {
        try dam(&c);
        ran = true;
    }
    if (all or std.mem.eql(u8, name, "pool")) {
        try pool(&c);
        ran = true;
    }
    if (std.mem.eql(u8, name, "residual")) {
        try debug(&c);
        ran = true;
    }
    if (all or std.mem.eql(u8, name, "reaction")) {
        try reaction(&c);
        ran = true;
    }
    if (all or std.mem.eql(u8, name, "determinism")) {
        try determinism(&c);
        ran = true;
    }
    if (!ran) {
        std.debug.print("unknown liquid test '{s}' (utube|dam|pool|reaction|determinism|all|residual)\n", .{name});
        return 2;
    }
    std.debug.print("liquid-test: {s} ({d} failures)\n", .{ if (c.failures == 0) "PASS" else "FAIL", c.failures });
    return if (c.failures == 0) 0 else 1;
}

/// Scenario 1 (scenarios/u_tube.zon): pour into the left arm for 61 ticks;
/// 120 ticks (2 s) after the pour both arms hold the same level.
fn utube(c: *Ctx) !void {
    // The 160-px arms oscillate with a period of about 4 s at 196 px/s^2
    // (decision 87); damping that equalizes in 2 s would kill dam-break
    // waves, so the integration asserts equalization within 12 s of the pour
    // (docs/decisions/116-integrate-liquid.md).
    std.debug.print("u_tube: water poured into the left arm (ticks 0-60), levels within 4 px by tick 780 (12 s after the pour)\n", .{});
    const e = try c.engine();
    defer c.destroy(e);
    const left: Rect = .{ .x = 60, .y = 40, .w = 20, .h = 160 };
    const right: Rect = .{ .x = 176, .y = 40, .w = 20, .h = 160 };
    var equal_at: ?u32 = null;
    try advance(e, .liquid_utube, c.cli.seed, 61);
    try snapshot(c, e);
    std.debug.print("    tick  61: {d} water cells poured\n", .{count(c, m.water, whole)});
    var t: u32 = 70;
    var nl: u32 = 0;
    var nr: u32 = 0;
    var total: u32 = 0;
    var settled_at: ?u32 = null;
    while (t <= 900) : (t += 10) {
        try advance(e, .liquid_utube, c.cli.seed, t);
        try snapshot(c, e);
        const hl = surface(c, left, 10);
        const hr = surface(c, right, 10);
        if (t <= 180 or t % 60 == 0) std.debug.print("    tick {d:3}: left surface y {d}, right y {d}, awake {d}\n", .{ t, hl, hr, e.pipeline.liquid.stats().alive });
        const both = @abs(hl - hr) <= 4 and hl < left.y + left.h;
        if (t <= 780 and equal_at == null and both) equal_at = t;
        if (settled_at == null and both) settled_at = t;
        if (!both) settled_at = null;
        if (t == 780) {
            nl = count(c, m.water, left);
            nr = count(c, m.water, right);
            total = count(c, m.water, whole);
        }
    }
    std.debug.print("    levels within 4 px for good from tick {?d} (equalization time after the pour: {?d} ticks)\n", .{ settled_at, if (settled_at) |st| st - 60 else null });
    // Arm counts at tick 780 (scenarios/u_tube.zon): both arms hold water,
    // within 4 rows of each other.
    c.check(nl >= 160 and nl <= 600, "left arm level: {d} water cells (160-600)", .{nl});
    c.check(nr >= 160 and nr <= 600, "right arm level: {d} water cells (160-600)", .{nr});
    c.check(@max(nl, nr) - @min(nl, nr) <= 80, "arms within 4 rows: {d} vs {d}", .{ nl, nr });
    c.check(settled_at != null and settled_at.? <= 780, "levels within 4 px for good by tick 780 (from tick {?d})", .{settled_at});
    c.check(count(c, m.water, .{ .x = 60, .y = 40, .w = 20, .h = 96 }) == 0, "left arm not overfull", .{});
    c.check(count(c, m.water, .{ .x = 176, .y = 40, .w = 20, .h = 96 }) == 0, "right arm not overfull", .{});
    c.check(equal_at != null, "levels within 4 px by tick 780 (first at tick {?d}; pour ended at tick 60); {d} water cells in total", .{ equal_at, total });
}

/// Scenario 2 (scenarios/dam_break.zon): 1-px wood dam removed at tick 60.
fn dam(c: *Ctx) !void {
    std.debug.print("dam_break: 1-px wood dam removed at tick 60\n", .{});
    const e = try c.engine();
    defer c.destroy(e);
    const right_half: Rect = .{ .x = 129, .y = 0, .w = 107, .h = 232 };
    try advance(e, .liquid_dam, c.cli.seed, 59);
    try snapshot(c, e);
    const total0 = count(c, m.water, whole);
    c.check(count(c, m.water, right_half) == 0, "dam holds until removed (tick 59; {d} water cells)", .{total0});
    try advance(e, .liquid_dam, c.cli.seed, 61);
    try snapshot(c, e);
    c.check(count(c, m.wood, whole) == 0, "dam removed (tick 61)", .{});
    var reached: ?u32 = null;
    var t: u32 = 70;
    while (t <= 150) : (t += 5) {
        try advance(e, .liquid_dam, c.cli.seed, t);
        try snapshot(c, e);
        if (reached == null and count(c, m.water, .{ .x = 200, .y = 150, .w = 36, .h = 82 }) >= 1) reached = t;
    }
    c.check(reached != null, "wave reached the far side by tick 150 (first seen tick {?d})", .{reached});
    t = 200;
    while (t <= 900) : (t += 100) {
        try advance(e, .liquid_dam, c.cli.seed, t);
        try snapshot(c, e);
        std.debug.print("    tick {d:3}: left surface y {d}, right y {d}, awake {d}\n", .{ t, surface(c, .{ .x = 20, .y = 100, .w = 108, .h = 132 }, 20), surface(c, .{ .x = 129, .y = 100, .w = 107, .h = 132 }, 20), e.pipeline.liquid.stats().alive });
    }
    const right = count(c, m.water, .{ .x = 129, .y = 120, .w = 107, .h = 112 });
    const total = count(c, m.water, whole);
    c.check(right >= 3900 and right <= 4950, "about half the water is on the right: {d} of {d} (3900-4950)", .{ right, total });
    const high = count(c, m.water, .{ .x = 20, .y = 0, .w = 216, .h = 184 });
    c.check(high == 0, "levels settled: {d} water cells above y 184", .{high});
    c.check(total * 100 >= total0 * 97, "volume kept: {d} of {d} cells", .{ total, total0 });
}

/// Scenario 5 (scenarios/pool_sleep.zon): poured pool fully asleep 5 s after
/// the pour; a gravel (sand) blob at tick 400 wakes it locally only.
fn pool(c: *Ctx) !void {
    std.debug.print("pool_sleep: poured for 61 ticks, asleep by 360, blob at 400 wakes the left only\n", .{});
    const e = try c.engine();
    defer c.destroy(e);
    var asleep_at: ?u32 = null;
    var t: u32 = 70;
    while (t <= 360) : (t += 10) {
        try advance(e, .liquid_pool, c.cli.seed, t);
        try e.finish();
        const ls = e.pipeline.liquid.stats();
        const alive = ls.alive;
        if (asleep_at == null and alive == 0) asleep_at = t;
        if (t % 50 == 0) std.debug.print("    tick {d:3}: awake {d}; this tick woke {d} (request/powder/landing/pushed/imbalance {any}), slept {d}\n", .{ t, alive, ls.spawned, ls.triggers, ls.slept });
    }
    try snapshot(c, e);
    const alive = e.pipeline.liquid.stats().alive;
    c.check(alive == 0 and particleCells(c, whole) == 0, "pool fully asleep at tick 360 ({d} awake, first fully asleep at tick {?d})", .{ alive, asleep_at });
    const water = count(c, m.water, whole);
    c.check(water >= 3000, "the pool exists: {d} water cells", .{water});
    var woke_max: u32 = 0;
    var far_max: u32 = 0;
    t = 402;
    while (t <= 440) : (t += 2) {
        try advance(e, .liquid_pool, c.cli.seed, t);
        try snapshot(c, e);
        const near = particleCells(c, .{ .x = 20, .y = 190, .w = 60, .h = 50 });
        woke_max = @max(woke_max, near);
        far_max = @max(far_max, particleCells(c, .{ .x = 196, .y = 190, .w = 40, .h = 50 }));
        if (t == 420) c.check(near >= 1, "impact woke the water: {d} particle cells near the drop at tick 420", .{near});
    }
    c.check(far_max == 0, "far edge stayed asleep (ticks 402-440; at most {d} awake near the drop)", .{woke_max});
}

/// Reactions coupling: another pass turns awake water into something else
/// (here a command paints smoke over it, as boiling would turn it into
/// steam); the particles there die in the next lift and no particle-backed
/// cell is left in the changed region.
fn reaction(c: *Ctx) !void {
    std.debug.print("reaction: smoke painted over awake water during the dam break kills its particles\n", .{});
    const e = try c.engine();
    defer c.destroy(e);
    try advance(e, .liquid_dam, c.cli.seed, 80);
    try e.finish();
    const killed0 = e.pipeline.liquid.stats().total_killed;
    // A smoke disc over the moving front: the cells change under the particles.
    var cmd: @import("sim/commands.zig").CommandList = .{};
    cmd.begin(e.tick);
    cmd.fillCircle(liquid_scenes.origin[0] + 128, liquid_scenes.origin[1] + 215, 10, m.smoke, .{});
    try e.frame(1, .{ .scene = .liquid_dam, .seed = c.cli.seed, .extra = cmd.slice() }, null);
    try advance(e, .liquid_dam, c.cli.seed, e.tick + 2);
    try snapshot(c, e);
    const killed = e.pipeline.liquid.stats().total_killed - killed0;
    // Particles may flow back in afterwards; right after, the disc holds no
    // particle that was there (they died), only smoke or newcomers.
    c.check(killed > 0, "{d} particles died when their cells were changed under them", .{killed});

    // Switching the solver off mid-flow turns every particle into a plain
    // cell in place: no water lost, none left particle-backed.
    const before = count(c, m.water, whole);
    e.pipeline.config.liquid = false;
    try advance(e, .liquid_dam, c.cli.seed, e.tick + 1);
    try snapshot(c, e);
    const after = count(c, m.water, whole);
    const left = particleCells(c, whole);
    c.check(left == 0 and after + 8 >= before, "solver off: {d} -> {d} water cells, {d} particle-backed left", .{ before, after, left });
}

/// Scenario 6: the same seed gives identical cell and owner images after
/// 600 ticks of a dam break (sort-based transfer, no float atomics).
fn determinism(c: *Ctx) !void {
    std.debug.print("determinism: dam break and pool, 600 ticks, two runs each\n", .{});
    const n = cell.world_size * cell.world_size;
    const a = try c.gpa.alloc(u32, n * 2);
    defer c.gpa.free(a);
    const b = try c.gpa.alloc(u32, n * 2);
    defer c.gpa.free(b);
    for ([_]scenes.Scene{ .liquid_dam, .liquid_basin }) |scene| {
        for ([_][]u32{ a, b }) |out| {
            const e = try c.engineWith(false);
            defer c.destroy(e);
            try advance(e, scene, c.cli.seed, 600);
            try e.readbackCells(out[0..n]);
            try readback.readbackOwner(&e.ctx, &e.pipeline.shared, &e.staging, out[n..]);
        }
        var diff_cells: usize = 0;
        var diff_owner: usize = 0;
        var particles: usize = 0;
        for (0..n) |i| {
            diff_cells += @intFromBool(a[i] != b[i]);
            const pa = cell.has(a[i], cell.flag_particle);
            particles += @intFromBool(pa);
            if (pa and a[n + i] != b[n + i]) diff_owner += 1;
        }
        c.check(diff_cells == 0 and diff_owner == 0, "{s}: {d} cells and {d} particle owners differ ({d} particle-backed cells)", .{ @tagName(scene), diff_cells, diff_owner, particles });
    }
}

/// Projection convergence on the 500K bench scene: rms of the pressure
/// equation residual |b - Ap| against |b| over pressurized cells (tuning).
fn debug(c: *Ctx) !void {
    const e = try c.engine();
    defer c.destroy(e);
    const lq = &e.pipeline.liquid;
    const g = 1024 * 1024;
    const bufs = try c.gpa.alloc(u32, g * 5);
    defer c.gpa.free(bufs);
    const ty = bufs[2 * g .. 3 * g];
    const b = bufs[3 * g .. 4 * g];
    const p = bufs[4 * g .. 5 * g];
    for ([_]u32{ 60, 120, 200 }) |t| {
        try advance(e, .liquid_slosh, c.cli.seed, t);
        try e.finish();
        try lq.debugRead(.mg_type, 0, 0, ty);
        try lq.debugRead(.mg_b, 0, 0, b);
        try lq.debugRead(.mg_p, 0, 0, p);
        var sb: f64 = 0;
        var sd: f64 = 0;
        var nf: f64 = 0;
        for (0..1024) |y| for (0..1024) |x| {
            const i = y * 1024 + x;
            if (ty[i] & 3 != 1 or @as(f32, @bitCast(p[i])) <= 0.01) continue;
            const r = y * 1024 + (x + 1) % 1024;
            const d = ((y + 1) % 1024) * 1024 + x;
            const wl: f32 = @floatFromInt((ty[i] >> 8) & 0xff);
            const wt: f32 = @floatFromInt((ty[i] >> 16) & 0xff);
            const wr: f32 = @floatFromInt((ty[r] >> 8) & 0xff);
            const wb: f32 = @floatFromInt((ty[d] >> 16) & 0xff);
            const l = y * 1024 + (x + 1023) % 1024;
            const up = ((y + 1023) % 1024) * 1024 + x;
            const pf = struct {
                fn f(tys: []const u32, ps: []const u32, k: usize) f32 {
                    return if (tys[k] & 3 == 1) @as(f32, @bitCast(ps[k])) else 0;
                }
            }.f;
            const ap = (wl + wr + wt + wb) * pf(ty, p, i) - wl * pf(ty, p, l) - wr * pf(ty, p, r) - wt * pf(ty, p, up) - wb * pf(ty, p, d);
            const bb: f32 = @bitCast(b[i]);
            const res = bb - ap;
            sb += bb * bb;
            sd += res * res;
            nf += 1;
        };
        std.debug.print("tick {d}: {d} pressurized cells, rms rhs {d:.3}, rms residual {d:.4} (ratio {d:.4})\n", .{ t, nf, @sqrt(sb / @max(nf, 1)), @sqrt(sd / @max(nf, 1)), @sqrt(sd / @max(sb, 1e-9)) });
    }
}
