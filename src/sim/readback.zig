//! Synchronous GPU -> CPU copies of world images, for tests, verification
//! and tools. Not the per-tick readback mirror (that is M4's readback.zig
//! work: solid mask, entity strips, event queue, one tick late).
const std = @import("std");
const gpu = @import("../gpu/gpu.zig");
const vk = gpu.vk;
const cell = @import("cell.zig");
const Shared = @import("pipeline.zig").Shared;

/// Copy a world-sized R32_UINT image (GENERAL layout) into `out` through
/// `staging` (host-visible, >= world_size^2 * 4 bytes). The GPU must be idle
/// or the caller must have waited for the work that wrote the image.
pub fn readbackImage(ctx: *gpu.Context, image: *const gpu.Image, staging: *gpu.Buffer, out: []u32) !void {
    std.debug.assert(out.len == @as(usize, image.width) * image.height);
    std.debug.assert(staging.size >= out.len * 4);
    try ctx.runOnce(.compute, recordCopy, .{ ctx, image, staging });
    @memcpy(out, staging.typed(u32)[0..out.len]);
}

/// The cell image. See `readbackImage`.
pub fn readbackCells(ctx: *gpu.Context, shared: *const Shared, staging: *gpu.Buffer, out: []u32) !void {
    try readbackImage(ctx, shared.cells, staging, out);
}

/// The owner image. See `readbackImage`.
pub fn readbackOwner(ctx: *gpu.Context, shared: *const Shared, staging: *gpu.Buffer, out: []u32) !void {
    try readbackImage(ctx, shared.owner, staging, out);
}

fn recordCopy(cmd: vk.CommandBuffer, ctx: *gpu.Context, image: *const gpu.Image, staging: *gpu.Buffer) void {
    gpu.memory.memoryBarrier(ctx, cmd, .{ .all_commands = true }, .{ .memory_write = true }, .{ .all_transfer = true }, .{ .transfer_read = true });
    ctx.vkd.cmdCopyImageToBuffer(cmd, image.handle, .general, staging.handle, &.{.{
        .buffer_offset = 0,
        .buffer_row_length = 0,
        .buffer_image_height = 0,
        .image_subresource = .{ .aspect_mask = .{ .color = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
        .image_offset = .{ .x = 0, .y = 0, .z = 0 },
        .image_extent = .{ .width = image.width, .height = image.height, .depth = 1 },
    }});
    gpu.memory.memoryBarrier(ctx, cmd, .{ .all_transfer = true }, .{ .transfer_write = true }, .{ .host = true }, .{ .host_read = true });
}
