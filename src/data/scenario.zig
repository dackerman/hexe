//! Scenario files: declarative regression worlds under `scenarios/`.
//!
//! A scenario is a small world (default 256 × 256), a list of fills applied
//! in order at tick 0, optional commands at later ticks, a tick count and
//! assertions on the cell image. The format is documented with examples in
//! `scenarios/README.md`; this file parses and validates it. Running the
//! simulation is the scenario runner's job, not this module's.
//!
//! Coordinates are cells, x to the right and y downward (gravity is +y),
//! origin at the top-left corner. A rect covers `x ≤ cx < x + w`,
//! `y ≤ cy < y + h`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const materials = @import("materials.zig");
const temperature = @import("temperature.zig");
const Diagnostics = materials.Diagnostics;

pub const default_size: Size = .{ .w = 256, .h = 256 };
/// Largest world a scenario may ask for: the standard active window.
pub const max_size: u32 = 2048;

pub const Size = struct { w: u32, h: u32 };
pub const Point = struct { x: i32, y: i32 };
pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };
pub const Circle = struct { x: i32, y: i32, r: i32 };
/// Segment from (x0, y0) to (x1, y1), `width` cells thick.
pub const Line = struct { x0: i32, y0: i32, x1: i32, y1: i32, width: i32 = 1 };

/// Resolved shape of a fill, region or command.
pub const Shape = union(enum) {
    rect: Rect,
    circle: Circle,
    line: Line,

    /// Axis-aligned bounds as a rect.
    pub fn bounds(s: Shape) Rect {
        return switch (s) {
            .rect => |r| r,
            .circle => |c| .{ .x = c.x - c.r, .y = c.y - c.r, .w = 2 * c.r + 1, .h = 2 * c.r + 1 },
            .line => |l| blk: {
                const half = @divFloor(l.width, 2);
                const x = @min(l.x0, l.x1) - half;
                const y = @min(l.y0, l.y1) - half;
                break :blk .{ .x = x, .y = y, .w = @max(l.x0, l.x1) + half - x + 1, .h = @max(l.y0, l.y1) + half - y + 1 };
            },
        };
    }
};

/// A shape written as exactly one of `.rect`, `.circle`, `.line`.
pub const Region = struct {
    rect: ?Rect = null,
    circle: ?Circle = null,
    line: ?Line = null,

    /// Valid after `validate`.
    pub fn shape(r: Region) Shape {
        if (r.rect) |v| return .{ .rect = v };
        if (r.circle) |v| return .{ .circle = v };
        return .{ .line = r.line.? };
    }
};

/// Paint a shape with a material.
pub const Fill = struct {
    rect: ?Rect = null,
    circle: ?Circle = null,
    line: ?Line = null,
    material: []const u8,
    /// °C; null = the material's spawn temperature.
    temperature: ?i32 = null,
    /// State byte override (health, lifetime); null = the material default.
    state: ?i32 = null,
    /// Only paint over cells of this material (e.g. "air" to pour without
    /// overwriting what is already there); null = paint over everything.
    only: ?[]const u8 = null,

    pub fn region(f: Fill) Region {
        return .{ .rect = f.rect, .circle = f.circle, .line = f.line };
    }
};

/// Set the temperature of every cell in a shape.
pub const Heat = struct {
    rect: ?Rect = null,
    circle: ?Circle = null,
    line: ?Line = null,
    temperature: i32,

    pub fn region(h: Heat) Region {
        return .{ .rect = h.rect, .circle = h.circle, .line = h.line };
    }
};

pub const Explode = struct {
    x: i32,
    y: i32,
    /// Cells.
    radius: i32,
    /// Relative to the standard explosion (gunpowder) = 1.
    strength: f32 = 1,
};

/// Something that happens at `tick` (and every `every` ticks after that up
/// to and including `until`, when `every > 0`). Exactly one action field.
pub const Command = struct {
    tick: u32,
    every: u32 = 0,
    until: ?u32 = null,
    /// Paint a material (pouring is a repeated fill with `.only = "air"`).
    fill: ?Fill = null,
    /// Set cells to air.
    remove: ?Region = null,
    /// Set the burning flag on flammable cells.
    ignite: ?Region = null,
    /// Set temperature.
    heat: ?Heat = null,
    /// Issue an explosion command, as gunpowder's event would.
    explode: ?Explode = null,

    pub const Action = enum { fill, remove, ignite, heat, explode };

    pub fn action(c: Command) Action {
        if (c.fill != null) return .fill;
        if (c.remove != null) return .remove;
        if (c.ignite != null) return .ignite;
        if (c.heat != null) return .heat;
        return .explode;
    }

    /// Whether the command fires on tick `t`.
    pub fn firesAt(c: Command, t: u32) bool {
        if (t < c.tick) return false;
        if (t == c.tick) return true;
        if (c.every == 0) return false;
        if (c.until) |u| if (t > u) return false;
        return (t - c.tick) % c.every == 0;
    }
};

/// Number of `material` cells in `rect` (whole world if null) in min…max.
pub const Count = struct {
    material: []const u8,
    rect: ?Rect = null,
    min: u32 = 0,
    max: ?u32 = null,
};

/// The cell at (x, y) is `material`.
pub const At = struct { x: i32, y: i32, material: []const u8 };

/// No cell of `material` in `rect` (whole world if null).
pub const None = struct { material: []const u8, rect: ?Rect = null };

/// Number of particle-backed (awake liquid) cells in `rect` in min…max;
/// `.max = 0` asserts the region sleeps.
pub const Particles = struct { rect: ?Rect = null, min: u32 = 0, max: ?u32 = null };

/// Air-field density at a cell, relative to ambient (1.0).
pub const Pressure = struct { x: i32, y: i32, min: ?f32 = null, max: ?f32 = null };

/// Run the scenario `runs` times from scratch and require identical cell
/// images at the assertion tick.
pub const Deterministic = struct { runs: u32 = 2 };

/// Checked after tick `tick` (default: the last tick). Exactly one kind.
pub const Assertion = struct {
    tick: ?u32 = null,
    /// Shown when the assertion fails.
    label: ?[]const u8 = null,
    count: ?Count = null,
    at: ?At = null,
    none: ?None = null,
    particles: ?Particles = null,
    pressure: ?Pressure = null,
    deterministic: ?Deterministic = null,

    pub const Kind = enum { count, at, none, particles, pressure, deterministic };

    pub fn kind(a: Assertion) Kind {
        if (a.count != null) return .count;
        if (a.at != null) return .at;
        if (a.none != null) return .none;
        if (a.particles != null) return .particles;
        if (a.pressure != null) return .pressure;
        return .deterministic;
    }
};

/// One scenario file.
pub const Def = struct {
    name: []const u8,
    description: []const u8 = "",
    size: Size = default_size,
    /// Seed for the simulation hash.
    seed: u64 = 0,
    ticks: u32,
    fills: []const Fill = &.{},
    commands: []const Command = &.{},
    assertions: []const Assertion,
};

pub const Scenario = struct {
    arena: std.heap.ArenaAllocator,
    path: []const u8,
    def: Def,

    pub fn deinit(self: *Scenario) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Tick an assertion is checked at.
    pub fn assertionTick(self: *const Scenario, a: Assertion) u32 {
        return a.tick orelse self.def.ticks;
    }
};

pub const ParseError = error{InvalidScenario} || Allocator.Error;

/// Parses and validates the structure of a scenario (shapes, ticks,
/// ranges). Material names are checked by `checkMaterials`.
pub fn parse(gpa: Allocator, path: []const u8, text: []const u8, diag: *Diagnostics) ParseError!Scenario {
    var s: Scenario = .{ .arena = .init(gpa), .path = undefined, .def = undefined };
    errdefer s.arena.deinit();
    const a = s.arena.allocator();
    s.path = try a.dupe(u8, path);
    const src = try a.dupeSentinel(u8, text, 0);
    var zd: std.zon.parse.Diagnostics = .{ .errors = &.{} };
    s.def = std.zon.parse.fromSlice(Def, .{ .gpa = gpa, .arena = a, .source = src, .diagnostics = &zd }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => {
            try diag.add("{f}", .{zd.fmt(s.path)});
            return error.InvalidScenario;
        },
    };
    const before = diag.messages.items.len;
    try validate(&s, diag);
    if (diag.messages.items.len > before) return error.InvalidScenario;
    return s;
}

/// Checks every material name against a loaded set.
pub fn checkMaterials(s: *const Scenario, set: *const materials.MaterialSet, diag: *Diagnostics) Allocator.Error!bool {
    const before = diag.messages.items.len;
    const V = Validator{ .s = s, .diag = diag };
    for (s.def.fills, 0..) |f, i| {
        try V.material(set, "fills", i, "material", f.material);
        if (f.only) |o| try V.material(set, "fills", i, "only", o);
    }
    for (s.def.commands, 0..) |c, i| if (c.fill) |f| {
        try V.material(set, "commands", i, "fill.material", f.material);
        if (f.only) |o| try V.material(set, "commands", i, "fill.only", o);
    };
    for (s.def.assertions, 0..) |as, i| {
        if (as.count) |c| try V.material(set, "assertions", i, "count.material", c.material);
        if (as.at) |c| try V.material(set, "assertions", i, "at.material", c.material);
        if (as.none) |c| try V.material(set, "assertions", i, "none.material", c.material);
    }
    return diag.messages.items.len == before;
}

const Validator = struct {
    s: *const Scenario,
    diag: *Diagnostics,

    fn fail(v: Validator, list: []const u8, i: usize, field: []const u8, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        const msg = try std.fmt.allocPrint(v.diag.arena.allocator(), fmt, args);
        if (list.len == 0) {
            try v.diag.add("{s}: .{s}: {s}", .{ v.s.path, field, msg });
        } else if (field.len == 0) {
            try v.diag.add("{s}: .{s}[{d}]: {s}", .{ v.s.path, list, i, msg });
        } else {
            try v.diag.add("{s}: .{s}[{d}].{s}: {s}", .{ v.s.path, list, i, field, msg });
        }
    }

    fn material(v: Validator, set: *const materials.MaterialSet, list: []const u8, i: usize, field: []const u8, name: []const u8) Allocator.Error!void {
        if (set.idOf(name) == null) try v.fail(list, i, field, "unknown material \"{s}\"", .{name});
    }

    fn world(v: Validator) Rect {
        return .{ .x = 0, .y = 0, .w = @intCast(v.s.def.size.w), .h = @intCast(v.s.def.size.h) };
    }

    fn overlaps(a: Rect, b: Rect) bool {
        return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h;
    }

    fn inside(a: Rect, b: Rect) bool {
        return a.x >= b.x and a.y >= b.y and a.x + a.w <= b.x + b.w and a.y + a.h <= b.y + b.h;
    }

    /// Exactly one shape, positive dimensions, touches the world.
    fn region(v: Validator, list: []const u8, i: usize, prefix: []const u8, r: Region) Allocator.Error!void {
        const n = @as(u8, @intFromBool(r.rect != null)) + @intFromBool(r.circle != null) + @intFromBool(r.line != null);
        const field = if (prefix.len == 0) "" else prefix;
        if (n != 1) return v.fail(list, i, field, "needs exactly one of .rect, .circle, .line (has {d})", .{n});
        if (r.rect) |rc| if (rc.w <= 0 or rc.h <= 0) return v.fail(list, i, field, "rect needs positive .w and .h", .{});
        if (r.circle) |c| if (c.r < 0) return v.fail(list, i, field, "circle needs .r >= 0", .{});
        if (r.line) |l| if (l.width <= 0) return v.fail(list, i, field, "line needs .width > 0", .{});
        if (!overlaps(r.shape().bounds(), v.world()))
            try v.fail(list, i, field, "shape lies entirely outside the {d}x{d} world", .{ v.s.def.size.w, v.s.def.size.h });
    }

    fn rectInside(v: Validator, list: []const u8, i: usize, field: []const u8, r: ?Rect) Allocator.Error!void {
        const rc = r orelse return;
        if (rc.w <= 0 or rc.h <= 0) return v.fail(list, i, field, "rect needs positive .w and .h", .{});
        if (!inside(rc, v.world()))
            try v.fail(list, i, field, "rect {d},{d} {d}x{d} is not inside the {d}x{d} world", .{ rc.x, rc.y, rc.w, rc.h, v.s.def.size.w, v.s.def.size.h });
    }

    fn pointInside(v: Validator, list: []const u8, i: usize, field: []const u8, x: i32, y: i32) Allocator.Error!void {
        if (!inside(.{ .x = x, .y = y, .w = 1, .h = 1 }, v.world()))
            try v.fail(list, i, field, "point {d},{d} is outside the world", .{ x, y });
    }

    fn temp(v: Validator, list: []const u8, i: usize, field: []const u8, t: ?i32) Allocator.Error!void {
        const c = t orelse return;
        if (!temperature.inRange(c)) try v.fail(list, i, field, "{d} °C out of range", .{c});
    }

    fn minMax(v: Validator, list: []const u8, i: usize, field: []const u8, min: u32, max: ?u32) Allocator.Error!void {
        if (max) |m| if (min > m) try v.fail(list, i, field, ".min {d} is above .max {d}", .{ min, m });
    }
};

fn validate(s: *const Scenario, diag: *Diagnostics) Allocator.Error!void {
    const v = Validator{ .s = s, .diag = diag };
    const d = s.def;
    if (d.name.len == 0) try v.fail("", 0, "name", "must not be empty", .{});
    const stem = std.fs.path.stem(s.path);
    if (!std.mem.eql(u8, stem, d.name))
        try v.fail("", 0, "name", "\"{s}\" does not match the file name \"{s}\"", .{ d.name, stem });
    if (d.size.w == 0 or d.size.h == 0 or d.size.w > max_size or d.size.h > max_size)
        return v.fail("", 0, "size", "{d}x{d} out of range 1–{d}", .{ d.size.w, d.size.h, max_size });
    if (d.ticks == 0) try v.fail("", 0, "ticks", "must be at least 1", .{});
    if (d.assertions.len == 0) try v.fail("", 0, "assertions", "a scenario needs at least one assertion", .{});

    for (d.fills, 0..) |f, i| {
        try v.region("fills", i, "", f.region());
        try v.temp("fills", i, "temperature", f.temperature);
        if (f.state) |st| if (st < 0 or st > 255) try v.fail("fills", i, "state", "{d} out of range 0–255", .{st});
    }

    for (d.commands, 0..) |c, i| {
        const n = @as(u8, @intFromBool(c.fill != null)) + @intFromBool(c.remove != null) +
            @intFromBool(c.ignite != null) + @intFromBool(c.heat != null) + @intFromBool(c.explode != null);
        if (n != 1) {
            try v.fail("commands", i, "", "needs exactly one of .fill, .remove, .ignite, .heat, .explode (has {d})", .{n});
            continue;
        }
        if (c.tick > d.ticks) try v.fail("commands", i, "tick", "{d} is after the last tick {d}", .{ c.tick, d.ticks });
        if (c.until) |u| {
            if (c.every == 0) try v.fail("commands", i, "until", "set without .every", .{});
            if (u < c.tick) try v.fail("commands", i, "until", "{d} is before .tick {d}", .{ u, c.tick });
        }
        switch (c.action()) {
            .fill => {
                try v.region("commands", i, "fill", c.fill.?.region());
                try v.temp("commands", i, "fill.temperature", c.fill.?.temperature);
            },
            .remove => try v.region("commands", i, "remove", c.remove.?),
            .ignite => try v.region("commands", i, "ignite", c.ignite.?),
            .heat => {
                try v.region("commands", i, "heat", c.heat.?.region());
                try v.temp("commands", i, "heat.temperature", c.heat.?.temperature);
            },
            .explode => {
                const e = c.explode.?;
                try v.pointInside("commands", i, "explode", e.x, e.y);
                if (e.radius <= 0) try v.fail("commands", i, "explode.radius", "must be positive", .{});
                if (!(e.strength > 0)) try v.fail("commands", i, "explode.strength", "must be positive", .{});
            },
        }
    }

    for (d.assertions, 0..) |as, i| {
        const n = @as(u8, @intFromBool(as.count != null)) + @intFromBool(as.at != null) +
            @intFromBool(as.none != null) + @intFromBool(as.particles != null) +
            @intFromBool(as.pressure != null) + @intFromBool(as.deterministic != null);
        if (n != 1) {
            try v.fail("assertions", i, "", "needs exactly one of .count, .at, .none, .particles, .pressure, .deterministic (has {d})", .{n});
            continue;
        }
        if (as.tick) |t| if (t > d.ticks or t == 0)
            try v.fail("assertions", i, "tick", "{d} is outside 1–{d}", .{ t, d.ticks });
        switch (as.kind()) {
            .count => {
                const c = as.count.?;
                try v.rectInside("assertions", i, "count.rect", c.rect);
                try v.minMax("assertions", i, "count", c.min, c.max);
            },
            .at => try v.pointInside("assertions", i, "at", as.at.?.x, as.at.?.y),
            .none => try v.rectInside("assertions", i, "none.rect", as.none.?.rect),
            .particles => {
                const p = as.particles.?;
                try v.rectInside("assertions", i, "particles.rect", p.rect);
                try v.minMax("assertions", i, "particles", p.min, p.max);
            },
            .pressure => {
                const p = as.pressure.?;
                try v.pointInside("assertions", i, "pressure", p.x, p.y);
                if (p.min == null and p.max == null) try v.fail("assertions", i, "pressure", "needs .min or .max", .{});
                if (p.min != null and p.max != null and p.min.? > p.max.?)
                    try v.fail("assertions", i, "pressure", ".min is above .max", .{});
            },
            .deterministic => if (as.deterministic.?.runs < 2)
                try v.fail("assertions", i, "deterministic.runs", "needs at least 2 runs", .{}),
        }
    }
}

/// Parses every `*.zon` in a directory. Stops at nothing: all problems go to
/// `diag`; returns the scenarios that parsed. Caller frees each and the slice.
pub fn loadDir(io: Io, gpa: Allocator, dir_path: []const u8, diag: *Diagnostics) ![]Scenario {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const sources = try materials.readZonDir(io, scratch.allocator(), dir_path);
    var out: std.ArrayList(Scenario) = .empty;
    errdefer {
        for (out.items) |*s| s.deinit();
        out.deinit(gpa);
    }
    for (sources) |src| {
        const s = parse(gpa, src.path, src.text, diag) catch |err| switch (err) {
            error.InvalidScenario => continue,
            else => |e| return e,
        };
        try out.append(gpa, s);
    }
    return out.toOwnedSlice(gpa);
}

// ------------------------------------------------------------------ tests

const testing = std.testing;
const build_options = @import("build_options");

const minimal =
    \\.{
    \\    .name = "t",
    \\    .ticks = 10,
    \\    .fills = .{ .{ .rect = .{ .x = 0, .y = 250, .w = 256, .h = 6 }, .material = "bedrock" } },
    \\    .assertions = .{ .{ .at = .{ .x = 0, .y = 255, .material = "bedrock" } } },
    \\}
;

fn expectParseError(text: []const u8, needle: []const u8) !void {
    var diag: Diagnostics = .init(testing.allocator);
    defer diag.deinit();
    var s = parse(testing.allocator, "s/t.zon", text, &diag) catch |err| {
        try testing.expectEqual(error.InvalidScenario, err);
        if (!diag.contains(needle)) {
            std.debug.print("expected \"{s}\" in:\n{f}\n", .{ needle, diag });
            return error.TestUnexpectedResult;
        }
        return;
    };
    s.deinit();
    return error.TestExpectedError;
}

test "minimal scenario parses with defaults" {
    var diag: Diagnostics = .init(testing.allocator);
    defer diag.deinit();
    var s = try parse(testing.allocator, "s/t.zon", minimal, &diag);
    defer s.deinit();
    try testing.expectEqual(default_size, s.def.size);
    try testing.expectEqual(@as(u32, 10), s.def.ticks);
    try testing.expectEqual(@as(u32, 10), s.assertionTick(s.def.assertions[0]));
    try testing.expectEqual(Assertion.Kind.at, s.def.assertions[0].kind());
    try testing.expectEqual(Shape{ .rect = .{ .x = 0, .y = 250, .w = 256, .h = 6 } }, s.def.fills[0].region().shape());
}

test "every shape, command and assertion kind parses" {
    const text =
        \\.{
        \\    .name = "t",
        \\    .size = .{ .w = 128, .h = 64 },
        \\    .seed = 7,
        \\    .ticks = 100,
        \\    .fills = .{
        \\        .{ .rect = .{ .x = 0, .y = 60, .w = 128, .h = 4 }, .material = "bedrock" },
        \\        .{ .circle = .{ .x = 20, .y = 20, .r = 5 }, .material = "water", .temperature = 50 },
        \\        .{ .line = .{ .x0 = 0, .y0 = 0, .x1 = 127, .y1 = 0, .width = 3 }, .material = "wood", .state = 1 },
        \\    },
        \\    .commands = .{
        \\        .{ .tick = 0, .every = 2, .until = 20, .fill = .{ .rect = .{ .x = 60, .y = 1, .w = 4, .h = 1 }, .material = "sand", .only = "air" } },
        \\        .{ .tick = 30, .remove = .{ .rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 } } },
        \\        .{ .tick = 31, .ignite = .{ .circle = .{ .x = 5, .y = 5, .r = 2 } } },
        \\        .{ .tick = 32, .heat = .{ .line = .{ .x0 = 0, .y0 = 5, .x1 = 9, .y1 = 5 }, .temperature = 900 } },
        \\        .{ .tick = 33, .explode = .{ .x = 64, .y = 32, .radius = 6, .strength = 0.5 } },
        \\    },
        \\    .assertions = .{
        \\        .{ .tick = 50, .count = .{ .material = "sand", .rect = .{ .x = 0, .y = 0, .w = 128, .h = 64 }, .min = 1, .max = 44 } },
        \\        .{ .at = .{ .x = 0, .y = 63, .material = "bedrock" } },
        \\        .{ .none = .{ .material = "wood" }, .label = "dam is gone" },
        \\        .{ .particles = .{ .max = 0 } },
        \\        .{ .tick = 40, .pressure = .{ .x = 64, .y = 32, .min = 1.01 } },
        \\        .{ .deterministic = .{} },
        \\    },
        \\}
    ;
    var diag: Diagnostics = .init(testing.allocator);
    defer diag.deinit();
    var s = parse(testing.allocator, "s/t.zon", text, &diag) catch |err| {
        std.debug.print("{f}\n", .{diag});
        return err;
    };
    defer s.deinit();
    try testing.expectEqual(@as(usize, 3), s.def.fills.len);
    try testing.expectEqual(@as(?i32, 1), s.def.fills[2].state);
    const kinds = [_]Command.Action{ .fill, .remove, .ignite, .heat, .explode };
    for (s.def.commands, kinds) |c, k| try testing.expectEqual(k, c.action());
    const akinds = [_]Assertion.Kind{ .count, .at, .none, .particles, .pressure, .deterministic };
    for (s.def.assertions, akinds) |a, k| try testing.expectEqual(k, a.kind());
    try testing.expectEqual(@as(u32, 2), s.def.assertions[5].deterministic.?.runs);
    try testing.expectEqual(@as(f32, 0.5), s.def.commands[4].explode.?.strength);

    const pour = s.def.commands[0];
    try testing.expect(pour.firesAt(0) and !pour.firesAt(1) and pour.firesAt(2) and pour.firesAt(20) and !pour.firesAt(22));
    try testing.expect(s.def.commands[1].firesAt(30) and !s.def.commands[1].firesAt(31));
}

test "shape bounds" {
    try testing.expectEqual(Rect{ .x = 5, .y = 5, .w = 11, .h = 11 }, (Shape{ .circle = .{ .x = 10, .y = 10, .r = 5 } }).bounds());
    try testing.expectEqual(Rect{ .x = -1, .y = 3, .w = 13, .h = 3 }, (Shape{ .line = .{ .x0 = 0, .y0 = 4, .x1 = 10, .y1 = 4, .width = 3 } }).bounds());
}

test "structural errors name the file and field" {
    try expectParseError(".{ .name = \"t\", .ticks = 10 }", "missing required field assertions");
    try expectParseError(".{ .name = \"t\", .ticks = 10, .assertions = .{} }", "s/t.zon: .assertions: a scenario needs at least one assertion");
    try expectParseError(".{ .name = \"x\", .ticks = 10, .assertions = .{ .{ .particles = .{} } } }", "s/t.zon: .name: \"x\" does not match");
    try expectParseError(".{ .name = \"t\", .ticks = 10, .fills = .{ .{ .material = \"sand\" } }, .assertions = .{ .{ .particles = .{} } } }", "s/t.zon: .fills[0]: needs exactly one of .rect, .circle, .line (has 0)");
    try expectParseError(".{ .name = \"t\", .ticks = 10, .fills = .{ .{ .rect = .{ .x = 300, .y = 0, .w = 5, .h = 5 }, .material = \"sand\" } }, .assertions = .{ .{ .particles = .{} } } }", "s/t.zon: .fills[0]: shape lies entirely outside the 256x256 world");
    try expectParseError(".{ .name = \"t\", .ticks = 10, .commands = .{ .{ .tick = 11, .ignite = .{ .rect = .{ .x = 0, .y = 0, .w = 1, .h = 1 } } } }, .assertions = .{ .{ .particles = .{} } } }", "s/t.zon: .commands[0].tick: 11 is after the last tick 10");
    try expectParseError(".{ .name = \"t\", .ticks = 10, .commands = .{ .{ .tick = 1 } }, .assertions = .{ .{ .particles = .{} } } }", "s/t.zon: .commands[0]: needs exactly one of");
    try expectParseError(".{ .name = \"t\", .ticks = 10, .assertions = .{ .{ .count = .{ .material = \"sand\", .min = 5, .max = 2 } } } }", "s/t.zon: .assertions[0].count: .min 5 is above .max 2");
    try expectParseError(".{ .name = \"t\", .ticks = 10, .assertions = .{ .{ .none = .{ .material = \"sand\", .rect = .{ .x = 250, .y = 0, .w = 10, .h = 1 } } } } }", "s/t.zon: .assertions[0].none.rect: rect 250,0 10x1 is not inside");
    try expectParseError(".{ .name = \"t\", .ticks = 10, .assertions = .{ .{ .tick = 11, .particles = .{} } } }", "s/t.zon: .assertions[0].tick: 11 is outside 1–10");
    try expectParseError(".{ .name = \"t\", .ticks = 10, .assertions = .{ .{ .particles = .{}, .none = .{ .material = \"sand\" } } } }", "has 2");
    try expectParseError(".{ .name = \"t\", .ticks = 10, .size = .{ .w = 4096, .h = 4 }, .assertions = .{ .{ .particles = .{} } } }", "s/t.zon: .size: 4096x4 out of range");
    try expectParseError(".{ .name = \"t\", .tick = 10, .assertions = .{ .{ .particles = .{} } } }", "s/t.zon:1:");
}

test "material names are checked against the loaded set" {
    var mdiag: Diagnostics = .init(testing.allocator);
    defer mdiag.deinit();
    var set = try materials.loadDir(testing.io, testing.allocator, build_options.materials_dir, &mdiag);
    defer set.deinit();
    var diag: Diagnostics = .init(testing.allocator);
    defer diag.deinit();
    var s = try parse(testing.allocator, "s/t.zon",
        \\.{ .name = "t", .ticks = 10,
        \\   .fills = .{ .{ .rect = .{ .x = 0, .y = 0, .w = 4, .h = 4 }, .material = "sandd" } },
        \\   .assertions = .{ .{ .none = .{ .material = "unobtainium" } } } }
    , &diag);
    defer s.deinit();
    try testing.expect(!try checkMaterials(&s, &set, &diag));
    try testing.expect(diag.contains("s/t.zon: .fills[0].material: unknown material \"sandd\""));
    try testing.expect(diag.contains("s/t.zon: .assertions[0].none.material: unknown material \"unobtainium\""));
}

test "all shipped scenarios parse and reference real materials" {
    var mdiag: Diagnostics = .init(testing.allocator);
    defer mdiag.deinit();
    var set = try materials.loadDir(testing.io, testing.allocator, build_options.materials_dir, &mdiag);
    defer set.deinit();
    var diag: Diagnostics = .init(testing.allocator);
    defer diag.deinit();
    const list = try loadDir(testing.io, testing.allocator, build_options.scenarios_dir, &diag);
    defer {
        for (list) |*s| s.deinit();
        testing.allocator.free(list);
    }
    for (list) |*s| _ = try checkMaterials(s, &set, &diag);
    if (diag.messages.items.len > 0) {
        std.debug.print("{f}\n", .{diag});
        return error.TestUnexpectedResult;
    }
    const expected = [_][]const u8{
        "u_tube",          "dam_break", "sealed_steam_room",  "corridor_blast", "pool_sleep",
        "determinism",     "sand_pile", "water_spreads_flat", "lava_water",     "wood_burns",
        "sand_lava_glass",
    };
    outer: for (expected) |name| {
        for (list) |s| if (std.mem.eql(u8, s.def.name, name)) continue :outer;
        std.debug.print("missing scenario {s}\n", .{name});
        return error.TestUnexpectedResult;
    }
}
