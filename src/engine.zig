//! Frame orchestration: frames in flight, queues, timeline semaphore, tick
//! recording, presentation, capture and readback.
//!
//! Synchronization (docs/decisions/04-frame-sync.md): one timeline
//! semaphore orders all GPU work. Each frame's simulation submission (compute
//! queue) waits for the previous value and signals the next; the render
//! submission (graphics queue) waits for the simulation's value and signals
//! the next. The CPU waits for a frame slot's last value before reusing its
//! command buffers, upload regions and timestamp queries, so up to
//! `frames_in_flight` frames are recorded ahead of the GPU.
const std = @import("std");
const gpu = @import("gpu/gpu.zig");
const vk = gpu.vk;
const sim_pipeline = @import("sim/pipeline.zig");
const Pipeline = sim_pipeline.Pipeline;
const Frame = sim_pipeline.Frame;
const frames_in_flight = sim_pipeline.frames_in_flight;
const max_ticks_per_frame = sim_pipeline.max_ticks_per_frame;
const cell = @import("sim/cell.zig");
const commands = @import("sim/commands.zig");
const materials = @import("sim/materials.zig");
const scenes = @import("sim/scenes.zig");
const readback = @import("sim/readback.zig");
const WorldPass = @import("render/world.zig").WorldPass;
const View = @import("render/world.zig").View;
const Hud = @import("render/hud.zig").Hud;
const png = @import("util/png.zig");
const Window = @import("platform/window.zig").Window;
const Profile = @import("profile.zig").Profile;

const log = std.log.scoped(.engine);

pub const Options = struct {
    /// Null = headless: no window, no swapchain.
    window: ?*Window = null,
    vsync: bool = true,
    validation: bool = @import("builtin").mode == .debug,
    pipeline: sim_pipeline.Config = .{},
    table: *const materials.Table,
};

/// What drives the ticks of one frame.
pub const TickSource = struct {
    scene: scenes.Scene = .empty,
    seed: u32 = 1,
    /// Extra commands (input) applied in the frame's first tick.
    extra: []const commands.CommandGpu = &.{},
};

/// Results of the most recently completed frame.
pub const FrameStats = struct {
    timings: gpu.timestamps.Timings = .{},
    ticks: u32 = 0,
    first_tick: u32 = 0,
    /// Active tiles in the last tick of that frame.
    active_tiles: u32 = 0,
    commands: u32 = 0,
    dropped_commands: u32 = 0,
};

const Slot = struct {
    sim_pool: vk.CommandPool,
    sim_cmd: vk.CommandBuffer,
    render_pool: vk.CommandPool,
    render_cmd: vk.CommandBuffer,
    recorder: gpu.timestamps.Recorder,
    acquire: vk.Semaphore,
    /// Host-visible: active tile count per tick of the frame.
    stats: gpu.Buffer,
    done_value: u64 = 0,
    pending: bool = false,
    ticks: u32 = 0,
    first_tick: u32 = 0,
    commands: u32 = 0,
    dropped: u32 = 0,
};

pub const Engine = struct {
    gpa: std.mem.Allocator,
    ctx: gpu.Context,
    pipeline: Pipeline,
    names: gpu.timestamps.Names = .{},
    slots: [frames_in_flight]Slot,
    timeline: vk.Semaphore,
    timeline_value: u64 = 0,
    frame_index: u64 = 0,
    tick: u32 = 0,
    list: commands.CommandList = .{},
    window: ?*Window,
    swapchain: ?gpu.Swapchain = null,
    world_pass: ?WorldPass = null,
    /// Text state and pipelines for the swapchain and the capture image.
    hud: Hud,
    capture_image: gpu.Image,
    capture_pass: WorldPass,
    staging: gpu.Buffer,
    last: FrameStats = .{},
    /// Receives every completed frame's stats (HUD smoothing, --profile, bench).
    profile: ?*Profile = null,

    pub const capture_format: vk.Format = .r8g8b8a8_unorm;

    /// In place; `self` must stay at this address.
    pub fn init(self: *Engine, gpa: std.mem.Allocator, opts: Options) !void {
        self.* = .{
            .gpa = gpa,
            .ctx = undefined,
            .pipeline = undefined,
            .slots = undefined,
            .timeline = .null,
            .window = opts.window,
            .capture_image = .{},
            .capture_pass = undefined,
            .staging = .{},
            .hud = undefined,
        };
        try self.ctx.init(gpa, .{
            .validation = opts.validation,
            .window_extensions = if (opts.window != null) Window.instanceExtensions() else &.{},
            .surface = if (opts.window) |w| .{ .context = w, .create = Window.createSurface } else null,
        });
        errdefer self.ctx.deinit();
        const ctx = &self.ctx;

        try self.pipeline.init(ctx, opts.pipeline, gpa, opts.table);
        errdefer self.pipeline.deinit();

        const timeline_info = vk.SemaphoreTypeCreateInfo{ .semaphore_type = .timeline, .initial_value = 0 };
        self.timeline = try ctx.vkd.createSemaphore(ctx.device, &.{ .p_next = &timeline_info }, null);
        errdefer ctx.vkd.destroySemaphore(ctx.device, self.timeline, null);

        var made: usize = 0;
        errdefer for (self.slots[0..made]) |*s| destroySlot(ctx, s);
        for (&self.slots) |*s| {
            s.* = try createSlot(ctx, &self.names);
            made += 1;
        }

        self.capture_image = try gpu.Image.init(ctx, .{
            .width = cell.world_size,
            .height = cell.world_size,
            .format = capture_format,
            .usage = .{ .color_attachment = true, .transfer_src = true },
        });
        errdefer self.capture_image.deinit(ctx);
        self.capture_pass = try WorldPass.init(ctx, capture_format);
        errdefer self.capture_pass.deinit(ctx);
        self.staging = try gpu.Buffer.init(ctx, cell.world_size * cell.world_size * 4, .{ .transfer_dst = true, .transfer_src = true }, .gpu_to_cpu);
        errdefer self.staging.deinit(ctx);

        var present_format = capture_format;
        if (opts.window) |w| {
            const width, const height = w.pixelSize();
            self.swapchain = try gpu.Swapchain.init(ctx, width, height, opts.vsync);
            self.world_pass = try WorldPass.init(ctx, self.swapchain.?.format);
            present_format = self.swapchain.?.format;
        }
        self.hud = try Hud.init(ctx, present_format, capture_format);
    }

    pub fn deinit(self: *Engine) void {
        const ctx = &self.ctx;
        ctx.waitIdle();
        self.hud.deinit(ctx);
        if (self.world_pass) |*p| p.deinit(ctx);
        if (self.swapchain) |*s| s.deinit(ctx);
        self.staging.deinit(ctx);
        self.capture_pass.deinit(ctx);
        self.capture_image.deinit(ctx);
        for (&self.slots) |*s| destroySlot(ctx, s);
        ctx.vkd.destroySemaphore(ctx.device, self.timeline, null);
        self.pipeline.deinit();
        ctx.deinit();
    }

    fn createSlot(ctx: *gpu.Context, names: *gpu.timestamps.Names) !Slot {
        var s: Slot = undefined;
        s.sim_pool = try ctx.vkd.createCommandPool(ctx.device, &.{ .queue_family_index = ctx.compute.family }, null);
        errdefer ctx.vkd.destroyCommandPool(ctx.device, s.sim_pool, null);
        s.render_pool = try ctx.vkd.createCommandPool(ctx.device, &.{ .queue_family_index = ctx.graphics.family }, null);
        errdefer ctx.vkd.destroyCommandPool(ctx.device, s.render_pool, null);
        try ctx.vkd.allocateCommandBuffers(ctx.device, &.{ .command_pool = s.sim_pool, .level = .primary, .command_buffer_count = 1 }, @ptrCast(&s.sim_cmd));
        try ctx.vkd.allocateCommandBuffers(ctx.device, &.{ .command_pool = s.render_pool, .level = .primary, .command_buffer_count = 1 }, @ptrCast(&s.render_cmd));
        s.recorder = try gpu.timestamps.Recorder.init(ctx, names);
        errdefer s.recorder.deinit(ctx);
        s.acquire = try ctx.vkd.createSemaphore(ctx.device, &.{}, null);
        errdefer ctx.vkd.destroySemaphore(ctx.device, s.acquire, null);
        s.stats = try gpu.Buffer.init(ctx, max_ticks_per_frame * 4, .{ .transfer_dst = true }, .gpu_to_cpu);
        s.done_value = 0;
        s.pending = false;
        s.ticks = 0;
        s.first_tick = 0;
        s.commands = 0;
        s.dropped = 0;
        return s;
    }

    fn destroySlot(ctx: *gpu.Context, s: *Slot) void {
        s.stats.deinit(ctx);
        ctx.vkd.destroySemaphore(ctx.device, s.acquire, null);
        s.recorder.deinit(ctx);
        ctx.vkd.destroyCommandPool(ctx.device, s.render_pool, null);
        ctx.vkd.destroyCommandPool(ctx.device, s.sim_pool, null);
    }

    fn waitValue(self: *Engine, value: u64) !void {
        if (value == 0) return;
        _ = try self.ctx.vkd.waitSemaphores(self.ctx.device, &.{
            .semaphore_count = 1,
            .p_semaphores = @ptrCast(&self.timeline),
            .p_values = @ptrCast(&value),
        }, std.math.maxInt(u64));
    }

    /// Wait for every submitted frame and fold in its results.
    pub fn finish(self: *Engine) !void {
        for (0..frames_in_flight) |_| {
            const slot = &self.slots[self.frame_index % frames_in_flight];
            try self.waitValue(slot.done_value);
            try self.collect(slot);
            self.frame_index += 1;
        }
    }

    fn collect(self: *Engine, slot: *Slot) !void {
        if (!slot.pending) return;
        slot.pending = false;
        var stats: FrameStats = .{ .ticks = slot.ticks, .first_tick = slot.first_tick, .commands = slot.commands, .dropped_commands = slot.dropped };
        try slot.recorder.collect(&self.ctx, &stats.timings);
        if (slot.ticks > 0) stats.active_tiles = slot.stats.typed(u32)[slot.ticks - 1];
        self.last = stats;
        if (self.profile) |p| p.record(&self.last, &self.names);
    }

    /// Record and submit `ticks` simulation ticks (0..max_ticks_per_frame)
    /// and, with a window and a view, render and present. Returns after
    /// submission; results of an earlier frame are in `last`.
    pub fn frame(self: *Engine, ticks: u32, src: TickSource, view: ?View) !void {
        std.debug.assert(ticks <= max_ticks_per_frame);
        const ctx = &self.ctx;
        const slot_index: u32 = @intCast(self.frame_index % frames_in_flight);
        const slot = &self.slots[slot_index];
        try self.waitValue(slot.done_value);
        try self.collect(slot);
        try ctx.vkd.resetCommandPool(ctx.device, slot.sim_pool, .{});
        try ctx.vkd.resetCommandPool(ctx.device, slot.render_pool, .{});
        slot.ticks = ticks;
        slot.first_tick = self.tick;
        slot.commands = 0;
        slot.dropped = 0;

        if (ticks > 0) {
            const cmd = slot.sim_cmd;
            try ctx.vkd.beginCommandBuffer(cmd, &.{ .flags = .{ .one_time_submit = true } });
            ctx.descriptors.bind(ctx, cmd, .compute);
            for (0..ticks) |k| {
                self.list.begin(self.tick);
                scenes.emit(src.scene, self.tick, src.seed, &self.list);
                if (k == 0) for (src.extra) |c| self.list.push(c);
                slot.commands += self.list.len;
                slot.dropped += self.list.dropped;
                const base = self.pipeline.applier.upload(slot_index, @intCast(k), &self.list);
                var f: Frame = .{
                    .ctx = ctx,
                    .cmd = cmd,
                    .tick = self.tick,
                    .slot = slot_index,
                    .shared = &self.pipeline.shared,
                    .timer = &slot.recorder,
                    .commands = self.list.slice(),
                    .command_base = base,
                    .sleep = self.pipeline.config.sleep,
                };
                self.pipeline.recordTick(&f);
                // Active tile count for the HUD and bench.
                gpu.memory.memoryBarrier(ctx, cmd, .{ .compute_shader = true }, .{ .shader_storage_write = true }, .{ .all_transfer = true }, .{ .transfer_read = true });
                ctx.vkd.cmdCopyBuffer(cmd, self.pipeline.shared.tile_list.handle, slot.stats.handle, &.{.{ .src_offset = 0, .dst_offset = k * 4, .size = 4 }});
                self.tick +%= 1;
            }
            try ctx.vkd.endCommandBuffer(cmd);
            self.timeline_value += 1;
            try self.submit(ctx.compute.handle, cmd, &.{.{ .sem = self.timeline, .value = self.timeline_value - 1, .stage = .{ .all_commands = true } }}, &.{.{ .sem = self.timeline, .value = self.timeline_value }});
        }

        if (view != null and self.swapchain != null) try self.render(slot, slot_index, view.?);
        slot.done_value = self.timeline_value;
        slot.pending = true;
        self.frame_index += 1;
    }

    const Wait = struct { sem: vk.Semaphore, value: u64 = 0, stage: vk.PipelineStageFlags2 };
    const Signal = struct { sem: vk.Semaphore, value: u64 = 0 };

    fn submit(self: *Engine, queue: vk.Queue, cmd: vk.CommandBuffer, waits: []const Wait, signals: []const Signal) !void {
        var wait_infos: [4]vk.SemaphoreSubmitInfo = undefined;
        var nw: u32 = 0;
        for (waits) |w| {
            if (w.sem == self.timeline and w.value == 0) continue;
            wait_infos[nw] = .{ .semaphore = w.sem, .value = w.value, .stage_mask = w.stage, .device_index = 0 };
            nw += 1;
        }
        var signal_infos: [4]vk.SemaphoreSubmitInfo = undefined;
        for (signals, 0..) |s, i| signal_infos[i] = .{ .semaphore = s.sem, .value = s.value, .stage_mask = .{ .all_commands = true }, .device_index = 0 };
        const cmd_info = vk.CommandBufferSubmitInfo{ .command_buffer = cmd, .device_mask = 0 };
        try self.ctx.vkd.queueSubmit2(queue, &.{.{
            .wait_semaphore_info_count = nw,
            .p_wait_semaphore_infos = &wait_infos,
            .command_buffer_info_count = 1,
            .p_command_buffer_infos = @ptrCast(&cmd_info),
            .signal_semaphore_info_count = @intCast(signals.len),
            .p_signal_semaphore_infos = &signal_infos,
        }}, .null);
    }

    fn render(self: *Engine, slot: *Slot, slot_index: u32, view: View) !void {
        const ctx = &self.ctx;
        const sc = &self.swapchain.?;
        if (self.window.?.input.resized) try self.resize();
        const image_index = (try sc.acquire(ctx, slot.acquire)) orelse {
            try self.resize();
            return;
        };
        const cmd = slot.render_cmd;
        try ctx.vkd.beginCommandBuffer(cmd, &.{ .flags = .{ .one_time_submit = true } });
        ctx.descriptors.bind(ctx, cmd, .graphics);
        const image = sc.images[image_index];
        gpu.memory.imageBarrier(ctx, cmd, image, .undefined, .color_attachment_optimal, .{ .color_attachment_output = true }, .{}, .{ .color_attachment_output = true }, .{ .color_attachment_write = true });
        const attachment = vk.RenderingAttachmentInfo{
            .image_view = sc.views[image_index],
            .image_layout = .color_attachment_optimal,
            .resolve_mode = .{},
            .resolve_image_layout = .undefined,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{ .color = .{ .float_32 = .{ 0, 0, 0, 1 } } },
        };
        ctx.vkd.cmdBeginRendering(cmd, &.{
            .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = sc.extent },
            .layer_count = 1,
            .view_mask = 0,
            .color_attachment_count = 1,
            .p_color_attachments = @ptrCast(&attachment),
        });
        const t_world = slot.recorder.begin(ctx, cmd, "render");
        self.world_pass.?.record(ctx, cmd, sc.extent, view);
        slot.recorder.end(ctx, cmd, t_world);
        const t_hud = slot.recorder.begin(ctx, cmd, "hud");
        self.hud.record(ctx, cmd, slot_index, sc.extent, .present);
        slot.recorder.end(ctx, cmd, t_hud);
        ctx.vkd.cmdEndRendering(cmd);
        gpu.memory.imageBarrier(ctx, cmd, image, .color_attachment_optimal, .present_src_khr, .{ .color_attachment_output = true }, .{ .color_attachment_write = true }, .{}, .{});
        try ctx.vkd.endCommandBuffer(cmd);

        self.timeline_value += 1;
        try self.submit(ctx.graphics.handle, cmd, &.{
            .{ .sem = self.timeline, .value = self.timeline_value - 1, .stage = .{ .fragment_shader = true } },
            .{ .sem = slot.acquire, .stage = .{ .color_attachment_output = true } },
        }, &.{
            .{ .sem = self.timeline, .value = self.timeline_value },
            .{ .sem = sc.render_done[image_index] },
        });
        if (!try sc.present(ctx, ctx.graphics.handle, image_index)) try self.resize();
    }

    fn resize(self: *Engine) !void {
        const width, const height = self.window.?.pixelSize();
        try self.swapchain.?.recreate(&self.ctx, width, height);
    }

    /// Copy the cell image into `out` (world_size^2 words). Waits for the GPU.
    pub fn readbackCells(self: *Engine, out: []u32) !void {
        try self.finish();
        try readback.readbackCells(&self.ctx, &self.pipeline.shared, &self.staging, out);
    }

    /// Render the whole world 1:1 through world.frag into the capture image
    /// and return its RGBA8 pixels (valid until the next capture/readback).
    pub fn captureWorld(self: *Engine) ![]const u8 {
        return self.captureView(.{ .show_liquid = self.pipeline.config.liquid_overlay }, .{ .width = cell.world_size, .height = cell.world_size }, false);
    }

    /// Render `view` (and the HUD) as the window would show it, into the
    /// top-left `extent` of the capture image; returns world_size-strided
    /// RGBA8 rows.
    pub fn captureView(self: *Engine, view: View, extent: vk.Extent2D, hud: bool) ![]const u8 {
        std.debug.assert(extent.width <= cell.world_size and extent.height <= cell.world_size);
        try self.finish();
        try self.ctx.runOnce(.graphics, recordCapture, .{ self, view, extent, hud });
        return self.staging.bytes()[0 .. cell.world_size * cell.world_size * 4];
    }

    fn recordCapture(cmd: vk.CommandBuffer, self: *Engine, view: View, extent: vk.Extent2D, hud: bool) void {
        const ctx = &self.ctx;
        gpu.memory.memoryBarrier(ctx, cmd, .{ .all_commands = true }, .{ .memory_write = true }, .{ .all_commands = true }, .{ .memory_read = true });
        gpu.memory.imageBarrier(ctx, cmd, self.capture_image.handle, .undefined, .color_attachment_optimal, .{}, .{}, .{ .color_attachment_output = true }, .{ .color_attachment_write = true });
        const attachment = vk.RenderingAttachmentInfo{
            .image_view = self.capture_image.view,
            .image_layout = .color_attachment_optimal,
            .resolve_mode = .{},
            .resolve_image_layout = .undefined,
            .load_op = .dont_care,
            .store_op = .store,
            .clear_value = .{ .color = .{ .float_32 = .{ 0, 0, 0, 1 } } },
        };
        ctx.vkd.cmdBeginRendering(cmd, &.{
            .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = extent },
            .layer_count = 1,
            .view_mask = 0,
            .color_attachment_count = 1,
            .p_color_attachments = @ptrCast(&attachment),
        });
        self.capture_pass.record(ctx, cmd, extent, view);
        if (hud) self.hud.record(ctx, cmd, 0, extent, .capture);
        ctx.vkd.cmdEndRendering(cmd);
        gpu.memory.imageBarrier(ctx, cmd, self.capture_image.handle, .color_attachment_optimal, .transfer_src_optimal, .{ .color_attachment_output = true }, .{ .color_attachment_write = true }, .{ .all_transfer = true }, .{ .transfer_read = true });
        ctx.vkd.cmdCopyImageToBuffer(cmd, self.capture_image.handle, .transfer_src_optimal, self.staging.handle, &.{.{
            .buffer_offset = 0,
            .buffer_row_length = cell.world_size,
            .buffer_image_height = 0,
            .image_subresource = .{ .aspect_mask = .{ .color = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
            .image_offset = .{ .x = 0, .y = 0, .z = 0 },
            .image_extent = .{ .width = extent.width, .height = extent.height, .depth = 1 },
        }});
        gpu.memory.memoryBarrier(ctx, cmd, .{ .all_transfer = true }, .{ .transfer_write = true }, .{ .host = true }, .{ .host_read = true });
    }

    /// Capture the world and write it as PNG, optionally cropped.
    pub fn screenshot(self: *Engine, io: std.Io, path: []const u8, crop: ?Crop) !void {
        try self.writePng(io, path, try self.captureWorld(), crop);
    }

    /// Capture `view` + HUD at `width` x `height` (as the window shows it)
    /// and write it as PNG.
    pub fn screenshotView(self: *Engine, io: std.Io, path: []const u8, view: View, width: u32, height: u32) !void {
        const w = @min(width, cell.world_size);
        const h = @min(height, cell.world_size);
        const rgba = try self.captureView(view, .{ .width = w, .height = h }, true);
        try self.writePng(io, path, rgba, .{ .x = 0, .y = 0, .w = w, .h = h });
    }

    fn writePng(self: *Engine, io: std.Io, path: []const u8, rgba: []const u8, crop: ?Crop) !void {
        const full = Crop{ .x = 0, .y = 0, .w = cell.world_size, .h = cell.world_size };
        const r = crop orelse full;
        if (r.w == 0 or r.h == 0 or r.x + r.w > cell.world_size or r.y + r.h > cell.world_size) return error.BadCrop;
        const pixels = try self.gpa.alloc(u8, @as(usize, r.w) * r.h * 4);
        defer self.gpa.free(pixels);
        for (0..r.h) |row| {
            const src = rgba[((r.y + row) * cell.world_size + r.x) * 4 ..][0 .. r.w * 4];
            @memcpy(pixels[row * r.w * 4 ..][0 .. r.w * 4], src);
        }
        const out = try self.gpa.alloc(u8, png.encodedSize(r.w, r.h));
        defer self.gpa.free(out);
        const encoded = png.encode(out, r.w, r.h, pixels);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = encoded });
        log.info("wrote {s} ({d}x{d}, tick {d})", .{ path, r.w, r.h, self.tick });
    }
};

pub const Crop = struct { x: u32, y: u32, w: u32, h: u32 };
