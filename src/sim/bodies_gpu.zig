//! Body rasterization on the GPU (M7, docs/01-architecture.md "Bodies",
//! frame pipeline step 2 "rasterize bodies").
//!
//! `BodiesGpu` owns:
//! - the bitmap **atlas**: a device copy of `BodyWorld.pixels`, same byte
//!   offsets, so a body's bitmap lives at the offset of its span there.
//!   Bitmaps are uploaded when a body is created or its bitmap changes, never
//!   per tick;
//! - an **upload ring** (host visible) with one region per (frame slot, tick in
//!   frame): this tick's body instances, work items, point writes and the
//!   staging bytes for new bitmaps;
//! - a private **claim image** (R32_UINT, world sized) that resolves two bodies
//!   racing for a pixel: lowest id wins (atomicMin of tick-stamped ids);
//! - the **eject queue** at the fixed slot SLOT_BUF_EJECT (displaced cells,
//!   debris) and its stand-in consumer until the particles layer drains it;
//! - a per-region **stats** buffer the CPU reads back one frame later.
//!
//! The CPU side (`bodies_sim.zig`) fills a region with `RegionWriter` right
//! before `Pipeline.recordTick`, then `record` replays it:
//!
//!   copy staging -> atlas, zero eject count and stats
//!   EXTRACT (loose terrain -> air) + RESET (claim image) | CLAIM | WRITE |
//!   CLEAR (last tick's cells not rewritten) | points | eject fallback
//!
//! with a barrier between steps. Bodies whose fixed-point pose and bitmap did
//! not change since the last tick are left out entirely, so sleeping bodies
//! cost nothing and do not keep activity tiles awake.
//! See docs/decisions/90-bodies-gpu-rasterization.md.
const std = @import("std");
const gpu = @import("../gpu/gpu.zig");
const vk = gpu.vk;
const cell = @import("cell.zig");
const pipeline_mod = @import("pipeline.zig");
const Frame = pipeline_mod.Frame;
const shaders = @import("shaders");

// ---- mirrors of shaders/sim/bodies/bodies.glsl (test "bodies.glsl mirror") ----
pub const mode_extract: u32 = 0;
pub const mode_reset: u32 = 1;
pub const mode_claim: u32 = 2;
pub const mode_write: u32 = 3;
pub const mode_clear: u32 = 4;
pub const id_bits = 13;
pub const id_mask: u32 = (1 << id_bits) - 1;
pub const stamp_mask: u32 = 0x7ffff;
pub const point_into_air: u32 = 0;
pub const point_replace: u32 = 1;
pub const point_eject: u32 = 2;
pub const Stat = enum(u32) {
    written = 0,
    overlap_static = 1,
    overlap_body = 2,
    displaced = 3,
    cleared = 4,
    extracted = 5,
    points = 6,
    fallback_placed = 7,
    fallback_dropped = 8,
    eject_overflow = 9,
};
pub const stat_instance_base = 16;
pub const eject_fallback_walk = 384;
pub const salt_body_variant = 0xb0d1;
pub const salt_point_variant = 0x9017;

const mirrors = .{
    .{ "BODY_MODE_EXTRACT", mode_extract },
    .{ "BODY_MODE_RESET", mode_reset },
    .{ "BODY_MODE_CLAIM", mode_claim },
    .{ "BODY_MODE_WRITE", mode_write },
    .{ "BODY_MODE_CLEAR", mode_clear },
    .{ "BODY_ID_BITS", id_bits },
    .{ "BODY_ID_MASK", id_mask },
    .{ "BODY_STAMP_MASK", stamp_mask },
    .{ "POINT_MODE_INTO_AIR", point_into_air },
    .{ "POINT_MODE_REPLACE", point_replace },
    .{ "POINT_MODE_EJECT", point_eject },
    .{ "BODY_STAT_WRITTEN", @backingInt(Stat.written) },
    .{ "BODY_STAT_OVERLAP_STATIC", @backingInt(Stat.overlap_static) },
    .{ "BODY_STAT_OVERLAP_BODY", @backingInt(Stat.overlap_body) },
    .{ "BODY_STAT_DISPLACED", @backingInt(Stat.displaced) },
    .{ "BODY_STAT_CLEARED", @backingInt(Stat.cleared) },
    .{ "BODY_STAT_EXTRACTED", @backingInt(Stat.extracted) },
    .{ "BODY_STAT_POINTS", @backingInt(Stat.points) },
    .{ "BODY_STAT_FALLBACK_PLACED", @backingInt(Stat.fallback_placed) },
    .{ "BODY_STAT_FALLBACK_DROPPED", @backingInt(Stat.fallback_dropped) },
    .{ "BODY_STAT_EJECT_OVERFLOW", @backingInt(Stat.eject_overflow) },
    .{ "BODY_STAT_INSTANCE_BASE", stat_instance_base },
    .{ "EJECT_FALLBACK_WALK", eject_fallback_walk },
    .{ "SALT_BODY_VARIANT", salt_body_variant },
    .{ "SALT_POINT_VARIANT", salt_point_variant },
};

/// `struct BodyInstance` in bodies.glsl (64 bytes, std430).
pub const BodyInstance = extern struct {
    ax: i32,
    ay: i32,
    aabb_size: u32,
    id: u32,
    l0x: i32,
    l0y: i32,
    cs: i32,
    sn: i32,
    bitmap_size: u32,
    atlas_offset: u32,
    flags: u32 = 0,
    index: u32 = 0,
    vx: f32 = 0,
    vy: f32 = 0,
    angular_velocity: f32 = 0,
    pad: u32 = 0,

    pub fn aabbW(self: BodyInstance) u32 {
        return self.aabb_size & 0xffff;
    }
    pub fn aabbH(self: BodyInstance) u32 {
        return self.aabb_size >> 16;
    }
    /// Same pose, bitmap and footprint: rasterizing again would change nothing.
    pub fn samePlacement(a: BodyInstance, b: BodyInstance) bool {
        return a.ax == b.ax and a.ay == b.ay and a.aabb_size == b.aabb_size and a.id == b.id and
            a.l0x == b.l0x and a.l0y == b.l0y and a.cs == b.cs and a.sn == b.sn and
            a.bitmap_size == b.bitmap_size and a.atlas_offset == b.atlas_offset;
    }
};

/// `struct BodyPoint` in bodies.glsl (16 bytes).
pub const BodyPoint = extern struct {
    x: i32,
    y: i32,
    packed_word: u32,
    vel: u32 = 0,

    pub fn make(x: i32, y: i32, material: u8, expect: u8, mode: u32, vx: f32, vy: f32) BodyPoint {
        return .{ .x = x, .y = y, .packed_word = @as(u32, material) | (@as(u32, expect) << 8) | (mode << 16), .vel = packHalf2x16(vx, vy) };
    }
};

pub const WorkItem = extern struct { instance: u32, block: u32 };

comptime {
    std.debug.assert(@sizeOf(BodyInstance) == 64);
    std.debug.assert(@offsetOf(BodyInstance, "l0x") == 16);
    std.debug.assert(@offsetOf(BodyInstance, "bitmap_size") == 32);
    std.debug.assert(@offsetOf(BodyInstance, "vx") == 48);
    std.debug.assert(@sizeOf(BodyPoint) == 16);
    std.debug.assert(@sizeOf(WorkItem) == 8);
}

/// `EjectEntry` in bodies.glsl; the queue is a 16-byte header then entries.
pub const EjectEntry = extern struct { x: i32, y: i32, cell: u32, vel: u32 };
pub const eject_header_bytes = 16;
pub const eject_bytes = eject_header_bytes + gpu.constants.eject_capacity * @sizeOf(EjectEntry);

pub fn packHalf2x16(x: f32, y: f32) u32 {
    const hx: u16 = @bitCast(@as(f16, @floatCast(std.math.clamp(x, -60000, 60000))));
    const hy: u16 = @bitCast(@as(f16, @floatCast(std.math.clamp(y, -60000, 60000))));
    return @as(u32, hx) | (@as(u32, hy) << 16);
}

/// Per-tick capacities of one upload region.
pub const caps = struct {
    /// Raster, clear and extract instances together.
    pub const instances = 4096;
    /// 16x16 work items over all passes.
    pub const items = 32768;
    pub const points = 16384;
    /// New bitmap bytes per tick; more are deferred to the next tick.
    pub const staging = 512 * 1024;
    pub const copies = 1024;
};

const off_instances = 0;
const off_items = off_instances + caps.instances * @sizeOf(BodyInstance);
const off_points = off_items + caps.items * @sizeOf(WorkItem);
const off_staging = off_points + caps.points * @sizeOf(BodyPoint);
pub const region_bytes = off_staging + caps.staging;
pub const regions = pipeline_mod.frames_in_flight * pipeline_mod.max_ticks_per_frame;
pub const stats_words = stat_instance_base + caps.instances;

comptime {
    std.debug.assert(off_items % 64 == 0 and off_points % 64 == 0 and off_staging % 64 == 0 and region_bytes % 64 == 0);
}

/// Record of what the CPU put into one upload region.
pub const RegionData = struct {
    raster: Range = .{},
    clear: Range = .{},
    extract: Range = .{},
    raster_items: Range = .{},
    clear_items: Range = .{},
    extract_items: Range = .{},
    points: u32 = 0,
    copies: [caps.copies]vk.BufferCopy = undefined,
    copy_count: u32 = 0,
    staging_used: u32 = 0,
    tick: u32 = 0,
    /// The region has been recorded since it was written; its stats are
    /// valid once the frame slot has completed.
    recorded: bool = false,

    pub const Range = struct { start: u32 = 0, len: u32 = 0 };
};

pub const Error = error{ OutOfInstances, OutOfWorkItems, OutOfPoints, OutOfStaging };

/// Fills one region. Instances are appended per list (raster, then clear,
/// then extract, in that order: `beginClear`/`beginExtract` switch lists).
pub const RegionWriter = struct {
    gpu_: *BodiesGpu,
    index: u32,
    data: *RegionData,
    instances: []BodyInstance,
    items: []WorkItem,
    points: []BodyPoint,
    staging: []u8,
    /// Index of this region's first instance in the whole upload buffer.
    inst_base: u32,
    n_inst: u32 = 0,
    n_items: u32 = 0,
    list: enum { raster, clear, extract } = .raster,

    pub fn addInstance(self: *RegionWriter, inst: BodyInstance) Error!void {
        const bw = (inst.aabbW() + 15) / 16;
        const bh = (inst.aabbH() + 15) / 16;
        if (self.n_inst >= caps.instances) return error.OutOfInstances;
        if (self.n_items + bw * bh > caps.items) return error.OutOfWorkItems;
        var v = inst;
        v.index = self.n_inst;
        self.instances[self.n_inst] = v;
        for (0..bh) |by| {
            for (0..bw) |bx| {
                self.items[self.n_items] = .{ .instance = self.inst_base + self.n_inst, .block = @intCast(bx | (by << 16)) };
                self.n_items += 1;
            }
        }
        self.n_inst += 1;
        self.closeList();
    }

    fn closeList(self: *RegionWriter) void {
        const d = self.data;
        switch (self.list) {
            .raster => {
                d.raster.len = self.n_inst - d.raster.start;
                d.raster_items.len = self.n_items - d.raster_items.start;
            },
            .clear => {
                d.clear.len = self.n_inst - d.clear.start;
                d.clear_items.len = self.n_items - d.clear_items.start;
            },
            .extract => {
                d.extract.len = self.n_inst - d.extract.start;
                d.extract_items.len = self.n_items - d.extract_items.start;
            },
        }
    }

    pub fn beginClear(self: *RegionWriter) void {
        std.debug.assert(self.list == .raster);
        self.list = .clear;
        self.data.clear = .{ .start = self.n_inst };
        self.data.clear_items = .{ .start = self.n_items };
    }

    pub fn beginExtract(self: *RegionWriter) void {
        std.debug.assert(self.list == .clear);
        self.list = .extract;
        self.data.extract = .{ .start = self.n_inst };
        self.data.extract_items = .{ .start = self.n_items };
    }

    pub fn addPoint(self: *RegionWriter, p: BodyPoint) Error!void {
        if (self.data.points >= caps.points) return error.OutOfPoints;
        self.points[self.data.points] = p;
        self.data.points += 1;
    }

    pub fn pointsLeft(self: *const RegionWriter) u32 {
        return caps.points - self.data.points;
    }

    /// Queue `bytes` for upload into the atlas at `atlas_offset`.
    pub fn uploadBitmap(self: *RegionWriter, atlas_offset: u32, bytes: []const u8) Error!void {
        const d = self.data;
        const len: u32 = @intCast(bytes.len);
        if (d.staging_used + len > caps.staging or d.copy_count >= caps.copies) return error.OutOfStaging;
        @memcpy(self.staging[d.staging_used..][0..len], bytes);
        d.copies[d.copy_count] = .{
            .src_offset = @as(u64, self.index) * region_bytes + off_staging + d.staging_used,
            .dst_offset = atlas_offset,
            .size = len,
        };
        d.copy_count += 1;
        d.staging_used = (d.staging_used + len + 3) & ~@as(u32, 3);
    }

    pub fn stagingLeft(self: *const RegionWriter) u32 {
        return caps.staging - self.data.staging_used;
    }
};

/// Last values of one region's stats (from the frame that used it before).
pub const Stats = struct {
    totals: [stat_instance_base]u32 = @splat(0),
    eject_count: u32 = 0,
    tick: u32 = 0,

    pub fn get(self: *const Stats, s: Stat) u32 {
        return self.totals[@backingInt(s)];
    }
};

pub const Config = struct {
    /// Bytes of the bitmap atlas; must equal `bodies.Config.max_body_pixels`.
    atlas_bytes: u32 = 1 << 22,
    /// Reinsert ejected cells above their position until the particles
    /// layer consumes the eject queue.
    eject_fallback: bool = true,
};

pub const BodiesGpu = struct {
    ctx: *gpu.Context,
    cfg: Config,
    upload: gpu.Buffer,
    atlas: gpu.Buffer,
    eject: gpu.Buffer,
    stats: gpu.Buffer,
    claim: gpu.Image,
    raster_pipeline: vk.Pipeline,
    points_pipeline: vk.Pipeline,
    fallback_pipeline: vk.Pipeline,
    region_data: []RegionData,
    /// Region filled for the tick about to be recorded (set by `beginRegion`,
    /// consumed by `record`).
    prepared: ?u32 = null,
    last_stats: Stats = .{},

    pub fn init(ctx: *gpu.Context, cfg: Config, alloc: std.mem.Allocator) !BodiesGpu {
        var self: BodiesGpu = undefined;
        self.ctx = ctx;
        self.cfg = cfg;
        self.prepared = null;
        self.last_stats = .{};
        self.upload = try gpu.Buffer.initSlotted(ctx, regions * region_bytes, .{ .transfer_src = true }, .cpu_to_gpu);
        errdefer self.upload.deinit(ctx);
        self.atlas = try gpu.Buffer.initSlotted(ctx, cfg.atlas_bytes, .{ .transfer_dst = true }, .gpu_only);
        errdefer self.atlas.deinit(ctx);
        self.eject = try gpu.Buffer.init(ctx, eject_bytes, .{ .storage_buffer = true, .transfer_dst = true, .transfer_src = true }, .gpu_only);
        errdefer self.eject.deinit(ctx);
        self.eject.register(ctx, gpu.constants.slot_buf_eject);
        self.stats = try gpu.Buffer.initSlotted(ctx, regions * stats_words * 4, .{ .transfer_dst = true }, .gpu_to_cpu);
        errdefer self.stats.deinit(ctx);
        @memset(self.stats.bytes(), 0);
        self.claim = try gpu.Image.init(ctx, .{
            .width = cell.world_size,
            .height = cell.world_size,
            .format = .r32_uint,
            .usage = .{ .storage = true, .transfer_dst = true },
        });
        errdefer self.claim.deinit(ctx);
        try self.claim.initLayout(ctx, .general, true);
        self.claim.register(ctx, try ctx.descriptors.allocImageSlot());
        try ctx.runOnce(.compute, zeroInit, .{ ctx, &self });

        self.raster_pipeline = try gpu.pipelines.createCompute(ctx, &shaders.sim_bodies_raster_comp);
        errdefer gpu.pipelines.destroy(ctx, self.raster_pipeline);
        self.points_pipeline = try gpu.pipelines.createCompute(ctx, &shaders.sim_bodies_points_comp);
        errdefer gpu.pipelines.destroy(ctx, self.points_pipeline);
        self.fallback_pipeline = try gpu.pipelines.createCompute(ctx, &shaders.sim_bodies_eject_fallback_comp);
        errdefer gpu.pipelines.destroy(ctx, self.fallback_pipeline);
        self.region_data = try alloc.alloc(RegionData, regions);
        for (self.region_data) |*r| r.* = .{};
        return self;
    }

    fn zeroInit(cmd: vk.CommandBuffer, ctx: *gpu.Context, self: *const BodiesGpu) void {
        ctx.vkd.cmdFillBuffer(cmd, self.atlas.handle, 0, vk.WHOLE_SIZE, 0);
        ctx.vkd.cmdFillBuffer(cmd, self.eject.handle, 0, vk.WHOLE_SIZE, 0);
    }

    pub fn deinit(self: *BodiesGpu, alloc: std.mem.Allocator) void {
        const ctx = self.ctx;
        alloc.free(self.region_data);
        gpu.pipelines.destroy(ctx, self.fallback_pipeline);
        gpu.pipelines.destroy(ctx, self.points_pipeline);
        gpu.pipelines.destroy(ctx, self.raster_pipeline);
        self.claim.deinit(ctx);
        self.stats.deinit(ctx);
        self.eject.deinit(ctx);
        self.atlas.deinit(ctx);
        self.upload.deinit(ctx);
    }

    /// Start filling the region for (slot, tick_in_frame). The engine has
    /// waited for the slot, so the region and its stats are free; the stats
    /// of its previous use are folded into `last_stats` first.
    pub fn beginRegion(self: *BodiesGpu, slot: u32, tick_in_frame: u32, tick: u32) RegionWriter {
        const index = slot * pipeline_mod.max_ticks_per_frame + tick_in_frame;
        const d = &self.region_data[index];
        if (d.recorded) {
            const words = self.stats.typed(u32)[index * stats_words ..][0..stats_words];
            @memcpy(&self.last_stats.totals, words[0..stat_instance_base]);
            self.last_stats.tick = d.tick;
        }
        d.* = .{ .tick = tick };
        const base = @as(usize, index) * region_bytes;
        const bytes = self.upload.bytes()[base..][0..region_bytes];
        self.prepared = index;
        return .{
            .gpu_ = self,
            .index = index,
            .inst_base = @intCast((base + off_instances) / @sizeOf(BodyInstance)),
            .data = d,
            .instances = @alignCast(std.mem.bytesAsSlice(BodyInstance, bytes[off_instances..off_items])),
            .items = @alignCast(std.mem.bytesAsSlice(WorkItem, bytes[off_items..off_points])),
            .points = @alignCast(std.mem.bytesAsSlice(BodyPoint, bytes[off_points..off_staging])),
            .staging = bytes[off_staging..region_bytes],
        };
    }

    /// Per-instance overlap counts of the region's previous use (index =
    /// instance index in that tick's upload).
    pub fn instanceOverlaps(self: *const BodiesGpu, region: u32) []const u32 {
        return self.stats.typed(u32)[region * stats_words + stat_instance_base ..][0..caps.instances];
    }

    /// Pipeline slot "rasterize bodies (M7)": after commands, before
    /// compaction and the substep loop.
    pub fn record(self: *BodiesGpu, frame: *Frame) void {
        const index = self.prepared orelse return;
        self.prepared = null;
        frame.timed("bodies", recordInner, .{ self, frame, index });
    }

    const RasterPush = extern struct {
        upload_slot: u32,
        atlas_slot: u32,
        claim_slot: u32,
        stats_slot: u32,
        item_base: u32,
        stats_base: u32,
        mode: u32,
        mark_tiles: u32,
        stamp: u32,
    };

    fn recordInner(self: *BodiesGpu, frame: *Frame, index: u32) void {
        const ctx = frame.ctx;
        const cmd = frame.cmd;
        const d = &self.region_data[index];
        d.recorded = true;
        const stats_base = index * stats_words;

        // Transfers: new bitmaps, eject queue header, this region's stats.
        frame.fullBarrier();
        if (d.copy_count > 0) ctx.vkd.cmdCopyBuffer(cmd, self.upload.handle, self.atlas.handle, d.copies[0..d.copy_count]);
        ctx.vkd.cmdFillBuffer(cmd, self.eject.handle, 0, eject_header_bytes, 0);
        ctx.vkd.cmdFillBuffer(cmd, self.stats.handle, @as(u64, stats_base) * 4, stats_words * 4, 0);
        gpu.memory.memoryBarrier(ctx, cmd, .{ .all_transfer = true }, .{ .transfer_write = true }, .{ .compute_shader = true }, .{ .shader_storage_read = true, .shader_storage_write = true });

        var push: RasterPush = .{
            .upload_slot = self.upload.slot,
            .atlas_slot = self.atlas.slot,
            .claim_slot = self.claim.slot,
            .stats_slot = self.stats.slot,
            .item_base = 0,
            .stats_base = stats_base,
            .mode = 0,
            .mark_tiles = @intFromBool(frame.sleep),
            .stamp = (frame.tick & stamp_mask) << id_bits,
        };
        const upload_items: u32 = @intCast((@as(usize, index) * region_bytes + off_items) / @sizeOf(WorkItem));
        frame.bindCompute(self.raster_pipeline);
        const passes = [_]struct { mode: u32, items: RegionData.Range, barrier: bool }{
            .{ .mode = mode_extract, .items = d.extract_items, .barrier = false },
            .{ .mode = mode_reset, .items = d.raster_items, .barrier = true },
            .{ .mode = mode_claim, .items = d.raster_items, .barrier = true },
            .{ .mode = mode_write, .items = d.raster_items, .barrier = true },
            .{ .mode = mode_clear, .items = d.clear_items, .barrier = true },
        };
        for (passes) |p| {
            if (p.items.len > 0) {
                push.mode = p.mode;
                push.item_base = upload_items + p.items.start;
                frame.push(push);
                frame.dispatch(p.items.len, 1, 1);
            }
            if (p.barrier) frame.barrier();
        }

        if (d.points > 0) {
            frame.bindCompute(self.points_pipeline);
            frame.push(extern struct { upload_slot: u32, point_base: u32, count: u32, stats_slot: u32, stats_base: u32, mark_tiles: u32, seed: u32 }{
                .upload_slot = self.upload.slot,
                .point_base = @intCast((@as(usize, index) * region_bytes + off_points) / @sizeOf(BodyPoint)),
                .count = d.points,
                .stats_slot = self.stats.slot,
                .stats_base = stats_base,
                .mark_tiles = @intFromBool(frame.sleep),
                .seed = cell.hashU32(frame.tick +% 0xb0d1e5),
            });
            frame.dispatch((d.points + 63) / 64, 1, 1);
            frame.barrier();
        }
        if (self.cfg.eject_fallback and (d.raster_items.len > 0 or d.points > 0)) {
            frame.bindCompute(self.fallback_pipeline);
            frame.push(extern struct { stats_slot: u32, stats_base: u32, mark_tiles: u32 }{
                .stats_slot = self.stats.slot,
                .stats_base = stats_base,
                .mark_tiles = @intFromBool(frame.sleep),
            });
            frame.dispatch(gpu.constants.eject_capacity / 64, 1, 1);
            frame.barrier();
        }
    }
};

// Instance and item arrays are indexed from the start of the whole upload
// buffer: region `r`'s items start at r * region_bytes / 8 + off_items / 8.
comptime {
    std.debug.assert(region_bytes % @sizeOf(BodyInstance) == 0);
    std.debug.assert(off_items % @sizeOf(WorkItem) == 0);
}

test "bodies.glsl mirror" {
    const src = @embedFile("bodies_glsl");
    const constants = gpu.constants;
    var defines: [128]constants.Define = undefined;
    const n = constants.parseDefines(src, &defines);
    try std.testing.expect(n > 20);
    for (defines[0..n]) |d| {
        var found = false;
        inline for (mirrors) |m| {
            if (std.mem.eql(u8, m[0], d.name)) {
                found = true;
                try std.testing.expectEqual(@as(u64, m[1]), d.value);
            }
        }
        if (!found) {
            std.debug.print("bodies.glsl define {s} has no mirror in bodies_gpu.zig\n", .{d.name});
            return error.MirrorMissing;
        }
    }
}

test "half packing" {
    const v = packHalf2x16(1.5, -2);
    try std.testing.expectEqual(@as(u16, 0x3e00), @as(u16, @truncate(v)));
    try std.testing.expectEqual(@as(u16, 0xc000), @as(u16, @truncate(v >> 16)));
}
