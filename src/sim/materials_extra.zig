//! Materials the rendering milestone needs before the data layer's material
//! set drives the simulation: lava, glass, flame, steam, wood, molten glass.
//! Values are transcribed from `materials/*.zon` (docs/03-materials.md);
//! transitions to materials the builtin table lacks are left out. Appended
//! after `materials_builtin` (ids 5..10), so every builtin id is unchanged.
//! Delete this file when the sim loads `materials/` (decisions/100).
const materials = @import("materials.zig");
const builtin = @import("materials_builtin.zig");

pub const lava: u8 = 5;
pub const glass: u8 = 6;
pub const flame: u8 = 7;
pub const steam: u8 = 8;
pub const wood: u8 = 9;
pub const molten_glass: u8 = 10;

pub const descs = [_]materials.MaterialDesc{
    .{
        .name = "lava",
        .phase = .liquid,
        .density = 270,
        .dispersion = 1,
        .temperature = 1100,
        .conductivity = 60,
        .emits_heat = 40,
        .freeze = .{ .at = 700, .to = builtin.stone },
        .impact = .splash,
        .blast_threshold = 40,
        .blast_response = .fly,
        .drag = 60,
        .emissive = 200,
        .glow = .{ .from = 700, .to = 1300 },
        .ramp = &.{ 0x8f1d0a, 0xc23410, 0xe8521a, 0xff7a24, 0xffa63a, 0xffd25a },
    },
    .{
        .name = "glass",
        .phase = .static,
        .density = 250,
        .health = 40,
        .conductivity = 30,
        .impact = .chip,
        .blast_threshold = 30,
        .blast_response = .@"break",
        .drag = 40,
        .translucent = true,
        .ramp = &.{ 0xa8d8e8, 0xbce4f0, 0x94ccdf, 0xd2eef6 },
    },
    .{
        .name = "flame",
        .phase = .gas,
        .density = 3,
        .dispersion = 2,
        .lifetime = 20,
        .decays_to = builtin.air,
        .temperature = 900,
        .conductivity = 80,
        .emits_heat = 60,
        .drag = 255,
        .emissive = 255,
        .translucent = true,
        .ramp = &.{ 0xffd23f, 0xffa52a, 0xff7a1a, 0xff4f12, 0xfff08a },
    },
    .{
        .name = "steam",
        .phase = .gas,
        .density = 5,
        .dispersion = 6,
        .lifetime = 600,
        .decays_to = builtin.air,
        .temperature = 110,
        .conductivity = 20,
        .drag = 255,
        .translucent = true,
        .ramp = &.{ 0xc8d0d8, 0xd8dee4, 0xb8c2cc, 0xe6eaee },
    },
    .{
        .name = "wood",
        .phase = .static,
        .density = 60,
        .health = 120,
        .conductivity = 10,
        .impact = .chip,
        .blast_threshold = 80,
        .blast_response = .@"break",
        .drag = 80,
        .ramp = &.{ 0x6b4423, 0x7d522c, 0x5a3a1e, 0x8f6236, 0x4e3219 },
    },
    .{
        .name = "molten_glass",
        .phase = .liquid,
        .density = 240,
        .dispersion = 1,
        .temperature = 1200,
        .conductivity = 50,
        .freeze = .{ .at = 800, .to = glass },
        .impact = .splash,
        .blast_threshold = 40,
        .blast_response = .fly,
        .drag = 60,
        .emissive = 160,
        .glow = .{ .from = 800, .to = 1200 },
        .ramp = &.{ 0xff9a3a, 0xffb855, 0xffd27a, 0xe8782a },
    },
};

/// Append the extra materials to a builtin table (ids `lava`..`molten_glass`).
pub fn extend(t: *materials.Table) void {
    std.debug.assert(t.len == builtin.descs.len);
    for (descs) |d| _ = t.add(d) catch unreachable;
}

/// The builtin table plus the extras.
pub fn table() materials.Table {
    var t = builtin.table();
    extend(&t);
    return t;
}

const std = @import("std");

test "extra ids follow the builtin table" {
    const t = table();
    try std.testing.expectEqual(lava, t.byName("lava").?);
    try std.testing.expectEqual(glass, t.byName("glass").?);
    try std.testing.expectEqual(flame, t.byName("flame").?);
    try std.testing.expectEqual(steam, t.byName("steam").?);
    try std.testing.expectEqual(wood, t.byName("wood").?);
    try std.testing.expectEqual(molten_glass, t.byName("molten_glass").?);
    try std.testing.expectEqual(builtin.smoke, t.byName("smoke").?);
}
