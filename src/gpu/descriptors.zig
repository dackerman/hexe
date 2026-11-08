//! The global bindless descriptor set (docs/decisions/02-bindless-descriptors.md).
//!
//! One descriptor set, bound once per command buffer at set 0 by every
//! pipeline, with four bindings of descriptor arrays:
//!   0  storage images   (constants.max_storage_images)
//!   1  storage buffers  (constants.max_storage_buffers)
//!   2  sampled images   (constants.max_sampled_images)
//!   3  samplers         (immutable: nearest/linear x clamp/repeat)
//! Bindings are PARTIALLY_BOUND and UPDATE_AFTER_BIND, so slots can be
//! filled at any time between submissions without rebinding. Shaders index
//! the arrays with slot numbers: fixed shared slots from common.glsl
//! (SLOT_IMG_*, SLOT_BUF_*) or dynamic slots allocated here at init and
//! passed in push constants. Slots are never freed; resources live for the
//! process (or the subsystem re-registers at the same slot).
const std = @import("std");
const vk = @import("vulkan");
const Context = @import("context.zig").Context;
const constants = @import("constants.zig");

pub const Descriptors = struct {
    pool: vk.DescriptorPool,
    layout: vk.DescriptorSetLayout,
    set: vk.DescriptorSet,
    samplers: [constants.sampler_count]vk.Sampler,
    next_image: u32 = constants.slot_img_dynamic_base,
    next_buffer: u32 = constants.slot_buf_dynamic_base,
    next_texture: u32 = 0,

    pub fn init(ctx: *Context) !Descriptors {
        const vkd = ctx.vkd;
        const dev = ctx.device;
        var self: Descriptors = .{ .pool = .null, .layout = .null, .set = .null, .samplers = undefined };

        const sampler_specs = [constants.sampler_count]struct { vk.Filter, vk.SamplerAddressMode }{
            .{ .nearest, .clamp_to_edge },
            .{ .linear, .clamp_to_edge },
            .{ .nearest, .repeat },
            .{ .linear, .repeat },
        };
        for (sampler_specs, 0..) |spec, i| {
            self.samplers[i] = try vkd.createSampler(dev, &.{
                .mag_filter = spec[0],
                .min_filter = spec[0],
                .mipmap_mode = .nearest,
                .address_mode_u = spec[1],
                .address_mode_v = spec[1],
                .address_mode_w = spec[1],
                .mip_lod_bias = 0,
                .anisotropy_enable = .false,
                .max_anisotropy = 1,
                .compare_enable = .false,
                .compare_op = .always,
                .min_lod = 0,
                .max_lod = 0,
                .border_color = .float_transparent_black,
                .unnormalized_coordinates = .false,
            }, null);
        }

        const all_stages = vk.ShaderStageFlags{ .compute = true, .vertex = true, .fragment = true };
        const bindings = [_]vk.DescriptorSetLayoutBinding{
            .{ .binding = constants.binding_storage_images, .descriptor_type = .storage_image, .descriptor_count = constants.max_storage_images, .stage_flags = all_stages },
            .{ .binding = constants.binding_storage_buffers, .descriptor_type = .storage_buffer, .descriptor_count = constants.max_storage_buffers, .stage_flags = all_stages },
            .{ .binding = constants.binding_sampled_images, .descriptor_type = .sampled_image, .descriptor_count = constants.max_sampled_images, .stage_flags = all_stages },
            .{ .binding = constants.binding_samplers, .descriptor_type = .sampler, .descriptor_count = constants.sampler_count, .stage_flags = all_stages, .p_immutable_samplers = &self.samplers },
        };
        const bindless = vk.DescriptorBindingFlags{ .partially_bound = true, .update_after_bind = true, .update_unused_while_pending = true };
        const binding_flags = [_]vk.DescriptorBindingFlags{ bindless, bindless, bindless, .{} };
        const flags_info = vk.DescriptorSetLayoutBindingFlagsCreateInfo{
            .binding_count = binding_flags.len,
            .p_binding_flags = &binding_flags,
        };
        self.layout = try vkd.createDescriptorSetLayout(dev, &.{
            .p_next = &flags_info,
            .flags = .{ .update_after_bind_pool = true },
            .binding_count = bindings.len,
            .p_bindings = &bindings,
        }, null);

        const sizes = [_]vk.DescriptorPoolSize{
            .{ .type = .storage_image, .descriptor_count = constants.max_storage_images },
            .{ .type = .storage_buffer, .descriptor_count = constants.max_storage_buffers },
            .{ .type = .sampled_image, .descriptor_count = constants.max_sampled_images },
            .{ .type = .sampler, .descriptor_count = constants.sampler_count },
        };
        self.pool = try vkd.createDescriptorPool(dev, &.{
            .flags = .{ .update_after_bind = true },
            .max_sets = 1,
            .pool_size_count = sizes.len,
            .p_pool_sizes = &sizes,
        }, null);
        try vkd.allocateDescriptorSets(dev, &.{
            .descriptor_pool = self.pool,
            .descriptor_set_count = 1,
            .p_set_layouts = @ptrCast(&self.layout),
        }, @ptrCast(&self.set));
        return self;
    }

    pub fn deinit(self: *Descriptors, ctx: *Context) void {
        ctx.vkd.destroyDescriptorPool(ctx.device, self.pool, null);
        ctx.vkd.destroyDescriptorSetLayout(ctx.device, self.layout, null);
        for (self.samplers) |s| ctx.vkd.destroySampler(ctx.device, s, null);
    }

    pub fn allocImageSlot(self: *Descriptors) !u32 {
        if (self.next_image >= constants.max_storage_images) return error.OutOfImageSlots;
        defer self.next_image += 1;
        return self.next_image;
    }

    pub fn allocBufferSlot(self: *Descriptors) !u32 {
        if (self.next_buffer >= constants.max_storage_buffers) return error.OutOfBufferSlots;
        defer self.next_buffer += 1;
        return self.next_buffer;
    }

    pub fn allocTextureSlot(self: *Descriptors) !u32 {
        if (self.next_texture >= constants.max_sampled_images) return error.OutOfTextureSlots;
        defer self.next_texture += 1;
        return self.next_texture;
    }

    /// Storage image at `slot`; the image must be in GENERAL layout when used.
    pub fn writeStorageImage(self: *Descriptors, ctx: *Context, slot: u32, view: vk.ImageView) void {
        std.debug.assert(slot < constants.max_storage_images);
        const info = vk.DescriptorImageInfo{ .sampler = .null, .image_view = view, .image_layout = .general };
        ctx.vkd.updateDescriptorSets(ctx.device, &.{.{
            .dst_set = self.set,
            .dst_binding = constants.binding_storage_images,
            .dst_array_element = slot,
            .descriptor_count = 1,
            .descriptor_type = .storage_image,
            .p_image_info = @ptrCast(&info),
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        }}, null);
    }

    pub fn writeStorageBuffer(self: *Descriptors, ctx: *Context, slot: u32, buffer: vk.Buffer, offset: u64, range: u64) void {
        std.debug.assert(slot < constants.max_storage_buffers);
        const info = vk.DescriptorBufferInfo{ .buffer = buffer, .offset = offset, .range = range };
        ctx.vkd.updateDescriptorSets(ctx.device, &.{.{
            .dst_set = self.set,
            .dst_binding = constants.binding_storage_buffers,
            .dst_array_element = slot,
            .descriptor_count = 1,
            .descriptor_type = .storage_buffer,
            .p_image_info = undefined,
            .p_buffer_info = @ptrCast(&info),
            .p_texel_buffer_view = undefined,
        }}, null);
    }

    pub fn writeSampledImage(self: *Descriptors, ctx: *Context, slot: u32, view: vk.ImageView, layout: vk.ImageLayout) void {
        std.debug.assert(slot < constants.max_sampled_images);
        const info = vk.DescriptorImageInfo{ .sampler = .null, .image_view = view, .image_layout = layout };
        ctx.vkd.updateDescriptorSets(ctx.device, &.{.{
            .dst_set = self.set,
            .dst_binding = constants.binding_sampled_images,
            .dst_array_element = slot,
            .descriptor_count = 1,
            .descriptor_type = .sampled_image,
            .p_image_info = @ptrCast(&info),
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        }}, null);
    }

    /// Bind the set at set 0 for `point` on `cmd`. Compute-queue command
    /// buffers may only bind `.compute`.
    pub fn bind(self: *const Descriptors, ctx: *const Context, cmd: vk.CommandBuffer, point: vk.PipelineBindPoint) void {
        ctx.vkd.cmdBindDescriptorSets(cmd, point, ctx.pipeline_layout, 0, &.{self.set}, null);
    }
};
