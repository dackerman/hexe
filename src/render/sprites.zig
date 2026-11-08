//! Sprite atlas and the sprite / debug-primitive batch (shaders/render/quads.*).
//!
//! Sprites are small RGBA8 bitmaps (sRGB, R in the low byte) uploaded once
//! into a 512x512 atlas with shelf packing; `upload` returns the atlas rect
//! to draw with. Per frame, gameplay appends `QuadGpu` entries through the
//! renderer (`drawSprite`, `drawRect`, `drawLine`); they are drawn at world
//! pixel scale into the scene image after the world pass, sprites lit by the
//! same irradiance as the world.
const std = @import("std");
const gpu = @import("../gpu/gpu.zig");
const vk = gpu.vk;

pub const atlas_size = 512;

pub const kind_sprite: u32 = 0;
pub const kind_rect: u32 = 1;
pub const kind_line: u32 = 2;
pub const flag_flip_x: u32 = 1;
pub const flag_lit: u32 = 2;
pub const max_quads = 8192;

pub const QuadGpu = extern struct {
    p0: [2]f32,
    p1: [2]f32,
    color: [4]f32,
    uv: [4]f32 = .{ 0, 0, 0, 0 },
    kind: u32,
    flags: u32 = 0,
    width: f32 = 1,
    pad: u32 = 0,
};

comptime {
    std.debug.assert(@sizeOf(QuadGpu) == 64);
}

/// Texel rectangle inside the atlas.
pub const AtlasRect = struct { x: u16, y: u16, w: u16, h: u16 };

pub const Atlas = struct {
    image: gpu.Image = .{},
    texture_slot: u32 = 0,
    shelf_x: u32 = 0,
    shelf_y: u32 = 0,
    shelf_h: u32 = 0,

    pub fn init(ctx: *gpu.Context) !Atlas {
        var self: Atlas = .{};
        self.image = try gpu.Image.init(ctx, .{
            .width = atlas_size,
            .height = atlas_size,
            .format = .r8g8b8a8_unorm,
            .usage = .{ .sampled = true, .transfer_dst = true },
        });
        errdefer self.image.deinit(ctx);
        try self.image.initLayout(ctx, .general, true);
        self.texture_slot = try ctx.descriptors.allocTextureSlot();
        ctx.descriptors.writeSampledImage(ctx, self.texture_slot, self.image.view, .general);
        return self;
    }

    pub fn deinit(self: *Atlas, ctx: *gpu.Context) void {
        self.image.deinit(ctx);
    }

    /// Copy a w x h RGBA8 bitmap (row major, R in the low byte) into the
    /// atlas. Waits for the GPU; call at init or between frames.
    pub fn upload(self: *Atlas, ctx: *gpu.Context, pixels: []const u32, w: u32, h: u32) !AtlasRect {
        std.debug.assert(pixels.len == w * h);
        if (w > atlas_size or h > atlas_size) return error.SpriteTooLarge;
        if (self.shelf_x + w > atlas_size) {
            self.shelf_y += self.shelf_h + 1;
            self.shelf_x = 0;
            self.shelf_h = 0;
        }
        if (self.shelf_y + h > atlas_size) return error.AtlasFull;
        const rect = AtlasRect{ .x = @intCast(self.shelf_x), .y = @intCast(self.shelf_y), .w = @intCast(w), .h = @intCast(h) };
        self.shelf_x += w + 1;
        self.shelf_h = @max(self.shelf_h, h);

        var staging = try gpu.Buffer.init(ctx, @as(u64, w) * h * 4, .{ .transfer_src = true }, .cpu_to_gpu);
        defer staging.deinit(ctx);
        @memcpy(staging.typed(u32), pixels);
        try ctx.runOnce(.graphics, recordUpload, .{ ctx, staging.handle, self.image.handle, rect });
        return rect;
    }

    fn recordUpload(cmd: vk.CommandBuffer, ctx: *gpu.Context, src: vk.Buffer, dst: vk.Image, rect: AtlasRect) void {
        gpu.memory.memoryBarrier(ctx, cmd, .{ .all_commands = true }, .{ .memory_read = true }, .{ .all_transfer = true }, .{ .transfer_write = true });
        ctx.vkd.cmdCopyBufferToImage(cmd, src, dst, .general, &.{.{
            .buffer_offset = 0,
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_subresource = .{ .aspect_mask = .{ .color = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
            .image_offset = .{ .x = rect.x, .y = rect.y, .z = 0 },
            .image_extent = .{ .width = rect.w, .height = rect.h, .depth = 1 },
        }});
        gpu.memory.memoryBarrier(ctx, cmd, .{ .all_transfer = true }, .{ .transfer_write = true }, .{ .all_commands = true }, .{ .memory_read = true });
    }
};

/// A bitmap drawn as text: one character per pixel, mapped through a
/// palette of (char, 0xRRGGBB); '.' is transparent.
pub fn Bitmap(comptime w: u32, comptime h: u32) type {
    return [w * h]u32;
}

pub fn parseBitmap(comptime w: u32, comptime h: u32, comptime rows: []const []const u8, comptime palette: []const struct { u8, u32 }) Bitmap(w, h) {
    @setEvalBranchQuota(20_000);
    if (rows.len != h) @compileError("bitmap height mismatch");
    var out: Bitmap(w, h) = @splat(0);
    for (rows, 0..) |row, y| {
        if (row.len != w) @compileError("bitmap row width mismatch: " ++ row);
        for (row, 0..) |ch, x| {
            if (ch == '.') continue;
            var found = false;
            for (palette) |p| {
                if (p[0] == ch) {
                    const rgb = p[1];
                    out[y * w + x] = ((rgb >> 16) & 0xff) | (rgb & 0xff00) | ((rgb & 0xff) << 16) | 0xff00_0000;
                    found = true;
                }
            }
            if (!found) @compileError("bitmap char not in palette");
        }
    }
    return out;
}

/// Placeholder: 12x30 witch silhouette (hat, cloak, staff hand).
pub const witch_w = 12;
pub const witch_h = 30;
pub const witch = parseBitmap(witch_w, witch_h, &.{
    ".....hh.....",
    "....hhh.....",
    "....hhhh....",
    "...hhhhh....",
    "...hhhhhh...",
    "..hhhhhhh...",
    "hhhhhhhhhhh.",
    ".hhhhhhhhh..",
    "...ssss.....",
    "...sesse....",
    "...sssss....",
    "....ss......",
    "...cccc.....",
    "..cccccc.w..",
    "..cccccccs..",
    ".cccccccc...",
    ".ccccccc....",
    ".cccbccc....",
    ".cccbcccc...",
    ".ccccccc....",
    "cccccccc....",
    "ccccccccc...",
    "ccccccccc...",
    "cccccccccc..",
    "cccccccccc..",
    "ccccccccccc.",
    "cccccccccccc",
    "...pp..pp...",
    "...pp..pp...",
    "..ppp..ppp..",
}, &.{
    .{ 'h', 0x2a1f3d }, // hat
    .{ 's', 0xe0b694 }, // skin
    .{ 'e', 0x30d0a0 }, // eyes
    .{ 'c', 0x4b2f6e }, // cloak
    .{ 'b', 0xc8a040 }, // buckle
    .{ 'w', 0xa0e8ff }, // wand tip
    .{ 'p', 0x2b2230 }, // boots
});

/// Placeholder: 16x16 wooden crate.
pub const crate_w = 16;
pub const crate_h = 16;
pub const crate = parseBitmap(crate_w, crate_h, &.{
    "dddddddddddddddd",
    "dlllllllllllllld",
    "dlbbbbbbbbbbbbld",
    "dlbmbbbbbbbbmbld",
    "dlbbmbbbbbbmbbld",
    "dlbbbmbbbbmbbbld",
    "dlbbbbmbbmbbbbld",
    "dlbbbbbmmbbbbbld",
    "dlbbbbbmmbbbbbld",
    "dlbbbbmbbmbbbbld",
    "dlbbbmbbbbmbbbld",
    "dlbbmbbbbbbmbbld",
    "dlbmbbbbbbbbmbld",
    "dlbbbbbbbbbbbbld",
    "dlllllllllllllld",
    "dddddddddddddddd",
}, &.{
    .{ 'd', 0x3a2414 }, // dark edge
    .{ 'l', 0x9a6a3a }, // light frame
    .{ 'b', 0x7a5230 }, // boards
    .{ 'm', 0x5a3a20 }, // brace
});

test "placeholder bitmaps" {
    // Hat tip is opaque, the corner is transparent.
    try std.testing.expect(witch[0 * witch_w + 5] >> 24 == 0xff);
    try std.testing.expectEqual(@as(u32, 0), witch[0]);
    // 0x9a6a3a -> R 0x9a in the low byte.
    try std.testing.expectEqual(@as(u32, 0xff3a6a9a), crate[1 * crate_w + 1]);
}
