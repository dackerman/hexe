//! Materials as the bodies layer sees them: Box2D density/friction/beam
//! behavior and breakup thresholds per grid material id, resolved by name
//! from the loaded material library (materials/*.zon). Body presets are
//! keyed by material name. See docs/decisions/98-bodies-gpu-materials.md and
//! 110-integrate-material-layout.md.
const std = @import("std");
const bodies = @import("bodies");
const materials = @import("materials.zig");

/// Breakup and rubble behavior of a body material.
pub const Breakup = struct {
    /// Speed change (impact impulse / body mass, px/s) above which a compact
    /// body of this material breaks. Long thin bodies break at a fraction of
    /// it (`shapeFactor`).
    break_dv: f32 = std.math.inf(f32),
    /// Grid material the broken pixels turn into (powder), or none.
    rubble: u8 = none,
    /// Anchors connectivity: a component containing it never falls.
    anchor: bool = false,
};

pub const Info = struct {
    body: bodies.Material = .{},
    breakup: Breakup = .{},
    /// Static phase: may be part of a body. Bodies made of other phases
    /// would be moved by the Margolus pass.
    static: bool = false,
    liquid: bool = false,
    /// Liquid density in kg per pixel (buoyancy).
    liquid_density: f32 = 0,
};

/// "No such material" in roles and rubble: no material has id 255 in the
/// shipped set (bodies use it only on the CPU side).
pub const none: u8 = 255;

/// Ids of the materials the bodies layer refers to by role.
pub const Roles = struct {
    concrete: u8 = none,
    steel: u8 = none,
    wood: u8 = none,
    stone: u8 = none,
    rubble: u8 = none,
    gravel: u8 = none,
    bedrock: u8 = none,
    water: u8 = none,
};

/// kg per pixel from the grid density (1 px = 5 cm cube; grid density 100 is
/// water, 1000 kg/m^3 * 1.25e-4 m^3 = 0.125 kg).
pub fn kgPerPixel(grid_density: u16) f32 {
    return @as(f32, @floatFromInt(grid_density)) * 1.25e-3;
}

pub const Table = struct {
    info: [256]Info = @splat(.{}),
    roles: Roles = .{},

    pub fn build(set: *const materials.MaterialSet, tables: *const materials.Tables) Table {
        var t: Table = .{};
        for (set.materials) |mat| {
            const i = mat.id;
            const g = tables.materials[i];
            const name = mat.def.name;
            var info: Info = .{};
            info.static = g.phase == @backingInt(materials.Phase.static);
            info.liquid = g.phase == @backingInt(materials.Phase.liquid);
            info.liquid_density = if (info.liquid) kgPerPixel(@intCast(g.density)) else 0;
            info.body = .{ .density = @max(kgPerPixel(@intCast(g.density)), 0.01), .friction = 0.7 };
            // Grid rubble from the material file (docs/03-materials.md:
            // concrete -> rubble, stone -> gravel); none when it is itself.
            if (g.rubble != i) info.breakup.rubble = @intCast(g.rubble);
            info.breakup.anchor = g.flags & materials.Flag.anchor != 0;
            for (presets) |p| {
                if (!std.mem.eql(u8, name, p.name)) continue;
                if (p.body) |b| info.body = b;
                if (p.beam) |b| info.body.beam = b;
                info.breakup.break_dv = p.break_dv;
                if (p.rubble) |r| info.breakup.rubble = set.idOf(r) orelse info.breakup.rubble;
            }
            t.info[i] = info;
        }
        const r = &t.roles;
        inline for (@typeInfo(Roles).@"struct".field_names) |f| {
            @field(r, f) = set.idOf(f) orelse none;
        }
        return t;
    }

    pub fn apply(self: *const Table, world: *bodies.BodyWorld) void {
        for (self.info, 0..) |info, i| world.setMaterial(@intCast(i), info.body);
    }
};

/// Long thin bodies break more easily: the threshold scales with the ratio
/// of the short to the long side, clamped to [0.35, 1] (a 40x40 crate keeps
/// the full threshold, a 160x16 slab a third of it).
pub fn shapeFactor(w: f32, h: f32) f32 {
    const short = @min(w, h);
    const long = @max(w, h);
    if (long <= 0) return 1;
    return std.math.clamp(2 * short / long, 0.35, 1);
}

/// Body behavior per material name. Materials not listed get a body from
/// their grid density and no breakup.
const Preset = struct {
    name: []const u8,
    body: ?bodies.Material = null,
    beam: ?@FieldType(bodies.Material, "beam") = null,
    break_dv: f32 = std.math.inf(f32),
    /// Overrides the material file's rubble for body breakup.
    rubble: ?[]const u8 = null,
};

const presets = [_]Preset{
    .{ .name = "steel", .body = bodies.Material.presets.steel, .break_dv = 4000 },
    .{ .name = "wood", .body = bodies.Material.presets.wood, .break_dv = 600 },
    .{ .name = "concrete", .body = bodies.Material.presets.concrete, .break_dv = 300 },
    .{ .name = "stone", .beam = bodies.Material.presets.concrete.beam, .break_dv = 300 },
    .{ .name = "glass", .break_dv = 120, .rubble = "sand" },
};

test "body table from the shipped materials" {
    const gpa = std.testing.allocator;
    var diag: materials.Diagnostics = .init(gpa);
    defer diag.deinit();
    var lib = try materials.Library.loadDir(std.testing.io, gpa, materials.default_dir, &diag);
    defer lib.deinit(gpa);
    const bt = Table.build(&lib.set, lib.tables);
    try std.testing.expectEqual(lib.id("rubble").?, bt.info[bt.roles.concrete].breakup.rubble);
    try std.testing.expectEqual(lib.id("gravel").?, bt.info[bt.roles.stone].breakup.rubble);
    try std.testing.expectEqual(lib.id("sand").?, bt.info[lib.id("glass").?].breakup.rubble);
    try std.testing.expect(bt.info[bt.roles.bedrock].breakup.anchor);
    try std.testing.expect(bt.info[bt.roles.water].liquid);
    try std.testing.expect(bt.info[bt.roles.steel].static);
    try std.testing.expectApproxEqAbs(@as(f32, 0.125), bt.info[bt.roles.water].liquid_density, 1e-6);
}

test "shape factor" {
    try std.testing.expectEqual(@as(f32, 1), shapeFactor(40, 40));
    try std.testing.expectEqual(@as(f32, 0.35), shapeFactor(200, 16));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), shapeFactor(80, 20), 1e-6);
}
