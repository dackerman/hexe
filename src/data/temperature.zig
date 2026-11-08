//! Temperature encoding shared by the cell format and the material tables.
//!
//! A cell stores temperature in one byte `t`; the represented value is
//! `°C = 8·t − 40`, so the byte covers −40 °C (t = 0) to 2000 °C (t = 255)
//! in 8 °C steps. See `docs/01-architecture.md`, cell image bits 8–15.

const std = @import("std");

/// Lowest representable temperature, °C (byte 0).
pub const min_celsius: i32 = -40;
/// Highest representable temperature, °C (byte 255).
pub const max_celsius: i32 = 2000;
/// °C per byte step.
pub const step_celsius: i32 = 8;

/// Exact value of a temperature byte in °C.
pub fn toCelsius(t: u8) i32 {
    return step_celsius * @as(i32, t) + min_celsius;
}

/// Nearest temperature byte for a value in °C, ties rounding up
/// (20 °C, exactly between bytes 7 and 8, becomes 8 = 24 °C).
/// Values outside −40…2000 clamp to the ends; callers that must reject
/// them check `inRange` first.
pub fn toByte(celsius: i32) u8 {
    const c = std.math.clamp(celsius, min_celsius, max_celsius);
    const t = @divFloor(c - min_celsius + @divExact(step_celsius, 2), step_celsius);
    return @intCast(@min(t, 255));
}

/// Whether a °C value is representable without clamping.
pub fn inRange(celsius: i32) bool {
    return celsius >= min_celsius and celsius <= max_celsius;
}

/// A rate in °C per tick converted to temperature-byte steps per tick,
/// rounded to nearest (ties up) and clamped to a byte. Used for
/// `emits_heat` and burn heat.
pub fn deltaToBytes(celsius_per_tick: i32) u8 {
    const c = @max(celsius_per_tick, 0);
    return @intCast(@min(@divFloor(c + @divExact(step_celsius, 2), step_celsius), 255));
}

test "byte to celsius endpoints" {
    try std.testing.expectEqual(@as(i32, -40), toCelsius(0));
    try std.testing.expectEqual(@as(i32, 2000), toCelsius(255));
    try std.testing.expectEqual(@as(i32, 0), toCelsius(5));
    try std.testing.expectEqual(@as(i32, 1096), toCelsius(142));
}

test "celsius to byte rounds to nearest and clamps" {
    try std.testing.expectEqual(@as(u8, 0), toByte(-40));
    try std.testing.expectEqual(@as(u8, 5), toByte(0));
    try std.testing.expectEqual(@as(u8, 8), toByte(20)); // tie rounds up
    try std.testing.expectEqual(@as(u8, 7), toByte(19));
    try std.testing.expectEqual(@as(u8, 18), toByte(100)); // 17.5 -> 18
    try std.testing.expectEqual(@as(u8, 255), toByte(2000));
    try std.testing.expectEqual(@as(u8, 0), toByte(-1000));
    try std.testing.expectEqual(@as(u8, 255), toByte(5000));
    try std.testing.expect(inRange(2000) and !inRange(2001) and !inRange(-41));
}

test "round trip is exact for every byte" {
    var t: u16 = 0;
    while (t <= 255) : (t += 1) {
        const b: u8 = @intCast(t);
        try std.testing.expectEqual(b, toByte(toCelsius(b)));
    }
}

test "round trip error is at most half a step" {
    var c: i32 = min_celsius;
    while (c <= max_celsius) : (c += 1) {
        const err = @abs(toCelsius(toByte(c)) - c);
        try std.testing.expect(err <= 4);
    }
}

test "heat delta conversion" {
    try std.testing.expectEqual(@as(u8, 0), deltaToBytes(0));
    try std.testing.expectEqual(@as(u8, 5), deltaToBytes(40));
    try std.testing.expectEqual(@as(u8, 8), deltaToBytes(60)); // 7.5 -> 8
    try std.testing.expectEqual(@as(u8, 255), deltaToBytes(100000));
    try std.testing.expectEqual(@as(u8, 0), deltaToBytes(-5));
}
