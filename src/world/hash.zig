//! Integer hashing shared by procgen and chunk compression.
//! Pure functions of their inputs, no floats, so they match a future GPU port.

const std = @import("std");

/// lowbias32 (Chris Wellons), a good 32-bit integer finalizer.
pub inline fn mix32(v: u32) u32 {
    var x = v;
    x ^= x >> 16;
    x *%= 0x7feb352d;
    x ^= x >> 15;
    x *%= 0x846ca68b;
    x ^= x >> 16;
    return x;
}

pub inline fn hash2(x: i32, y: i32, seed: u32) u32 {
    const ux: u32 = @bitCast(x);
    const uy: u32 = @bitCast(y);
    return mix32(ux *% 0x9e3779b1 +% mix32(uy +% seed *% 0x85ebca6b));
}

pub inline fn hash3(x: i32, y: i32, z: i32, seed: u32) u32 {
    const uz: u32 = @bitCast(z);
    return mix32(hash2(x, y, seed) ^ (uz *% 0xc2b2ae35));
}

/// Stable per-pixel shade of a freshly generated cell at world (x, y).
/// Chunk compression XORs stored variants with this, so unmoved pixels
/// compress to runs. Mixes a 1-pixel hash (fine grain) with a 2×4 hash
/// (clumps) so textures are not pure white noise.
pub inline fn baseVariant(x: i32, y: i32) u4 {
    const fine = hash2(x, y, 0x5eed_0001);
    const coarse = hash2(x >> 2, y >> 1, 0x5eed_0002);
    return @truncate((coarse & 0xc) | (fine & 0x3));
}

test "hash is deterministic and spreads" {
    try std.testing.expectEqual(hash2(3, -7, 42), hash2(3, -7, 42));
    try std.testing.expect(hash2(3, -7, 42) != hash2(-7, 3, 42));
    try std.testing.expect(hash2(3, -7, 42) != hash2(3, -7, 43));
    var counts: [16]u32 = @splat(0);
    var y: i32 = -64;
    while (y < 64) : (y += 1) {
        var x: i32 = -64;
        while (x < 64) : (x += 1) counts[baseVariant(x, y)] += 1;
    }
    for (counts) |c| try std.testing.expect(c > 16384 / 16 / 2);
}
