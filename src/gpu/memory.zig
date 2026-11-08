//! Device memory, buffers and images (docs/decisions/03-dedicated-allocations.md).
//!
//! Every buffer and image gets its own dedicated VkDeviceMemory. The engine
//! creates a few dozen long-lived resources, far below the driver's
//! allocation limit, so a suballocator would buy nothing yet. Resources are
//! created CONCURRENT across the graphics and compute families.
const std = @import("std");
const vk = @import("vulkan");
const Context = @import("context.zig").Context;

pub const Location = enum {
    /// Device local, not mapped.
    gpu_only,
    /// Host visible + coherent, persistently mapped; GPU reads what the CPU
    /// writes (prefers device-local BAR memory).
    cpu_to_gpu,
    /// Host visible, cached when possible, persistently mapped; CPU reads
    /// what the GPU writes.
    gpu_to_cpu,
};

pub const no_slot = std.math.maxInt(u32);

fn allocate(ctx: *Context, reqs: vk.MemoryRequirements, location: Location, dedicated: vk.MemoryDedicatedAllocateInfo) !struct { vk.DeviceMemory, bool } {
    const required: vk.MemoryPropertyFlags, const preferred: vk.MemoryPropertyFlags = switch (location) {
        .gpu_only => .{ .{ .device_local = true }, .{} },
        .cpu_to_gpu => .{ .{ .host_visible = true, .host_coherent = true }, .{ .device_local = true } },
        .gpu_to_cpu => .{ .{ .host_visible = true, .host_coherent = true }, .{ .host_cached = true } },
    };
    const type_index = ctx.findMemoryType(reqs.memory_type_bits, required, preferred) orelse return error.NoSuitableMemoryType;
    const memory = try ctx.vkd.allocateMemory(ctx.device, &.{
        .p_next = &dedicated,
        .allocation_size = reqs.size,
        .memory_type_index = type_index,
    }, null);
    return .{ memory, location != .gpu_only };
}

pub const Buffer = struct {
    handle: vk.Buffer = .null,
    memory: vk.DeviceMemory = .null,
    size: u64 = 0,
    mapped: ?[*]u8 = null,
    /// Descriptor slot in the bindless storage buffer array, if registered.
    slot: u32 = no_slot,

    pub fn init(ctx: *Context, size: u64, usage: vk.BufferUsageFlags, location: Location) !Buffer {
        var self: Buffer = .{ .size = size };
        self.handle = try ctx.vkd.createBuffer(ctx.device, &.{
            .size = size,
            .usage = usage,
            .sharing_mode = ctx.sharingMode(),
            .queue_family_index_count = ctx.family_count,
            .p_queue_family_indices = &ctx.families,
        }, null);
        errdefer ctx.vkd.destroyBuffer(ctx.device, self.handle, null);
        const reqs = ctx.vkd.getBufferMemoryRequirements(ctx.device, self.handle);
        const memory, const mappable = try allocate(ctx, reqs, location, .{ .image = .null, .buffer = self.handle });
        self.memory = memory;
        errdefer ctx.vkd.freeMemory(ctx.device, self.memory, null);
        try ctx.vkd.bindBufferMemory(ctx.device, self.handle, self.memory, 0);
        if (mappable) {
            const ptr = try ctx.vkd.mapMemory(ctx.device, self.memory, 0, vk.WHOLE_SIZE, .{});
            self.mapped = @ptrCast(ptr);
        }
        return self;
    }

    /// Create and register at a newly allocated dynamic descriptor slot.
    pub fn initSlotted(ctx: *Context, size: u64, usage: vk.BufferUsageFlags, location: Location) !Buffer {
        var self = try init(ctx, size, usage.merge(.{ .storage_buffer = true }), location);
        errdefer self.deinit(ctx);
        self.register(ctx, try ctx.descriptors.allocBufferSlot());
        return self;
    }

    pub fn deinit(self: *Buffer, ctx: *Context) void {
        if (self.handle == .null) return;
        ctx.vkd.destroyBuffer(ctx.device, self.handle, null);
        ctx.vkd.freeMemory(ctx.device, self.memory, null);
        self.* = .{};
    }

    /// Point bindless storage buffer `slot` at this whole buffer.
    pub fn register(self: *Buffer, ctx: *Context, slot: u32) void {
        self.slot = slot;
        ctx.descriptors.writeStorageBuffer(ctx, slot, self.handle, 0, self.size);
    }

    /// The mapped bytes of a host-visible buffer.
    pub fn bytes(self: *const Buffer) []u8 {
        return self.mapped.?[0..self.size];
    }

    pub fn typed(self: *const Buffer, comptime T: type) []T {
        const n = self.size / @sizeOf(T);
        const ptr: [*]T = @ptrCast(@alignCast(self.mapped.?));
        return ptr[0..n];
    }
};

pub const ImageDesc = struct {
    width: u32,
    height: u32,
    format: vk.Format,
    usage: vk.ImageUsageFlags,
};

pub const Image = struct {
    handle: vk.Image = .null,
    memory: vk.DeviceMemory = .null,
    view: vk.ImageView = .null,
    format: vk.Format = .undefined,
    width: u32 = 0,
    height: u32 = 0,
    /// Descriptor slot in the bindless storage image array, if registered.
    slot: u32 = no_slot,

    /// Creates the image in UNDEFINED layout; call `initLayout` (or
    /// transition it yourself) before use.
    pub fn init(ctx: *Context, desc: ImageDesc) !Image {
        var self: Image = .{ .format = desc.format, .width = desc.width, .height = desc.height };
        self.handle = try ctx.vkd.createImage(ctx.device, &.{
            .image_type = .@"2d",
            .format = desc.format,
            .extent = .{ .width = desc.width, .height = desc.height, .depth = 1 },
            .mip_levels = 1,
            .array_layers = 1,
            .samples = .{ .@"1" = true },
            .tiling = .optimal,
            .usage = desc.usage,
            .sharing_mode = ctx.sharingMode(),
            .queue_family_index_count = ctx.family_count,
            .p_queue_family_indices = &ctx.families,
            .initial_layout = .undefined,
        }, null);
        errdefer ctx.vkd.destroyImage(ctx.device, self.handle, null);
        const reqs = ctx.vkd.getImageMemoryRequirements(ctx.device, self.handle);
        self.memory, _ = try allocate(ctx, reqs, .gpu_only, .{ .image = self.handle, .buffer = .null });
        errdefer ctx.vkd.freeMemory(ctx.device, self.memory, null);
        try ctx.vkd.bindImageMemory(ctx.device, self.handle, self.memory, 0);
        self.view = try ctx.vkd.createImageView(ctx.device, &.{
            .image = self.handle,
            .view_type = .@"2d",
            .format = desc.format,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = color_range,
        }, null);
        return self;
    }

    pub fn deinit(self: *Image, ctx: *Context) void {
        if (self.handle == .null) return;
        ctx.vkd.destroyImageView(ctx.device, self.view, null);
        ctx.vkd.destroyImage(ctx.device, self.handle, null);
        ctx.vkd.freeMemory(ctx.device, self.memory, null);
        self.* = .{};
    }

    /// Point bindless storage image `slot` at this image (GENERAL layout).
    pub fn register(self: *Image, ctx: *Context, slot: u32) void {
        self.slot = slot;
        ctx.descriptors.writeStorageImage(ctx, slot, self.view);
    }

    /// One-shot: transition from UNDEFINED to `layout` and, for GENERAL
    /// storage images, clear to zero.
    pub fn initLayout(self: *Image, ctx: *Context, layout: vk.ImageLayout, clear: bool) !void {
        try ctx.runOnce(.compute, recordInitLayout, .{ ctx, self.handle, layout, clear });
    }

    fn recordInitLayout(cmd: vk.CommandBuffer, ctx: *Context, image: vk.Image, layout: vk.ImageLayout, clear: bool) void {
        if (clear) {
            imageBarrier(ctx, cmd, image, .undefined, .general, .{}, .{}, .{ .all_transfer = true }, .{ .transfer_write = true });
            const zero = vk.ClearColorValue{ .uint_32 = .{ 0, 0, 0, 0 } };
            ctx.vkd.cmdClearColorImage(cmd, image, .general, &zero, &.{color_range});
            imageBarrier(ctx, cmd, image, .general, layout, .{ .all_transfer = true }, .{ .transfer_write = true }, .{ .all_commands = true }, .{ .memory_read = true, .memory_write = true });
        } else {
            imageBarrier(ctx, cmd, image, .undefined, layout, .{}, .{}, .{ .all_commands = true }, .{ .memory_read = true, .memory_write = true });
        }
    }
};

pub const color_range = vk.ImageSubresourceRange{
    .aspect_mask = .{ .color = true },
    .base_mip_level = 0,
    .level_count = 1,
    .base_array_layer = 0,
    .layer_count = 1,
};

pub fn imageBarrier(
    ctx: *const Context,
    cmd: vk.CommandBuffer,
    image: vk.Image,
    old: vk.ImageLayout,
    new: vk.ImageLayout,
    src_stage: vk.PipelineStageFlags2,
    src_access: vk.AccessFlags2,
    dst_stage: vk.PipelineStageFlags2,
    dst_access: vk.AccessFlags2,
) void {
    const b = vk.ImageMemoryBarrier2{
        .src_stage_mask = src_stage,
        .src_access_mask = src_access,
        .dst_stage_mask = dst_stage,
        .dst_access_mask = dst_access,
        .old_layout = old,
        .new_layout = new,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresource_range = color_range,
    };
    ctx.vkd.cmdPipelineBarrier2(cmd, &.{ .image_memory_barrier_count = 1, .p_image_memory_barriers = @ptrCast(&b) });
}

/// Global memory barrier (all buffers and GENERAL-layout images).
pub fn memoryBarrier(
    ctx: *const Context,
    cmd: vk.CommandBuffer,
    src_stage: vk.PipelineStageFlags2,
    src_access: vk.AccessFlags2,
    dst_stage: vk.PipelineStageFlags2,
    dst_access: vk.AccessFlags2,
) void {
    const b = vk.MemoryBarrier2{
        .src_stage_mask = src_stage,
        .src_access_mask = src_access,
        .dst_stage_mask = dst_stage,
        .dst_access_mask = dst_access,
    };
    ctx.vkd.cmdPipelineBarrier2(cmd, &.{ .memory_barrier_count = 1, .p_memory_barriers = @ptrCast(&b) });
}

/// The common case between compute passes: shader writes visible to the
/// next compute pass's reads and writes.
pub fn computeBarrier(ctx: *const Context, cmd: vk.CommandBuffer) void {
    memoryBarrier(
        ctx,
        cmd,
        .{ .compute_shader = true },
        .{ .shader_storage_write = true },
        .{ .compute_shader = true },
        .{ .shader_storage_read = true, .shader_storage_write = true },
    );
}
