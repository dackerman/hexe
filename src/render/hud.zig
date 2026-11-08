//! On-screen text HUD (per-pass GPU ms, frame ms, tool state). Text is
//! formatted on the CPU into a fixed character grid (no allocation), copied
//! into this frame slot's host-visible buffer, and drawn by
//! shaders/render/hud.frag with the embedded font.
//!
//! `printWorld` adds text anchored to a world pixel (floating signs, docs/07):
//! centered above the anchor, drawn at window resolution with a drop shadow
//! by shaders/render/hud_text.* so it stays crisp at any zoom.
const std = @import("std");
const gpu = @import("../gpu/gpu.zig");
const vk = gpu.vk;
const shaders = @import("shaders");
const font = @import("font.zig");
const world = @import("world.zig");
const frames_in_flight = @import("../sim/pipeline.zig").frames_in_flight;

pub const cols = 100;
pub const rows = 24;
/// World-anchored text: entries per frame and characters per entry.
pub const max_world_texts = 64;
pub const world_text_len = 64;
const max_glyphs = max_world_texts * world_text_len;

pub const WorldText = struct {
    x: i32,
    y: i32,
    len: u32,
    /// RGBA8, R in the low byte.
    color: u32,
    text: [world_text_len]u8,
};

/// Which color format a HUD draw targets (the swapchain or the RGBA8
/// capture image); a pipeline exists for each.
pub const Target = enum { present, capture };

pub const Hud = struct {
    pipelines: [2]vk.Pipeline,
    text_pipelines: [2]vk.Pipeline = @splat(.null),
    font_buffer: gpu.Buffer,
    text: [frames_in_flight]gpu.Buffer,
    glyphs: [frames_in_flight]gpu.Buffer = @splat(.{}),
    lines: [rows][cols]u8 = undefined,
    line_len: [rows]u32 = @splat(0),
    used: u32 = 0,
    scale: u32 = 2,
    world_texts: [max_world_texts]WorldText = undefined,
    world_used: u32 = 0,

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
            self.text_pipelines[i] = try gpu.pipelines.createGraphics(ctx, .{
                .vert = &shaders.render_hud_text_vert,
                .frag = &shaders.render_hud_text_frag,
                .color_format = format,
                .blend = .alpha,
            });
        }
        self.font_buffer = try gpu.Buffer.initSlotted(ctx, @sizeOf(@TypeOf(font.words)), .{}, .cpu_to_gpu);
        @memcpy(self.font_buffer.typed(u32), &font.words);
        for (&self.text) |*t| t.* = try gpu.Buffer.initSlotted(ctx, cols * rows * 4, .{}, .cpu_to_gpu);
        for (&self.glyphs) |*g| g.* = try gpu.Buffer.initSlotted(ctx, max_glyphs * 16, .{}, .cpu_to_gpu);
        return self;
    }

    pub fn deinit(self: *Hud, ctx: *gpu.Context) void {
        for (&self.glyphs) |*g| g.deinit(ctx);
        for (&self.text) |*t| t.deinit(ctx);
        self.font_buffer.deinit(ctx);
        for (&self.text_pipelines) |*p| {
            if (p.* != .null) gpu.pipelines.destroy(ctx, p.*);
            p.* = .null;
        }
        for (&self.pipelines) |*p| {
            if (p.* != .null) gpu.pipelines.destroy(ctx, p.*);
            p.* = .null;
        }
    }

    pub fn clear(self: *Hud) void {
        self.used = 0;
        self.world_used = 0;
    }

    /// Text anchored to world pixel (x, y): centered horizontally, bottom
    /// edge just above the anchor. Uppercase font; extra entries are dropped.
    pub fn printWorld(self: *Hud, x: i32, y: i32, comptime fmt: []const u8, args: anytype) void {
        self.printWorldColor(x, y, .{ 1.0, 0.92, 0.6, 1.0 }, fmt, args);
    }

    pub fn printWorldColor(self: *Hud, x: i32, y: i32, color: [4]f32, comptime fmt: []const u8, args: anytype) void {
        if (self.world_used >= max_world_texts) return;
        const e = &self.world_texts[self.world_used];
        const s = std.fmt.bufPrint(&e.text, fmt, args) catch e.text[0..];
        e.x = x;
        e.y = y;
        e.len = @intCast(s.len);
        var c: u32 = 0;
        for (color, 0..) |v, i| c |= @as(u32, @intFromFloat(std.math.clamp(v, 0, 1) * 255 + 0.5)) << @intCast(i * 8);
        e.color = c;
        self.world_used += 1;
    }

    /// Draw this frame's world-anchored text for `view`. Inside an active
    /// rendering scope on the graphics queue.
    pub fn recordWorld(self: *Hud, ctx: *const gpu.Context, cmd: vk.CommandBuffer, slot: u32, extent: vk.Extent2D, target: Target, view: world.View) void {
        if (self.world_used == 0) return;
        const words = self.glyphs[slot].typed(u32);
        const zoom: i32 = @intCast(@max(view.scale, 1));
        const ts: i32 = @intCast(self.scale);
        const W: i32 = @import("../sim/cell.zig").world_size;
        var n: u32 = 0;
        for (self.world_texts[0..self.world_used]) |e| {
            const rx = @mod(e.x - view.camera_x + W / 2, W) - W / 2;
            const ry = @mod(e.y - view.camera_y + W / 2, W) - W / 2;
            const width = @as(i32, @intCast(e.len)) * font.cell_w * ts;
            const ox = rx * zoom + @divFloor(zoom, 2) - @divFloor(width, 2);
            const oy = ry * zoom - (font.cell_h + 2) * ts;
            if (ox > @as(i32, @intCast(extent.width)) or oy > @as(i32, @intCast(extent.height)) or ox + width < 0 or oy + font.cell_h * ts < 0) continue;
            for (e.text[0..e.len], 0..) |ch, i| {
                if (n >= max_glyphs) break;
                if (ch == ' ') continue;
                words[n * 4 + 0] = @bitCast(ox + @as(i32, @intCast(i)) * font.cell_w * ts);
                words[n * 4 + 1] = @bitCast(oy);
                words[n * 4 + 2] = ch;
                words[n * 4 + 3] = e.color;
                n += 1;
            }
        }
        if (n == 0) return;
        world.setViewport(ctx, cmd, extent);
        ctx.vkd.cmdBindPipeline(cmd, .graphics, self.text_pipelines[@backingInt(target)]);
        gpu.pipelines.push(ctx, cmd, extern struct { glyph_slot: u32, font_slot: u32, scale: u32, pad: u32 = 0, extent: [2]f32 }{
            .glyph_slot = self.glyphs[slot].slot,
            .font_slot = self.font_buffer.slot,
            .scale = self.scale,
            .extent = .{ @floatFromInt(extent.width), @floatFromInt(extent.height) },
        });
        ctx.vkd.cmdDraw(cmd, n * 6, 1, 0, 0);
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
