//! On-screen text HUD (per-pass GPU ms, frame ms, tool state). Text is
//! formatted on the CPU into a fixed character grid (no allocation), copied
//! into this frame slot's host-visible buffer, and drawn by
//! shaders/render/hud.frag with the embedded font.
const std = @import("std");
const gpu = @import("../gpu/gpu.zig");
const vk = gpu.vk;
const shaders = @import("shaders");
const font = @import("font.zig");
const world = @import("world.zig");
const frames_in_flight = @import("../sim/pipeline.zig").frames_in_flight;

pub const cols = 100;
pub const rows = 24;

/// Which color format a HUD draw targets (the swapchain or the RGBA8
/// capture image); a pipeline exists for each.
pub const Target = enum { present, capture };

pub const Hud = struct {
    pipelines: [2]vk.Pipeline,
    font_buffer: gpu.Buffer,
    text: [frames_in_flight]gpu.Buffer,
    lines: [rows][cols]u8 = undefined,
    line_len: [rows]u32 = @splat(0),
    used: u32 = 0,
    scale: u32 = 2,

    pub fn init(ctx: *gpu.Context, present_format: vk.Format, capture_format: vk.Format) !Hud {
        var self: Hud = .{ .pipelines = @splat(.null), .font_buffer = .{}, .text = @splat(.{}) };
        errdefer self.deinit(ctx);
        for ([2]vk.Format{ present_format, capture_format }, 0..) |format, i| {
            self.pipelines[i] = try gpu.pipelines.createGraphics(ctx, .{
                .vert = &shaders.render_fullscreen_vert,
                .frag = &shaders.render_hud_frag,
                .color_format = format,
                .blend = .alpha,
            });
        }
        self.font_buffer = try gpu.Buffer.initSlotted(ctx, @sizeOf(@TypeOf(font.words)), .{}, .cpu_to_gpu);
        @memcpy(self.font_buffer.typed(u32), &font.words);
        for (&self.text) |*t| t.* = try gpu.Buffer.initSlotted(ctx, cols * rows * 4, .{}, .cpu_to_gpu);
        return self;
    }

    pub fn deinit(self: *Hud, ctx: *gpu.Context) void {
        for (&self.text) |*t| t.deinit(ctx);
        self.font_buffer.deinit(ctx);
        for (&self.pipelines) |*p| {
            if (p.* != .null) gpu.pipelines.destroy(ctx, p.*);
            p.* = .null;
        }
    }

    pub fn clear(self: *Hud) void {
        self.used = 0;
    }

    /// Append one line (truncated to `cols`; extra lines are dropped).
    pub fn print(self: *Hud, comptime fmt: []const u8, args: anytype) void {
        if (self.used >= rows) return;
        const line = &self.lines[self.used];
        const s = std.fmt.bufPrint(line, fmt, args) catch line[0..];
        self.line_len[self.used] = @intCast(s.len);
        self.used += 1;
    }

    /// Upload this frame's text into `slot`'s buffer and draw it. Inside an
    /// active rendering scope on the graphics queue.
    pub fn record(self: *Hud, ctx: *const gpu.Context, cmd: vk.CommandBuffer, slot: u32, extent: vk.Extent2D, target: Target) void {
        if (self.used == 0) return;
        var width: u32 = 0;
        for (self.line_len[0..self.used]) |l| width = @max(width, l);
        width += 1;
        const words = self.text[slot].typed(u32);
        for (0..self.used) |r| {
            for (0..width) |c| {
                words[r * width + c] = if (c < self.line_len[r]) self.lines[r][c] else ' ';
            }
        }
        world.setViewport(ctx, cmd, extent);
        ctx.vkd.cmdBindPipeline(cmd, .graphics, self.pipelines[@backingInt(target)]);
        gpu.pipelines.push(ctx, cmd, extern struct {
            ox: i32,
            oy: i32,
            cols: u32,
            rows: u32,
            scale: u32,
            text_slot: u32,
            font_slot: u32,
            pad: u32 = 0,
            fg: [4]f32,
            bg: [4]f32,
        }{
            .ox = 8,
            .oy = 8,
            .cols = width,
            .rows = self.used,
            .scale = self.scale,
            .text_slot = self.text[slot].slot,
            .font_slot = self.font_buffer.slot,
            .fg = .{ 0.92, 0.95, 0.85, 1.0 },
            .bg = .{ 0.0, 0.0, 0.0, 0.55 },
        });
        ctx.vkd.cmdDraw(cmd, 3, 1, 0, 0);
    }
};
