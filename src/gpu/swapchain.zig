//! Swapchain for the SDL3 surface. Prefers B8G8R8A8_UNORM (the world and
//! HUD write display-ready sRGB-encoded values; see world.frag) and FIFO
//! (vsync) unless told otherwise. Recreated on resize or OUT_OF_DATE.
const std = @import("std");
const vk = @import("vulkan");
const Context = @import("context.zig").Context;

pub const max_images = 8;

pub const Swapchain = struct {
    handle: vk.SwapchainKHR = .null,
    format: vk.Format = .undefined,
    extent: vk.Extent2D = .{ .width = 0, .height = 0 },
    images: [max_images]vk.Image = undefined,
    views: [max_images]vk.ImageView = undefined,
    /// Signaled by the render submission for image i, waited by present.
    render_done: [max_images]vk.Semaphore = undefined,
    count: u32 = 0,
    vsync: bool = true,

    pub fn init(ctx: *Context, width: u32, height: u32, vsync: bool) !Swapchain {
        var self: Swapchain = .{ .vsync = vsync };
        try self.create(ctx, width, height, .null);
        return self;
    }

    pub fn deinit(self: *Swapchain, ctx: *Context) void {
        self.destroyViews(ctx);
        if (self.handle != .null) ctx.vkd.destroySwapchainKHR(ctx.device, self.handle, null);
        self.handle = .null;
    }

    pub fn recreate(self: *Swapchain, ctx: *Context, width: u32, height: u32) !void {
        ctx.waitIdle();
        self.destroyViews(ctx);
        const old = self.handle;
        try self.create(ctx, width, height, old);
        ctx.vkd.destroySwapchainKHR(ctx.device, old, null);
    }

    fn destroyViews(self: *Swapchain, ctx: *Context) void {
        for (0..self.count) |i| {
            ctx.vkd.destroyImageView(ctx.device, self.views[i], null);
            ctx.vkd.destroySemaphore(ctx.device, self.render_done[i], null);
        }
        self.count = 0;
    }

    fn create(self: *Swapchain, ctx: *Context, width: u32, height: u32, old: vk.SwapchainKHR) !void {
        const caps = try ctx.vki.getPhysicalDeviceSurfaceCapabilitiesKHR(ctx.pdev, ctx.surface);
        const formats = try ctx.vki.getPhysicalDeviceSurfaceFormatsAllocKHR(ctx.pdev, ctx.surface, ctx.gpa);
        defer ctx.gpa.free(formats);
        const modes = try ctx.vki.getPhysicalDeviceSurfacePresentModesAllocKHR(ctx.pdev, ctx.surface, ctx.gpa);
        defer ctx.gpa.free(modes);

        var chosen = formats[0];
        for (formats) |f| {
            if ((f.format == .b8g8r8a8_unorm or f.format == .r8g8b8a8_unorm) and f.color_space == .srgb_nonlinear_khr) {
                chosen = f;
                break;
            }
        }
        var mode: vk.PresentModeKHR = .fifo_khr;
        if (!self.vsync) {
            for (modes) |m| {
                if (m == .mailbox_khr) mode = m;
            }
            for (modes) |m| {
                if (m == .immediate_khr and mode != .mailbox_khr) mode = m;
            }
        }

        var extent = caps.current_extent;
        if (extent.width == std.math.maxInt(u32)) {
            extent = .{
                .width = std.math.clamp(width, caps.min_image_extent.width, caps.max_image_extent.width),
                .height = std.math.clamp(height, caps.min_image_extent.height, caps.max_image_extent.height),
            };
        }
        var image_count = caps.min_image_count + 1;
        if (caps.max_image_count > 0) image_count = @min(image_count, caps.max_image_count);
        image_count = @min(image_count, max_images);

        self.handle = try ctx.vkd.createSwapchainKHR(ctx.device, &.{
            .surface = ctx.surface,
            .min_image_count = image_count,
            .image_format = chosen.format,
            .image_color_space = chosen.color_space,
            .image_extent = extent,
            .image_array_layers = 1,
            .image_usage = .{ .color_attachment = true, .transfer_dst = true },
            .image_sharing_mode = .exclusive,
            .pre_transform = caps.current_transform,
            .composite_alpha = .{ .opaque_khr = true },
            .present_mode = mode,
            .clipped = .true,
            .old_swapchain = old,
        }, null);
        self.format = chosen.format;
        self.extent = extent;

        var count: u32 = 0;
        _ = try ctx.vkd.getSwapchainImagesKHR(ctx.device, self.handle, &count, null);
        count = @min(count, max_images);
        _ = try ctx.vkd.getSwapchainImagesKHR(ctx.device, self.handle, &count, &self.images);
        for (0..count) |i| {
            self.views[i] = try ctx.vkd.createImageView(ctx.device, &.{
                .image = self.images[i],
                .view_type = .@"2d",
                .format = self.format,
                .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
                .subresource_range = @import("memory.zig").color_range,
            }, null);
            self.render_done[i] = try ctx.vkd.createSemaphore(ctx.device, &.{}, null);
            self.count = @intCast(i + 1);
        }
        std.log.scoped(.gpu).info("swapchain {d}x{d} {s} {s}, {d} images", .{ extent.width, extent.height, @tagName(self.format), @tagName(mode), count });
    }

    /// Returns null when the swapchain must be recreated.
    pub fn acquire(self: *Swapchain, ctx: *Context, signal: vk.Semaphore) !?u32 {
        const r = ctx.vkd.acquireNextImageKHR(ctx.device, self.handle, std.math.maxInt(u64), signal, .null) catch |err| switch (err) {
            error.OutOfDateKHR => return null,
            else => return err,
        };
        return r.image_index;
    }

    /// Returns false when the swapchain should be recreated.
    pub fn present(self: *Swapchain, ctx: *Context, queue: vk.Queue, index: u32) !bool {
        const result = ctx.vkd.queuePresentKHR(queue, &.{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&self.render_done[index]),
            .swapchain_count = 1,
            .p_swapchains = @ptrCast(&self.handle),
            .p_image_indices = @ptrCast(&index),
        }) catch |err| switch (err) {
            error.OutOfDateKHR => return false,
            else => return err,
        };
        return result != .suboptimal_khr;
    }
};
