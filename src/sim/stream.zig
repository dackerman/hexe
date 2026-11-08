//! GPU side of world streaming: the `UploadSink` the world layer's
//! `Streaming` drives (docs/decisions/13-world-streaming.md,
//! 60-stream-gpu-sink.md, 61-stream-dirty-bits.md).
//!
//! - `uploadChunk` copies the cells into a host-visible staging ring entry
//!   and queues it; `recordUploads` (first pass of the next recorded tick)
//!   copies it into the cell image at the slot, clears the owner region and
//!   dirty bit and wakes the slot's tiles (shaders/sim/stream/upload.comp).
//! - Dirty bits: one u32 per window chunk slot on the GPU, set by
//!   `recordDirty` (shaders/sim/stream/dirty.comp) from the activity marks
//!   after commands, so no cell-writing pass has to know about streaming.
//! - `takeDirty` and `downloadChunk` are synchronous: the first call after a
//!   tick waits for the GPU to go idle and reads every dirty bit back in one
//!   copy; the first download then copies every dirty slot in the same row
//!   and column as the requested one (an evicted row or column, or a flush),
//!   so a whole move costs one wait.
//!
//! Disabled (no allocation beyond the pipelines and the 256-byte dirty
//! buffer, record is a no-op) until `enable` is called for world mode.
const std = @import("std");
const world = @import("world");
const gpu = @import("../gpu/gpu.zig");
const vk = gpu.vk;
const cell = @import("cell.zig");
const pipeline_mod = @import("pipeline.zig");
const Frame = pipeline_mod.Frame;
const shaders = @import("shaders");

const chunk = world.chunk;
const window = world.window;
pub const UploadSink = world.streaming.UploadSink;

const slot_count = window.slot_count;
const chunk_bytes = chunk.cell_count * 4;
const dirty_bytes = slot_count * 4;
/// Staging entries for queued uploads. A tick normally uploads one or two
/// chunks; startup's `loadAll` overflows it and flushes synchronously.
pub const ring_entries = 16;

comptime {
    // shaders/sim/stream/stream.glsl
    std.debug.assert(chunk.size == 256);
    std.debug.assert(window.chunks == 8);
    std.debug.assert(chunk.size / cell.tile_size == 8);
    std.debug.assert(window.size == cell.world_size);
}

const Pending = struct { slot_x: u32, slot_y: u32, entry: u32 };

pub const Config = pipeline_mod.Config;

pub const Stream = struct {
    ctx: *gpu.Context,
    upload_pipeline: vk.Pipeline,
    dirty_pipeline: vk.Pipeline,
    /// u32[64] dirty bits, bindless dynamic slot.
    dirty: gpu.Buffer,
    /// The cell image (owned by Grid); set by Pipeline.init.
    cells: *gpu.Image = undefined,
    io: std.Io = undefined,
    enabled: bool = false,
    /// Activity tiles off: nothing marks changes, so every slot counts as
    /// dirty (correct, just more downloads).
    sleep: bool = true,

    // ---- allocated by `enable` ----
    staging: gpu.Buffer = .{},
    /// dirty words, then one chunk per slot.
    readback: gpu.Buffer = .{},
    /// Timeline value after which each staging entry is free again.
    ring_value: [ring_entries]u64 = @splat(0),
    ring_next: u32 = 0,
    pending: [ring_entries]Pending = undefined,
    pending_len: u32 = 0,
    timeline: vk.Semaphore = .null,
    timeline_value: *const u64 = undefined,

    // ---- dirty and download snapshot, valid until the next tick or upload ----
    snap_valid: bool = false,
    /// Dirty bits seen by syncs and not yet taken.
    bits: [slot_count]bool = @splat(false),
    /// Slots dirty at the last sync (download batching).
    snap_dirty: u64 = 0,
    /// Slots whose cells are in `readback` for this snapshot.
    downloaded: u64 = 0,

    stats: Stats = .{},

    pub const Stats = struct {
        uploads: u64 = 0,
        sync_uploads: u64 = 0,
        syncs: u64 = 0,
        downloads: u64 = 0,
        download_copies: u64 = 0,
        /// Main-thread time inside syncs and downloads, ns.
        sync_ns: u64 = 0,
    };

    pub fn init(ctx: *gpu.Context, cfg: Config, alloc: std.mem.Allocator) !Stream {
        _ = alloc;
        var self: Stream = .{
            .ctx = ctx,
            .upload_pipeline = .null,
            .dirty_pipeline = .null,
            .dirty = .{},
            .sleep = cfg.sleep,
        };
        self.upload_pipeline = try gpu.pipelines.createCompute(ctx, &shaders.sim_stream_upload_comp);
        errdefer gpu.pipelines.destroy(ctx, self.upload_pipeline);
        self.dirty_pipeline = try gpu.pipelines.createCompute(ctx, &shaders.sim_stream_dirty_comp);
        errdefer gpu.pipelines.destroy(ctx, self.dirty_pipeline);
        self.dirty = try gpu.Buffer.initSlotted(ctx, dirty_bytes, .{ .transfer_src = true, .transfer_dst = true }, .gpu_only);
        errdefer self.dirty.deinit(ctx);
        try ctx.runOnce(.compute, zeroDirty, .{ ctx, self.dirty.handle });
        return self;
    }

    fn zeroDirty(cmd: vk.CommandBuffer, ctx: *gpu.Context, buf: vk.Buffer) void {
        ctx.vkd.cmdFillBuffer(cmd, buf, 0, vk.WHOLE_SIZE, 0);
    }

    pub fn deinit(self: *Stream) void {
        const ctx = self.ctx;
        self.readback.deinit(ctx);
        self.staging.deinit(ctx);
        self.dirty.deinit(ctx);
        gpu.pipelines.destroy(ctx, self.dirty_pipeline);
        gpu.pipelines.destroy(ctx, self.upload_pipeline);
    }

    /// Turns streaming on. `timeline` / `timeline_value` are the engine's
    /// timeline semaphore and its last submitted value; a tick's sim
    /// submission signals `timeline_value.* + 1`.
    pub fn enable(self: *Stream, io: std.Io, timeline: vk.Semaphore, timeline_value: *const u64) !void {
        if (self.enabled) return;
        const ctx = self.ctx;
        self.staging = try gpu.Buffer.init(ctx, ring_entries * chunk_bytes, .{ .transfer_src = true }, .cpu_to_gpu);
        errdefer self.staging.deinit(ctx);
        self.readback = try gpu.Buffer.init(ctx, dirty_bytes + slot_count * chunk_bytes, .{ .transfer_dst = true }, .gpu_to_cpu);
        self.io = io;
        self.timeline = timeline;
        self.timeline_value = timeline_value;
        self.enabled = true;
    }

    pub fn sink(self: *Stream) UploadSink {
        return .{ .ptr = self, .vtable = &.{
            .uploadChunk = uploadChunk,
            .downloadChunk = downloadChunk,
            .takeDirty = takeDirty,
        } };
    }

    // ---- per tick ----------------------------------------------------------

    /// Queued chunk uploads; first thing in a tick, before commands.
    pub fn recordUploads(self: *Stream, frame: *Frame) void {
        if (!self.enabled) return;
        self.snap_valid = false; // the GPU is about to change cells
        if (self.pending_len == 0) return;
        const signal = self.timeline_value.* + 1;
        frame.timed("stream", recordPending, .{ self, frame.cmd, signal });
    }

    /// Dirty bits from this tick's and last tick's marks; after commands,
    /// before compaction.
    pub fn recordDirty(self: *Stream, frame: *Frame) void {
        if (!self.enabled) return;
        frame.barrier();
        recordDirtyPass(self, frame.cmd);
    }

    fn recordDirtyPass(self: *Stream, cmd: vk.CommandBuffer) void {
        const ctx = self.ctx;
        ctx.vkd.cmdBindPipeline(cmd, .compute, self.dirty_pipeline);
        gpu.pipelines.push(ctx, cmd, extern struct { dirty: u32 }{ .dirty = self.dirty.slot });
        ctx.vkd.cmdDispatch(cmd, cell.tiles_per_side / 16, cell.tiles_per_side / 16, 1);
        gpu.memory.computeBarrier(ctx, cmd);
    }

    fn recordPending(self: *Stream, cmd: vk.CommandBuffer, signal: u64) void {
        const ctx = self.ctx;
        const list = self.pending[0..self.pending_len];
        gpu.memory.memoryBarrier(ctx, cmd, .{ .all_commands = true }, .{ .memory_write = true, .memory_read = true }, .{ .all_transfer = true }, .{ .transfer_write = true });
        for (list) |p| {
            ctx.vkd.cmdCopyBufferToImage(cmd, self.staging.handle, self.cells.handle, .general, &.{.{
                .buffer_offset = @as(u64, p.entry) * chunk_bytes,
                .buffer_row_length = 0,
                .buffer_image_height = 0,
                .image_subresource = .{ .aspect_mask = .{ .color = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
                .image_offset = .{ .x = @intCast(p.slot_x * chunk.size), .y = @intCast(p.slot_y * chunk.size), .z = 0 },
                .image_extent = .{ .width = chunk.size, .height = chunk.size, .depth = 1 },
            }});
        }
        gpu.memory.memoryBarrier(ctx, cmd, .{ .all_transfer = true }, .{ .transfer_write = true }, .{ .compute_shader = true }, .{ .shader_storage_read = true, .shader_storage_write = true });
        ctx.vkd.cmdBindPipeline(cmd, .compute, self.upload_pipeline);
        for (list) |p| {
            gpu.pipelines.push(ctx, cmd, extern struct { sx: u32, sy: u32, dirty: u32 }{ .sx = p.slot_x, .sy = p.slot_y, .dirty = self.dirty.slot });
            ctx.vkd.cmdDispatch(cmd, chunk.size / 16, chunk.size / 16, 1);
            // Adjacent chunks' tile rings overlap each other's tiles.
            gpu.memory.computeBarrier(ctx, cmd);
        }
        for (list) |p| self.ring_value[p.entry] = signal;
        self.stats.uploads += list.len;
        self.pending_len = 0;
    }

    fn recordPendingOnce(cmd: vk.CommandBuffer, self: *Stream) void {
        recordPending(self, cmd, 0);
    }

    // ---- synchronous paths -------------------------------------------------

    /// Uploads everything queued now and waits (staging ring full).
    fn flushPendingSync(self: *Stream) !void {
        self.ctx.waitIdle();
        try self.ctx.runOnce(.compute, recordPendingOnce, .{self});
        self.stats.sync_uploads += 1;
    }

    /// Makes `bits` and `snap_dirty` exact as of now: waits for the GPU, runs
    /// the dirty pass, reads the bits back and clears them on the GPU.
    fn sync(self: *Stream) !void {
        if (self.snap_valid) return;
        const t0 = std.Io.Timestamp.now(self.io, .awake);
        defer self.stats.sync_ns += @intCast(t0.untilNow(self.io, .awake).nanoseconds);
        self.ctx.waitIdle();
        try self.ctx.runOnce(.compute, recordSync, .{self});
        const words = self.readback.typed(u32)[0..slot_count];
        self.snap_dirty = 0;
        for (words, 0..) |w, i| {
            if (w != 0 or !self.sleep) self.bits[i] = true;
            if (self.bits[i]) self.snap_dirty |= @as(u64, 1) << @intCast(i);
        }
        self.downloaded = 0;
        self.snap_valid = true;
        self.stats.syncs += 1;
    }

    fn recordSync(cmd: vk.CommandBuffer, self: *Stream) void {
        const ctx = self.ctx;
        if (self.pending_len > 0) recordPending(self, cmd, 0);
        gpu.memory.memoryBarrier(ctx, cmd, .{ .all_commands = true }, .{ .memory_write = true }, .{ .compute_shader = true }, .{ .shader_storage_read = true, .shader_storage_write = true });
        recordDirtyPass(self, cmd);
        gpu.memory.memoryBarrier(ctx, cmd, .{ .compute_shader = true }, .{ .shader_storage_write = true }, .{ .all_transfer = true }, .{ .transfer_read = true, .transfer_write = true });
        ctx.vkd.cmdCopyBuffer(cmd, self.dirty.handle, self.readback.handle, &.{.{ .src_offset = 0, .dst_offset = 0, .size = dirty_bytes }});
        gpu.memory.memoryBarrier(ctx, cmd, .{ .all_transfer = true }, .{ .transfer_read = true, .transfer_write = true }, .{ .all_transfer = true }, .{ .transfer_write = true });
        ctx.vkd.cmdFillBuffer(cmd, self.dirty.handle, 0, dirty_bytes, 0);
        gpu.memory.memoryBarrier(ctx, cmd, .{ .all_transfer = true }, .{ .transfer_write = true }, .{ .host = true, .compute_shader = true }, .{ .host_read = true, .shader_storage_read = true, .shader_storage_write = true });
    }

    fn recordDownloads(cmd: vk.CommandBuffer, self: *Stream, mask: u64) void {
        const ctx = self.ctx;
        gpu.memory.memoryBarrier(ctx, cmd, .{ .all_commands = true }, .{ .memory_write = true }, .{ .all_transfer = true }, .{ .transfer_read = true });
        for (0..slot_count) |i| {
            if (mask & (@as(u64, 1) << @intCast(i)) == 0) continue;
            const s = window.Slot.fromIndex(@intCast(i));
            ctx.vkd.cmdCopyImageToBuffer(cmd, self.cells.handle, .general, self.readback.handle, &.{.{
                .buffer_offset = dirty_bytes + @as(u64, i) * chunk_bytes,
                .buffer_row_length = 0,
                .buffer_image_height = 0,
                .image_subresource = .{ .aspect_mask = .{ .color = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
                .image_offset = .{ .x = @intCast(s.x * chunk.size), .y = @intCast(s.y * chunk.size), .z = 0 },
                .image_extent = .{ .width = chunk.size, .height = chunk.size, .depth = 1 },
            }});
        }
        gpu.memory.memoryBarrier(ctx, cmd, .{ .all_transfer = true }, .{ .transfer_write = true }, .{ .host = true }, .{ .host_read = true });
    }

    /// Slots sharing a row or a column with `i`.
    fn crossMask(i: u32) u64 {
        const s = window.Slot.fromIndex(i);
        var m: u64 = 0;
        for (0..window.chunks) |k| {
            m |= @as(u64, 1) << @intCast(s.y * window.chunks + @as(u32, @intCast(k)));
            m |= @as(u64, 1) << @intCast(@as(u32, @intCast(k)) * window.chunks + s.x);
        }
        return m;
    }

    // ---- UploadSink --------------------------------------------------------

    fn uploadChunk(ptr: *anyopaque, slot_x: u32, slot_y: u32, cells: *const chunk.Cells) void {
        const self: *Stream = @ptrCast(@alignCast(ptr));
        self.upload(slot_x, slot_y, cells) catch |err| std.debug.panic("stream upload: {s}", .{@errorName(err)});
    }

    fn upload(self: *Stream, slot_x: u32, slot_y: u32, cells: *const chunk.Cells) !void {
        std.debug.assert(self.enabled and slot_x < window.chunks and slot_y < window.chunks);
        if (self.pending_len == ring_entries) try self.flushPendingSync();
        const e = self.ring_next;
        self.ring_next = (e + 1) % ring_entries;
        if (self.ring_value[e] != 0) {
            // Almost always long signaled: the entry was used ring_entries
            // uploads ago.
            const value = self.ring_value[e];
            _ = try self.ctx.vkd.waitSemaphores(self.ctx.device, &.{
                .semaphore_count = 1,
                .p_semaphores = @ptrCast(&self.timeline),
                .p_values = @ptrCast(&value),
            }, std.math.maxInt(u64));
            self.ring_value[e] = 0;
        }
        @memcpy(self.staging.bytes()[@as(usize, e) * chunk_bytes ..][0..chunk_bytes], std.mem.sliceAsBytes(cells));
        self.pending[self.pending_len] = .{ .slot_x = slot_x, .slot_y = slot_y, .entry = e };
        self.pending_len += 1;
        self.bits[slot_y * window.chunks + slot_x] = false;
        self.snap_valid = false;
    }

    fn downloadChunk(ptr: *anyopaque, slot_x: u32, slot_y: u32, out: *chunk.Cells) void {
        const self: *Stream = @ptrCast(@alignCast(ptr));
        self.download(slot_x, slot_y, out) catch |err| std.debug.panic("stream download: {s}", .{@errorName(err)});
    }

    fn download(self: *Stream, slot_x: u32, slot_y: u32, out: *chunk.Cells) !void {
        const i = slot_y * window.chunks + slot_x;
        const bit = @as(u64, 1) << @intCast(i);
        try self.sync();
        if (self.downloaded & bit == 0) {
            const t0 = std.Io.Timestamp.now(self.io, .awake);
            defer self.stats.sync_ns += @intCast(t0.untilNow(self.io, .awake).nanoseconds);
            const mask = (bit | (self.snap_dirty & crossMask(i))) & ~self.downloaded;
            try self.ctx.runOnce(.compute, recordDownloads, .{ self, mask });
            self.downloaded |= mask;
            self.stats.download_copies += 1;
        }
        const src = self.readback.bytes()[dirty_bytes + @as(usize, i) * chunk_bytes ..][0..chunk_bytes];
        @memcpy(std.mem.sliceAsBytes(out), src);
        self.stats.downloads += 1;
    }

    fn takeDirty(ptr: *anyopaque, slot_x: u32, slot_y: u32) bool {
        const self: *Stream = @ptrCast(@alignCast(ptr));
        self.sync() catch |err| {
            std.log.err("stream: dirty readback failed ({s}); assuming dirty", .{@errorName(err)});
            return true;
        };
        const i = slot_y * window.chunks + slot_x;
        defer self.bits[i] = false;
        return self.bits[i];
    }
};
