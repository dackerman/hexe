//! Minimal PNG encoder: 8-bit RGB, filter 0 rows, zlib via std.compress.flate.

const std = @import("std");
const flate = std.compress.flate;

fn chunkOut(w: *std.Io.Writer, kind: *const [4]u8, data: []const u8) !void {
    try w.writeInt(u32, @intCast(data.len), .big);
    try w.writeAll(kind);
    try w.writeAll(data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    try w.writeInt(u32, crc.final(), .big);
}

/// Encodes `rgb` (width·height·3 bytes) as PNG into `out`.
pub fn encode(gpa: std.mem.Allocator, out: *std.Io.Writer, width: u32, height: u32, rgb: []const u8) !void {
    std.debug.assert(rgb.len == @as(usize, width) * height * 3);
    try out.writeAll("\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 2; // truecolor
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try chunkOut(out, "IHDR", &ihdr);

    var zbuf: std.Io.Writer.Allocating = .init(gpa);
    defer zbuf.deinit();
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var z = try flate.Compress.init(&zbuf.writer, window, .zlib, .default);
    const stride = @as(usize, width) * 3;
    for (0..height) |y| {
        try z.writer.writeByte(0);
        try z.writer.writeAll(rgb[y * stride ..][0..stride]);
    }
    try z.finish();
    try chunkOut(out, "IDAT", zbuf.written());
    try chunkOut(out, "IEND", "");
}
