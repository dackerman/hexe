//! Cell packing for the world layer.
//!
//! Layout (docs/01-architecture.md, "Pixel grid"):
//!   bits  0..7   material id
//!   bits  8..15  temperature byte, °C = 8·t − 40
//!   bits 16..23  state (material-defined: health, lifetime, fill)
//!   bits 24..27  flags (burning, moved, particle-backed, body-owned)
//!   bits 28..31  variant (stable shade index)
//!
//! This is a world-local copy; the integrator will dedupe it against
//! `src/sim/cell.zig` once that exists. Keep the two bit-identical.

const std = @import("std");

pub const Cell = packed struct(u32) {
    material: u8 = 0,
    temperature: u8 = ambient_temperature,
    state: u8 = 0,
    flags: u4 = 0,
    variant: u4 = 0,

    pub inline fn pack(c: Cell) u32 {
        return @bitCast(c);
    }

    pub inline fn unpack(raw: u32) Cell {
        return @bitCast(raw);
    }
};

pub const flag_burning: u4 = 1 << 0;
pub const flag_moved: u4 = 1 << 1;
pub const flag_particle: u4 = 1 << 2;
pub const flag_body: u4 = 1 << 3;

/// Temperature byte for ambient (20 °C would be t = 7.5). We round up:
/// t = 8 decodes to 24 °C. See docs/decisions/01-world-cell-temperature.md.
pub const ambient_temperature: u8 = 8;

pub inline fn material(raw: u32) u8 {
    return @truncate(raw);
}

pub inline fn temperature(raw: u32) u8 {
    return @truncate(raw >> 8);
}

pub inline fn state(raw: u32) u8 {
    return @truncate(raw >> 16);
}

pub inline fn flags(raw: u32) u4 {
    return @truncate(raw >> 24);
}

pub inline fn variant(raw: u32) u4 {
    return @truncate(raw >> 28);
}

pub inline fn pack(mat: u8, temp: u8, st: u8, fl: u4, vari: u4) u32 {
    return @as(u32, mat) | (@as(u32, temp) << 8) | (@as(u32, st) << 16) |
        (@as(u32, fl) << 24) | (@as(u32, vari) << 28);
}

pub inline fn withVariant(raw: u32, vari: u4) u32 {
    return (raw & 0x0fff_ffff) | (@as(u32, vari) << 28);
}

/// Temperature byte → °C.
pub inline fn byteToCelsius(t: u8) i32 {
    return 8 * @as(i32, t) - 40;
}

/// °C → nearest temperature byte, clamped to the representable range.
pub fn celsiusToByte(c: i32) u8 {
    const t = @divFloor(c + 40 + 4, 8);
    return @intCast(std.math.clamp(t, 0, 255));
}

test "cell pack and unpack agree with the bit layout" {
    const raw = pack(0xab, 0xcd, 0xef, 0x9, 0x6);
    try std.testing.expectEqual(@as(u32, 0x69ef_cdab), raw);
    const c = Cell.unpack(raw);
    try std.testing.expectEqual(@as(u8, 0xab), c.material);
    try std.testing.expectEqual(@as(u8, 0xcd), c.temperature);
    try std.testing.expectEqual(@as(u8, 0xef), c.state);
    try std.testing.expectEqual(@as(u4, 0x9), c.flags);
    try std.testing.expectEqual(@as(u4, 0x6), c.variant);
    try std.testing.expectEqual(raw, c.pack());
    try std.testing.expectEqual(@as(u8, 0xab), material(raw));
    try std.testing.expectEqual(@as(u8, 0xcd), temperature(raw));
    try std.testing.expectEqual(@as(u8, 0xef), state(raw));
    try std.testing.expectEqual(@as(u4, 0x9), flags(raw));
    try std.testing.expectEqual(@as(u4, 0x6), variant(raw));
    try std.testing.expectEqual(@as(u4, 0x3), variant(withVariant(raw, 3)));
    try std.testing.expectEqual(@as(u8, 0xab), material(withVariant(raw, 3)));
}

test "temperature byte conversion" {
    try std.testing.expectEqual(@as(i32, -40), byteToCelsius(0));
    try std.testing.expectEqual(@as(i32, 2000), byteToCelsius(255));
    try std.testing.expectEqual(@as(i32, 24), byteToCelsius(ambient_temperature));
    try std.testing.expectEqual(@as(u8, 8), celsiusToByte(20)); // 7.5 rounds up
    try std.testing.expectEqual(@as(u8, 143), celsiusToByte(1100)); // lava
    try std.testing.expectEqual(@as(u8, 0), celsiusToByte(-500));
    try std.testing.expectEqual(@as(u8, 255), celsiusToByte(5000));
    var t: u16 = 0;
    while (t < 256) : (t += 1) {
        try std.testing.expectEqual(@as(u8, @intCast(t)), celsiusToByte(byteToCelsius(@intCast(t))));
    }
}
