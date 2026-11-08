//! The shared particle buffer and the ballistic particle pass
//! (docs/01-architecture.md "Particle buffer", docs/04-fluids.md "Particle
//! layout", docs/decisions/50-particle-buffer.md, 51-ballistic-pass.md).
//!
//! GPU ABI (shaders/sim/particles/particles.glsl, mirrored below): structure
//! of arrays at fixed bindless slots, `capacity` entries each:
//!
//!   SLOT_BUF_PARTICLE_POS      vec2  position, world px, wrapped
//!   SLOT_BUF_PARTICLE_VEL      vec2  velocity, px/s
//!   SLOT_BUF_PARTICLE_AFFINE   vec4  APIC matrix (FLIP only), zero at spawn
//!   SLOT_BUF_PARTICLE_META     uint  material | mode | stuck | temp | variant
//!   SLOT_BUF_PARTICLE_BINDING  uint  FLIP cell binding, else PARTICLE_UNBOUND
//!   SLOT_BUF_PARTICLE_CTRL     uint  header (counters, indirect args),
//!                                    per-material live counts and budgets
//!   SLOT_BUF_PARTICLE_FREE     uint  free stack of particle indices
//!   SLOT_BUF_PARTICLE_SPAWN    SpawnRequest  this tick's spawn queue
//!   SLOT_IMG_PARTICLE_OVERLAY  r32ui ballistic particles drawn for render
//!
//! Per tick: `recordBegin` zeroes the per-tick counters; `recordCommands`
//! (after command application) runs spray commands and CPU spawns; `record`
//! (architecture step 6) runs the ballistic pass, then turns every request
//! queued this tick (commands, impacts, blast, FLIP wake) into particles.
const std = @import("std");
const gpu = @import("../gpu/gpu.zig");
const vk = gpu.vk;
const cell = @import("cell.zig");
const commands = @import("commands.zig");
const pipeline_mod = @import("pipeline.zig");
const Frame = pipeline_mod.Frame;
const shaders = @import("shaders");

// ---- particles.glsl mirror (test "particles.glsl mirror") ----
pub const mode_free = 0;
pub const mode_ballistic = 1;
pub const mode_liquid = 2;

pub const meta_material_shift = 0;
pub const meta_mode_shift = 8;
pub const meta_stuck_shift = 10;
pub const meta_temp_shift = 16;
pub const meta_variant_shift = 24;
pub const meta_stuck_max = 15;
pub const unbound: u32 = 0xffff_ffff;
pub const none: u32 = 0xffff_ffff;
pub const group_size = 256;

pub const ctrl_dispatch = 0;
pub const ctrl_high_water = 3;
pub const ctrl_spawn_dispatch = 4;
pub const ctrl_free_count = 7;
pub const ctrl_spawn_count = 8;
pub const ctrl_spawn_limit = 9;
pub const ctrl_live = 10;
pub const ctrl_capacity = 11;
pub const ctrl_spawned = 12;
pub const ctrl_landed = 13;
pub const ctrl_refused = 14;
pub const ctrl_lost = 15;
pub const ctrl_impacts = 16;
pub const ctrl_stats_first = 12;
pub const ctrl_stats_count = 5;
pub const ctrl_queue_capacity = 17;
pub const ctrl_rebuild_dispatch = 18;
pub const ctrl_header_words = 32;
pub const ctrl_mat_live = 32;
pub const ctrl_budget = 288;
pub const ctrl_words = 544;

/// `struct SpawnRequest` in particles.glsl (32 bytes).
pub const SpawnRequest = extern struct {
    pos: [2]f32,
    vel: [2]f32,
    meta: u32,
    binding: u32 = unbound,
    /// cpu_spawn.comp: 1 = take the material's spawn temperature.
    pad0: u32 = 0,
    pad1: u32 = 0,
};

/// The first `ctrl_header_words` words of the control buffer; also what the
/// readback copies each tick (`Mirror.particles`).
pub const Stats = extern struct {
    dispatch: [3]u32 = .{ 0, 1, 1 },
    /// Every live particle has an index below this.
    high_water: u32 = 0,
    spawn_dispatch: [3]u32 = .{ 0, 1, 1 },
    free_count: u32 = 0,
    spawn_count: u32 = 0,
    spawn_limit: u32 = 0,
    /// Live particles (any mode) at the end of the tick.
    live: u32 = 0,
    capacity: u32 = 0,
    /// This tick: particles created, landed into cells, requests refused
    /// (capacity or material budget), deleted without landing, impacts.
    spawned: u32 = 0,
    landed: u32 = 0,
    refused: u32 = 0,
    lost: u32 = 0,
    impacts: u32 = 0,
    queue_capacity: u32 = 0,
    rebuild_dispatch: [3]u32 = .{ 0, 1, 1 },
    reserved: [11]u32 = @splat(0),
};

comptime {
    std.debug.assert(@sizeOf(SpawnRequest) == 32);
    std.debug.assert(@sizeOf(Stats) == ctrl_header_words * 4);
    std.debug.assert(@offsetOf(Stats, "high_water") == ctrl_high_water * 4);
    std.debug.assert(@offsetOf(Stats, "spawn_dispatch") == ctrl_spawn_dispatch * 4);
    std.debug.assert(@offsetOf(Stats, "free_count") == ctrl_free_count * 4);
    std.debug.assert(@offsetOf(Stats, "live") == ctrl_live * 4);
    std.debug.assert(@offsetOf(Stats, "spawned") == ctrl_spawned * 4);
    std.debug.assert(@offsetOf(Stats, "impacts") == ctrl_impacts * 4);
    std.debug.assert(@offsetOf(Stats, "queue_capacity") == ctrl_queue_capacity * 4);
    std.debug.assert(@offsetOf(Stats, "rebuild_dispatch") == ctrl_rebuild_dispatch * 4);
}

pub fn makeMeta(material: u8, mode: u32, temperature: u8, variant: u4) u32 {
    return @as(u32, material) | (mode << meta_mode_shift) | (@as(u32, temperature) << meta_temp_shift) | (@as(u32, variant) << meta_variant_shift);
}

/// Seconds per tick and gravity (docs/01-architecture.md: 60 Hz, 196 px/s^2).
pub const dt: f32 = 1.0 / 60.0;
pub const gravity: f32 = 196.0;
/// Speed cap, px per tick (3600 px/s); the DDA visits at most 2x this.
pub const max_step: f32 = 60.0;
/// Ballistic air drag (1/s) at material drag 255, a small term: water
/// spray (drag 200) follows a blast's wind over a second, dirt (70) and sand
/// (60) fall at their 600-700 px/s terminal speed in still air.
pub const air_drag: f32 = 2.0;
/// CPU spawns accepted per frame (`spawn`).
pub const cpu_spawn_capacity = 4096;

pub const Particles = struct {
    ctx: *gpu.Context,
    /// Set by the pipeline each tick: the air field / liquid solver runs
    /// (air drag; landing solver liquid wakes the liquid).
    air_on: bool = false,
    liquid_on: bool = false,
    capacity: u32,
    queue_capacity: u32,
    pos: gpu.Buffer,
    vel: gpu.Buffer,
    affine: gpu.Buffer,
    meta: gpu.Buffer,
    binding: gpu.Buffer,
    ctrl: gpu.Buffer,
    free: gpu.Buffer,
    spawn_queue: gpu.Buffer,
    overlay: gpu.Image,
    /// Host-visible: frames_in_flight regions of `cpu_spawn_capacity`.
    cpu_ring: gpu.Buffer,
    ballistic_pipeline: vk.Pipeline,
    erase_pipeline: vk.Pipeline,
    spawn_pipeline: vk.Pipeline,
    control_pipeline: vk.Pipeline,
    rebuild_pipeline: vk.Pipeline,
    spray_pipeline: vk.Pipeline,
    cpu_spawn_pipeline: vk.Pipeline,
    cpu_pending: [cpu_spawn_capacity]SpawnRequest = undefined,
    cpu_len: u32 = 0,
    /// CPU spawns refused because `cpu_pending` was full.
    cpu_dropped: u32 = 0,
    budgets: [256]u32 = undefined,
    budgets_dirty: bool = false,

    pub fn init(ctx: *gpu.Context, cfg: pipeline_mod.Config, alloc: std.mem.Allocator) !Particles {
        _ = alloc;
        const n: u32 = @max(cfg.particle_capacity, group_size);
        const q: u32 = @max(@min(cfg.particle_queue, n), group_size);
        var self: Particles = .{
            .ctx = ctx,
            .capacity = n,
            .queue_capacity = q,
            .pos = .{},
            .vel = .{},
            .affine = .{},
            .meta = .{},
            .binding = .{},
            .ctrl = .{},
            .free = .{},
            .spawn_queue = .{},
            .overlay = .{},
            .cpu_ring = .{},
            .ballistic_pipeline = .null,
            .erase_pipeline = .null,
            .spawn_pipeline = .null,
            .control_pipeline = .null,
            .rebuild_pipeline = .null,
            .spray_pipeline = .null,
            .cpu_spawn_pipeline = .null,
        };
        errdefer self.deinit();
        const storage: vk.BufferUsageFlags = .{ .storage_buffer = true, .transfer_dst = true, .transfer_src = true };
        const C = gpu.constants;
        const soa = [_]struct { *gpu.Buffer, u64, u32 }{
            .{ &self.pos, 8, C.slot_buf_particle_pos },
            .{ &self.vel, 8, C.slot_buf_particle_vel },
            .{ &self.affine, 16, C.slot_buf_particle_affine },
            .{ &self.meta, 4, C.slot_buf_particle_meta },
            .{ &self.binding, 4, C.slot_buf_particle_binding },
            .{ &self.free, 4, C.slot_buf_particle_free },
        };
        for (soa) |b| {
            b[0].* = try gpu.Buffer.init(ctx, @as(u64, n) * b[1], storage, .gpu_only);
            b[0].register(ctx, b[2]);
        }
        self.ctrl = try gpu.Buffer.init(ctx, ctrl_words * 4, storage.merge(.{ .indirect_buffer = true }), .gpu_only);
        self.ctrl.register(ctx, C.slot_buf_particle_ctrl);
        self.spawn_queue = try gpu.Buffer.init(ctx, @as(u64, q) * @sizeOf(SpawnRequest), storage, .gpu_only);
        self.spawn_queue.register(ctx, C.slot_buf_particle_spawn);
        self.cpu_ring = try gpu.Buffer.initSlotted(ctx, pipeline_mod.frames_in_flight * cpu_spawn_capacity * @sizeOf(SpawnRequest), .{}, .cpu_to_gpu);

        self.overlay = try gpu.Image.init(ctx, .{
            .width = cell.world_size,
            .height = cell.world_size,
            .format = .r32_uint,
            .usage = .{ .storage = true, .transfer_dst = true },
        });
        try self.overlay.initLayout(ctx, .general, true);
        self.overlay.register(ctx, C.slot_img_particle_overlay);

        // Default budget: a quarter of the capacity per material, none for air.
        const per_material = if (cfg.particle_budget != 0) @min(cfg.particle_budget, n) else n / 4;
        for (&self.budgets, 0..) |*b, m| b.* = if (m == 0) 0 else per_material;
        try self.upload();

        self.ballistic_pipeline = try gpu.pipelines.createCompute(ctx, &shaders.sim_particles_ballistic_comp);
        self.erase_pipeline = try gpu.pipelines.createCompute(ctx, &shaders.sim_particles_erase_comp);
        self.spawn_pipeline = try gpu.pipelines.createCompute(ctx, &shaders.sim_particles_spawn_comp);
        self.control_pipeline = try gpu.pipelines.createCompute(ctx, &shaders.sim_particles_control_comp);
        self.rebuild_pipeline = try gpu.pipelines.createCompute(ctx, &shaders.sim_particles_rebuild_comp);
        self.spray_pipeline = try gpu.pipelines.createCompute(ctx, &shaders.sim_particles_spray_comp);
        self.cpu_spawn_pipeline = try gpu.pipelines.createCompute(ctx, &shaders.sim_particles_cpu_spawn_comp);
        return self;
    }

    /// Initial state: every index free (stack top = index 0), empty queue.
    fn upload(self: *Particles) !void {
        const ctx = self.ctx;
        const free_bytes = @as(u64, self.capacity) * 4;
        var staging = try gpu.Buffer.init(ctx, free_bytes + ctrl_words * 4, .{ .transfer_src = true }, .cpu_to_gpu);
        defer staging.deinit(ctx);
        const words = staging.typed(u32);
        for (words[0..self.capacity], 0..) |*w, j| w.* = self.capacity - 1 - @as(u32, @intCast(j));
        const ctrl = words[self.capacity..][0..ctrl_words];
        @memset(ctrl, 0);
        const header: Stats = .{
            .free_count = self.capacity,
            .spawn_limit = @min(self.capacity, self.queue_capacity),
            .capacity = self.capacity,
            .queue_capacity = self.queue_capacity,
        };
        @memcpy(ctrl[0..ctrl_header_words], std.mem.bytesAsSlice(u32, std.mem.asBytes(&header)));
        @memcpy(ctrl[ctrl_budget..][0..256], &self.budgets);
        try ctx.runOnce(.compute, recordUpload, .{ ctx, self, staging.handle, free_bytes });
    }

    fn recordUpload(cmd: vk.CommandBuffer, ctx: *gpu.Context, self: *const Particles, staging: vk.Buffer, free_bytes: u64) void {
        for ([_]*const gpu.Buffer{ &self.pos, &self.vel, &self.affine, &self.meta, &self.binding, &self.spawn_queue }) |b| {
            ctx.vkd.cmdFillBuffer(cmd, b.handle, 0, vk.WHOLE_SIZE, 0);
        }
        ctx.vkd.cmdCopyBuffer(cmd, staging, self.free.handle, &.{.{ .src_offset = 0, .dst_offset = 0, .size = free_bytes }});
        ctx.vkd.cmdCopyBuffer(cmd, staging, self.ctrl.handle, &.{.{ .src_offset = free_bytes, .dst_offset = 0, .size = ctrl_words * 4 }});
        gpu.memory.memoryBarrier(ctx, cmd, .{ .all_transfer = true }, .{ .transfer_write = true }, .{ .all_commands = true }, .{ .memory_read = true, .memory_write = true });
    }

    pub fn deinit(self: *Particles) void {
        const ctx = self.ctx;
        for ([_]vk.Pipeline{ self.cpu_spawn_pipeline, self.spray_pipeline, self.rebuild_pipeline, self.control_pipeline, self.spawn_pipeline, self.erase_pipeline, self.ballistic_pipeline }) |p| {
            if (p != .null) gpu.pipelines.destroy(ctx, p);
        }
        self.overlay.deinit(ctx);
        self.cpu_ring.deinit(ctx);
        for ([_]*gpu.Buffer{ &self.spawn_queue, &self.free, &self.ctrl, &self.binding, &self.meta, &self.affine, &self.vel, &self.pos }) |b| b.deinit(ctx);
    }

    /// CPU-side spawn for gameplay (bullets, sparks, debris): one ballistic
    /// particle, created during the next recorded tick. `temperature` null =
    /// the material's spawn temperature. Returns false when this frame's
    /// list (`cpu_spawn_capacity`) is full; the GPU may still refuse it
    /// (capacity, material budget: `Stats.refused`).
    pub fn spawn(self: *Particles, x: f32, y: f32, vx: f32, vy: f32, material: u8, temperature: ?u8) bool {
        if (self.cpu_len >= cpu_spawn_capacity) {
            self.cpu_dropped += 1;
            return false;
        }
        const variant: u4 = @truncate(cell.hashU32(self.cpu_len *% 0x9e37_79b9 +% @as(u32, @bitCast(x))) >> 28);
        self.cpu_pending[self.cpu_len] = .{
            .pos = .{ x, y },
            .vel = .{ vx, vy },
            .meta = makeMeta(material, mode_ballistic, temperature orelse 0, variant),
            .pad0 = @intFromBool(temperature == null),
        };
        self.cpu_len += 1;
        return true;
    }

    /// Most live particles of `material` (applied from the next tick).
    pub fn setBudget(self: *Particles, material: u8, count: u32) void {
        self.budgets[material] = @min(count, self.capacity);
        self.budgets_dirty = true;
    }

    /// Start of tick: zero the per-tick counters.
    pub fn recordBegin(self: *Particles, frame: *Frame) void {
        const ctx = frame.ctx;
        frame.fullBarrier();
        ctx.vkd.cmdFillBuffer(frame.cmd, self.ctrl.handle, ctrl_stats_first * 4, ctrl_stats_count * 4, 0);
        if (self.budgets_dirty) {
            ctx.vkd.cmdUpdateBuffer(frame.cmd, self.ctrl.handle, ctrl_budget * 4, 256 * 4, &self.budgets);
            self.budgets_dirty = false;
        }
        gpu.memory.memoryBarrier(ctx, frame.cmd, .{ .all_transfer = true }, .{ .transfer_write = true }, .{ .compute_shader = true }, .{ .shader_storage_read = true, .shader_storage_write = true });
    }

    /// After command application: spray commands and this frame's CPU
    /// spawns become spawn requests.
    pub fn recordCommands(self: *Particles, frame: *Frame) void {
        var sprays = false;
        for (frame.commands) |c| sprays = sprays or c.kind == @backingInt(commands.Kind.spray);
        const cpu = frame.tick_in_frame == 0 and self.cpu_len > 0;
        if (!sprays and !cpu) return;
        frame.timed("particles", recordCommandsInner, .{ self, frame, sprays, cpu });
    }

    fn recordCommandsInner(self: *Particles, frame: *Frame, sprays: bool, cpu: bool) void {
        if (sprays) {
            frame.bindCompute(self.spray_pipeline);
            for (frame.commands, 0..) |c, i| {
                if (c.kind != @backingInt(commands.Kind.spray) or c.x1 <= 0) continue;
                frame.push(extern struct { index: u32 }{ .index = frame.command_base + @as(u32, @intCast(i)) });
                frame.dispatch((@as(u32, @intCast(c.x1)) + group_size - 1) / group_size, 1, 1);
            }
        }
        if (cpu) {
            const base = frame.slot * cpu_spawn_capacity;
            @memcpy(self.cpu_ring.typed(SpawnRequest)[base..][0..self.cpu_len], self.cpu_pending[0..self.cpu_len]);
            frame.bindCompute(self.cpu_spawn_pipeline);
            frame.push(extern struct { ring: u32, base: u32, count: u32 }{ .ring = self.cpu_ring.slot, .base = base, .count = self.cpu_len });
            frame.dispatch((self.cpu_len + group_size - 1) / group_size, 1, 1);
            self.cpu_len = 0;
        }
        frame.barrier();
    }

    /// Architecture step 6 (after the liquid solver): ballistic particles,
    /// then this tick's spawn queue.
    pub fn record(self: *Particles, frame: *Frame) void {
        frame.timed("particles", recordInner, .{ self, frame });
    }

    fn recordInner(self: *Particles, frame: *Frame) void {
        const ctx = frame.ctx;
        const cmd = frame.cmd;
        const indirect = self.ctrl.handle;
        // Overlay: erase every particle's pixel; ballistic and spawn redraw.
        frame.barrier();
        frame.bindCompute(self.erase_pipeline);
        ctx.vkd.cmdDispatchIndirect(cmd, indirect, ctrl_dispatch * 4);
        frame.barrier();

        frame.bindCompute(self.ballistic_pipeline);
        frame.push(extern struct { tick: u32, dt: f32, gravity: f32, max_step: f32, flags: u32, air_drag: f32 }{
            .tick = frame.tick,
            .dt = dt,
            .gravity = gravity,
            .max_step = max_step,
            .flags = @as(u32, @intFromBool(self.air_on)) | (@as(u32, @intFromBool(self.liquid_on)) << 1),
            .air_drag = air_drag,
        });
        ctx.vkd.cmdDispatchIndirect(cmd, indirect, ctrl_dispatch * 4);
        indirectBarrier(frame);

        frame.bindCompute(self.control_pipeline);
        frame.push(extern struct { stage: u32 }{ .stage = 0 });
        frame.dispatch(1, 1, 1);
        indirectBarrier(frame);

        frame.bindCompute(self.spawn_pipeline);
        ctx.vkd.cmdDispatchIndirect(cmd, indirect, ctrl_spawn_dispatch * 4);
        indirectBarrier(frame);

        frame.bindCompute(self.control_pipeline);
        frame.push(extern struct { stage: u32 }{ .stage = 1 });
        frame.dispatch(1, 1, 1);
        indirectBarrier(frame);

        frame.bindCompute(self.rebuild_pipeline);
        ctx.vkd.cmdDispatchIndirect(cmd, indirect, ctrl_rebuild_dispatch * 4);
        indirectBarrier(frame);
    }

    fn indirectBarrier(frame: *Frame) void {
        gpu.memory.memoryBarrier(frame.ctx, frame.cmd, .{ .compute_shader = true }, .{ .shader_storage_write = true }, .{ .compute_shader = true, .draw_indirect = true, .all_transfer = true }, .{ .shader_storage_read = true, .shader_storage_write = true, .indirect_command_read = true, .transfer_read = true });
    }
};

test "particles.glsl mirror" {
    const constants = @import("../gpu/constants.zig");
    const src = @embedFile("particles_glsl");
    var defines: [128]constants.Define = undefined;
    const n = constants.parseDefines(src, &defines);
    const mirrors = .{
        .{ "PARTICLE_MODE_FREE", mode_free },
        .{ "PARTICLE_MODE_BALLISTIC", mode_ballistic },
        .{ "PARTICLE_MODE_LIQUID", mode_liquid },
        .{ "PMETA_MATERIAL_SHIFT", meta_material_shift },
        .{ "PMETA_MODE_SHIFT", meta_mode_shift },
        .{ "PMETA_STUCK_SHIFT", meta_stuck_shift },
        .{ "PMETA_TEMP_SHIFT", meta_temp_shift },
        .{ "PMETA_VARIANT_SHIFT", meta_variant_shift },
        .{ "PMETA_STUCK_MAX", meta_stuck_max },
        .{ "PARTICLE_UNBOUND", unbound },
        .{ "PARTICLE_NONE", none },
        .{ "PARTICLE_GROUP", group_size },
        .{ "PCTRL_DISPATCH", ctrl_dispatch },
        .{ "PCTRL_HIGH_WATER", ctrl_high_water },
        .{ "PCTRL_SPAWN_DISPATCH", ctrl_spawn_dispatch },
        .{ "PCTRL_FREE_COUNT", ctrl_free_count },
        .{ "PCTRL_SPAWN_COUNT", ctrl_spawn_count },
        .{ "PCTRL_SPAWN_LIMIT", ctrl_spawn_limit },
        .{ "PCTRL_LIVE", ctrl_live },
        .{ "PCTRL_CAPACITY", ctrl_capacity },
        .{ "PCTRL_SPAWNED", ctrl_spawned },
        .{ "PCTRL_LANDED", ctrl_landed },
        .{ "PCTRL_REFUSED", ctrl_refused },
        .{ "PCTRL_LOST", ctrl_lost },
        .{ "PCTRL_IMPACTS", ctrl_impacts },
        .{ "PCTRL_STATS_FIRST", ctrl_stats_first },
        .{ "PCTRL_STATS_COUNT", ctrl_stats_count },
        .{ "PCTRL_QUEUE_CAPACITY", ctrl_queue_capacity },
        .{ "PCTRL_REBUILD_DISPATCH", ctrl_rebuild_dispatch },
        .{ "PCTRL_HEADER_WORDS", ctrl_header_words },
        .{ "PCTRL_MAT_LIVE", ctrl_mat_live },
        .{ "PCTRL_BUDGET", ctrl_budget },
        .{ "PCTRL_WORDS", ctrl_words },
        .{ "EJECT_MIN_SPEED", commands.eject_min_speed },
        .{ "EJECT_DAMAGE_SHIFT", commands.eject_damage_shift },
    };
    try checkMirror(defines[0..n], mirrors);
}

/// Every numeric define in `defines` has a mirror with the same value, and
/// every mirror is defined.
pub fn checkMirror(defines: []const @import("../gpu/constants.zig").Define, comptime mirrors: anytype) !void {
    for (defines) |d| {
        var found = false;
        inline for (mirrors) |m| {
            if (std.mem.eql(u8, m[0], d.name)) {
                found = true;
                if (@as(u64, m[1]) != d.value) {
                    std.debug.print("mirror mismatch: {s} = {d} in GLSL, {d} on the CPU\n", .{ d.name, d.value, @as(u64, m[1]) });
                    return error.MirrorMismatch;
                }
            }
        }
        if (!found) {
            std.debug.print("GLSL define {s} has no CPU mirror\n", .{d.name});
            return error.MirrorMissing;
        }
    }
    inline for (mirrors) |m| {
        var found = false;
        for (defines) |d| found = found or std.mem.eql(u8, m[0], d.name);
        if (!found) {
            std.debug.print("mirror {s} no longer defined in GLSL\n", .{m[0]});
            return error.MirrorStale;
        }
    }
}

test "meta packing matches the GLSL layout" {
    const m = makeMeta(7, mode_ballistic, 200, 9);
    try std.testing.expectEqual(@as(u32, 7), m & 0xff);
    try std.testing.expectEqual(@as(u32, mode_ballistic), (m >> meta_mode_shift) & 3);
    try std.testing.expectEqual(@as(u32, 0), (m >> meta_stuck_shift) & 0xf);
    try std.testing.expectEqual(@as(u32, 200), (m >> meta_temp_shift) & 0xff);
    try std.testing.expectEqual(@as(u32, 9), (m >> meta_variant_shift) & 0xf);
}
