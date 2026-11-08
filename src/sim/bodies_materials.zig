//! Materials as the bodies layer sees them: Box2D density/friction/beam
//! behavior and breakup thresholds per grid material id, resolved by name
//! from whatever material table the engine runs (the hardcoded M1 table or
//! the ZON loader's). See docs/decisions/98-bodies-gpu-materials.md.
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
    rubble: u8 = materials.none,
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

/// Ids of the materials the bodies layer refers to by role.
pub const Roles = struct {
    concrete: u8 = materials.none,
    steel: u8 = materials.none,
    wood: u8 = materials.none,
    stone: u8 = materials.none,
    rubble: u8 = materials.none,
    gravel: u8 = materials.none,
    bedrock: u8 = materials.none,
    water: u8 = materials.none,
};

/// kg per pixel from the grid density (1 px = 5 cm cube; grid density 100 is
/// water, 1000 kg/m^3 * 1.25e-4 m^3 = 0.125 kg).
pub fn kgPerPixel(grid_density: u16) f32 {
    return @as(f32, @floatFromInt(grid_density)) * 1.25e-3;
}

pub const Table = struct {
    info: [256]Info = @splat(.{}),
    roles: Roles = .{},

    pub fn build(table: *const materials.Table) Table {
        var t: Table = .{};
        for (0..table.len) |i| {
            const g = table.gpu[i];
            const name = table.names[i];
            var info: Info = .{};
            info.static = g.phase == @backingInt(materials.Phase.static);
            info.liquid = g.phase == @backingInt(materials.Phase.liquid);
            info.liquid_density = if (info.liquid) kgPerPixel(g.density) else 0;
            info.body = .{ .density = @max(kgPerPixel(g.density), 0.01), .friction = 0.7 };
            if (std.mem.eql(u8, name, "steel")) {
                info.body = bodies.Material.presets.steel;
                info.breakup = .{ .break_dv = 4000 };
            } else if (std.mem.eql(u8, name, "wood")) {
                info.body = bodies.Material.presets.wood;
                info.breakup = .{ .break_dv = 600 };
            } else if (std.mem.eql(u8, name, "concrete")) {
                info.body = bodies.Material.presets.concrete;
                info.breakup = .{ .break_dv = 300 };
            } else if (std.mem.eql(u8, name, "stone")) {
                info.body.beam = bodies.Material.presets.concrete.beam;
                info.breakup = .{ .break_dv = 300 };
            } else if (std.mem.eql(u8, name, "glass")) {
                info.breakup = .{ .break_dv = 120 };
            } else if (std.mem.eql(u8, name, "bedrock")) {
                info.breakup = .{ .anchor = true };
            }
            t.info[i] = info;
        }
        const r = &t.roles;
        r.concrete = table.byName("concrete") orelse materials.none;
        r.steel = table.byName("steel") orelse materials.none;
        r.wood = table.byName("wood") orelse materials.none;
        r.stone = table.byName("stone") orelse materials.none;
        r.rubble = table.byName("rubble") orelse materials.none;
        r.gravel = table.byName("gravel") orelse materials.none;
        r.bedrock = table.byName("bedrock") orelse materials.none;
        r.water = table.byName("water") orelse materials.none;
        // Rubble products (docs/03-materials.md: concrete -> rubble, stone -> gravel).
        if (r.concrete != materials.none) t.info[r.concrete].breakup.rubble = r.rubble;
        if (r.stone != materials.none) t.info[r.stone].breakup.rubble = if (r.gravel != materials.none) r.gravel else r.rubble;
        if (table.byName("glass")) |gl| t.info[gl].breakup.rubble = table.byName("sand") orelse materials.none;
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

/// Materials the bodies layer needs (concrete, steel, wood, rubble, gravel,
/// bedrock), appended to `table` when it lacks them, with the values of the
/// ZON files in materials/. A table loaded from materials/ has them all and
/// is left unchanged. Appending keeps existing ids, so scenes that do not use
/// them (the determinism scene) are unaffected.
pub fn ensureMaterials(table: *materials.Table) void {
    for (extra) |d| {
        if (table.byName(d.name) == null) _ = table.add(d) catch return;
    }
}

const extra = [_]materials.MaterialDesc{
    .{ .name = "concrete", .phase = .static, .density = 280, .health = 180, .conductivity = 30, .impact = .chip, .blast_threshold = 150, .blast_response = .@"break", .drag = 20, .ramp = &.{ 0x8a8a86, 0x9a9a95, 0x7c7c78, 0xa8a8a2, 0x6e6e6a } },
    .{ .name = "steel", .phase = .static, .density = 800, .health = 255, .conductivity = 220, .conductive = true, .impact = .dent, .drag = 5, .ramp = &.{ 0x6e7782, 0x828c98, 0x5c646e, 0x98a2ae, 0x4e555e } },
    .{ .name = "wood", .phase = .static, .density = 60, .health = 120, .conductivity = 10, .impact = .chip, .blast_threshold = 80, .blast_response = .@"break", .drag = 80, .ramp = &.{ 0x6b4423, 0x7d522c, 0x5a3a1e, 0x8f6236, 0x4e3219 } },
    .{ .name = "rubble", .phase = .powder, .density = 170, .slide = 100, .conductivity = 25, .impact = .spray, .blast_threshold = 40, .blast_response = .fly, .drag = 25, .ramp = &.{ 0x7a756e, 0x8c867e, 0x66615b, 0x9e978e, 0x58534e } },
    .{ .name = "gravel", .phase = .powder, .density = 180, .slide = 60, .conductivity = 35, .impact = .spray, .blast_threshold = 30, .blast_response = .fly, .drag = 20, .ramp = &.{ 0x6f6a64, 0x7d7770, 0x5f5a55, 0x8a847c, 0x544f4b } },
    .{ .name = "bedrock", .phase = .static, .density = 1000, .conductivity = 30, .impact = .ricochet, .ramp = &.{ 0x1c1b22, 0x26252e, 0x302e3a, 0x3a3846, 0x221f29 } },
};

test "ensureMaterials appends missing materials and keeps ids" {
    const builtin = @import("materials_builtin.zig");
    var t = builtin.table();
    const before = t.len;
    var missing: usize = 0;
    for (extra) |d| {
        if (t.byName(d.name) == null) missing += 1;
    }
    ensureMaterials(&t);
    try std.testing.expectEqual(builtin.smoke, t.byName("smoke").?);
    try std.testing.expect(t.len == before + missing);
    const len = t.len;
    ensureMaterials(&t);
    try std.testing.expectEqual(len, t.len);
    const bt = Table.build(&t);
    try std.testing.expectEqual(t.byName("rubble").?, bt.info[bt.roles.concrete].breakup.rubble);
    try std.testing.expect(bt.info[bt.roles.bedrock].breakup.anchor);
    try std.testing.expect(bt.info[bt.roles.water].liquid);
    try std.testing.expectApproxEqAbs(@as(f32, 0.125), bt.info[bt.roles.water].liquid_density, 1e-6);
}

test "shape factor" {
    try std.testing.expectEqual(@as(f32, 1), shapeFactor(40, 40));
    try std.testing.expectEqual(@as(f32, 0.35), shapeFactor(200, 16));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), shapeFactor(80, 20), 1e-6);
}
