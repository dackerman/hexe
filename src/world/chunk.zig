//! Chunks: 256 × 256 cells of packed u32 (see cell.zig), addressed by i32
//! chunk coordinates in an unbounded world. World cell coordinates are i32,
//! x to the right, y downward; y < 0 is sky.
//!
//! Also holds the chunk compression codec (RLE over u32 cells, variant bits
//! XORed with the procgen base variant so unmoved pixels form runs). Format
//! in docs/decisions/02-world-chunk-compression.md.

const std = @import("std");
const hash = @import("hash.zig");

pub const size_log2 = 8;
pub const size: u32 = 1 << size_log2; // 256
pub const cell_count: u32 = size * size; // 65536

pub const Cells = [cell_count]u32;

pub const Coord = struct {
    x: i32,
    y: i32,

    pub fn eql(a: Coord, b: Coord) bool {
        return a.x == b.x and a.y == b.y;
    }

    /// World cell coordinate of this chunk's top-left cell.
    pub fn originCell(c: Coord) [2]i32 {
        return .{ c.x * @as(i32, size), c.y * @as(i32, size) };
    }
};

/// Chunk containing world cell (x, y). Floor division, so −1 is in chunk −1.
pub inline fn coordOfCell(x: i32, y: i32) Coord {
    return .{ .x = x >> size_log2, .y = y >> size_log2 };
}

/// Cell offset within its chunk, 0..255.
pub inline fn localOfCell(x: i32, y: i32) [2]u32 {
    return .{ @as(u32, @bitCast(x)) & (size - 1), @as(u32, @bitCast(y)) & (size - 1) };
}

pub inline fn index(lx: u32, ly: u32) u32 {
    std.debug.assert(lx < size and ly < size);
    return ly * size + lx;
}

// ---------------------------------------------------------------------------
// Compression
// ---------------------------------------------------------------------------

pub const Format = enum(u8) {
    /// Sequence of (LEB128 run length − 1, u32 LE value) pairs.
    rle = 1,
    /// 65536 u32 LE values.
    raw = 2,
};

/// Worst case: every cell its own run, 3 varint bytes (65535 < 2^21) + 4.
pub const max_rle_len = 1 + cell_count * 7;
/// Upper bound on `compress` output (it falls back to raw when RLE is larger).
pub const max_compressed_len = 1 + cell_count * 4;
/// Scratch buffer size `compress` needs.
pub const compress_scratch_len = max_rle_len;

pub const DecodeError = error{CorruptChunk};

/// Material 0 is air, defined by the engine (docs/03-materials.md).
pub const air_material: u8 = 0;

inline fn baseVariantAt(c: Coord, i: u32) u32 {
    const o = c.originCell();
    const lx: i32 = @intCast(i & (size - 1));
    const ly: i32 = @intCast(i >> size_log2);
    return hash.baseVariant(o[0] + lx, o[1] + ly);
}

/// Encode-side transform: variant XOR base variant, and air's variant is
/// dropped (air has no visual, so dug-out air compresses no matter what
/// variant the GPU gave it). Decoding air yields the base variant.
inline fn encodeCell(c: Coord, i: u32, raw: u32) u32 {
    if (raw & 0xff == air_material) return raw & 0x0fff_ffff;
    return raw ^ (baseVariantAt(c, i) << 28);
}

inline fn decodeCell(c: Coord, i: u32, v: u32) u32 {
    return v ^ (baseVariantAt(c, i) << 28);
}

/// What a cell becomes after a compress/decompress round trip.
pub fn normalized(c: Coord, i: u32, raw: u32) u32 {
    return decodeCell(c, i, encodeCell(c, i, raw));
}

/// Compresses `cells` of chunk `c` into `scratch` (len ≥ compress_scratch_len)
/// and returns the used prefix. Never allocates.
pub fn compress(c: Coord, cells: *const Cells, scratch: []u8) []u8 {
    std.debug.assert(scratch.len >= compress_scratch_len);
    scratch[0] = @backingInt(Format.rle);
    var n: usize = 1;
    var i: u32 = 0;
    var next = encodeCell(c, 0, cells[0]);
    while (i < cell_count) {
        const v = next;
        var j = i + 1;
        while (j < cell_count) : (j += 1) {
            next = encodeCell(c, j, cells[j]);
            if (next != v) break;
        }
        var run: u32 = j - i - 1;
        while (true) {
            const b: u8 = @truncate(run & 0x7f);
            run >>= 7;
            if (run == 0) {
                scratch[n] = b;
                n += 1;
                break;
            }
            scratch[n] = b | 0x80;
            n += 1;
        }
        std.mem.writeInt(u32, scratch[n..][0..4], v, .little);
        n += 4;
        i = j;
    }
    if (n <= max_compressed_len) return scratch[0..n];
    // RLE lost; store raw (still variant-transformed, so the decoder is uniform).
    scratch[0] = @backingInt(Format.raw);
    for (cells, 0..) |raw, k| {
        std.mem.writeInt(u32, scratch[1 + k * 4 ..][0..4], encodeCell(c, @intCast(k), raw), .little);
    }
    return scratch[0..max_compressed_len];
}

/// Inverse of `compress`. Rejects truncated, overlong or unknown data.
pub fn decompress(c: Coord, data: []const u8, out: *Cells) DecodeError!void {
    if (data.len < 1) return error.CorruptChunk;
    const fmt = std.enums.fromInt(Format, data[0]) orelse return error.CorruptChunk;
    switch (fmt) {
        .raw => {
            if (data.len != max_compressed_len) return error.CorruptChunk;
            for (out, 0..) |*dst, k| {
                const v = std.mem.readInt(u32, data[1 + k * 4 ..][0..4], .little);
                dst.* = decodeCell(c, @intCast(k), v);
            }
        },
        .rle => {
            var p: usize = 1;
            var i: u32 = 0;
            while (i < cell_count) {
                var run: u32 = 0;
                var shift: u5 = 0;
                while (true) {
                    if (p >= data.len) return error.CorruptChunk;
                    const b = data[p];
                    p += 1;
                    run |= @as(u32, b & 0x7f) << shift;
                    if (b & 0x80 == 0) break;
                    if (shift >= 14) return error.CorruptChunk;
                    shift += 7;
                }
                if (p + 4 > data.len) return error.CorruptChunk;
                const v = std.mem.readInt(u32, data[p..][0..4], .little);
                p += 4;
                const count = run + 1;
                if (count > cell_count - i) return error.CorruptChunk;
                const end = i + count;
                while (i < end) : (i += 1) out[i] = decodeCell(c, i, v);
            }
            if (p != data.len) return error.CorruptChunk;
        },
    }
}

const testing = std.testing;

fn fillPristine(c: Coord, cells: *Cells, mat_of_row: fn (u32) u8) void {
    const o = c.originCell();
    for (cells, 0..) |*dst, k| {
        const lx: i32 = @intCast(k & (size - 1));
        const ly: i32 = @intCast(k >> size_log2);
        const v = hash.baseVariant(o[0] + lx, o[1] + ly);
        dst.* = @as(u32, mat_of_row(@intCast(ly))) | (8 << 8) | (@as(u32, v) << 28);
    }
}

fn bands(row: u32) u8 {
    return if (row < 100) 0 else if (row < 140) 3 else 2;
}

test "coord helpers handle negative cells" {
    try testing.expectEqual(Coord{ .x = -1, .y = 0 }, coordOfCell(-1, 0));
    try testing.expectEqual(Coord{ .x = -1, .y = -1 }, coordOfCell(-256, -1));
    try testing.expectEqual(Coord{ .x = -2, .y = 1 }, coordOfCell(-257, 256));
    try testing.expectEqual([2]u32{ 255, 0 }, localOfCell(-1, 0));
    try testing.expectEqual([2]u32{ 255, 1 }, localOfCell(-257, 257));
    try testing.expectEqual([2]i32{ -512, 256 }, (Coord{ .x = -2, .y = 1 }).originCell());
}

test "chunk RLE round-trip: pristine, edited, noise" {
    const cells = try testing.allocator.create(Cells);
    defer testing.allocator.destroy(cells);
    const back = try testing.allocator.create(Cells);
    defer testing.allocator.destroy(back);
    const scratch = try testing.allocator.alloc(u8, compress_scratch_len);
    defer testing.allocator.free(scratch);

    const c: Coord = .{ .x = -3, .y = 7 };
    fillPristine(c, cells, bands);
    const small = compress(c, cells, scratch);
    // Three material bands, variant noise cancelled by the XOR transform.
    try testing.expect(small.len < 64);
    try decompress(c, small, back);
    try testing.expectEqualSlices(u32, cells, back);

    // Simulated edits: a dug tunnel and some moved pixels keeping their variant.
    var k: u32 = 0;
    while (k < 2000) : (k += 1) cells[120 * size + k % 256 + (k / 256) * size] = 0;
    cells[5] = cells[200 * size + 9];
    const edited = compress(c, cells, scratch);
    try testing.expect(edited.len < 2048);
    try decompress(c, edited, back);
    for (cells, back, 0..) |orig, got, i| try testing.expectEqual(normalized(c, @intCast(i), orig), got);
    try testing.expectEqual(cells[5], back[5]); // moved pixel keeps its variant

    // Incompressible: falls back to raw and still round-trips.
    var prng = std.Random.DefaultPrng.init(1);
    for (cells) |*v| v.* = prng.random().int(u32) | 1; // non-air: lossless
    const noisy = compress(c, cells, scratch);
    try testing.expectEqual(@as(u8, @backingInt(Format.raw)), noisy[0]);
    try testing.expectEqual(max_compressed_len, noisy.len);
    try decompress(c, noisy, back);
    try testing.expectEqualSlices(u32, cells, back);
}

test "decompress rejects corrupt input" {
    const back = try testing.allocator.create(Cells);
    defer testing.allocator.destroy(back);
    const c: Coord = .{ .x = 0, .y = 0 };
    try testing.expectError(error.CorruptChunk, decompress(c, &.{}, back));
    try testing.expectError(error.CorruptChunk, decompress(c, &.{9}, back));
    // One run of 10 cells only: too short.
    try testing.expectError(error.CorruptChunk, decompress(c, &.{ 1, 9, 0, 0, 0, 0 }, back));
    // Run longer than the chunk: 0xff 0xff 0x7f = 2^21 − 1.
    try testing.expectError(error.CorruptChunk, decompress(c, &.{ 1, 0xff, 0xff, 0x7f, 0, 0, 0, 0 }, back));
    // Exactly one full run is fine; trailing garbage is not.
    try decompress(c, &.{ 1, 0xff, 0xff, 0x03, 0, 0, 0, 0 }, back);
    try testing.expectError(error.CorruptChunk, decompress(c, &.{ 1, 0xff, 0xff, 0x03, 0, 0, 0, 0, 1 }, back));
}
