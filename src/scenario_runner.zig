//! `zig build scenarios` / `hexe --headless --scenarios DIR | --scenario FILE`:
//! headless GPU regression worlds (scenarios/README.md, src/data/scenario.zig).
//!
//! Each scenario gets a fresh engine. Its world (w x h cells, origin at
//! `origin` in the 2048 torus) is framed by a one-cell bedrock ring so that
//! nothing leaves it ("cells outside it are treated as the world edge").
//! Fills are tick-0 commands, scheduled commands run before the step of
//! their tick, and assertions are evaluated from a full cell-image readback
//! after the step of their tick. Scenarios that `.requires` systems not
//! built yet are reported as SKIP with the reason; any FAIL makes the exit
//! code 1. docs/decisions/44-reactions-scenario-runner.md.
const std = @import("std");
const data = @import("data");
const Cli = @import("main.zig").Cli;
const Engine = @import("engine.zig").Engine;
const cell = @import("sim/cell.zig");
const commands = @import("sim/commands.zig");
const materials = @import("sim/materials.zig");

const scen = data.scenario;
const Scenario = scen.Scenario;

/// World cell of scenario cell (0, 0).
pub const origin: i32 = 16;

/// Systems this build has. Everything else in `Requirement` makes a
/// scenario SKIP.
const implemented = [_]scen.Requirement{};

const Outcome = enum { pass, fail, skip };

pub fn run(gpa: std.mem.Allocator, io: std.Io, cli: Cli, lib: *const materials.Library) !u8 {
    var diag: materials.Diagnostics = .init(gpa);
    defer diag.deinit();
    var list: std.ArrayList(Scenario) = .empty;
    defer {
        for (list.items) |*s| s.deinit();
        list.deinit(gpa);
    }
    var failed: u32 = 0;
    if (cli.scenario) |path| {
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
            std.debug.print("{s}: cannot read: {s}\n", .{ path, @errorName(err) });
            return 1;
        };
        defer gpa.free(text);
        const s = scen.parse(gpa, path, text, &diag) catch |err| switch (err) {
            error.InvalidScenario => {
                std.debug.print("{f}\nFAIL {s}: invalid scenario\n", .{ diag, path });
                return 1;
            },
            else => |e| return e,
        };
        try list.append(gpa, s);
    }
    if (cli.scenarios) |dir| {
        const all = try scen.loadDir(io, gpa, dir, &diag);
        defer gpa.free(all);
        try list.appendSlice(gpa, all);
        if (diag.messages.items.len > 0) {
            std.debug.print("{f}\n", .{diag});
            failed += @intCast(diag.messages.items.len);
            diag.clear();
        }
    }

    var passed: u32 = 0;
    var skipped: u32 = 0;
    const start = std.Io.Timestamp.now(io, .awake);
    for (list.items) |*s| {
        const outcome = try runOne(gpa, io, cli, lib, s);
        switch (outcome) {
            .pass => passed += 1,
            .fail => failed += 1,
            .skip => skipped += 1,
        }
    }
    const secs = @as(f64, @floatFromInt(start.untilNow(io, .awake).nanoseconds)) / 1e9;
    std.debug.print("\nscenarios: {d} passed, {d} failed, {d} skipped ({d:.1} s)\n", .{ passed, failed, skipped, secs });
    return if (failed == 0) 0 else 1;
}

fn missingRequirement(s: *const Scenario) ?scen.Requirement {
    outer: for (s.def.requires) |r| {
        for (implemented) |have| if (have == r) continue :outer;
        return r;
    }
    return null;
}

fn requirementReason(r: scen.Requirement) []const u8 {
    return switch (r) {
        .flip => "needs the FLIP liquid solver (M6)",
        .air_field => "needs the air field and pressure (M5)",
        .explosions => "needs the explosion command (M4/M5)",
        .particles => "needs the particle buffer (M4)",
        .bodies => "needs rigid bodies (M7)",
    };
}

fn runOne(gpa: std.mem.Allocator, io: std.Io, cli: Cli, lib: *const materials.Library, s: *const Scenario) !Outcome {
    const def = &s.def;
    if (missingRequirement(s)) |r| {
        std.debug.print("SKIP {s}: {s}\n", .{ def.name, requirementReason(r) });
        return .skip;
    }
    var diag: materials.Diagnostics = .init(gpa);
    defer diag.deinit();
    if (!try scen.checkMaterials(s, &lib.set, &diag)) {
        std.debug.print("{f}\nFAIL {s}: unknown materials\n", .{ diag, def.name });
        return .fail;
    }
    for (def.commands) |c| if (c.action() == .explode) {
        std.debug.print("SKIP {s}: explode command without `.requires = .{{ .explosions }}`; {s}\n", .{ def.name, requirementReason(.explosions) });
        return .skip;
    };

    std.debug.print("scenario {s}: {d} ticks, {d}x{d}\n", .{ def.name, def.ticks, def.size.w, def.size.h });
    const t0 = std.Io.Timestamp.now(io, .awake);

    // Assertion ticks in order; deterministic assertions need extra runs.
    var last: u32 = def.ticks;
    var runs: u32 = 1;
    for (def.assertions) |a| {
        last = @max(last, s.assertionTick(a));
        if (a.deterministic) |d| runs = @max(runs, d.runs);
    }

    const cells = try gpa.alloc(u32, cell.world_size * cell.world_size);
    defer gpa.free(cells);
    const results = try gpa.alloc(?bool, def.assertions.len);
    defer gpa.free(results);
    @memset(results, null);
    const hashes = try gpa.alloc(u64, def.assertions.len * runs);
    defer gpa.free(hashes);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const details = try arena.allocator().alloc([]const u8, def.assertions.len);
    @memset(details, "");

    var run_index: u32 = 0;
    while (run_index < runs) : (run_index += 1) {
        const engine = try gpa.create(Engine);
        defer gpa.destroy(engine);
        try engine.init(gpa, .{
            .tables = lib.tables,
            .ids = lib.ids(),
            .validation = cli.validation orelse false,
            .pipeline = .{ .sleep = cli.sleep },
        });
        defer engine.deinit();
        engine.tick = @truncate(def.seed);
        const base_tick = engine.tick;

        var list: commands.CommandList = .{};
        var t: u32 = 0;
        while (t <= last) : (t += 1) {
            list.begin(base_tick +% t);
            if (t == 0) {
                frame(lib, def, &list);
                for (def.fills) |f| fill(lib, def, &list, f.region().shape(), f);
            }
            for (def.commands) |c| if (c.firesAt(t)) command(lib, def, &list, c);
            if (list.dropped > 0) std.debug.print("  warning: tick {d}: {d} commands dropped\n", .{ t, list.dropped });
            try engine.frame(1, .{ .scene = .empty, .extra = list.slice() }, null);

            var wanted = false;
            for (def.assertions) |a| wanted = wanted or s.assertionTick(a) == t;
            if (!wanted) continue;
            try engine.readbackCells(cells);
            for (def.assertions, 0..) |a, i| {
                if (s.assertionTick(a) != t) continue;
                if (a.deterministic != null) {
                    hashes[i * runs + run_index] = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(cells));
                    continue;
                }
                if (run_index > 0) continue;
                results[i] = evaluate(lib, def, a, cells);
                var buf: [160]u8 = undefined;
                details[i] = try arena.allocator().dupe(u8, describe(&buf, lib, def, a, cells));
            }
        }
    }

    var ok = true;
    var skipped_asserts: u32 = 0;
    for (def.assertions, 0..) |a, i| {
        var pass: ?bool = results[i];
        var detail_buf: [160]u8 = undefined;
        var detail: []const u8 = details[i];
        if (a.deterministic) |d| {
            pass = true;
            for (1..d.runs) |r| pass = pass.? and hashes[i * runs + r] == hashes[i * runs];
            detail = std.fmt.bufPrint(&detail_buf, "{d} runs, cell image hash {x:0>16}", .{ d.runs, hashes[i * runs] }) catch "";
        }
        const label = a.label orelse @tagName(a.kind());
        if (pass) |p| {
            if (!p) ok = false;
            std.debug.print("  {s}  t={d: <5} {s}  ({s})\n", .{ if (p) "PASS" else "FAIL", s.assertionTick(a), label, detail });
        } else {
            skipped_asserts += 1;
            std.debug.print("  SKIP  t={d: <5} {s}  ({s})\n", .{ s.assertionTick(a), label, detail });
        }
    }
    const secs = @as(f64, @floatFromInt(t0.untilNow(io, .awake).nanoseconds)) / 1e9;
    if (ok) {
        std.debug.print("PASS {s} ({d:.1} s{s})\n", .{ def.name, secs, if (skipped_asserts > 0) ", some assertions skipped" else "" });
    } else {
        std.debug.print("FAIL {s} ({d:.1} s): {s}\n", .{ def.name, secs, def.description });
    }
    return if (ok) .pass else .fail;
}

// ---------------------------------------------------------------- world

fn worldW(def: *const scen.Def) i32 {
    return @intCast(def.size.w);
}
fn worldH(def: *const scen.Def) i32 {
    return @intCast(def.size.h);
}

/// One-cell bedrock ring around the scenario world.
fn frame(lib: *const materials.Library, def: *const scen.Def, list: *commands.CommandList) void {
    const edge = lib.id("bedrock") orelse lib.id("stone") orelse return;
    const w = worldW(def);
    const h = worldH(def);
    if (w + 2 > cell.world_size or h + 2 > cell.world_size) return;
    const x0 = origin - 1;
    const y0 = origin - 1;
    const x1 = origin + w + 1;
    const y1 = origin + h + 1;
    list.fillRect(x0, y0, x1, origin, edge, .{});
    list.fillRect(x0, origin + h, x1, y1, edge, .{});
    list.fillRect(x0, origin, origin, origin + h, edge, .{});
    list.fillRect(origin + w, origin, x1, origin + h, edge, .{});
}

/// Push `shape` as commands with `opts`: rects clipped to the world,
/// circles as is, lines as a run of circles of radius width/2.
fn pushShape(def: *const scen.Def, list: *commands.CommandList, shape: scen.Shape, material: u8, opts: commands.Options) void {
    switch (shape) {
        .rect => |r| {
            const x0 = @max(r.x, 0);
            const y0 = @max(r.y, 0);
            const x1 = @min(r.x + r.w, worldW(def));
            const y1 = @min(r.y + r.h, worldH(def));
            list.fillRect(origin + x0, origin + y0, origin + x1, origin + y1, material, opts);
        },
        .circle => |c| list.fillCircle(origin + c.x, origin + c.y, c.r, material, opts),
        .line => |l| {
            const dx = l.x1 - l.x0;
            const dy = l.y1 - l.y0;
            const steps: i32 = @intCast(@max(@abs(dx), @abs(dy)));
            const radius = @divFloor(l.width, 2);
            var i: i32 = 0;
            while (i <= steps) : (i += 1) {
                const x = l.x0 + if (steps > 0) @divFloor(dx * i, steps) else 0;
                const y = l.y0 + if (steps > 0) @divFloor(dy * i, steps) else 0;
                list.fillCircle(origin + x, origin + y, radius, material, opts);
            }
        },
    }
}

fn fill(lib: *const materials.Library, def: *const scen.Def, list: *commands.CommandList, shape: scen.Shape, f: scen.Fill) void {
    var opts: commands.Options = .{};
    if (f.only) |o| {
        if (std.mem.eql(u8, o, "air")) opts.only_air = true else opts.only = lib.id(o).?;
    }
    if (f.temperature) |c| opts.temperature = data.temperature.toByte(c);
    if (f.state) |st| opts.state = @intCast(std.math.clamp(st, 0, 255));
    pushShape(def, list, shape, lib.id(f.material).?, opts);
}

fn command(lib: *const materials.Library, def: *const scen.Def, list: *commands.CommandList, c: scen.Command) void {
    switch (c.action()) {
        .fill => fill(lib, def, list, c.fill.?.region().shape(), c.fill.?),
        .remove => pushShape(def, list, c.remove.?.shape(), materials.air, .{}),
        .ignite => pushShape(def, list, c.ignite.?.shape(), 0, .{ .action = .ignite }),
        .heat => pushShape(def, list, c.heat.?.region().shape(), 0, .{ .action = .heat, .temperature = data.temperature.toByte(c.heat.?.temperature) }),
        .explode => {}, // filtered out before the run
    }
}

// ----------------------------------------------------------- assertions

fn cellAt(cells: []const u32, x: i32, y: i32) u32 {
    return cells[cell.index(cell.wrap(origin + x), cell.wrap(origin + y))];
}

fn countIn(def: *const scen.Def, cells: []const u32, rect: ?scen.Rect, material: ?u8, particle: bool) u32 {
    const r = rect orelse scen.Rect{ .x = 0, .y = 0, .w = worldW(def), .h = worldH(def) };
    var n: u32 = 0;
    var y = r.y;
    while (y < r.y + r.h) : (y += 1) {
        var x = r.x;
        while (x < r.x + r.w) : (x += 1) {
            const c = cellAt(cells, x, y);
            if (material) |m| {
                n += @intFromBool(cell.material(c) == m);
            } else if (particle) n += @intFromBool(cell.has(c, cell.flag_particle));
        }
    }
    return n;
}

/// null = not evaluable in this build (reported as SKIP).
fn evaluate(lib: *const materials.Library, def: *const scen.Def, a: scen.Assertion, cells: []const u32) ?bool {
    switch (a.kind()) {
        .count => {
            const c = a.count.?;
            const n = countIn(def, cells, c.rect, lib.id(c.material).?, false);
            return n >= c.min and (c.max == null or n <= c.max.?);
        },
        .at => {
            const at = a.at.?;
            return cell.material(cellAt(cells, at.x, at.y)) == lib.id(at.material).?;
        },
        .none => {
            const no = a.none.?;
            return countIn(def, cells, no.rect, lib.id(no.material).?, false) == 0;
        },
        .particles => {
            const p = a.particles.?;
            const n = countIn(def, cells, p.rect, null, true);
            return n >= p.min and (p.max == null or n <= p.max.?);
        },
        .pressure => return null,
        .deterministic => return null,
    }
}

fn describe(buf: []u8, lib: *const materials.Library, def: *const scen.Def, a: scen.Assertion, cells: []const u32) []const u8 {
    return switch (a.kind()) {
        .count => blk: {
            const c = a.count.?;
            const n = countIn(def, cells, c.rect, lib.id(c.material).?, false);
            if (c.max) |mx| break :blk std.fmt.bufPrint(buf, "{s} = {d}, want {d}..{d}", .{ c.material, n, c.min, mx }) catch "";
            break :blk std.fmt.bufPrint(buf, "{s} = {d}, want >= {d}", .{ c.material, n, c.min }) catch "";
        },
        .at => blk: {
            const at = a.at.?;
            break :blk std.fmt.bufPrint(buf, "({d},{d}) is {s}, want {s}", .{ at.x, at.y, lib.name(@intCast(cell.material(cellAt(cells, at.x, at.y)))), at.material }) catch "";
        },
        .none => blk: {
            const no = a.none.?;
            break :blk std.fmt.bufPrint(buf, "{s} = {d}, want 0", .{ no.material, countIn(def, cells, no.rect, lib.id(no.material).?, false) }) catch "";
        },
        .particles => blk: {
            const p = a.particles.?;
            const n = countIn(def, cells, p.rect, null, true);
            break :blk std.fmt.bufPrint(buf, "particle-backed cells = {d} (no liquid solver yet: always 0)", .{n}) catch "";
        },
        .pressure => "no air field yet (M5)",
        .deterministic => "",
    };
}
