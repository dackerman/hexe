//! GPU -> CPU: the per-tick readback mirror and the event queue
//! (docs/01-architecture.md "The CPU-GPU boundary", docs/decisions/52-readback-mirror.md,
//! 53-event-queue.md), plus synchronous copies of world images for tests,
//! verification and tools.
//!
//! Each tick the GPU writes, into the frame slot's host-visible buffers:
//! a 1-bit solid mask and a 1-bit liquid mask of the whole window, the
//! material and info bytes of up to `max_regions` requested rectangles, the event
//! queue and the particle counters. When the engine finds that slot's
//! submission complete (it never waits for it just for this), `collect`
//! copies it into `Mirror`. Gameplay reads the mirror: state as of the end
//! of tick `mirror.tick`, normally the tick before the one being recorded.
const std = @import("std");
const gpu = @import("../gpu/gpu.zig");
const vk = gpu.vk;
const cell = @import("cell.zig");
const pipeline_mod = @import("pipeline.zig");
const Shared = pipeline_mod.Shared;
const Frame = pipeline_mod.Frame;
const particles_mod = @import("particles.zig");
const shaders = @import("shaders");

// ---- the event ABI lives in events.zig (mirror of events.glsl) ----
pub const events_abi = @import("events.zig");
pub const event_capacity = events_abi.capacity;
pub const event_header_words = events_abi.header_words;
pub const EventKind = events_abi.Kind;
pub const Event = events_abi.Event;

const event_bytes = event_header_words * 4 + event_capacity * @sizeOf(Event);
const stats_bytes = @sizeOf(particles_mod.Stats);
/// Per tick in a frame slot's `ticks` buffer: events, then particle stats.
const tick_stride = std.mem.alignForward(usize, event_bytes + stats_bytes, 256);

/// Words of one 1-bit world mask (2048 x 2048 bits = 512 KiB).
pub const mask_words = cell.world_size * cell.world_size / 32;
pub const max_regions = 64;
/// Material bytes available to regions per tick (rows padded to 4 bytes).
pub const region_bytes = 1 << 20;
/// Ticks of events the mirror keeps (`eventsAt`).
pub const event_history = 8;

pub const Region = struct { x: i32, y: i32, w: u32, h: u32 };

/// Info byte per region cell (`Mirror.info`), INFO_* in
/// shaders/sim/readback/region.comp (docs/decisions/120-gameplay-readback-info.md).
pub const Info = struct {
    /// Conductive cell with a nonzero charge phase (decision 42).
    pub const charged: u8 = 0x1;
    pub const burning: u8 = 0x2;
    pub const body: u8 = 0x4;
    pub const particle: u8 = 0x8;
};

/// CPU definition of a cell's info byte (`cell_info` in region.comp).
pub fn cellInfo(c: u32, tables: *const @import("materials.zig").Tables) u8 {
    var i: u8 = 0;
    const conductive = tables.materials[cell.material(c)].flags & @import("materials.zig").Flag.conductive != 0;
    if (conductive and cell.state(c) >> cell.charge_shift != 0) i |= Info.charged;
    if (cell.has(c, cell.flag_burning)) i |= Info.burning;
    if (cell.has(c, cell.flag_body)) i |= Info.body;
    if (cell.has(c, cell.flag_particle)) i |= Info.particle;
    return i;
}

/// Words one region occupies in the readback: the material plane, then the
/// info plane, each ceil(w / 4) words per row.
pub fn regionWords(w: u32, h: u32) u32 {
    return 2 * ((w + 3) / 4) * h;
}

const host_bytes = (2 * mask_words) * 4 + region_bytes;

/// `struct Region` in shaders/sim/readback/region.comp.
const RegionGpu = extern struct { x: i32, y: i32, w: u32, h: u32, offset_words: u32, words_per_row: u32, pad0: u32 = 0, pad1: u32 = 0 };

pub const TickEvents = struct {
    tick: u32 = 0,
    valid: bool = false,
    len: u32 = 0,
    /// Appends the GPU refused this tick (queue full).
    dropped: u32 = 0,
    items: [event_capacity]Event = undefined,
};

/// The CPU's one-tick-stale view of the world.
pub const Mirror = struct {
    /// Tick whose end state this is; meaningful once `valid`.
    tick: u32 = 0,
    valid: bool = false,
    /// Bit (x % 32) of word (y * 64 + x / 32): static phase or body-owned.
    solid: []u32,
    /// Same layout: liquid phase (cellular or particle-backed).
    liquid: []u32,
    /// Particle counters at the end of `tick`.
    particles: particles_mod.Stats = .{},
    regions: [max_regions]Region = undefined,
    region_offset: [max_regions]u32 = undefined,
    region_count: u32 = 0,
    region_data: []u32,
    history: []TickEvents,
    /// Requests for the next recorded frame (`requestRegion`).
    pending: [max_regions]Region = undefined,
    pending_count: u32 = 0,
    pending_bytes: u32 = 0,

    fn wordIndex(x: i32, y: i32) struct { usize, u5 } {
        const wx = cell.wrap(x);
        const wy = cell.wrap(y);
        return .{ @as(usize, wy) * (cell.world_size / 32) + wx / 32, @intCast(wx % 32) };
    }

    /// Static or body-owned at the end of `tick` (coordinates wrap). False
    /// before the first readback arrives.
    pub fn isSolid(self: *const Mirror, x: i32, y: i32) bool {
        const i, const b = wordIndex(x, y);
        return (self.solid[i] >> b) & 1 != 0;
    }

    pub fn isLiquid(self: *const Mirror, x: i32, y: i32) bool {
        const i, const b = wordIndex(x, y);
        return (self.liquid[i] >> b) & 1 != 0;
    }

    /// Material id at (x, y) if it lies in a region requested for `tick`.
    pub fn material(self: *const Mirror, x: i32, y: i32) ?u8 {
        return self.regionByte(x, y, 0);
    }

    /// `Info` bits of the cell at (x, y) if it lies in a region requested
    /// for `tick` (charge, burning, body-owned, particle-backed).
    pub fn info(self: *const Mirror, x: i32, y: i32) ?u8 {
        return self.regionByte(x, y, 1);
    }

    /// A region read back at `tick` that contains the whole rectangle, for
    /// fast repeated lookups (entity collision and contact scans); null if
    /// none does.
    pub fn regionView(self: *const Mirror, x: i32, y: i32, w: u32, h: u32) ?RegionView {
        for (self.regions[0..self.region_count], self.region_offset[0..self.region_count]) |r, off| {
            const dx = cell.wrap(x -% r.x);
            const dy = cell.wrap(y -% r.y);
            if (dx + w > r.w or dy + h > r.h) continue;
            const wpr = (r.w + 3) / 4;
            return .{
                .x = r.x,
                .y = r.y,
                .w = r.w,
                .h = r.h,
                .wpr = wpr,
                .mats = self.region_data[off..][0 .. wpr * r.h],
                .infos = self.region_data[off + wpr * r.h ..][0 .. wpr * r.h],
            };
        }
        return null;
    }

    fn regionByte(self: *const Mirror, x: i32, y: i32, plane: u32) ?u8 {
        for (self.regions[0..self.region_count], self.region_offset[0..self.region_count]) |r, off| {
            const dx = cell.wrap(x -% r.x);
            const dy = cell.wrap(y -% r.y);
            if (dx >= r.w or dy >= r.h) continue;
            const wpr = (r.w + 3) / 4;
            const word = self.region_data[off + plane * wpr * r.h + dy * wpr + dx / 4];
            return @truncate(word >> @intCast(8 * (dx % 4)));
        }
        return null;
    }

    /// Ask for the material bytes of a rectangle (an entity strip) in the
    /// next recorded frame's readback. Requests are per frame: ask again
    /// every frame for as long as it is needed.
    pub fn requestRegion(self: *Mirror, x: i32, y: i32, w: u32, h: u32) !void {
        if (w == 0 or h == 0 or w > cell.world_size or h > cell.world_size) return error.BadRegion;
        const bytes: u32 = regionWords(w, h) * 4;
        if (self.pending_count >= max_regions or self.pending_bytes + bytes > region_bytes) return error.TooManyRegions;
        self.pending[self.pending_count] = .{ .x = x, .y = y, .w = w, .h = h };
        self.pending_count += 1;
        self.pending_bytes += bytes;
    }

    /// Events of tick `t` if they have arrived and are still kept (the last
    /// `event_history` ticks); null otherwise.
    pub fn eventsAt(self: *const Mirror, t: u32) ?[]const Event {
        const h = &self.history[t % event_history];
        if (!h.valid or h.tick != t) return null;
        return h.items[0..h.len];
    }

    /// Appends the GPU refused in tick `t` (queue full); 0 if unknown.
    pub fn droppedAt(self: *const Mirror, t: u32) u32 {
        const h = &self.history[t % event_history];
        if (!h.valid or h.tick != t) return 0;
        return h.dropped;
    }

    /// Events of `tick` (the newest tick read back).
    pub fn events(self: *const Mirror) []const Event {
        if (!self.valid) return &.{};
        return self.eventsAt(self.tick) orelse &.{};
    }

    /// Live particles at the end of `tick` (scenario `particles` assertions,
    /// HUD).
    pub fn liveParticles(self: *const Mirror) u32 {
        return self.particles.live;
    }
};

/// One read-back region (`Mirror.regionView`): material and info bytes of
/// a rectangle, coordinates wrapping on the torus like the mirror's.
pub const RegionView = struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    wpr: u32,
    mats: []const u32,
    infos: []const u32,

    inline fn index(self: *const RegionView, x: i32, y: i32) ?struct { usize, u5 } {
        const dx = cell.wrap(x -% self.x);
        const dy = cell.wrap(y -% self.y);
        if (dx >= self.w or dy >= self.h) return null;
        return .{ dy * self.wpr + dx / 4, @intCast(8 * (dx % 4)) };
    }

    pub fn material(self: *const RegionView, x: i32, y: i32) ?u8 {
        const i, const shift = self.index(x, y) orelse return null;
        return @truncate(self.mats[i] >> shift);
    }

    pub fn info(self: *const RegionView, x: i32, y: i32) ?u8 {
        const i, const shift = self.index(x, y) orelse return null;
        return @truncate(self.infos[i] >> shift);
    }
};

const SlotBuffers = struct {
    /// Copy of `Readback.scratch`: masks, then region bytes.
    host: gpu.Buffer = .{},
    /// Copy-written: per tick in the frame, events then particle stats.
    ticks: gpu.Buffer = .{},
    /// Region table for region.comp (host-visible, written while recording).
    table: gpu.Buffer = .{},
    regions: [max_regions]Region = undefined,
    offsets: [max_regions]u32 = undefined,
    region_count: u32 = 0,
};

pub const Readback = struct {
    ctx: *gpu.Context,
    alloc: std.mem.Allocator,
    /// The event queue (SLOT_BUF_EVENTS), reset at the start of every tick.
    events: gpu.Buffer,
    /// Device-local: the shaders write masks and regions here; one copy
    /// moves them to the slot's host buffer (much cheaper than shader
    /// writes over PCIe).
    scratch: gpu.Buffer,
    slots: [pipeline_mod.frames_in_flight]SlotBuffers,
    mask_pipeline: vk.Pipeline,
    region_pipeline: vk.Pipeline,
    mirror: Mirror,

    pub fn init(ctx: *gpu.Context, cfg: pipeline_mod.Config, alloc: std.mem.Allocator) !Readback {
        _ = cfg;
        var self: Readback = .{
            .ctx = ctx,
            .alloc = alloc,
            .events = .{},
            .scratch = .{},
            .slots = @splat(.{}),
            .mask_pipeline = .null,
            .region_pipeline = .null,
            .mirror = .{ .solid = &.{}, .liquid = &.{}, .region_data = &.{}, .history = &.{} },
        };
        errdefer self.deinit();
        self.events = try gpu.Buffer.init(ctx, event_bytes, .{ .storage_buffer = true, .transfer_dst = true, .transfer_src = true }, .gpu_only);
        self.events.register(ctx, gpu.constants.slot_buf_events);
        try ctx.runOnce(.compute, zeroEvents, .{ ctx, self.events.handle });
        self.scratch = try gpu.Buffer.initSlotted(ctx, host_bytes, .{ .transfer_src = true }, .gpu_only);
        for (&self.slots) |*s| {
            s.host = try gpu.Buffer.init(ctx, host_bytes, .{ .transfer_dst = true }, .gpu_to_cpu);
            s.ticks = try gpu.Buffer.init(ctx, pipeline_mod.max_ticks_per_frame * tick_stride, .{ .transfer_dst = true }, .gpu_to_cpu);
            s.table = try gpu.Buffer.initSlotted(ctx, max_regions * @sizeOf(RegionGpu), .{}, .cpu_to_gpu);
        }
        self.mirror.solid = try alloc.alloc(u32, mask_words);
        @memset(self.mirror.solid, 0);
        self.mirror.liquid = try alloc.alloc(u32, mask_words);
        @memset(self.mirror.liquid, 0);
        self.mirror.region_data = try alloc.alloc(u32, region_bytes / 4);
        self.mirror.history = try alloc.alloc(TickEvents, event_history);
        for (self.mirror.history) |*h| h.* = .{};
        self.mask_pipeline = try gpu.pipelines.createCompute(ctx, &shaders.sim_readback_mask_comp);
        self.region_pipeline = try gpu.pipelines.createCompute(ctx, &shaders.sim_readback_region_comp);
        return self;
    }

    fn zeroEvents(cmd: vk.CommandBuffer, ctx: *gpu.Context, buf: vk.Buffer) void {
        ctx.vkd.cmdFillBuffer(cmd, buf, 0, vk.WHOLE_SIZE, 0);
    }

    pub fn deinit(self: *Readback) void {
        const ctx = self.ctx;
        if (self.region_pipeline != .null) gpu.pipelines.destroy(ctx, self.region_pipeline);
        if (self.mask_pipeline != .null) gpu.pipelines.destroy(ctx, self.mask_pipeline);
        if (self.mirror.history.len > 0) self.alloc.free(self.mirror.history);
        if (self.mirror.region_data.len > 0) self.alloc.free(self.mirror.region_data);
        if (self.mirror.liquid.len > 0) self.alloc.free(self.mirror.liquid);
        if (self.mirror.solid.len > 0) self.alloc.free(self.mirror.solid);
        for (&self.slots) |*s| {
            s.table.deinit(ctx);
            s.ticks.deinit(ctx);
            s.host.deinit(ctx);
        }
        self.scratch.deinit(ctx);
        self.events.deinit(ctx);
    }

    /// Start of tick: empty the event queue.
    pub fn recordBegin(self: *Readback, frame: *Frame) void {
        const ctx = frame.ctx;
        frame.fullBarrier();
        ctx.vkd.cmdFillBuffer(frame.cmd, self.events.handle, 0, 8, 0);
        gpu.memory.memoryBarrier(ctx, frame.cmd, .{ .all_transfer = true }, .{ .transfer_write = true }, .{ .compute_shader = true }, .{ .shader_storage_read = true, .shader_storage_write = true });
    }

    /// End of tick (architecture step 7): masks, regions, events, particle
    /// counters into this frame slot's host-visible buffers.
    pub fn record(self: *Readback, frame: *Frame, particles: *const particles_mod.Particles) void {
        frame.timed("readback", recordInner, .{ self, frame, particles });
    }

    fn recordInner(self: *Readback, frame: *Frame, particles: *const particles_mod.Particles) void {
        const ctx = frame.ctx;
        const cmd = frame.cmd;
        const s = &self.slots[frame.slot];
        if (frame.tick_in_frame == 0) {
            // This frame's region requests.
            const m = &self.mirror;
            s.region_count = m.pending_count;
            var offset: u32 = 0;
            const table = s.table.typed(RegionGpu);
            for (m.pending[0..m.pending_count], 0..) |r, i| {
                const wpr = (r.w + 3) / 4;
                s.regions[i] = r;
                s.offsets[i] = offset;
                table[i] = .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h, .offset_words = offset, .words_per_row = wpr };
                offset += regionWords(r.w, r.h);
            }
            m.pending_count = 0;
            m.pending_bytes = 0;
        }
        frame.barrier();
        frame.bindCompute(self.mask_pipeline);
        frame.push(extern struct { out: u32 }{ .out = self.scratch.slot });
        frame.dispatch(cell.world_size / 256, cell.world_size, 1);
        var region_words: u64 = 0;
        if (s.region_count > 0) {
            var max_words: u32 = 0;
            for (s.regions[0..s.region_count], s.offsets[0..s.region_count]) |r, off| {
                max_words = @max(max_words, ((r.w + 3) / 4) * r.h);
                region_words = @max(region_words, off + regionWords(r.w, r.h));
            }
            frame.bindCompute(self.region_pipeline);
            frame.push(extern struct { table: u32, out: u32, base: u32 }{ .table = s.table.slot, .out = self.scratch.slot, .base = 2 * mask_words });
            frame.dispatch((max_words + 255) / 256, s.region_count, 1);
        }
        gpu.memory.memoryBarrier(ctx, cmd, .{ .compute_shader = true }, .{ .shader_storage_write = true }, .{ .all_transfer = true }, .{ .transfer_read = true });
        ctx.vkd.cmdCopyBuffer(cmd, self.scratch.handle, s.host.handle, &.{.{ .src_offset = 0, .dst_offset = 0, .size = (2 * mask_words + region_words) * 4 }});
        const base = frame.tick_in_frame * tick_stride;
        ctx.vkd.cmdCopyBuffer(cmd, self.events.handle, s.ticks.handle, &.{.{ .src_offset = 0, .dst_offset = base, .size = event_bytes }});
        ctx.vkd.cmdCopyBuffer(cmd, particles.ctrl.handle, s.ticks.handle, &.{.{ .src_offset = 0, .dst_offset = base + event_bytes, .size = stats_bytes }});
        gpu.memory.memoryBarrier(ctx, cmd, .{ .all_transfer = true }, .{ .transfer_write = true }, .{ .host = true }, .{ .host_read = true });
    }

    /// Fold a completed frame slot (ticks first_tick .. first_tick+ticks-1)
    /// into the mirror. Call only after that slot's submission finished.
    pub fn collect(self: *Readback, slot: u32, first_tick: u32, ticks: u32) void {
        if (ticks == 0) return;
        const s = &self.slots[slot];
        const m = &self.mirror;
        const host = s.host.typed(u32);
        @memcpy(m.solid, host[0..mask_words]);
        @memcpy(m.liquid, host[mask_words..][0..mask_words]);
        m.region_count = s.region_count;
        var words: usize = 0;
        for (s.regions[0..s.region_count], 0..) |r, i| {
            m.regions[i] = r;
            m.region_offset[i] = s.offsets[i];
            words = @max(words, s.offsets[i] + regionWords(r.w, r.h));
        }
        @memcpy(m.region_data[0..words], host[2 * mask_words ..][0..words]);
        const bytes = s.ticks.bytes();
        for (0..ticks) |k| {
            const t = first_tick +% @as(u32, @intCast(k));
            const region = bytes[k * tick_stride ..][0..tick_stride];
            const header = std.mem.bytesAsSlice(u32, region[0 .. event_header_words * 4]);
            const h = &m.history[t % event_history];
            h.tick = t;
            h.valid = true;
            h.len = @min(header[0], event_capacity);
            h.dropped = header[1];
            @memcpy(std.mem.sliceAsBytes(h.items[0..h.len]), region[event_header_words * 4 ..][0 .. h.len * @sizeOf(Event)]);
            if (k == ticks - 1) m.particles = std.mem.bytesToValue(particles_mod.Stats, region[event_bytes..][0..stats_bytes]);
        }
        m.tick = first_tick +% (ticks - 1);
        m.valid = true;
    }
};

// ---- synchronous copies (tests, verification, tools) ----

/// Copy a world-sized R32_UINT image (GENERAL layout) into `out` through
/// `staging` (host-visible, >= world_size^2 * 4 bytes). The GPU must be idle
/// or the caller must have waited for the work that wrote the image.
pub fn readbackImage(ctx: *gpu.Context, image: *const gpu.Image, staging: *gpu.Buffer, out: []u32) !void {
    std.debug.assert(out.len == @as(usize, image.width) * image.height);
    std.debug.assert(staging.size >= out.len * 4);
    try ctx.runOnce(.compute, recordCopy, .{ ctx, image, staging });
    @memcpy(out, staging.typed(u32)[0..out.len]);
}

/// The cell image. See `readbackImage`.
pub fn readbackCells(ctx: *gpu.Context, shared: *const Shared, staging: *gpu.Buffer, out: []u32) !void {
    try readbackImage(ctx, shared.cells, staging, out);
}

/// The owner image. See `readbackImage`.
pub fn readbackOwner(ctx: *gpu.Context, shared: *const Shared, staging: *gpu.Buffer, out: []u32) !void {
    try readbackImage(ctx, shared.owner, staging, out);
}

fn recordCopy(cmd: vk.CommandBuffer, ctx: *gpu.Context, image: *const gpu.Image, staging: *gpu.Buffer) void {
    gpu.memory.memoryBarrier(ctx, cmd, .{ .all_commands = true }, .{ .memory_write = true }, .{ .all_transfer = true }, .{ .transfer_read = true });
    ctx.vkd.cmdCopyImageToBuffer(cmd, image.handle, .general, staging.handle, &.{.{
        .buffer_offset = 0,
        .buffer_row_length = 0,
        .buffer_image_height = 0,
        .image_subresource = .{ .aspect_mask = .{ .color = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
        .image_offset = .{ .x = 0, .y = 0, .z = 0 },
        .image_extent = .{ .width = image.width, .height = image.height, .depth = 1 },
    }});
    gpu.memory.memoryBarrier(ctx, cmd, .{ .all_transfer = true }, .{ .transfer_write = true }, .{ .host = true }, .{ .host_read = true });
}

/// CPU computation of the masks from a cell image (tests and tools; the
/// same definition as shaders/sim/readback/mask.comp).
pub fn computeMasks(cells: []const u32, tables: *const @import("materials.zig").Tables, solid: []u32, liquid: []u32) void {
    @memset(solid, 0);
    @memset(liquid, 0);
    for (cells, 0..) |c, i| {
        const phase = tables.materials[cell.material(c)].phase;
        const bit = @as(u32, 1) << @intCast(i % 32);
        if (phase == 0 or cell.has(c, cell.flag_body)) solid[i / 32] |= bit else if (phase == 2) liquid[i / 32] |= bit;
    }
}

test "mirror bit addressing and regions" {
    var solid: [mask_words]u32 = @splat(0);
    var liquid: [mask_words]u32 = @splat(0);
    var data: [64]u32 = @splat(0);
    var history: [event_history]TickEvents = undefined;
    var m: Mirror = .{ .solid = &solid, .liquid = &liquid, .region_data = &data, .history = &history };
    for (&history) |*h| h.* = .{};
    solid[5 * 64 + 1] = 1 << 3; // cell (35, 5)
    try std.testing.expect(m.isSolid(35, 5));
    try std.testing.expect(m.isSolid(35 + cell.world_size, 5 - cell.world_size));
    try std.testing.expect(!m.isSolid(34, 5));
    // A 6x2 region at (-2, 10): rows of 2 words.
    m.regions[0] = .{ .x = -2, .y = 10, .w = 6, .h = 2 };
    m.region_offset[0] = 4;
    m.region_count = 1;
    data[4 + 2 + 1] = 0x0000_0900; // row 1, column 5 -> byte 1 of word 1
    data[4 + 4 + 2 + 1] = 0x0000_0100; // the info plane follows (2 rows of 2 words)
    try std.testing.expectEqual(@as(?u8, 9), m.material(3, 11));
    try std.testing.expectEqual(@as(?u8, Info.charged), m.info(3, 11));
    try std.testing.expectEqual(@as(?u8, 0), m.info(2, 11));
    const v = m.regionView(-1, 10, 4, 2).?;
    try std.testing.expectEqual(@as(?u8, 9), v.material(3, 11));
    try std.testing.expectEqual(@as(?u8, Info.charged), v.info(3, 11));
    try std.testing.expectEqual(@as(?u8, null), v.material(4, 11));
    try std.testing.expect(m.regionView(0, 10, 6, 2) == null);
    try std.testing.expectEqual(@as(?u8, 0), m.material(cell.world_size - 2, 10));
    try std.testing.expectEqual(@as(?u8, null), m.material(4, 11));
    try m.requestRegion(0, 0, 10, 10);
    try std.testing.expectEqual(@as(u32, 1), m.pending_count);
    try std.testing.expectError(error.BadRegion, m.requestRegion(0, 0, 0, 1));
    history[3] = .{ .tick = 11, .valid = true, .len = 1 };
    history[3].items[0] = .init(1, 2, .eject, 4);
    m.tick = 11;
    m.valid = true;
    try std.testing.expectEqual(@as(usize, 1), m.events().len);
    try std.testing.expect(m.eventsAt(3) == null);
}
