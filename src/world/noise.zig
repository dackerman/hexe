//! Hand-written 2D noise for procgen: simplex gradient noise (Gustavson's
//! formulation with hashed gradients), fractal sums, and cheap lattice value
//! noise. Deterministic: integer hashing plus f32 add/multiply/floor only.

const std = @import("std");
const hash = @import("hash.zig");

const F2: f32 = 0.36602540378443865; // (sqrt(3) - 1) / 2
const G2: f32 = 0.21132486540518713; // (3 - sqrt(3)) / 6

// 8 gradient directions, unit length.
const gx = [8]f32{ 1, -1, 0, 0, 0.70710678, -0.70710678, 0.70710678, -0.70710678 };
const gy = [8]f32{ 0, 0, 1, -1, 0.70710678, 0.70710678, -0.70710678, -0.70710678 };

inline fn corner(i: i32, j: i32, x: f32, y: f32, seed: u32) f32 {
    const t = 0.5 - x * x - y * y;
    if (t <= 0) return 0;
    const g = hash.hash2(i, j, seed) & 7;
    const t2 = t * t;
    return t2 * t2 * (gx[g] * x + gy[g] * y);
}

/// Simplex noise in roughly [−1, 1].
pub fn simplex(x: f32, y: f32, seed: u32) f32 {
    const s = (x + y) * F2;
    const fi = @floor(x + s);
    const fj = @floor(y + s);
    const i: i32 = @intFromFloat(fi);
    const j: i32 = @intFromFloat(fj);
    const t = (fi + fj) * G2;
    const x0 = x - (fi - t);
    const y0 = y - (fj - t);
    const step_i: i32 = if (x0 > y0) 1 else 0;
    const step_j: i32 = 1 - step_i;
    const x1 = x0 - @as(f32, @floatFromInt(step_i)) + G2;
    const y1 = y0 - @as(f32, @floatFromInt(step_j)) + G2;
    const x2 = x0 - 1 + 2 * G2;
    const y2 = y0 - 1 + 2 * G2;
    const n = corner(i, j, x0, y0, seed) +
        corner(i + step_i, j + step_j, x1, y1, seed) +
        corner(i + 1, j + 1, x2, y2, seed);
    return 99.0 * n;
}

/// Fractal sum of `octaves` simplex layers, normalized to roughly [−1, 1].
pub fn fbm(x: f32, y: f32, seed: u32, octaves: u32) f32 {
    var sum: f32 = 0;
    var amp: f32 = 1;
    var norm: f32 = 0;
    var fx = x;
    var fy = y;
    var o: u32 = 0;
    while (o < octaves) : (o += 1) {
        sum += amp * simplex(fx, fy, seed +% o *% 0x9e37);
        norm += amp;
        amp *= 0.5;
        // Rotate slightly between octaves to hide lattice alignment.
        const rx = fx * 1.6 - fy * 1.2;
        const ry = fx * 1.2 + fy * 1.6;
        fx = rx + 17.3;
        fy = ry - 9.1;
    }
    return sum / norm;
}

inline fn unit(h: u32) f32 {
    return @as(f32, @floatFromInt(h >> 8)) * (1.0 / 16777216.0);
}

/// Value noise on an integer lattice of spacing `period`, bilinear with a
/// smoothstep, in [0, 1). Cheap; used for small-scale roughness.
pub fn value(x: i32, y: i32, period_log2: u5, seed: u32) f32 {
    const i = x >> period_log2;
    const j = y >> period_log2;
    const mask: i32 = (@as(i32, 1) << period_log2) - 1;
    const inv: f32 = 1.0 / @as(f32, @floatFromInt(@as(i32, 1) << period_log2));
    var u = @as(f32, @floatFromInt(x & mask)) * inv;
    var v = @as(f32, @floatFromInt(y & mask)) * inv;
    u = u * u * (3 - 2 * u);
    v = v * v * (3 - 2 * v);
    const a = unit(hash.hash2(i, j, seed));
    const b = unit(hash.hash2(i + 1, j, seed));
    const c = unit(hash.hash2(i, j + 1, seed));
    const d = unit(hash.hash2(i + 1, j + 1, seed));
    return (a + (b - a) * u) + ((c + (d - c) * u) - (a + (b - a) * u)) * v;
}

/// Uniform [0, 1) from a hash of (x, y, seed).
pub inline fn rand01(x: i32, y: i32, seed: u32) f32 {
    return unit(hash.hash2(x, y, seed));
}

test "simplex is deterministic, bounded and not constant" {
    var lo: f32 = 10;
    var hi: f32 = -10;
    var y: f32 = -50;
    while (y < 50) : (y += 0.37) {
        var x: f32 = -50;
        while (x < 50) : (x += 0.41) {
            const n = simplex(x, y, 7);
            try std.testing.expectEqual(n, simplex(x, y, 7));
            lo = @min(lo, n);
            hi = @max(hi, n);
        }
    }
    try std.testing.expect(lo < -0.6 and lo >= -1.2);
    try std.testing.expect(hi > 0.6 and hi <= 1.2);
    const f = fbm(3.3, -4.4, 1, 4);
    try std.testing.expect(f >= -1.2 and f <= 1.2);
    const v = value(-13, 77, 3, 5);
    try std.testing.expect(v >= 0 and v < 1);
}
