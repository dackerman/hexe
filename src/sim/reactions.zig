//! The reactions and heat gather pass (M3), run once per substep before
//! movement: shaders/sim/grid/reactions.comp computes every active cell's
//! next value from a snapshot of its neighbors into a private image and a
//! per-tile change mask, reactions_commit.comp copies the changed cells back.
//! Owns the reaction table (SLOT_BUF_REACTIONS); events go to the engine's
//! queue (src/sim/events.zig). Rules and their order: docs/decisions/41-
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
/// Ticks a cell spends held at its boil point (counted in its state byte)
/// before it turns into its boil product: latent heat as time, so a fire
/// next to a pond does not flash it to steam.
pub const boil_latent: u32 = 40;
/// Burning cells heat themselves up to this temperature byte (900 C).
pub const burn_temp: u32 = 118;
/// Per tick, out of 256: a flammable cell next to fire ignites.
pub const ignite_contact_chance: u32 = 24;
/// Per tick, out of 256: air next to a burning cell becomes its flame /
/// its smoke (cumulative ranges of one roll).
pub const flame_chance: u32 = 40;
pub const smoke_chance: u32 = 10;

/// Events the pass appends go to the engine's one queue (events.zig,
/// SLOT_BUF_EVENTS, owned by src/sim/readback.zig).
pub const Event = @import("events.zig").Kind;

/// Mask words per tile list entry: one per tile row.
const mask_words_per_tile = cell.tile_size;

pub const Reactions = struct {
    ctx: *gpu.Context,
    table: gpu.Buffer,
    next: gpu.Image,
    masks: gpu.Buffer,
    react_pipeline: vk.Pipeline,
    commit_pipeline: vk.Pipeline,
    /// The air field runs: feeds_air gas created/removed by a reaction adds
    /// or removes air mass.
    air: bool,

    pub fn init(ctx: *gpu.Context, cfg: pipeline_mod.Config, alloc: std.mem.Allocator) !Reactions {
        _ = alloc;
        var self: Reactions = undefined;
        self.ctx = ctx;
        self.air = cfg.air;
        self.table = try gpu.Buffer.init(ctx, materials.gpu_tables.reaction_table_len * @sizeOf(materials.ReactionEntry), .{ .storage_buffer = true, .transfer_dst = true }, .gpu_only);
        errdefer self.table.deinit(ctx);
        self.table.register(ctx, gpu.constants.slot_buf_reactions);

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
        frame.push(extern struct { tick: u32, substep: u32, mark: u32, next: u32, masks: u32, air: u32 }{
            .tick = frame.tick,
            .substep = frame.substep,
            .mark = @intFromBool(frame.sleep),
            .next = self.next.slot,
            .masks = self.masks.slot,
            .air = @intFromBool(self.air),
        });
        frame.dispatchActiveTiles();
        frame.barrier();
        frame.bindCompute(self.commit_pipeline);
        frame.push(extern struct { next: u32, masks: u32 }{ .next = self.next.slot, .masks = self.masks.slot });
        frame.dispatchActiveTiles();
        frame.barrier();
    }
};
