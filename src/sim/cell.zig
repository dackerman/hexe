//! Cell format, world geometry and hashed randomness: the CPU mirror of
//! shaders/common.glsl. Field layout from docs/01-architecture.md:
//!
//!   bits  0-7  material      bits 16-23 state      bits 28-31 variant
//!   bits  8-15 temperature   bits 24-27 flags (burning, moved, particle, body)
//!
//! Constants are checked against common.glsl by the "common.glsl mirror" test
//! in src/gpu/constants.zig; the accessors and hash are checked against the
//! GPU by `--verify-determinism` (shaders/test/cell_accessors.comp) and by
//! the bit-exact CPU reference.
const std = @import("std");

pub const world_size = 2048;
pub const world_mask = world_size - 1;
pub const tile_shift = 5;
pub const tile_size = 1 << tile_shift;
pub const tiles_per_side = world_size / tile_size;
pub const tile_count = tiles_per_side * tiles_per_side;
pub const substeps = 8;
pub const tile_active_offset = tile_count;
pub const tile_mark_bytes = tile_count * 2;
/// Ticks a tile stays active after its last change (see common.glsl).
pub const tile_wake_ticks = 8;

pub const material_shift = 0;
pub const material_bits = 8;
pub const temp_shift = 8;
pub const temp_bits = 8;
pub const state_shift = 16;
pub const state_bits = 8;
pub const flag_burning: u32 = 1 << 24;
pub const flag_moved: u32 = 1 << 25;
pub const flag_particle: u32 = 1 << 26;
pub const flag_body: u32 = 1 << 27;
pub const flags_mask: u32 = 0x0f00_0000;
pub const variant_shift = 28;
pub const variant_bits = 4;

pub const salt_spawn_variant: u32 = 0x51a7;

pub const Cell = u32;

pub inline fn material(c: Cell) u32 {
    return (c >> material_shift) & 0xff;
}
pub inline fn temperature(c: Cell) u32 {
    return (c >> temp_shift) & 0xff;
}
pub inline fn state(c: Cell) u32 {
    return (c >> state_shift) & 0xff;
}
pub inline fn flags(c: Cell) u32 {
    return c & flags_mask;
}
pub inline fn variant(c: Cell) u32 {
    return (c >> variant_shift) & 0xf;
}
pub inline fn has(c: Cell, flag: u32) bool {
    return c & flag != 0;
}

pub inline fn withMaterial(c: Cell, m: u32) Cell {
    return (c & ~@as(u32, 0xff)) | (m & 0xff);
}
pub inline fn withTemperature(c: Cell, t: u32) Cell {
    return (c & ~@as(u32, 0xff << temp_shift)) | ((t & 0xff) << temp_shift);
}
pub inline fn withState(c: Cell, s: u32) Cell {
    return (c & ~@as(u32, 0xff << state_shift)) | ((s & 0xff) << state_shift);
}
pub inline fn withVariant(c: Cell, v: u32) Cell {
    return (c & ~@as(u32, 0xf << variant_shift)) | ((v & 0xf) << variant_shift);
}
pub inline fn withFlag(c: Cell, flag: u32, on: bool) Cell {
    return if (on) c | flag else c & ~flag;
}

/// `flag_bits` is already positioned (flag_* values); fields are masked.
pub inline fn make(m: u32, t: u32, s: u32, flag_bits: u32, v: u32) Cell {
    return (m & 0xff) | ((t & 0xff) << temp_shift) | ((s & 0xff) << state_shift) |
        (flag_bits & flags_mask) | ((v & 0xf) << variant_shift);
}

pub inline fn tempToCelsius(t: u32) i32 {
    return @as(i32, @intCast(t)) * 8 - 40;
}
pub inline fn celsiusToTemp(c: i32) u32 {
    return @intCast(std.math.clamp((c + 40) >> 3, 0, 255));
}

// ---- hash (lowbias32, Chris Wellons) ----

pub inline fn hashU32(v: u32) u32 {
    var x = v;
    x ^= x >> 16;
    x *%= 0x7feb352d;
    x ^= x >> 15;
    x *%= 0x846ca68b;
    x ^= x >> 16;
    return x;
}

pub inline fn hash(x: u32, y: u32, tick: u32, substep: u32) u32 {
    const xy = ((y & 0xffff) << 16) | (x & 0xffff);
    return hashU32(xy ^ hashU32(tick ^ hashU32(substep)));
}

pub inline fn hashSalt(x: u32, y: u32, tick: u32, salt: u32) u32 {
    return hash(x, y, tick, salt ^ 0x9e3779b9);
}

/// Chance test shared by every probabilistic rule: 255 means always.
pub inline fn chance8(rnd8: u32, chance: u32) bool {
    return chance >= 255 or rnd8 < chance;
}

// ---- world / tile geometry ----

pub inline fn wrap(v: i32) u32 {
    return @as(u32, @bitCast(v)) & world_mask;
}

pub inline fn index(x: u32, y: u32) usize {
    return @as(usize, y & world_mask) * world_size + (x & world_mask);
}

pub inline fn tileIndex(tx: u32, ty: u32) usize {
    return @as(usize, ty & (tiles_per_side - 1)) * tiles_per_side + (tx & (tiles_per_side - 1));
}

/// Expected GPU output of shaders/test/cell_accessors.comp for sample `i`.
pub const accessor_test_stride = 12;
pub fn accessorTestExpected(c: Cell, i: u32) [accessor_test_stride]u32 {
    return .{
        material(c),
        temperature(c),
        state(c),
        flags(c),
        variant(c),
        make(material(c), temperature(c), state(c), flags(c), variant(c)),
        hash(c & world_mask, (c >> 11) & world_mask, c, i & 7),
        hashU32(c),
        @bitCast(tempToCelsius(temperature(c))),
        celsiusToTemp(@as(i32, @intCast(c % 2400)) - 100),
        withFlag(withState(c, i & 0xff), flag_moved, i & 1 != 0),
        hashSalt(i, c & 0xffff, c >> 7, c >> 3),
    };
}

/// Sample words for the accessor test: edge patterns plus hashed values.
pub fn accessorTestSamples(out: []u32) void {
    const fixed = [_]u32{ 0, 0xffff_ffff, 0x0000_00ff, 0x0000_ff00, 0x00ff_0000, 0x0f00_0000, 0xf000_0000, 0x1234_5678, 0x8000_0001, 0x0200_0003 };
    for (out, 0..) |*o, i| {
        o.* = if (i < fixed.len) fixed[i] else hashU32(@as(u32, @truncate(i)) *% 2654435761);
    }
}

test "cell pack and unpack" {
    const samples = [_]struct { m: u32, t: u32, s: u32, f: u32, v: u32 }{
        .{ .m = 0, .t = 0, .s = 0, .f = 0, .v = 0 },
        .{ .m = 255, .t = 255, .s = 255, .f = flags_mask, .v = 15 },
        .{ .m = 2, .t = 7, .s = 100, .f = flag_moved, .v = 9 },
        .{ .m = 17, .t = 130, .s = 1, .f = flag_burning | flag_body, .v = 3 },
    };
    for (samples) |s| {
        const c = make(s.m, s.t, s.s, s.f, s.v);
        try std.testing.expectEqual(s.m, material(c));
        try std.testing.expectEqual(s.t, temperature(c));
        try std.testing.expectEqual(s.s, state(c));
        try std.testing.expectEqual(s.f, flags(c));
        try std.testing.expectEqual(s.v, variant(c));
        try std.testing.expectEqual(c, withMaterial(withTemperature(withState(withVariant(c, s.v), s.s), s.t), s.m));
    }
    // Field writers do not disturb neighbors.
    const c = make(1, 2, 3, flag_particle, 4);
    try std.testing.expectEqual(make(9, 2, 3, flag_particle, 4), withMaterial(c, 9));
    try std.testing.expectEqual(make(1, 2, 3, flag_particle | flag_moved, 4), withFlag(c, flag_moved, true));
    try std.testing.expectEqual(make(1, 2, 3, 0, 4), withFlag(c, flag_particle, false));
    // Bit positions match the architecture table.
    try std.testing.expectEqual(@as(u32, 1 << 25), make(0, 0, 0, flag_moved, 0));
    try std.testing.expectEqual(@as(u32, 0xf0000000), make(0, 0, 0, 0, 15));
}

test "temperature encoding" {
    try std.testing.expectEqual(@as(i32, -40), tempToCelsius(0));
    try std.testing.expectEqual(@as(i32, 2000), tempToCelsius(255));
    try std.testing.expectEqual(@as(u32, 7), celsiusToTemp(20));
    try std.testing.expectEqual(@as(u32, 0), celsiusToTemp(-300));
    try std.testing.expectEqual(@as(u32, 255), celsiusToTemp(5000));
    for (0..256) |t| try std.testing.expectEqual(@as(u32, @intCast(t)), celsiusToTemp(tempToCelsius(@intCast(t))));
}

test "hash known values" {
    // Pinned so an accidental change to the hash (which would silently change
    // every simulation result) fails loudly.
    try std.testing.expectEqual(@as(u32, 0), hashU32(0));
    try std.testing.expectEqual(@as(u32, 0x688990c0), hashU32(1));
    try std.testing.expect(hash(1, 0, 0, 0) != hash(0, 1, 0, 0));
    try std.testing.expect(hash(0, 0, 1, 0) != hash(0, 0, 0, 1));
    try std.testing.expectEqual(@as(u32, 0xb96d7543), hash(10, 20, 30, 3));
}
