//! Frame orchestration: frames in flight, queues, timeline semaphore, tick
//! recording, presentation, capture and readback.
//!
//! Synchronization (docs/decisions/23-frame-sync.md, revised by
//! docs/decisions/104-render-snapshot-overlap.md): two timeline semaphores,
//! one per queue. The simulation (compute queue) ends each frame's ticks
//! with a copy of what rendering reads into one of two snapshots and signals
//! the sim timeline; the render (graphics queue) waits for the sim value that
//! wrote its snapshot and signals the render timeline. The next frame's
//! simulation waits only for the render that last read the snapshot it is
//! about to overwrite, so render N overlaps sim N+1. The CPU waits for a
//! frame slot's last values before reusing its command buffers, upload
//! regions and timestamp queries, so up to `frames_in_flight` frames are
//! recorded ahead of the GPU.
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
const bodies_scenes = @import("sim/bodies_scenes.zig");
const readback = @import("sim/readback.zig");
const View = @import("render/world.zig").View;
const Hud = @import("render/hud.zig").Hud;
const Renderer = @import("render/renderer.zig").Renderer;
const snapshot_count = @import("render/renderer.zig").snapshot_count;
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
    /// The loaded materials: tables to upload (the data layer's packing),
    /// names for the ids scenes paint with, the bodies layer's roles and the
    /// renderer's art overrides.
    library: *const materials.Library,
    /// Let the render of frame N overlap the simulation of frame N+1
    /// (render snapshots). False reproduces the strictly serial chain.
    overlap: bool = true,
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
    /// Sim and render timeline values of this slot's last submissions.
    done_sim: u64 = 0,
    done_render: u64 = 0,
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
    sim_timeline: vk.Semaphore,
    sim_value: u64 = 0,
    render_timeline: vk.Semaphore,
    render_value: u64 = 0,
    overlap: bool = true,
    /// Snapshot ring: the sim value that wrote each snapshot, the render
    /// value that last read it, and the newest one.
    snap_written: [snapshot_count]u64 = @splat(0),
    snap_read: [snapshot_count]u64 = @splat(0),
    snap_latest: ?u32 = null,
    /// A render that read the live cell image (no snapshot yet); the next
    /// sim must wait for it.
    live_read: u64 = 0,
    frame_index: u64 = 0,
    tick: u32 = 0,
    list: commands.CommandList = .{},
    window: ?*Window,
    swapchain: ?gpu.Swapchain = null,
    /// World, lighting, sprites, post; `renderer.settings` holds the modes.
    renderer: Renderer,
    /// Text state and pipelines for the swapchain and the capture image.
    hud: Hud,
    capture_image: gpu.Image,
    staging: gpu.Buffer,
    /// Headless `frame` renders into the capture image at this size.
    headless_extent: vk.Extent2D = .{ .width = 1920, .height = 1080 },
    last: FrameStats = .{},
    /// Receives every completed frame's stats (HUD smoothing, --profile, bench).
    profile: ?*Profile = null,
    /// Material ids for scenes (`TickSource.scene`).
    ids: materials.Ids = .{},
    /// The uploaded tables (owned by the caller's `materials.Library`).
    tables: *const materials.Tables,

    pub const capture_format: vk.Format = .r8g8b8a8_unorm;

    /// In place; `self` must stay at this address.
    pub fn init(self: *Engine, gpa: std.mem.Allocator, opts: Options) !void {
        self.* = .{
            .gpa = gpa,
            .ctx = undefined,
            .pipeline = undefined,
            .slots = undefined,
            .sim_timeline = .null,
            .render_timeline = .null,
            .overlap = opts.overlap,
            .window = opts.window,
            .capture_image = .{},
            .staging = .{},
            .hud = undefined,
            .renderer = undefined,
            .ids = opts.library.ids(),
            .tables = opts.library.tables,
        };
        try self.ctx.init(gpa, .{
            .validation = opts.validation,
            .window_extensions = if (opts.window != null) Window.instanceExtensions() else &.{},
            .surface = if (opts.window) |w| .{ .context = w, .create = Window.createSurface } else null,
        });
        errdefer self.ctx.deinit();
        const ctx = &self.ctx;

        try self.pipeline.init(ctx, opts.pipeline, gpa, opts.library);
        errdefer self.pipeline.deinit();

        const timeline_info = vk.SemaphoreTypeCreateInfo{ .semaphore_type = .timeline, .initial_value = 0 };
        self.sim_timeline = try ctx.vkd.createSemaphore(ctx.device, &.{ .p_next = &timeline_info }, null);
        errdefer ctx.vkd.destroySemaphore(ctx.device, self.sim_timeline, null);
        self.render_timeline = try ctx.vkd.createSemaphore(ctx.device, &.{ .p_next = &timeline_info }, null);
        errdefer ctx.vkd.destroySemaphore(ctx.device, self.render_timeline, null);

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
        self.staging = try gpu.Buffer.init(ctx, cell.world_size * cell.world_size * 4, .{ .transfer_dst = true, .transfer_src = true }, .gpu_to_cpu);
        errdefer self.staging.deinit(ctx);

        var present_format = capture_format;
        if (opts.window) |w| {
            const width, const height = w.pixelSize();
            self.swapchain = try gpu.Swapchain.init(ctx, width, height, opts.vsync);
            present_format = self.swapchain.?.format;
        }
        errdefer if (self.swapchain) |*sc| sc.deinit(ctx);
        try self.renderer.init(ctx, opts.library, present_format, capture_format);
        errdefer self.renderer.deinit();
        self.hud = try Hud.init(ctx, present_format, capture_format);
    }

    pub fn deinit(self: *Engine) void {
        const ctx = &self.ctx;
        ctx.waitIdle();
        self.hud.deinit(ctx);
        self.renderer.deinit();
        if (self.swapchain) |*s| s.deinit(ctx);
        self.staging.deinit(ctx);
        self.capture_image.deinit(ctx);
        for (&self.slots) |*s| destroySlot(ctx, s);
        ctx.vkd.destroySemaphore(ctx.device, self.render_timeline, null);
        ctx.vkd.destroySemaphore(ctx.device, self.sim_timeline, null);
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
        s.done_sim = 0;
        s.done_render = 0;
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

    fn waitValue(self: *Engine, sem: vk.Semaphore, value: u64) !void {
        if (value == 0) return;
        _ = try self.ctx.vkd.waitSemaphores(self.ctx.device, &.{
            .semaphore_count = 1,
            .p_semaphores = @ptrCast(&sem),
            .p_values = @ptrCast(&value),
        }, std.math.maxInt(u64));
    }

    fn waitSlot(self: *Engine, slot: *const Slot) !void {
        try self.waitValue(self.sim_timeline, slot.done_sim);
        try self.waitValue(self.render_timeline, slot.done_render);
    }

    /// Wait for every submitted frame and fold in its results.
    pub fn finish(self: *Engine) !void {
        for (0..frames_in_flight) |_| {
            const slot = &self.slots[self.frame_index % frames_in_flight];
            try self.waitSlot(slot);
            try self.collect(slot);
            self.frame_index += 1;
        }
    }

    fn slotIndex(self: *const Engine, slot: *const Slot) u32 {
        return @intCast((@intFromPtr(slot) - @intFromPtr(&self.slots[0])) / @sizeOf(Slot));
    }

    fn collect(self: *Engine, slot: *Slot) !void {
        if (!slot.pending) return;
        slot.pending = false;
        const index = self.slotIndex(slot);
        self.pipeline.readback.collect(index, slot.first_tick, slot.ticks);
        self.pipeline.air.collect(index);
        var stats: FrameStats = .{ .ticks = slot.ticks, .first_tick = slot.first_tick, .commands = slot.commands, .dropped_commands = slot.dropped };
        try slot.recorder.collect(&self.ctx, &stats.timings);
        if (slot.ticks > 0) stats.active_tiles = slot.stats.typed(u32)[slot.ticks - 1];
        self.last = stats;
        if (self.profile) |p| p.record(&self.last, &self.names);
    }

    /// Fold every submitted frame that has finished (sim and render) into
    /// `last` and the readback mirror, oldest first, without waiting.
    /// Gameplay calls this before building a tick's commands so it sees the
    /// newest state.
    pub fn poll(self: *Engine) !void {
        const sim_done = try self.ctx.vkd.getSemaphoreCounterValue(self.ctx.device, self.sim_timeline);
        const render_done = try self.ctx.vkd.getSemaphoreCounterValue(self.ctx.device, self.render_timeline);
        for (0..frames_in_flight) |k| {
            const slot = &self.slots[(self.frame_index + k) % frames_in_flight];
            if (!slot.pending) continue;
            if (slot.done_sim > sim_done or slot.done_render > render_done) break;
            try self.collect(slot);
        }
    }

    /// The readback mirror: the world as of the end of `mirror.tick`.
    pub fn mirror(self: *Engine) *readback.Mirror {
        return &self.pipeline.readback.mirror;
    }

    /// Record and submit `ticks` simulation ticks (0..max_ticks_per_frame)
    /// and, with a view, render it: presented with a window, into the
    /// capture image headless (bench, overlap measurements). Returns after
    /// submission; results of an earlier frame are in `last`.
    pub fn frame(self: *Engine, ticks: u32, src: TickSource, view: ?View) !void {
        std.debug.assert(ticks <= max_ticks_per_frame);
        const ctx = &self.ctx;
        const slot_index: u32 = @intCast(self.frame_index % frames_in_flight);
        const slot = &self.slots[slot_index];
        try self.poll();
        try self.waitSlot(slot);
        try self.collect(slot);
        try ctx.vkd.resetCommandPool(ctx.device, slot.sim_pool, .{});
        try ctx.vkd.resetCommandPool(ctx.device, slot.render_pool, .{});
        slot.ticks = ticks;
        slot.first_tick = self.tick;
        slot.commands = 0;
        slot.dropped = 0;

        // ---- bodies (M7): ticks before this frame are submitted; a terrain
        // readback taken while recording it shows their results.
        if (self.pipeline.config.bodies) self.pipeline.bodies.beginFrame(self.tick);
        // ---- end bodies ----
        if (ticks > 0) {
            const cmd = slot.sim_cmd;
            try ctx.vkd.beginCommandBuffer(cmd, &.{ .flags = .{ .one_time_submit = true } });
            ctx.descriptors.bind(ctx, cmd, .compute);
            for (0..ticks) |k| {
                self.list.begin(self.tick);
                scenes.emit(src.scene, self.tick, src.seed, &self.ids, &self.list);
                if (k == 0) for (src.extra) |c| self.list.push(c);
                // ---- bodies (M7): scripted body actions, CPU step, GPU upload ----
                if (self.pipeline.config.bodies) {
                    bodies_scenes.script(src.scene, self.tick, self.pipeline.bodies.sim, &self.list);
                    try self.pipeline.bodies.tick(&self.list, .{ .tick = self.tick, .slot = slot_index, .tick_in_frame = @intCast(k) });
                }
                // ---- end bodies ----
                slot.commands += self.list.len;
                slot.dropped += self.list.dropped;
                const base = self.pipeline.applier.upload(slot_index, @intCast(k), &self.list);
                var f: Frame = .{
                    .ctx = ctx,
                    .cmd = cmd,
                    .tick = self.tick,
                    .slot = slot_index,
                    .tick_in_frame = @intCast(k),
                    .shared = &self.pipeline.shared,
                    .timer = &slot.recorder,
                    .commands = self.list.slice(),
                    .command_base = base,
                    .sleep = self.pipeline.config.sleep,
                    .overlay = @backingInt(self.renderer.settings.overlay),
                };
                self.pipeline.recordTick(&f);
                // Active tile count for the HUD and bench.
                gpu.memory.memoryBarrier(ctx, cmd, .{ .compute_shader = true }, .{ .shader_storage_write = true }, .{ .all_transfer = true }, .{ .transfer_read = true });
                ctx.vkd.cmdCopyBuffer(cmd, self.pipeline.shared.tile_list.handle, slot.stats.handle, &.{.{ .src_offset = 0, .dst_offset = k * 4, .size = 4 }});
                self.tick +%= 1;
            }
            // Snapshot for this frame's render (and the next ones while
            // paused), into the ring entry the newest render is not using.
            var snap: ?u32 = null;
            if (view != null) {
                const next: u32 = if (self.snap_latest) |l| (l + 1) % snapshot_count else 0;
                const t_snap = slot.recorder.begin(ctx, cmd, "snapshot");
                self.renderer.recordSnapshot(cmd, &self.pipeline.shared, self.pipeline.particles.overlay.handle, next);
                slot.recorder.end(ctx, cmd, t_snap);
                snap = next;
            }
            try ctx.vkd.endCommandBuffer(cmd);
            var waits: [3]Wait = undefined;
            var nw: usize = 0;
            waits[nw] = .{ .sem = self.sim_timeline, .value = self.sim_value, .stage = .{ .all_commands = true } };
            nw += 1;
            // The render that last read the snapshot (or the live image) we
            // overwrite; serial mode waits for every render.
            var render_dep = self.live_read;
            if (snap) |n| render_dep = @max(render_dep, self.snap_read[n]);
            if (!self.overlap) render_dep = self.render_value;
            if (render_dep > 0) {
                waits[nw] = .{ .sem = self.render_timeline, .value = render_dep, .stage = .{ .all_commands = true } };
                nw += 1;
            }
            self.sim_value += 1;
            try self.submit(ctx.compute.handle, cmd, waits[0..nw], &.{.{ .sem = self.sim_timeline, .value = self.sim_value }});
            if (snap) |n| {
                self.snap_written[n] = self.sim_value;
                self.snap_latest = n;
            } else self.snap_latest = null; // snapshots are stale now
        }

        if (view) |v| try self.render(slot, slot_index, v);
        self.renderer.clearDraws();
        slot.done_sim = self.sim_value;
        slot.done_render = self.render_value;
        slot.pending = true;
        self.frame_index += 1;
    }

    const Wait = struct { sem: vk.Semaphore, value: u64 = 0, stage: vk.PipelineStageFlags2 };
    const Signal = struct { sem: vk.Semaphore, value: u64 = 0 };

    fn submit(self: *Engine, queue: vk.Queue, cmd: vk.CommandBuffer, waits: []const Wait, signals: []const Signal) !void {
        var wait_infos: [4]vk.SemaphoreSubmitInfo = undefined;
        var nw: u32 = 0;
        for (waits) |w| {
            if ((w.sem == self.sim_timeline or w.sem == self.render_timeline) and w.value == 0) continue;
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
        var image_index: u32 = 0;
        var target: @import("render/renderer.zig").Target = undefined;
        var image: vk.Image = undefined;
        if (self.swapchain) |*sc| {
            if (self.window.?.input.resized) try self.resize();
            image_index = (try sc.acquire(ctx, slot.acquire)) orelse {
                try self.resize();
                return;
            };
            image = sc.images[image_index];
            target = .{ .view = sc.views[image_index], .extent = sc.extent, .kind = .present };
        } else {
            image = self.capture_image.handle;
            target = .{ .view = self.capture_image.view, .extent = self.headless_extent, .kind = .capture };
        }
        const cmd = slot.render_cmd;
        try ctx.vkd.beginCommandBuffer(cmd, &.{ .flags = .{ .one_time_submit = true } });
        ctx.descriptors.bind(ctx, cmd, .graphics);
        ctx.descriptors.bind(ctx, cmd, .compute);

        // Read the newest snapshot; before the first one exists, the live
        // images (and the next sim waits for this render).
        var sources = self.renderer.liveSources(&self.pipeline.shared);
        var sim_dep = self.sim_value;
        if (self.snap_latest) |n| {
            sources = self.renderer.snapshotSources(n);
            sim_dep = self.snap_written[n];
        }

        gpu.memory.imageBarrier(ctx, cmd, image, .undefined, .color_attachment_optimal, .{ .color_attachment_output = true }, .{}, .{ .color_attachment_output = true }, .{ .color_attachment_write = true });
        const t_render = slot.recorder.begin(ctx, cmd, "render");
        self.renderer.record(cmd, slot_index, sources, view, target, &self.hud, &slot.recorder, self.tick);
        slot.recorder.end(ctx, cmd, t_render);
        const final: vk.ImageLayout = if (self.swapchain != null) .present_src_khr else .color_attachment_optimal;
        gpu.memory.imageBarrier(ctx, cmd, image, .color_attachment_optimal, final, .{ .color_attachment_output = true }, .{ .color_attachment_write = true }, .{}, .{});
        try ctx.vkd.endCommandBuffer(cmd);

        var waits: [2]Wait = undefined;
        var nw: usize = 0;
        waits[nw] = .{ .sem = self.sim_timeline, .value = sim_dep, .stage = .{ .all_commands = true } };
        nw += 1;
        if (self.swapchain != null) {
            waits[nw] = .{ .sem = slot.acquire, .stage = .{ .color_attachment_output = true } };
            nw += 1;
        }
        self.render_value += 1;
        if (self.snap_latest) |n| self.snap_read[n] = self.render_value else self.live_read = self.render_value;
        if (self.swapchain) |*sc| {
            try self.submit(ctx.graphics.handle, cmd, waits[0..nw], &.{
                .{ .sem = self.render_timeline, .value = self.render_value },
                .{ .sem = sc.render_done[image_index] },
            });
            if (!try sc.present(ctx, ctx.graphics.handle, image_index)) try self.resize();
        } else {
            try self.submit(ctx.graphics.handle, cmd, waits[0..nw], &.{.{ .sem = self.render_timeline, .value = self.render_value }});
        }
    }

    fn resize(self: *Engine) !void {
        const width, const height = self.window.?.pixelSize();
        try self.swapchain.?.recreate(&self.ctx, width, height);
    }

    /// Replace the material and reaction tables (hot reload), the ids
    /// scenes use, the bodies layer's material roles and the renderer's
    /// material table. Waits for the GPU to go idle. `lib` must outlive its
    /// use by the engine.
    pub fn reloadTables(self: *Engine, lib: *const materials.Library) !void {
        try self.finish();
        try self.pipeline.uploadTables(lib);
        self.renderer.uploadMaterials(lib);
        self.ids = lib.ids();
        self.tables = lib.tables;
    }

    /// Copy the cell image into `out` (world_size^2 words). Waits for the GPU.
    pub fn readbackCells(self: *Engine, out: []u32) !void {
        try self.finish();
        try readback.readbackCells(&self.ctx, &self.pipeline.shared, &self.staging, out);
    }

    /// Render the whole world 1:1 (lit, no HUD) into the capture image and
    /// return its RGBA8 pixels (valid until the next capture/readback).
    pub fn captureWorld(self: *Engine) ![]const u8 {
        return self.captureView(.{}, .{ .width = cell.world_size, .height = cell.world_size }, false);
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
        // The GPU is idle: render straight from the live images. Without
        // `hud`, the HUD text (lines and signs) is hidden for this capture.
        const saved = .{ self.hud.used, self.hud.world_used };
        if (!hud) {
            self.hud.used = 0;
            self.hud.world_used = 0;
        }
        self.renderer.record(cmd, 0, self.renderer.liveSources(&self.pipeline.shared), view, .{ .view = self.capture_image.view, .extent = extent, .kind = .capture }, &self.hud, null, self.tick);
        self.hud.used, self.hud.world_used = saved;
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
