//! The camera (`View`) and viewport helper shared by the render passes. The
//! world pass itself is shaders/render/world.frag, recorded by
//! src/render/renderer.zig into the world-resolution scene image, which
//! composite.frag integer-upscales to the window.
const gpu = @import("../gpu/gpu.zig");
const vk = gpu.vk;

pub const View = struct {
    /// World pixel at the viewport's top-left corner (wraps on the torus).
    camera_x: i32 = 0,
    camera_y: i32 = 0,
    /// Integer zoom, >= 1: one world pixel covers scale x scale window pixels.
    scale: u32 = 1,

    /// World pixel under window pixel (x, y), unwrapped.
    pub fn toWorld(self: View, x: f32, y: f32) [2]i32 {
        const s: i32 = @intCast(@max(self.scale, 1));
        return .{ self.camera_x + @divFloor(@as(i32, @intFromFloat(x)), s), self.camera_y + @divFloor(@as(i32, @intFromFloat(y)), s) };
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
