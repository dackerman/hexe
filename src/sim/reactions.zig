//! The reactions and heat gather pass (M3), run once per substep before
//! movement: shaders/sim/grid/reactions.comp computes every active cell's
//! next value from a snapshot of its neighbors into a private image and a
//! per-tile change mask, reactions_commit.comp copies the changed cells back.
//! Owns the reaction table (SLOT_BUF_REACTIONS) and the GPU -> CPU event
//! ring (SLOT_BUF_EVENTS). Rules and their order: docs/decisions/41-
//! reactions-pass.md; the CPU mirror is src/sim/reference/grid.zig.
const std = @import("std");
const gpu = @import("../gpu/gpu.zig");
const vk = gpu.vk;
const cell = @import("cell.zig");
const materials = @import("materials.zig");
const pipeline_mod = @import("pipeline.zig");
const Frame = pipeline_mod.Frame;
const shaders = @import("shaders");

// ---- tuning, mirrored in shaders/common.glsl ----
pub const salt_cell: u32 = 0x4e1;
pub const salt_pair: u32 = 0x4e2;
/// Conduction per substep: dT = sum(min(k_a, k_b) * (T_n - T)) >> heat_shift
/// (k / 1024 per tick over the 8 substeps), stochastically rounded.
pub const heat_shift = 13;
/// Emission per tick moves at most (gap >> emit_gap_shift) bytes per pair.
pub const emit_gap_shift = 3;
/// An emitter loses (what it gave) >> emit_drain_shift: emitters are mostly
/// heat sources, but pools of them still cool down eventually.
pub const emit_drain_shift = 2;
/// Burning cells heat themselves up to this temperature byte (900 C).
pub const burn_temp: u32 = 118;
/// Per tick, out of 256: a flammable cell next to fire ignites.
pub const ignite_contact_chance: u32 = 24;
/// Per tick, out of 256: air next to a burning cell becomes its flame /
/// its smoke (cumulative ranges of one roll).
pub const flame_chance: u32 = 40;
pub const smoke_chance: u32 = 10;

/// Event kinds. Below 128: `data.materials.Event` (explode, pressure),
/// appended by material rules; from 128: the engine's own.
pub const Event = enum(u32) {
    none = 0,
    explode = 1,
    pressure = 2,
    /// A particle-backed cell changed material in a reaction; payload is the
    /// owner image value (the particle index). For the liquid solver (M6).
    particle_cell_changed = 128,
    _,
};

pub const event_capacity = 4096;

/// One event as the GPU writes it (common.glsl `emit_event`).
pub const EventGpu = extern struct {
    /// x | y << 16, world cell.
    pos: u32,
    kind: u32,
    /// Material id for material events, particle index for
    /// particle_cell_changed.
    payload: u32,
    tick: u32,

    pub fn x(e: EventGpu) u32 {
        return e.pos & 0xffff;
    }
    pub fn y(e: EventGpu) u32 {
        return e.pos >> 16;
    }
    pub fn lessThan(_: void, a: EventGpu, b: EventGpu) bool {
        if (a.tick != b.tick) return a.tick < b.tick;
        if (a.pos != b.pos) return a.pos < b.pos;
        if (a.kind != b.kind) return a.kind < b.kind;
        return a.payload < b.payload;
    }
};

/// Header (count, capacity, dropped, pad) then the ring.
pub const event_header_words = 4;
pub const event_buffer_bytes = event_header_words * 4 + event_capacity * @sizeOf(EventGpu);

/// Mask words per tile list entry: one per tile row.
const mask_words_per_tile = cell.tile_size;

pub const Reactions = struct {
    ctx: *gpu.Context,
    table: gpu.Buffer,
    events: gpu.Buffer,
    next: gpu.Image,
    masks: gpu.Buffer,
    react_pipeline: vk.Pipeline,
    commit_pipeline: vk.Pipeline,
    /// Event ring count at the last `drainEvents`.
    events_read: u32 = 0,

    pub fn init(ctx: *gpu.Context, cfg: pipeline_mod.Config, alloc: std.mem.Allocator) !Reactions {
        _ = cfg;
        _ = alloc;
        var self: Reactions = undefined;
        self.ctx = ctx;
        self.events_read = 0;
        self.table = try gpu.Buffer.init(ctx, materials.gpu_tables.reaction_table_len * @sizeOf(materials.ReactionEntry), .{ .storage_buffer = true, .transfer_dst = true }, .gpu_only);
        errdefer self.table.deinit(ctx);
        self.table.register(ctx, gpu.constants.slot_buf_reactions);

        self.events = try gpu.Buffer.init(ctx, event_buffer_bytes, .{ .storage_buffer = true, .transfer_dst = true }, .cpu_to_gpu);
        errdefer self.events.deinit(ctx);
        self.events.register(ctx, gpu.constants.slot_buf_events);
        @memset(self.events.bytes(), 0);
        self.events.typed(u32)[1] = event_capacity;

        self.next = try gpu.Image.init(ctx, .{
            .width = cell.world_size,
            .height = cell.world_size,
            .format = .r32_uint,
            .usage = .{ .storage = true },
        });
        errdefer self.next.deinit(ctx);
        try self.next.initLayout(ctx, .general, false);
        self.next.register(ctx, try ctx.descriptors.allocImageSlot());

        self.masks = try gpu.Buffer.initSlotted(ctx, cell.tile_count * mask_words_per_tile * 4, .{}, .gpu_only);
        errdefer self.masks.deinit(ctx);

        self.react_pipeline = try gpu.pipelines.createCompute(ctx, &shaders.sim_grid_reactions_comp);
        errdefer gpu.pipelines.destroy(ctx, self.react_pipeline);
        self.commit_pipeline = try gpu.pipelines.createCompute(ctx, &shaders.sim_grid_reactions_commit_comp);
        return self;
    }

    pub fn deinit(self: *Reactions) void {
        const ctx = self.ctx;
        gpu.pipelines.destroy(ctx, self.commit_pipeline);
        gpu.pipelines.destroy(ctx, self.react_pipeline);
        self.masks.deinit(ctx);
        self.next.deinit(ctx);
        self.events.deinit(ctx);
        self.table.deinit(ctx);
    }

    /// Replace the GPU reaction table. Waits for the GPU to go idle; call
    /// between frames (startup, hot reload).
    pub fn uploadReactions(self: *Reactions, tables: *const materials.Tables) !void {
        const ctx = self.ctx;
        ctx.waitIdle();
        var staging = try gpu.Buffer.init(ctx, self.table.size, .{ .transfer_src = true }, .cpu_to_gpu);
        defer staging.deinit(ctx);
        @memcpy(staging.bytes(), tables.reactionBytes());
        try ctx.runOnce(.compute, copyWhole, .{ ctx, staging.handle, self.table.handle, self.table.size });
    }

    fn copyWhole(cmd: vk.CommandBuffer, ctx: *gpu.Context, src: vk.Buffer, dst: vk.Buffer, size: u64) void {
        ctx.vkd.cmdCopyBuffer(cmd, src, dst, &.{.{ .src_offset = 0, .dst_offset = 0, .size = size }});
    }

    /// Reactions + commit over the active tiles; before movement.
    pub fn recordSubstep(self: *Reactions, frame: *Frame) void {
        frame.timed("reactions", recordInner, .{ self, frame });
    }

    fn recordInner(self: *Reactions, frame: *Frame) void {
        frame.bindCompute(self.react_pipeline);
        frame.push(extern struct { tick: u32, substep: u32, mark: u32, next: u32, masks: u32 }{
            .tick = frame.tick,
            .substep = frame.substep,
            .mark = @intFromBool(frame.sleep),
            .next = self.next.slot,
            .masks = self.masks.slot,
        });
        frame.dispatchActiveTiles();
        frame.barrier();
        frame.bindCompute(self.commit_pipeline);
        frame.push(extern struct { next: u32, masks: u32 }{ .next = self.next.slot, .masks = self.masks.slot });
        frame.dispatchActiveTiles();
        frame.barrier();
    }

    /// Total events appended so far (wrapping counter). The GPU must be idle
    /// or past the work of interest.
    pub fn eventCount(self: *const Reactions) u32 {
        return @atomicLoad(u32, &self.events.typed(u32)[0], .acquire);
    }

    /// Copy the events appended since the last drain into `out` (oldest
    /// first, up to out.len); returns how many were copied and how many
    /// were lost to ring overwrite or a short `out`. Synchronous: the GPU
    /// must be idle (tests, scenario runner). The per-frame asynchronous
    /// readback belongs to the readback mirror (M4).
    pub fn drainEvents(self: *Reactions, out: []EventGpu) struct { n: usize, lost: u32 } {
        const count = self.eventCount();
        const new = count -% self.events_read;
        const ring: []const EventGpu = @as([*]const EventGpu, @ptrCast(@alignCast(self.events.mapped.? + event_header_words * 4)))[0..event_capacity];
        const available: u32 = @min(new, event_capacity);
        const n: usize = @min(available, out.len);
        const first = count -% available;
        for (0..n) |i| out[i] = ring[(first +% @as(u32, @intCast(i))) % event_capacity];
        self.events_read = count;
        return .{ .n = n, .lost = new - @as(u32, @intCast(n)) };
    }
};
