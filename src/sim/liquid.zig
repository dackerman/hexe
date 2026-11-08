//! Liquid solver (M6, docs/04-fluids.md "Liquid solver"): FLIP/APIC particles
//! with a multigrid pressure projection on a 1024 x 1024 MAC grid, sleeping
//! into plain cells when still and waking when disturbed.
//!
//! Per tick, after the grid substeps (docs/01-architecture.md step 6):
//!   wake     command boxes -> wake requests; lift last tick's particles out
//!            of the cell image (killing those whose cell another pass
//!            changed); wake requested cells into particles (deterministic
//!            ranks, budget, capacity)
//!   sort     counting sort of particles by grid cell (+ per-bin index sort),
//!            reorder into the other particle set (compaction)
//!   p2g      APIC gather onto the MAC grid, cut-cell weights, gravity, rhs
//!   project  multigrid V-cycles (red-black Gauss-Seidel), pressure gradient
//!   g2p      FLIP/PIC blend, APIC affine, RK2 advection marched through the
//!            pixel grid, ballistic/liquid mode switches, wake by impact
//!   raster   one particle per pixel (atomic min), separation, hole
//!            compaction, sleep
//!
//! The particle arrays and the obstacle coarsening are this subsystem's own,
//! pending the shared particle buffer and solid mask from the particles and
//! air subsystems: see `particleArrays` / `obstacleSource` and
//! docs/decisions/80-liquid-integration.md for the integration steps (80-87
//! hold the rest of the design decisions).
const std = @import("std");
const gpu = @import("../gpu/gpu.zig");
const vk = gpu.vk;
const cell = @import("cell.zig");
const commands = @import("commands.zig");
const pipeline_mod = @import("pipeline.zig");
const Frame = pipeline_mod.Frame;
const shaders = @import("shaders");

// ---- mirrors of shaders/sim/liquid/liquid.glsl (test "liquid.glsl mirror") ----
pub const grid = 1024;
pub const grid_mask = grid - 1;
pub const grid_shift = 10;
pub const levels = 6;
pub const none: u32 = 0xffff_ffff;
pub const bind_pending: u32 = 0x8000_0000;

pub const Buf = enum(u32) {
    state = 0,
    pos = 1, // + set
    vel = 3,
    aff = 5,
    info = 7,
    bind = 9,
    bin_of = 11,
    bin_count = 12,
    bin_scan = 13,
    bin_sums = 14,
    sorted = 15,
    u = 16,
    v = 17,
    u_old = 18,
    v_old = 19,
    uw = 20,
    vw = 21,
    mg_type = 22,
    mg_p = 23,
    mg_b = 24,
    tile_count = 25,
    tile_scan = 26,
    tile_sums = 27,
};
pub const buf_count = 28;

pub const St = struct {
    pub const count = 0;
    pub const args_particles = 1;
    pub const args_cells = 4;
    pub const args_scan = 7;
    pub const args_mg = 10;
    pub const spawned = 52;
    pub const refused = 53;
    pub const killed = 54;
    pub const slept = 55;
    pub const merged = 56;
    pub const ballistic = 57;
    pub const alive = 58;
    pub const candidates = 59;
    pub const grid_valid = 60;
    pub const total_merged = 61;
    pub const total_killed = 62;
    pub const total_slept = 63;
    pub const moved = 46;
    pub const triggers = 47;
    pub const grace = 64;
    pub const words = 80;
};

pub const mode_dead = 0;
pub const mode_liquid = 1;
pub const mode_ballistic = 2;
pub const merge_ticks = 15;
pub const type_air = 0;
pub const type_fluid = 1;
pub const type_solid = 2;
pub const wake_hops_command = 3;
pub const wake_hops_powder = 4;
pub const wake_hops_particle = 2;
pub const wake_hops_flow = 1;
pub const pc_mark_tiles = 1;
pub const pc_overlay = 2;
pub const pc_no_spawn = 4;
/// g2p hands particles leaving the liquid to the shared ballistic buffer.
pub const pc_handoff = 8;

/// Ticks between a tick and the CPU's use of its counters to choose the
/// recording mode. The engine has waited for every tick this old (2 frames
/// in flight x 4 ticks per frame), so the choice never stalls and depends
/// on ticks only, not on frame pacing: the simulation stays deterministic.
pub const mode_lag = 12;
const ring_len = 16;

/// How much of the solver a tick records (docs/decisions/86-liquid-idle.md).
pub const Mode = enum {
    /// Everything.
    full,
    /// Everything, but wakes are deferred (requests kept): the particles
    /// left run out (sleep) so the solver can stop.
    drain,
    /// Wake detection only (deferred); no particles exist and nothing is
    /// out of balance. A still lake costs a handful of tiny dispatches.
    idle,
};

/// Tunables (reasoning in docs/decisions/82-86).
pub const Params = struct {
    /// Hard ceiling on awake liquid; wakes beyond it are refused and the
    /// water stays cellular.
    capacity: u32 = 1 << 20,
    /// Cells woken per tick at most; the rest wait (the wake stops spreading
    /// while the budget is exhausted).
    wake_budget: u32 = 65536,
    /// Ticks below `sleep_speed` before a supported particle sleeps.
    sleep_ticks: u32 = 16,
    /// px/s.
    sleep_speed: f32 = 8.0,
    /// px/s: liquid particles faster than this wake sleeping liquid they touch.
    wake_speed: f32 = 40.0,
    /// FLIP share of the FLIP/PIC blend.
    flip: f32 = 0.95,
    /// px/s^2 (+y down).
    gravity: f32 = 196.0,
    /// px/s; 480 = 8 px per tick, the grid's own speed limit.
    max_speed: f32 = 480.0,
    vcycles: u32 = 4,
    pre_smooth: u32 = 2,
    post_smooth: u32 = 2,
    coarsest_iterations: u32 = 40,
    /// Scale of the coarse-grid correction (piecewise-constant prolongation
    /// under-corrects; > 1 compensates). 1.5 halves the residual after 4
    /// V-cycles compared to 1.0 (decision 82).
    correction: f32 = 1.5,
    /// 1/s: linear drag on liquid-mode particles (0 = off; settling is the
    /// speed-banded `settle_*` drag, decision 83).
    damping: f32 = 0.0,
    /// Divergence target per excess particle in an over-full cell (pushes
    /// particles apart; 0 = off).
    density_gain: f32 = 32.0,
    /// Settling drag (1/s) on liquid-mode particles at rest, fading linearly
    /// to zero at `settle_speed` (px/s): residual sloshing dies out so pools
    /// sleep, fast flows are untouched.
    settle_rate: f32 = 4.0,
    settle_speed: f32 = 64.0,
    /// Settling drag multiplier for liquid resting on sleeping liquid or a
    /// solid (the soft band before sleep, docs/04-fluids.md "Hybrid pools").
    band_factor: f32 = 3.0,
    /// px/s^2: sleeping liquid that the projection accelerates faster than
    /// this (out of hydrostatic balance) wakes.
    imbalance_accel: f32 = 80.0,
    /// px/s: a liquid particle the solve pushes into sleeping liquid this
    /// fast wakes the pixel in its way.
    push_speed: f32 = 4.0,
    /// Ticks the solver keeps running after the last awake particle or
    /// moving body of cellular solver liquid, checking that what fell
    /// asleep is in balance.
    grace_ticks: u32 = 30,
};

/// "name=value" for one `Params` field (command line tuning).
pub fn parseParam(p: *Params, text: []const u8) !void {
    const eq = std.mem.indexOfScalar(u8, text, '=') orelse return error.BadLiquidParam;
    const name = text[0..eq];
    const value = text[eq + 1 ..];
    inline for (@typeInfo(Params).@"struct".field_names) |field| {
        if (std.mem.eql(u8, field, name)) {
            const T = @TypeOf(@field(p.*, field));
            @field(p.*, field) = if (T == f32) try std.fmt.parseFloat(f32, value) else try std.fmt.parseInt(T, value, 10);
            return;
        }
    }
    return error.UnknownLiquidParam;
}

/// GLSL `PC` in liquid.glsl.
const Push = extern struct {
    buf: u32,
    overlay: u32,
    tick: u32,
    src: u32,
    dst: u32,
    level: u32 = 0,
    mode: u32 = 0,
    n: u32 = 0,
    cap: u32,
    flags: u32,
    box_origin: [2]i32 = .{ 0, 0 },
    box_size: [2]u32 = .{ 0, 0 },
    dt: f32,
    gravity: f32,
    flip: f32,
    sleep_speed: f32,
    sleep_ticks: u32,
    wake_speed: f32,
    max_speed: f32,
    correction: f32,
    damping: f32,
    density_gain: f32,
    settle_rate: f32,
    settle_speed: f32,
    imbalance_accel: f32,
    push_speed: f32,
    band_factor: f32,
};

comptime {
    std.debug.assert(@offsetOf(Push, "box_origin") == 40);
    std.debug.assert(@offsetOf(Push, "dt") == 56);
    std.debug.assert(@sizeOf(Push) == 116);
}

const Kernel = enum {
    wake_commands,
    lift,
    wake,
    scan_local,
    scan_sums,
    finalize,
    bin_count,
    bin_scatter,
    bin_fixup,
    reorder,
    p2g,
    classify,
    divergence,
    mg_build,
    mg_smooth,
    mg_restrict,
    mg_coarsest,
    project,
    g2p,
    claim,
    drop,
    settle,
    flush,
};

fn kernelCode(k: Kernel) gpu.pipelines.Spirv {
    return switch (k) {
        .wake_commands => &shaders.sim_liquid_wake_commands_comp,
        .lift => &shaders.sim_liquid_lift_comp,
        .wake => &shaders.sim_liquid_wake_comp,
        .scan_local => &shaders.sim_liquid_scan_local_comp,
        .scan_sums => &shaders.sim_liquid_scan_sums_comp,
        .finalize => &shaders.sim_liquid_finalize_comp,
        .bin_count => &shaders.sim_liquid_bin_count_comp,
        .bin_scatter => &shaders.sim_liquid_bin_scatter_comp,
        .bin_fixup => &shaders.sim_liquid_bin_fixup_comp,
        .reorder => &shaders.sim_liquid_reorder_comp,
        .p2g => &shaders.sim_liquid_p2g_comp,
        .classify => &shaders.sim_liquid_classify_comp,
        .divergence => &shaders.sim_liquid_divergence_comp,
        .mg_build => &shaders.sim_liquid_mg_build_comp,
        .mg_smooth => &shaders.sim_liquid_mg_smooth_comp,
        .mg_restrict => &shaders.sim_liquid_mg_restrict_comp,
        .mg_coarsest => &shaders.sim_liquid_mg_coarsest_comp,
        .project => &shaders.sim_liquid_project_comp,
        .g2p => &shaders.sim_liquid_g2p_comp,
        .claim => &shaders.sim_liquid_claim_comp,
        .drop => &shaders.sim_liquid_drop_comp,
        .settle => &shaders.sim_liquid_settle_comp,
        .flush => &shaders.sim_liquid_flush_comp,
    };
}

const kernel_count = @typeInfo(Kernel).@"enum".field_names.len;

fn buf(b: Buf) u32 {
    return @backingInt(b);
}

pub fn levelSize(l: u32) u32 {
    return @as(u32, grid) >> @intCast(l);
}

pub fn levelOffset(l: u32) u32 {
    var off: u32 = 0;
    var k: u32 = 0;
    while (k < l) : (k += 1) off += levelSize(k) * levelSize(k);
    return off;
}

const mg_cells = levelOffset(levels);
const grid_cells = grid * grid;

/// Snapshot of the solver's per-tick counters (STATE words), one tick late.
pub const Stats = struct {
    /// Particles alive at the end of the tick.
    alive: u32 = 0,
    spawned: u32 = 0,
    refused: u32 = 0,
    killed: u32 = 0,
    slept: u32 = 0,
    merged: u32 = 0,
    ballistic: u32 = 0,
    candidates: u32 = 0,
    total_merged: u32 = 0,
    total_killed: u32 = 0,
    total_slept: u32 = 0,
    /// Wake decisions this tick by trigger: request (commands, wake_at,
    /// spread), powder, landing, pushed by awake water, out of balance.
    triggers: [5]u32 = @splat(0),
    grace: u32 = 0,
    moved: u32 = 0,
};

pub const Liquid = struct {
    ctx: *gpu.Context,
    params: Params,
    buffers: [buf_count]gpu.Buffer,
    base_slot: u32,
    wake: gpu.Image,
    /// The renderer's debug overlay image (SLOT_IMG_DEBUG_OVERLAY), set by
    /// the engine: cleared and written while Frame.overlay is
    /// liquid_particles.
    overlay_image: vk.Image = .null,
    /// Hand particles leaving the liquid to the shared ballistic pass
    /// (Config.liquid_handoff).
    handoff: bool = true,
    /// Host-visible copies of STATE, one per tick, ring of `ring_len`.
    readback: gpu.Buffer,
    pipelines: [kernel_count]vk.Pipeline,
    /// Particle set holding the current particles (0 or 1).
    set: u32 = 0,
    /// Particles may exist (the solver ran since the last flush).
    live: bool = false,
    /// Tick of the most recent stats copy.
    last_tick: u32 = 0,
    mode: Mode = .full,
    /// First tick of the current mode / of this enabled stretch.
    mode_since: u32 = 0,
    enabled_since: ?u32 = null,

    pub fn init(ctx: *gpu.Context, cfg: pipeline_mod.Config, alloc: std.mem.Allocator) !Liquid {
        _ = alloc;
        const p = cfg.liquid_params;
        std.debug.assert(p.capacity > 0 and p.capacity <= 1 << 22);
        var self: Liquid = .{
            .ctx = ctx,
            .params = p,
            .buffers = @splat(.{}),
            .base_slot = 0,
            .wake = .{},
            .readback = .{},
            .pipelines = @splat(.null),
        };
        errdefer self.destroy();

        const cap: u64 = p.capacity;
        const sizes = [buf_count]u64{
            St.words * 4, // state
            cap * 8, cap * 8, // pos
            cap * 8, cap * 8, // vel
            cap * 16, cap * 16, // aff
            cap * 4, cap * 4, // info
            cap * 4, cap * 4, // bind
            cap * 4, // bin_of
            grid_cells * 4, // bin_count
            grid_cells * 4, // bin_scan
            (grid_cells / 1024 + 4) * 4, // bin_sums (+ total)
            cap * 4, // sorted
            grid_cells * 4, grid_cells * 4, grid_cells * 4, grid_cells * 4, grid_cells * 4, grid_cells * 4, // u v u_old v_old uw vw
            mg_cells * 4, mg_cells * 4, mg_cells * 4, // mg type p b
            cell.tile_count * 4, cell.tile_count * 4, 16 * 4, // tile count scan sums
        };
        for (&self.buffers, sizes, 0..) |*b, size, i| {
            const usage: vk.BufferUsageFlags = .{ .transfer_dst = true, .transfer_src = true, .indirect_buffer = i == 0 };
            b.* = try gpu.Buffer.initSlotted(ctx, size, usage, .gpu_only);
            if (i == 0) self.base_slot = b.slot;
            // Shaders address buffer k as base + k.
            if (b.slot != self.base_slot + i) return error.LiquidSlotsNotConsecutive;
        }

        const world_image = gpu.memory.ImageDesc{
            .width = cell.world_size,
            .height = cell.world_size,
            .format = .r32_uint,
            .usage = .{ .storage = true, .transfer_dst = true },
        };
        self.wake = try gpu.Image.init(ctx, world_image);
        try self.wake.initLayout(ctx, .general, true);
        self.wake.register(ctx, gpu.constants.slot_img_liquid_wake);

        comptime std.debug.assert(mode_lag > pipeline_mod.frames_in_flight * pipeline_mod.max_ticks_per_frame and mode_lag < ring_len);
        self.readback = try gpu.Buffer.init(ctx, ring_len * St.words * 4, .{ .transfer_dst = true }, .gpu_to_cpu);
        @memset(self.readback.bytes(), 0);

        try ctx.runOnce(.compute, zeroAll, .{ ctx, &self });
        for (&self.pipelines, 0..) |*pl, i| pl.* = try gpu.pipelines.createCompute(ctx, kernelCode(@fromBackingInt(@intCast(i))));
        return self;
    }

    fn zeroAll(cmd: vk.CommandBuffer, ctx: *gpu.Context, self: *const Liquid) void {
        for (self.buffers) |b| ctx.vkd.cmdFillBuffer(cmd, b.handle, 0, vk.WHOLE_SIZE, 0);
    }

    fn destroy(self: *Liquid) void {
        const ctx = self.ctx;
        for (self.pipelines) |pl| if (pl != .null) gpu.pipelines.destroy(ctx, pl);
        self.readback.deinit(ctx);
        self.wake.deinit(ctx);
        for (&self.buffers) |*b| b.deinit(ctx);
    }

    pub fn deinit(self: *Liquid) void {
        self.destroy();
    }

    /// Counters of the most recently recorded tick. Valid once the engine
    /// has waited for that frame (e.g. after `Engine.finish`).
    pub fn stats(self: *const Liquid) Stats {
        return statsOf(self.ringWords(self.last_tick));
    }

    /// Counters of a tick the GPU has certainly finished (mode_lag ticks
    /// back): safe to read any time, e.g. for the HUD.
    pub fn statsSettled(self: *const Liquid) Stats {
        return statsOf(self.ringWords(self.last_tick -% mode_lag));
    }

    fn ringWords(self: *const Liquid, tick: u32) *const [St.words]u32 {
        return self.readback.typed(u32)[(tick % ring_len) * St.words ..][0..St.words];
    }

    fn statsOf(w: *const [St.words]u32) Stats {
        return .{
            .alive = w[St.alive],
            .spawned = w[St.spawned],
            .refused = w[St.refused],
            .killed = w[St.killed],
            .slept = w[St.slept],
            .merged = w[St.merged],
            .ballistic = w[St.ballistic],
            .candidates = w[St.candidates],
            .total_merged = w[St.total_merged],
            .total_killed = w[St.total_killed],
            .total_slept = w[St.total_slept],
            .triggers = w[St.triggers..][0..5].*,
            .grace = w[St.grace],
            .moved = w[St.moved],
        };
    }

    /// Choose this tick's mode from the counters of tick - mode_lag.
    fn decide(self: *Liquid, tick: u32) Mode {
        const since = self.enabled_since orelse blk: {
            self.enabled_since = tick;
            self.mode = .full;
            self.mode_since = tick;
            break :blk tick;
        };
        if (tick -% since < mode_lag) return self.mode;
        const seen = tick - mode_lag;
        const s = statsOf(self.ringWords(seen));
        const quiet = s.alive == 0 and s.grace == 0 and s.candidates == 0 and s.moved == 0;
        const next: Mode = switch (self.mode) {
            .full => if (quiet) .drain else .full,
            // Wakes waiting: run them. Quiet during the drain (no spawns
            // since): nothing can be awake any more.
            .drain => if (s.candidates > 0) .full else if (seen >= self.mode_since and quiet) .idle else .drain,
            .idle => if (s.candidates > 0 or s.moved > 0) .full else .idle,
        };
        if (next != self.mode) {
            self.mode = next;
            self.mode_since = tick;
        }
        return self.mode;
    }

    /// Debug/tests: copy `out.len` words of private buffer `b` from word
    /// `offset` (the GPU must be idle, e.g. after `Engine.finish`).
    pub fn debugRead(self: *Liquid, b: Buf, set: u32, offset: u64, out: []u32) !void {
        const ctx = self.ctx;
        var staging = try gpu.Buffer.init(ctx, out.len * 4, .{ .transfer_dst = true }, .gpu_to_cpu);
        defer staging.deinit(ctx);
        const src = self.buffers[buf(b) + set].handle;
        try ctx.runOnce(.compute, copyRegion, .{ ctx, src, staging.handle, offset * 4, out.len * 4 });
        @memcpy(out, staging.typed(u32)[0..out.len]);
    }

    /// Particle set holding the particles after the last recorded tick.
    pub fn currentSet(self: *const Liquid) u32 {
        return self.set;
    }

    fn copyRegion(cmd: vk.CommandBuffer, ctx: *gpu.Context, src: vk.Buffer, dst: vk.Buffer, offset: u64, size: u64) void {
        gpu.memory.memoryBarrier(ctx, cmd, .{ .all_commands = true }, .{ .memory_write = true }, .{ .all_transfer = true }, .{ .transfer_read = true });
        ctx.vkd.cmdCopyBuffer(cmd, src, dst, &.{.{ .src_offset = offset, .dst_offset = 0, .size = size }});
        gpu.memory.memoryBarrier(ctx, cmd, .{ .all_transfer = true }, .{ .transfer_write = true }, .{ .host = true }, .{ .host_read = true });
    }

    // ---- recording helpers ----

    fn push(self: *const Liquid, f: *Frame, overrides: anytype) void {
        var pc: Push = .{
            .buf = self.base_slot,
            .overlay = gpu.constants.slot_img_debug_overlay,
            .tick = f.tick,
            .src = self.set,
            .dst = self.set ^ 1,
            .cap = self.params.capacity,
            .flags = self.flags(f),
            .dt = 1.0 / 60.0,
            .gravity = self.params.gravity,
            .flip = self.params.flip,
            .sleep_speed = self.params.sleep_speed,
            .sleep_ticks = self.params.sleep_ticks,
            .wake_speed = self.params.wake_speed,
            .max_speed = self.params.max_speed,
            .correction = self.params.correction,
            .damping = self.params.damping,
            .density_gain = self.params.density_gain,
            .settle_rate = self.params.settle_rate,
            .settle_speed = self.params.settle_speed,
            .imbalance_accel = self.params.imbalance_accel,
            .push_speed = self.params.push_speed,
            .band_factor = self.params.band_factor,
        };
        inline for (@typeInfo(@TypeOf(overrides)).@"struct".field_names) |name| @field(pc, name) = @field(overrides, name);
        f.push(pc);
    }

    fn flags(self: *const Liquid, f: *const Frame) u32 {
        return (if (f.sleep) @as(u32, pc_mark_tiles) else 0) | (if (self.showOverlay(f)) @as(u32, pc_overlay) else 0) | (if (self.handoff) @as(u32, pc_handoff) else 0);
    }

    fn showOverlay(self: *const Liquid, f: *const Frame) bool {
        return self.overlay_image != .null and f.overlay == gpu.constants.overlay_liquid_particles;
    }

    fn bind(self: *const Liquid, f: *Frame, k: Kernel) void {
        f.bindCompute(self.pipelines[@backingInt(k)]);
    }

    fn indirect(self: *const Liquid, f: *Frame, word: u32) void {
        f.ctx.vkd.cmdDispatchIndirect(f.cmd, self.buffers[0].handle, word * 4);
    }

    /// Compute/transfer writes -> compute reads/writes and indirect reads.
    fn bar(f: *Frame) void {
        gpu.memory.memoryBarrier(
            f.ctx,
            f.cmd,
            .{ .compute_shader = true, .all_transfer = true },
            .{ .shader_storage_write = true, .transfer_write = true },
            .{ .compute_shader = true, .draw_indirect = true, .all_transfer = true },
            .{ .shader_storage_read = true, .shader_storage_write = true, .indirect_command_read = true, .transfer_read = true, .transfer_write = true },
        );
    }

    fn run(self: *const Liquid, f: *Frame, k: Kernel, overrides: anytype, word: u32) void {
        self.bind(f, k);
        self.push(f, overrides);
        self.indirect(f, word);
    }

    fn runDirect(self: *const Liquid, f: *Frame, k: Kernel, overrides: anytype, x: u32, y: u32) void {
        self.bind(f, k);
        self.push(f, overrides);
        f.dispatch(x, y, 1);
    }

    /// Exclusive scan of `n` u32 (<= 1024 * 1024) from `input` into `out`
    /// with block totals in `sums` (consumers add them: scan_prefix()).
    fn scan(self: *const Liquid, f: *Frame, input: Buf, out: Buf, sums: Buf, n: u32, gated: bool) void {
        const blocks = (n + 1023) / 1024;
        if (gated) {
            self.run(f, .scan_local, .{ .mode = buf(input), .level = buf(out), .dst = buf(sums), .n = n }, St.args_scan);
        } else {
            self.runDirect(f, .scan_local, .{ .mode = buf(input), .level = buf(out), .dst = buf(sums), .n = n }, blocks, 1);
        }
        bar(f);
        self.runDirect(f, .scan_sums, .{ .dst = buf(sums), .n = blocks }, 1, 1);
        bar(f);
    }

    /// Gated dispatch over level l: one 16x16 group per 16x16 cells.
    fn mgCells(l: u32) u32 {
        return St.args_mg + 6 * l;
    }
    /// Gated dispatch over level l: one group per 32x32 tile of one color.
    fn mgTiles(l: u32) u32 {
        return St.args_mg + 6 * l + 3;
    }

    // ---- per tick ----

    /// One solver tick (pipeline step 6).
    pub fn record(self: *Liquid, f: *Frame) void {
        self.live = true;
        const mode = self.decide(f.tick);
        const ctx = f.ctx;
        // Reset this tick's counters (words spawned..candidates, moved).
        ctx.vkd.cmdFillBuffer(f.cmd, self.buffers[0].handle, St.spawned * 4, (St.grid_valid - St.spawned) * 4, 0);
        ctx.vkd.cmdFillBuffer(f.cmd, self.buffers[0].handle, St.moved * 4, 6 * 4, 0);
        if (self.showOverlay(f)) {
            const zero = vk.ClearColorValue{ .float_32 = .{ 0, 0, 0, 0 } };
            ctx.vkd.cmdClearColorImage(f.cmd, self.overlay_image, .general, &zero, &.{gpu.memory.color_range});
        }
        bar(f);
        f.timed("lq_wake", recordWake, .{ self, f, mode });
        if (mode != .idle) {
            f.timed("lq_sort", recordSort, .{ self, f });
            f.timed("lq_p2g", recordP2g, .{ self, f });
            f.timed("lq_project", recordProject, .{ self, f });
            f.timed("lq_g2p", recordG2p, .{ self, f });
            f.timed("lq_raster", recordRaster, .{ self, f });
            self.set ^= 1;
        }
        self.copyStats(f);
    }

    /// The solver is off this tick: if particles may exist, turn them all
    /// into plain cells (the cellular rules take over) and empty the buffer.
    pub fn recordOff(self: *Liquid, f: *Frame) void {
        self.enabled_since = null;
        if (!self.live) return;
        self.live = false;
        bar(f);
        self.run(f, .flush, .{}, St.args_particles);
        bar(f);
        self.runDirect(f, .finalize, .{ .mode = 2 }, 1, 1);
        bar(f);
        self.copyStats(f);
    }

    fn copyStats(self: *Liquid, f: *Frame) void {
        self.last_tick = f.tick;
        f.ctx.vkd.cmdCopyBuffer(f.cmd, self.buffers[0].handle, self.readback.handle, &.{.{ .src_offset = 0, .dst_offset = (f.tick % ring_len) * St.words * 4, .size = St.words * 4 }});
        gpu.memory.memoryBarrier(f.ctx, f.cmd, .{ .all_transfer = true }, .{ .transfer_write = true }, .{ .host = true, .compute_shader = true }, .{ .host_read = true, .shader_storage_read = true });
    }

    fn recordWake(self: *Liquid, f: *Frame, mode: Mode) void {
        const no_spawn: u32 = if (mode == .full) 0 else pc_no_spawn;
        // Trigger: cells near anything a command touched.
        self.bind(f, .wake_commands);
        for (f.commands, 0..) |c, i| {
            const box = commands.bounds(c) orelse continue;
            const w = @min(box.w + 32, cell.world_size);
            const h = @min(box.h + 32, cell.world_size);
            self.push(f, .{ .level = f.command_base + @as(u32, @intCast(i)), .box_origin = .{ box.x - 16, box.y - 16 }, .box_size = .{ w, h } });
            f.dispatch((w + 15) / 16, (h + 15) / 16, 1);
        }
        f.ctx.vkd.cmdFillBuffer(f.cmd, self.buffers[buf(.tile_count)].handle, 0, vk.WHOLE_SIZE, 0);
        bar(f);
        self.bind(f, .wake);
        self.push(f, .{ .mode = 0 });
        f.dispatchActiveTiles();
        bar(f);
        self.scan(f, .tile_count, .tile_scan, .tile_sums, cell.tile_count, false);
        self.bind(f, .wake);
        self.push(f, .{ .mode = 1, .n = self.params.wake_budget, .flags = self.flags(f) | no_spawn });
        f.dispatchActiveTiles();
        bar(f);
        self.runDirect(f, .finalize, .{ .mode = if (mode == .idle) @as(u32, 3) else 0, .n = self.params.wake_budget, .level = self.params.grace_ticks, .flags = self.flags(f) | no_spawn }, 1, 1);
        bar(f);
        if (mode == .idle) return;
        // Lift after the wake (which needs awake water visible); spawned
        // particles have no binding and are skipped.
        self.run(f, .lift, .{}, St.args_particles);
        bar(f);
    }

    fn recordSort(self: *Liquid, f: *Frame) void {
        self.run(f, .bin_count, .{}, St.args_particles);
        bar(f);
        self.scan(f, .bin_count, .bin_scan, .bin_sums, grid_cells, true);
        self.run(f, .bin_scatter, .{}, St.args_particles);
        bar(f);
        self.runDirect(f, .finalize, .{ .mode = 1 }, 1, 1);
        bar(f);
        self.run(f, .bin_fixup, .{}, St.args_cells);
        bar(f);
        self.run(f, .reorder, .{}, St.args_particles);
        bar(f);
    }

    fn recordP2g(self: *Liquid, f: *Frame) void {
        self.run(f, .p2g, .{}, St.args_cells);
        bar(f);
        self.run(f, .classify, .{}, St.args_cells);
        bar(f);
        self.run(f, .divergence, .{}, St.args_cells);
        var l: u32 = 0;
        while (l + 1 < levels) : (l += 1) {
            bar(f);
            self.run(f, .mg_build, .{ .level = l }, mgCells(l + 1));
        }
        bar(f);
    }

    /// Tile-local smoothing at level l, both checkerboard colors.
    fn smoothTiles(self: *const Liquid, f: *Frame, l: u32, mode: u32, iterations: u32) void {
        var color: u32 = 0;
        while (color < 2) : (color += 1) {
            self.run(f, .mg_smooth, .{ .level = l | (color << 8), .mode = mode, .n = iterations }, mgTiles(l));
            bar(f);
        }
    }

    fn recordProject(self: *Liquid, f: *Frame) void {
        const p = self.params;
        var cycle: u32 = 0;
        while (cycle < p.vcycles) : (cycle += 1) {
            var l: u32 = 0;
            while (l + 1 < levels) : (l += 1) {
                self.smoothTiles(f, l, 0, p.pre_smooth);
                self.run(f, .mg_restrict, .{ .level = l }, mgCells(l + 1));
                bar(f);
            }
            self.run(f, .mg_coarsest, .{ .n = p.coarsest_iterations }, mgTiles(levels - 1));
            bar(f);
            l = levels - 1;
            while (l > 0) {
                l -= 1;
                self.smoothTiles(f, l, 1, p.post_smooth);
            }
        }
        self.run(f, .project, .{}, St.args_cells);
        bar(f);
    }

    fn recordG2p(self: *Liquid, f: *Frame) void {
        self.run(f, .g2p, .{}, St.args_particles);
        bar(f);
    }

    fn recordRaster(self: *Liquid, f: *Frame) void {
        var round: u32 = 0;
        while (round < 2) : (round += 1) {
            var m: u32 = 0;
            while (m < 3) : (m += 1) {
                self.run(f, .claim, .{ .level = round, .mode = m }, St.args_particles);
                bar(f);
            }
        }
        self.run(f, .drop, .{ .mode = 0 }, St.args_particles);
        bar(f);
        self.run(f, .drop, .{ .mode = 1 }, St.args_particles);
        bar(f);
        self.run(f, .settle, .{ .mode = 0 }, St.args_particles);
        bar(f);
        self.run(f, .settle, .{ .mode = 1 }, St.args_particles);
        bar(f);
    }
};

test "liquid.glsl mirror" {
    const constants = @import("../gpu/constants.zig");
    const src = @embedFile("liquid_glsl");
    var defines: [256]constants.Define = undefined;
    const n = constants.parseDefines(src, &defines);
    const mirrors = .{
        .{ "LQ_GRID", grid },                         .{ "LQ_GRID_MASK", grid_mask },
        .{ "LQ_GRID_SHIFT", grid_shift },             .{ "LQ_LEVELS", levels },
        .{ "LQ_NONE", none },                         .{ "LQ_BIND_PENDING", bind_pending },
        .{ "LQ_BUF_STATE", buf(.state) },             .{ "LQ_BUF_POS", buf(.pos) },
        .{ "LQ_BUF_VEL", buf(.vel) },                 .{ "LQ_BUF_AFF", buf(.aff) },
        .{ "LQ_BUF_INFO", buf(.info) },               .{ "LQ_BUF_BIND", buf(.bind) },
        .{ "LQ_BUF_BIN_OF", buf(.bin_of) },           .{ "LQ_BUF_BIN_COUNT", buf(.bin_count) },
        .{ "LQ_BUF_BIN_SCAN", buf(.bin_scan) },       .{ "LQ_BUF_BIN_SUMS", buf(.bin_sums) },
        .{ "LQ_BUF_SORTED", buf(.sorted) },           .{ "LQ_BUF_U", buf(.u) },
        .{ "LQ_BUF_V", buf(.v) },                     .{ "LQ_BUF_U_OLD", buf(.u_old) },
        .{ "LQ_BUF_V_OLD", buf(.v_old) },             .{ "LQ_BUF_UW", buf(.uw) },
        .{ "LQ_BUF_VW", buf(.vw) },                   .{ "LQ_BUF_MG_TYPE", buf(.mg_type) },
        .{ "LQ_BUF_MG_P", buf(.mg_p) },               .{ "LQ_BUF_MG_B", buf(.mg_b) },
        .{ "LQ_BUF_TILE_COUNT", buf(.tile_count) },   .{ "LQ_BUF_TILE_SCAN", buf(.tile_scan) },
        .{ "LQ_BUF_TILE_SUMS", buf(.tile_sums) },     .{ "LQ_BUF_COUNT", buf_count },
        .{ "LQ_ST_COUNT", St.count },                 .{ "LQ_ST_ARGS_PARTICLES", St.args_particles },
        .{ "LQ_ST_ARGS_CELLS", St.args_cells },       .{ "LQ_ST_ARGS_SCAN", St.args_scan },
        .{ "LQ_ST_ARGS_MG", St.args_mg },             .{ "LQ_ST_SPAWNED", St.spawned },
        .{ "LQ_ST_REFUSED", St.refused },             .{ "LQ_ST_KILLED", St.killed },
        .{ "LQ_ST_SLEPT", St.slept },                 .{ "LQ_ST_MERGED", St.merged },
        .{ "LQ_ST_BALLISTIC", St.ballistic },         .{ "LQ_ST_ALIVE", St.alive },
        .{ "LQ_ST_CANDIDATES", St.candidates },       .{ "LQ_ST_WORDS", St.words },
        .{ "LQ_MODE_DEAD", mode_dead },               .{ "LQ_MODE_LIQUID", mode_liquid },
        .{ "LQ_MODE_BALLISTIC", mode_ballistic },     .{ "LQ_MERGE_TICKS", merge_ticks },
        .{ "LQ_AIR", type_air },                      .{ "LQ_FLUID", type_fluid },
        .{ "LQ_SOLID", type_solid },                  .{ "LQ_WAKE_HOPS_COMMAND", wake_hops_command },
        .{ "LQ_WAKE_HOPS_POWDER", wake_hops_powder }, .{ "LQ_WAKE_HOPS_PARTICLE", wake_hops_particle },
        .{ "LQ_WAKE_HOPS_FLOW", wake_hops_flow },     .{ "LQ_ST_GRID_VALID", St.grid_valid },
        .{ "LQ_ST_TOTAL_MERGED", St.total_merged },   .{ "LQ_ST_MOVED", St.moved },
        .{ "LQ_ST_GRACE", St.grace },                 .{ "LQ_ST_TRIGGERS", St.triggers },
        .{ "LQ_ST_TOTAL_KILLED", St.total_killed },   .{ "LQ_ST_TOTAL_SLEPT", St.total_slept },
        .{ "LQ_PC_MARK_TILES", pc_mark_tiles },       .{ "LQ_PC_OVERLAY", pc_overlay },
        .{ "LQ_PC_NO_SPAWN", pc_no_spawn },           .{ "LQ_PC_HANDOFF", pc_handoff },
    };
    for (defines[0..n]) |d| {
        var found = false;
        inline for (mirrors) |m| {
            if (std.mem.eql(u8, m[0], d.name)) {
                found = true;
                try std.testing.expectEqual(@as(u64, m[1]), d.value);
            }
        }
        if (!found) {
            std.debug.print("liquid.glsl define {s} has no mirror in src/sim/liquid.zig\n", .{d.name});
            return error.MirrorMissing;
        }
    }
    try std.testing.expectEqual(@as(usize, @typeInfo(@TypeOf(mirrors)).@"struct".field_names.len), n);
}

test "multigrid level layout" {
    try std.testing.expectEqual(@as(u32, 0), levelOffset(0));
    try std.testing.expectEqual(@as(u32, grid * grid), levelOffset(1));
    // The coarsest level is solved by one 32 x 32 workgroup (mg_coarsest.comp).
    try std.testing.expectEqual(@as(u32, 32), levelSize(levels - 1));
}
