//! Minimal PNG encoder: 8-bit RGBA, filter 0, zlib stream of stored
//! (uncompressed) deflate blocks with Adler-32, chunks with CRC-32
//! (docs/decisions/06-png-encoder.md). Big files, zero dependencies, exact.
const std = @import("std");

const signature = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };
const max_stored = 65535;

/// Encoded size for a width x height RGBA image (exact).
pub fn encodedSize(width: u32, height: u32) usize {
    const raw = (@as(usize, width) * 4 + 1) * height;
    const blocks = @max(1, (raw + max_stored - 1) / max_stored);
    const zlib = 2 + raw + blocks * 5 + 4;
    return signature.len + (12 + 13) + (12 + zlib) + 12;
}

/// Encode `rgba` (width * height * 4 bytes, rows top to bottom) into `out`,
/// which must be at least `encodedSize` bytes. Returns the used slice.
pub fn encode(out: []u8, width: u32, height: u32, rgba: []const u8) []u8 {
    std.debug.assert(rgba.len == @as(usize, width) * height * 4);
    std.debug.assert(out.len >= encodedSize(width, height));
    var w: Writer = .{ .buf = out };
    w.bytes(&signature);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // color type RGBA
    ihdr[10] = 0; // compression
    ihdr[11] = 0; // filter
    ihdr[12] = 0; // interlace
    w.chunk("IHDR", &ihdr);

    // IDAT: write the header, then stream the zlib payload and patch length/CRC.
    const raw_len = (@as(usize, width) * 4 + 1) * height;
    const blocks = @max(1, (raw_len + max_stored - 1) / max_stored);
    const zlib_len = 2 + raw_len + blocks * 5 + 4;
    w.u32be(@intCast(zlib_len));
    const crc_start = w.pos;
    w.bytes("IDAT");
    w.bytes(&.{ 0x78, 0x01 });
    var adler: std.hash.Adler32 = .{};
    var remaining = raw_len;
    var row: usize = 0;
    var col: usize = 0; // byte index within the current filtered row (0 = filter byte)
    const row_bytes = @as(usize, width) * 4 + 1;
    while (remaining > 0) {
        const n = @min(remaining, max_stored);
        remaining -= n;
        w.byte(if (remaining == 0) 1 else 0);
        w.u16le(@intCast(n));
        w.u16le(@intCast(~@as(u16, @intCast(n))));
        var left = n;
        while (left > 0) {
            if (col == 0) {
                w.byte(0);
                adler.update(&.{0});
                col = 1;
                left -= 1;
                continue;
            }
            const take = @min(left, row_bytes - col);
            const src = rgba[row * width * 4 + (col - 1) ..][0..take];
            w.bytes(src);
            adler.update(src);
            col += take;
            left -= take;
            if (col == row_bytes) {
                col = 0;
                row += 1;
            }
        }
    }
    w.u32be(adler.adler);
    w.u32be(std.hash.Crc32.hash(out[crc_start..w.pos]));
    w.chunk("IEND", "");
    return out[0..w.pos];
}

const Writer = struct {
    buf: []u8,
    pos: usize = 0,

    fn byte(self: *Writer, b: u8) void {
        self.buf[self.pos] = b;
        self.pos += 1;
    }
    fn bytes(self: *Writer, b: []const u8) void {
        @memcpy(self.buf[self.pos..][0..b.len], b);
        self.pos += b.len;
    }
    fn u32be(self: *Writer, v: u32) void {
        std.mem.writeInt(u32, self.buf[self.pos..][0..4], v, .big);
        self.pos += 4;
    }
    fn u16le(self: *Writer, v: u16) void {
        std.mem.writeInt(u16, self.buf[self.pos..][0..2], v, .little);
        self.pos += 2;
    }
    fn chunk(self: *Writer, kind: *const [4]u8, data: []const u8) void {
        self.u32be(@intCast(data.len));
        const start = self.pos;
        self.bytes(kind);
        self.bytes(data);
        self.u32be(std.hash.Crc32.hash(self.buf[start..self.pos]));
    }
};

test "png round trip through zlib" {
    const gpa = std.testing.allocator;
    const w = 300;
    const h = 250; // > 65535 raw bytes, several stored blocks, rows split across blocks
    const rgba = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(rgba);
    for (rgba, 0..) |*b, i| b.* = @truncate(i *% 31 +% i / 7);
    const out = try gpa.alloc(u8, encodedSize(w, h));
    defer gpa.free(out);
    const png = encode(out, w, h, rgba);
    try std.testing.expectEqual(encodedSize(w, h), png.len);
    try std.testing.expectEqualSlices(u8, &signature, png[0..8]);

    // Locate IDAT and inflate it with std's zlib decoder.
    const idat_len = std.mem.readInt(u32, png[33..37], .big);
    try std.testing.expectEqualSlices(u8, "IDAT", png[37..41]);
    const zdata = png[41..][0..idat_len];
    var in: std.Io.Reader = .fixed(zdata);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var dec: std.compress.flate.Decompress = .init(&in, .zlib, &window);
    const raw = try dec.reader.allocRemaining(gpa, .unlimited);
    defer gpa.free(raw);
    try std.testing.expectEqual(@as(usize, (w * 4 + 1) * h), raw.len);
    for (0..h) |y| {
        try std.testing.expectEqual(@as(u8, 0), raw[y * (w * 4 + 1)]);
        try std.testing.expectEqualSlices(u8, rgba[y * w * 4 ..][0 .. w * 4], raw[y * (w * 4 + 1) + 1 ..][0 .. w * 4]);
    }
    // IEND chunk CRC is the well-known constant.
    try std.testing.expectEqualSlices(u8, &.{ 0xae, 0x42, 0x60, 0x82 }, png[png.len - 4 ..]);
}
