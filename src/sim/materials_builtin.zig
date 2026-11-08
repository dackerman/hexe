//! Hardcoded M1 material set (air, stone, sand, water, smoke) with values
//! from docs/03-materials.md. Replaced by the ZON loader in src/data/ (M3);
//! until then this is the table every scene and test uses. Transitions that
//! name materials which do not exist yet (lava, steam, ice) are left out.
const materials = @import("materials.zig");

pub const air: u8 = 0;
pub const stone: u8 = 1;
pub const sand: u8 = 2;
pub const water: u8 = 3;
pub const smoke: u8 = 4;
pub const wood: u8 = 5;

pub const descs = [_]materials.MaterialDesc{
    .{
        .name = "air",
        .phase = .gas,
        .density = 0,
        .conductivity = 4,
        .translucent = true,
        .ramp = &.{0x0d0f16},
    },
    .{
        .name = "stone",
        .phase = .static,
        .density = 300,
        .health = 200,
        .conductivity = 60,
        .impact = .chip,
        .blast_threshold = 200,
        .blast_response = .@"break",
        .ramp = &.{ 0x5b5a60, 0x504f55, 0x67666c, 0x48474d, 0x55545a, 0x605f66 },
    },
    .{
        .name = "sand",
        .phase = .powder,
        .density = 150,
        .slide = 200,
        .conductivity = 30,
        .impact = .spray,
        .blast_threshold = 20,
        .blast_response = .fly,
        .ramp = &.{ 0xd9c18b, 0xcfb47a, 0xe3cd99, 0xc6a96c, 0xd4bb82 },
    },
    .{
        .name = "water",
        .phase = .liquid,
        .solver = .flip, // FLIP solver when Config.liquid is on, cellular otherwise
        .density = 100,
        .dispersion = 5,
        .conductivity = 40,
        .conductive = true,
        .impact = .splash,
        .blast_threshold = 10,
        .blast_response = .fly,
        .drag = 200,
        .translucent = true,
        .ramp = &.{ 0x1a3a6b, 0x215091, 0x2a66b5, 0x3a7ad0 },
    },
    .{
        .name = "smoke",
        .phase = .gas,
        .density = 8,
        .dispersion = 3,
        .lifetime = 1200,
        .conductivity = 4,
        .drag = 255,
        .translucent = true,
        .ramp = &.{ 0x3b3b40, 0x47474c, 0x333338, 0x525257 },
    },
    .{
        // Static here (no reactions yet); values from materials/wood.zon.
        .name = "wood",
        .phase = .static,
        .density = 60,
        .health = 120,
        .ramp = &.{ 0x6b4423, 0x7d522c, 0x5a3a1e, 0x8f6236, 0x4e3219 },
    },
};

pub fn table() materials.Table {
    var t: materials.Table = .{};
    for (descs) |d| _ = t.add(d) catch unreachable;
    return t;
}

test "builtin ids match table order" {
    const std = @import("std");
    const t = table();
    try std.testing.expectEqual(air, t.byName("air").?);
    try std.testing.expectEqual(stone, t.byName("stone").?);
    try std.testing.expectEqual(sand, t.byName("sand").?);
    try std.testing.expectEqual(water, t.byName("water").?);
    try std.testing.expectEqual(smoke, t.byName("smoke").?);
    try std.testing.expectEqual(wood, t.byName("wood").?);
}
