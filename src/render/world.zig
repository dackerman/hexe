//! World pass: shaders/render/world.frag over a fullscreen triangle. Maps
//! cells to material ramp colors with integer upscale; records inside an
//! active dynamic-rendering scope set up by the caller.
const std = @import("std");
const gpu = @import("../gpu/gpu.zig");
const vk = gpu.vk;
const shaders = @import("shaders");

pub const View = struct {
    /// World pixel at the viewport's top-left corner (wraps on the torus).
    camera_x: i32 = 0,
    camera_y: i32 = 0,
    /// Integer zoom, >= 1.
    scale: u32 = 1,
    /// Tint tiles on this tick's active list.
    show_tiles: bool = false,
    /// Liquid solver overlay: awake particles cyan (ballistic yellow),
    /// sleeping solver liquid dimmed (needs Config.liquid_overlay).
    show_liquid: bool = false,
};

pub const WorldPass = struct {
    pipeline: vk.Pipeline,
    format: vk.Format,

    pub fn init(ctx: *gpu.Context, format: vk.Format) !WorldPass {
        return .{
            .pipeline = try gpu.pipelines.createGraphics(ctx, .{
                .vert = &shaders.render_fullscreen_vert,
                .frag = &shaders.render_world_frag,
                .color_format = format,
            }),
            .format = format,
        };
    }

    pub fn deinit(self: *WorldPass, ctx: *gpu.Context) void {
        gpu.pipelines.destroy(ctx, self.pipeline);
    }

    pub fn record(self: *const WorldPass, ctx: *const gpu.Context, cmd: vk.CommandBuffer, extent: vk.Extent2D, view: View) void {
        setViewport(ctx, cmd, extent);
        ctx.vkd.cmdBindPipeline(cmd, .graphics, self.pipeline);
        gpu.pipelines.push(ctx, cmd, extern struct { cx: i32, cy: i32, ox: i32, oy: i32, scale: u32, flags: u32 }{
            .cx = view.camera_x,
            .cy = view.camera_y,
            .ox = 0,
            .oy = 0,
            .scale = @max(view.scale, 1),
            .flags = @as(u32, @intFromBool(view.show_tiles)) | (@as(u32, @intFromBool(view.show_liquid)) << 1),
        });
        ctx.vkd.cmdDraw(cmd, 3, 1, 0, 0);
    }
};

pub fn setViewport(ctx: *const gpu.Context, cmd: vk.CommandBuffer, extent: vk.Extent2D) void {
    ctx.vkd.cmdSetViewport(cmd, 0, &.{.{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(extent.width),
        .height = @floatFromInt(extent.height),
        .min_depth = 0,
        .max_depth = 1,
    }});
    ctx.vkd.cmdSetScissor(cmd, 0, &.{.{ .offset = .{ .x = 0, .y = 0 }, .extent = extent }});
}
