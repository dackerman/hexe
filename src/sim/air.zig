//! Air field (M5): a D2Q9 lattice Boltzmann gas at half pixel resolution
//! (docs/04-fluids.md "Air field"). 1024 x 1024 lattice cells of 2 x 2
//! pixels, nine f32 distributions per cell in two ping-pong buffers
//! (structure of arrays), BGK collision fused with a pull stream, half-way
//! bounce-back on coarsened walls, open edges at the window seam.
//!
//! Per tick, after the grid substeps and coarsening (`record`):
//!   prep        node words (walls, buoyancy), mass conservation when walls
//!               change, wakes tiles                              full window
//!   inject      explosion / pressure sources from CMD_INJECT_PRESSURE
//!   compact     active air tiles -> AIR_TILE_LIST (indirect)
//!   lbm x N     N = `params.steps` stream+collide steps          active tiles
//!   effects     blast thresholds, pressure events                active tiles
//!   io          overlay, point samples, 256^2 field, readback copies
//! and per substep, before movement (`recordSubstep`):
//!   gas advect  gas cells drift with the air velocity            active tiles
//!
//! CPU API (all take effect on the next recorded tick; results arrive when
//! the engine collects the frame, one frame later):
//!   commands: `CommandList.injectPressure` / `.explosion` (commands.zig)
//!   `requestSample(x, y)` -> index; `samples()` the last completed results
//!   `field_readback = true`; `field()` the last 256 x 256 field
//!   `events()` pressure events of the last completed frame
//!   `stats` per-frame counts (active tiles, ejects, events)
//! GPU ABI for other passes: shaders/sim/air/air_api.glsl, common.glsl
//! "Air field" section, src/sim/air_abi.zig. Decisions 70-79.
const std = @import("std");
const gpu = @import("../gpu/gpu.zig");
const vk = gpu.vk;
const cell = @import("cell.zig");
const commands = @import("commands.zig");
const abi = @import("air_abi.zig");
const pipeline_mod = @import("pipeline.zig");
const Frame = pipeline_mod.Frame;
const shaders = @import("shaders");

pub const size = abi.size;
const frames = pipeline_mod.frames_in_flight;
const max_ticks = pipeline_mod.max_ticks_per_frame;
pub const max_injections = 64;

const P = enum { init, prep, inject_count, inject_apply, compact, lbm, effects, gas, overlay, sample, downsample };
const pipe_count = @typeInfo(P).@"enum".field_names.len;

/// Runtime-tunable parameters (docs/decisions/72-air-lbm-parameters.md).
pub const Params = struct {
    /// BGK relaxation time; viscosity nu = (tau - 0.5) / 3. Kept >= 0.55.
    tau: f32 = 0.6,
    /// LBM steps per tick. Sound speed = steps * 2 px / sqrt(3) per tick.
    steps: u32 = 4,
    /// Mach clamp, as a fraction of the lattice sound speed.
    mach_max: f32 = 0.3,
    rho_min: f32 = 0.25,
    rho_max: f32 = 4.0,
    /// Below this |u| (lattice units) everywhere, a tile counts as at rest.
    eps_u: f32 = 2e-4,
    /// Upward lattice force per temperature byte above ambient (8 C).
    buoyancy: f32 = 2e-6,
    /// Temperature byte of ambient air (20 C).
    ambient_temp: u32 = 7,
    /// Sponge band at the open edges, lattice cells, and its strength.
    sponge_width: f32 = 24,
    sponge_strength: f32 = 0.25,
    /// Wall slip: 1 = free slip (specular), 0 = no slip (bounce-back).
    slip: f32 = 0.97,
    /// Blast units per unit density difference per lattice cell: gradient
    /// load (loose material, fly) and wall load (solids across a wall).
    blast_scale: f32 = 700,
    wall_scale: f32 = 1000,
    /// Health lost per blast unit of excess per tick.
    damage_scale: f32 = 0.25,
    /// Ejected pixels: air velocity multiplier, push down the gradient per
    /// unit excess, and speed cap (pixels per tick).
    eject_scale: f32 = 3.0,
    eject_push: f32 = 0.05,
    eject_max: f32 = 8.0,
    /// Wall load: how far to look for fluid on each side, lattice cells.
    wall_search: i32 = 3,
    /// Gas advection: swap probability per (pixel per tick) of air speed.
    gas_scale: f32 = 0.5,
    /// Overlay gains.
    overlay_pressure_gain: f32 = 4.0,
    overlay_speed_gain: f32 = 1.5,
};

/// GPU layout of one injection (shaders/sim/air/inject.glsl).
const InjectionGpu = extern struct {
    cx: f32,
    cy: f32,
    radius: f32,
    mass: f32,
    momentum: f32,
    steps: u32,
    _pad: [2]u32 = .{ 0, 0 },
};

/// An injection in progress (CPU side), in lattice units.
const Active = struct {
    cx: f32,
    cy: f32,
    radius: f32,
    /// Per step.
    mass: f32,
    momentum: f32,
    steps_left: u32,
};

pub const Stats = struct {
    /// Active air tiles in the last tick of the frame.
    active_tiles: u32 = 0,
    /// Blast ejects / events appended over the frame's ticks.
    ejects: u32 = 0,
    ejects_dropped: u32 = 0,
    events: u32 = 0,
    events_dropped: u32 = 0,
    first_tick: u32 = 0,
    ticks: u32 = 0,
};

pub const SampleResult = struct {
    x: i32,
    y: i32,
    sample: abi.Sample,
};

/// Per tick, per frame slot: what gets copied back.
const stats_stride = 64;
const events_stride = @sizeOf(abi.ListHeader) + abi.event_capacity * @sizeOf(abi.AirEvent);

const Readback = struct {
    stats: gpu.Buffer,
    events: gpu.Buffer,
    sample_req: gpu.Buffer,
    sample_res: gpu.Buffer,
    field: gpu.Buffer,
    /// Recorded state for `collect`.
    ticks: u32 = 0,
    first_tick: u32 = 0,
    samples: u32 = 0,
    field_written: bool = false,
};

pub const Air = struct {
    ctx: *gpu.Context,
    alloc: std.mem.Allocator,
    enabled: bool,
    all_active: bool,
    params: Params = .{},
    /// Open edge of the field, lattice coordinates of the window's top-left
    /// (docs/decisions/71-air-boundaries.md). Streaming sets it to the
    /// window origin / 2 and must `resetRegion` loaded chunks.
    seam: [2]i32 = .{ 0, 0 },
    /// Write the 256 x 256 field to the CPU each tick.
    field_readback: bool = false,
    /// Slot of the coarsened temperature image (set by the pipeline).
    temp_slot: u32 = 0,

    dist: [2]gpu.Buffer,
    /// Which of `dist` holds the current state.
    parity: u1 = 0,
    node: gpu.Image,
    field_image: gpu.Image,
    source: gpu.Image,
    tile_marks: gpu.Buffer,
    tile_list: gpu.Buffer,
    ejects: gpu.Buffer,
    events_buf: gpu.Buffer,
    inject_ring: gpu.Buffer,
    inject_counts: gpu.Buffer,
    readback: [frames]Readback,

    pipes: [pipe_count]vk.Pipeline,

    first: bool = true,
    active: [max_injections]Active = undefined,
    active_len: u32 = 0,
    dropped_injections: u32 = 0,

    pending_samples: [abi.max_samples][2]i32 = undefined,
    pending_len: u32 = 0,
    sample_points: [abi.max_samples][2]i32 = undefined,
    sample_values: [abi.max_samples]SampleResult = undefined,
    sample_len: u32 = 0,
    /// Tick the current `samples()` / `field()` were taken after.
    sample_tick: u32 = 0,
    field_tick: u32 = 0,
    /// CPU copy of the last field readback (field_size^2 cells).
    field_cpu: []abi.FieldCell,
    field_valid: bool = false,
    event_list: [4 * abi.event_capacity]abi.AirEvent = undefined,
    event_len: u32 = 0,
    stats: Stats = .{},
    /// Totals since init (harness, bench).
    total_ejects: u64 = 0,
    total_events: u64 = 0,

    pub fn init(ctx: *gpu.Context, cfg: pipeline_mod.Config, alloc: std.mem.Allocator) !Air {
        var self: Air = undefined;
        self.ctx = ctx;
        self.alloc = alloc;
        self.enabled = cfg.air;
        self.all_active = !cfg.air_sleep;
        self.params = .{};
        self.seam = .{ 0, 0 };
        self.field_readback = false;
        self.temp_slot = 0;
        self.parity = 0;
        self.first = true;
        self.active_len = 0;
        self.dropped_injections = 0;
        self.pending_len = 0;
        self.sample_len = 0;
        self.sample_tick = 0;
        self.field_tick = 0;
        self.field_valid = false;
        self.event_len = 0;
        self.stats = .{};
        self.total_ejects = 0;
        self.total_events = 0;

        self.field_cpu = try alloc.alloc(abi.FieldCell, abi.field_size * abi.field_size);
        errdefer alloc.free(self.field_cpu);

        const plane_bytes: u64 = size * size * 4;
        self.dist[0] = try gpu.Buffer.initSlotted(ctx, plane_bytes * 9, .{}, .gpu_only);
        errdefer self.dist[0].deinit(ctx);
        self.dist[1] = try gpu.Buffer.initSlotted(ctx, plane_bytes * 9, .{}, .gpu_only);
        errdefer self.dist[1].deinit(ctx);

        self.node = try makeImage(ctx, .r32_uint, try ctx.descriptors.allocImageSlot());
        errdefer self.node.deinit(ctx);
        self.field_image = try makeImage(ctx, .r32g32b32a32_sfloat, gpu.constants.slot_img_air);
        errdefer self.field_image.deinit(ctx);
        self.source = try makeImage(ctx, .r32_uint, gpu.constants.slot_img_air_source);
        errdefer self.source.deinit(ctx);

        self.tile_marks = try gpu.Buffer.init(ctx, abi.tile_mark_bytes, .{ .storage_buffer = true, .transfer_dst = true }, .gpu_only);
        errdefer self.tile_marks.deinit(ctx);
        self.tile_marks.register(ctx, gpu.constants.slot_buf_air_tile_marks);
        self.tile_list = try gpu.Buffer.init(ctx, 16 + abi.tile_count * 4, .{ .storage_buffer = true, .indirect_buffer = true, .transfer_dst = true, .transfer_src = true }, .gpu_only);
        errdefer self.tile_list.deinit(ctx);
        self.tile_list.register(ctx, gpu.constants.slot_buf_air_tile_list);
        self.ejects = try gpu.Buffer.init(ctx, @sizeOf(abi.ListHeader) + abi.blast_eject_capacity * @sizeOf(abi.BlastEject), .{ .storage_buffer = true, .transfer_dst = true, .transfer_src = true }, .gpu_only);
        errdefer self.ejects.deinit(ctx);
        self.ejects.register(ctx, gpu.constants.slot_buf_blast_ejects);
        self.events_buf = try gpu.Buffer.init(ctx, events_stride, .{ .storage_buffer = true, .transfer_dst = true, .transfer_src = true }, .gpu_only);
        errdefer self.events_buf.deinit(ctx);
        self.events_buf.register(ctx, gpu.constants.slot_buf_air_events);

        self.inject_ring = try gpu.Buffer.initSlotted(ctx, frames * max_ticks * max_injections * @sizeOf(InjectionGpu), .{}, .cpu_to_gpu);
        errdefer self.inject_ring.deinit(ctx);
        self.inject_counts = try gpu.Buffer.initSlotted(ctx, max_injections * 4, .{ .transfer_dst = true }, .gpu_only);
        errdefer self.inject_counts.deinit(ctx);

        var made: usize = 0;
        errdefer for (self.readback[0..made]) |*r| deinitReadback(ctx, r);
        for (&self.readback) |*r| {
            r.* = try initReadback(ctx);
            made += 1;
        }

        const codes = [pipe_count]gpu.pipelines.Spirv{
            &shaders.sim_air_init_comp,         &shaders.sim_air_prep_comp,       &shaders.sim_air_inject_count_comp,
            &shaders.sim_air_inject_apply_comp, &shaders.sim_air_compact_comp,    &shaders.sim_air_lbm_comp,
            &shaders.sim_air_effects_comp,      &shaders.sim_air_gas_advect_comp, &shaders.sim_air_overlay_comp,
            &shaders.sim_air_sample_comp,       &shaders.sim_air_downsample_comp,
        };
        var built: usize = 0;
        errdefer for (self.pipes[0..built]) |pl| gpu.pipelines.destroy(ctx, pl);
        for (codes, 0..) |code, i| {
            self.pipes[i] = try gpu.pipelines.createCompute(ctx, code);
            built += 1;
        }

        try ctx.runOnce(.compute, recordReset, .{ ctx, &self });
        return self;
    }

    fn makeImage(ctx: *gpu.Context, format: vk.Format, slot: u32) !gpu.Image {
        var img = try gpu.Image.init(ctx, .{
            .width = size,
            .height = size,
            .format = format,
            .usage = .{ .storage = true, .transfer_src = true, .transfer_dst = true },
        });
        errdefer img.deinit(ctx);
        try img.initLayout(ctx, .general, true);
        img.register(ctx, slot);
        return img;
    }

    fn initReadback(ctx: *gpu.Context) !Readback {
        var r: Readback = undefined;
        r.stats = try gpu.Buffer.init(ctx, max_ticks * stats_stride, .{ .transfer_dst = true }, .gpu_to_cpu);
        errdefer r.stats.deinit(ctx);
        r.events = try gpu.Buffer.init(ctx, max_ticks * events_stride, .{ .transfer_dst = true }, .gpu_to_cpu);
        errdefer r.events.deinit(ctx);
        r.sample_req = try gpu.Buffer.initSlotted(ctx, abi.max_samples * 8, .{}, .cpu_to_gpu);
        errdefer r.sample_req.deinit(ctx);
        r.sample_res = try gpu.Buffer.initSlotted(ctx, abi.max_samples * @sizeOf(abi.Sample), .{}, .gpu_to_cpu);
        errdefer r.sample_res.deinit(ctx);
        r.field = try gpu.Buffer.initSlotted(ctx, abi.field_size * abi.field_size * @sizeOf(abi.FieldCell), .{}, .gpu_to_cpu);
        r.ticks = 0;
        r.first_tick = 0;
        r.samples = 0;
        r.field_written = false;
        return r;
    }

    fn deinitReadback(ctx: *gpu.Context, r: *Readback) void {
        r.field.deinit(ctx);
        r.sample_res.deinit(ctx);
        r.sample_req.deinit(ctx);
        r.events.deinit(ctx);
        r.stats.deinit(ctx);
    }

    pub fn deinit(self: *Air) void {
        const ctx = self.ctx;
        for (self.pipes) |pl| gpu.pipelines.destroy(ctx, pl);
        for (&self.readback) |*r| deinitReadback(ctx, r);
        self.inject_counts.deinit(ctx);
        self.inject_ring.deinit(ctx);
        self.events_buf.deinit(ctx);
        self.ejects.deinit(ctx);
        self.tile_list.deinit(ctx);
        self.tile_marks.deinit(ctx);
        self.source.deinit(ctx);
        self.field_image.deinit(ctx);
        self.node.deinit(ctx);
        self.dist[1].deinit(ctx);
        self.dist[0].deinit(ctx);
        self.alloc.free(self.field_cpu);
    }

    /// Ambient air at rest everywhere; walls are re-read next tick without
    /// conservation transfers. Waits for the GPU.
    pub fn reset(self: *Air) !void {
        self.ctx.waitIdle();
        try self.ctx.runOnce(.compute, recordReset, .{ self.ctx, self });
        self.first = true;
        self.active_len = 0;
    }

    fn recordReset(cmd: vk.CommandBuffer, ctx: *gpu.Context, self: *const Air) void {
        ctx.vkd.cmdFillBuffer(cmd, self.tile_marks.handle, 0, vk.WHOLE_SIZE, 0);
        ctx.vkd.cmdFillBuffer(cmd, self.tile_list.handle, 0, vk.WHOLE_SIZE, 0);
        ctx.vkd.cmdFillBuffer(cmd, self.ejects.handle, 0, vk.WHOLE_SIZE, 0);
        ctx.vkd.cmdFillBuffer(cmd, self.events_buf.handle, 0, vk.WHOLE_SIZE, 0);
        gpu.memory.memoryBarrier(ctx, cmd, .{ .all_transfer = true }, .{ .transfer_write = true }, .{ .compute_shader = true }, .{ .shader_storage_read = true, .shader_storage_write = true });
        ctx.vkd.cmdBindPipeline(cmd, .compute, self.pipes[@backingInt(P.init)]);
        gpu.pipelines.push(ctx, cmd, extern struct { d0: u32, d1: u32 }{ .d0 = self.dist[0].slot, .d1 = self.dist[1].slot });
        ctx.vkd.cmdDispatch(cmd, size / 16, size / 16, 1);
        gpu.memory.computeBarrier(ctx, cmd);
    }

    // ------------------------------------------------------------------
    // CPU API
    // ------------------------------------------------------------------

    /// Ask for the air at world pixel (x, y) in the next recorded frame.
    /// Returns the index into `samples()` once that frame completes, or
    /// null when 64 points are already pending.
    pub fn requestSample(self: *Air, x: i32, y: i32) ?u32 {
        if (self.pending_len >= abi.max_samples) return null;
        self.pending_samples[self.pending_len] = .{ x, y };
        self.pending_len += 1;
        return self.pending_len - 1;
    }

    /// Results for the points requested before the most recently completed
    /// frame (sampled after that frame's last tick).
    pub fn samples(self: *const Air) []const SampleResult {
        return self.sample_values[0..self.sample_len];
    }

    /// The last 256 x 256 downsampled field, or null before the first
    /// readback (set `field_readback`). Index `y * field_size + x`, cells of
    /// 8 x 8 pixels in window coordinates.
    pub fn field(self: *const Air) ?[]const abi.FieldCell {
        return if (self.field_valid) self.field_cpu else null;
    }

    /// Pressure events appended during the most recently completed frame.
    pub fn events(self: *const Air) []const abi.AirEvent {
        return self.event_list[0..self.event_len];
    }

    /// Called by the engine when frame slot `slot` has completed.
    pub fn collect(self: *Air, slot: u32) void {
        const r = &self.readback[slot];
        if (r.ticks == 0) return;
        var st: Stats = .{ .first_tick = r.first_tick, .ticks = r.ticks };
        self.event_len = 0;
        for (0..r.ticks) |k| {
            const words = r.stats.typed(u32)[k * stats_stride / 4 ..];
            const ej: abi.ListHeader = .{ .count = words[0], .capacity = words[1], .dropped = words[2], .tick = words[3] };
            const ev: abi.ListHeader = .{ .count = words[4], .capacity = words[5], .dropped = words[6], .tick = words[7] };
            st.active_tiles = words[8];
            st.ejects += @min(ej.count, abi.blast_eject_capacity);
            st.ejects_dropped += ej.dropped;
            const n_ev = @min(ev.count, abi.event_capacity);
            st.events += n_ev;
            st.events_dropped += ev.dropped;
            const bytes = r.events.bytes()[k * events_stride + @sizeOf(abi.ListHeader) ..];
            const recs: [*]const abi.AirEvent = @ptrCast(@alignCast(bytes.ptr));
            for (recs[0..n_ev]) |e| {
                if (self.event_len >= self.event_list.len) break;
                self.event_list[self.event_len] = e;
                self.event_len += 1;
            }
        }
        self.stats = st;
        self.total_ejects += st.ejects;
        self.total_events += st.events;
        self.sample_len = r.samples;
        self.sample_tick = r.first_tick + r.ticks - 1;
        const res = r.sample_res.typed(abi.Sample);
        for (0..r.samples) |i| {
            self.sample_values[i] = .{ .x = self.sample_points[i][0], .y = self.sample_points[i][1], .sample = res[i] };
        }
        if (r.field_written) {
            @memcpy(self.field_cpu, r.field.typed(abi.FieldCell)[0..self.field_cpu.len]);
            self.field_valid = true;
            self.field_tick = r.first_tick + r.ticks - 1;
        }
        r.ticks = 0;
    }

    // ------------------------------------------------------------------
    // Recording
    // ------------------------------------------------------------------

    /// Gas advection, once per substep before movement.
    pub fn recordSubstep(self: *Air, frame: *Frame) void {
        if (!self.enabled or self.first) return;
        frame.timed("air.gas", recordGas, .{ self, frame });
    }

    fn recordGas(self: *Air, frame: *Frame) void {
        frame.bindCompute(self.pipes[@backingInt(P.gas)]);
        frame.push(extern struct { tick: u32, substep: u32, mark: u32, scale: f32 }{
            .tick = frame.tick,
            .substep = frame.substep,
            .mark = @intFromBool(frame.sleep),
            .scale = self.params.gas_scale,
        });
        self.ctx.vkd.cmdDispatchIndirect(frame.cmd, self.tile_list.handle, 0);
        frame.barrier();
    }

    /// The tick's air work, after coarsening.
    pub fn record(self: *Air, frame: *Frame) void {
        if (!self.enabled) return;
        const k = frame.command_base / commands.capacity - frame.slot * max_ticks;
        std.debug.assert(k < max_ticks);
        self.takeCommands(frame.commands);
        const r = &self.readback[frame.slot];
        if (k == 0) {
            r.ticks = 0;
            r.first_tick = frame.tick;
            r.field_written = false;
            // Requests made before this frame are sampled at each of its ticks.
            @memcpy(self.sample_points[0..self.pending_len], self.pending_samples[0..self.pending_len]);
            const req = r.sample_req.typed([2]i32);
            @memcpy(req[0..self.pending_len], self.pending_samples[0..self.pending_len]);
            r.samples = self.pending_len;
            self.pending_len = 0;
        }
        r.ticks = @intCast(k + 1);

        const n_inject = self.uploadInjections(frame.slot, @intCast(k));
        frame.timed("air.prep", recordPrep, .{ self, frame, n_inject, @as(u32, @intCast(k)) });
        var s: u32 = 0;
        while (s < self.params.steps) : (s += 1) {
            frame.timed("air.lbm", recordStep, .{ self, frame, n_inject, @as(u32, @intCast(k)), s });
        }
        frame.timed("air.fx", recordEffects, .{ self, frame });
        frame.timed("air.io", recordIo, .{ self, frame, r, @as(u32, @intCast(k)) });
        self.first = false;
        self.advanceInjections();
    }

    fn takeCommands(self: *Air, list: []const commands.CommandGpu) void {
        for (list) |c| {
            if (c.kind != @backingInt(commands.Kind.inject_pressure)) continue;
            if (self.active_len >= max_injections) {
                self.dropped_injections += 1;
                continue;
            }
            const radius = @as(f32, @floatFromInt(c.x1)) * 0.5;
            const steps: u32 = @intCast(@max(c.y1, 1));
            const disc = std.math.pi * radius * radius;
            const density: f32 = @bitCast(c.material);
            const momentum: f32 = @bitCast(c.flags);
            self.active[self.active_len] = .{
                .cx = @as(f32, @floatFromInt(c.x0)) * 0.5,
                .cy = @as(f32, @floatFromInt(c.y0)) * 0.5,
                .radius = radius,
                .mass = density * disc / @as(f32, @floatFromInt(steps)),
                .momentum = momentum * disc / @as(f32, @floatFromInt(steps)),
                .steps_left = steps,
            };
            self.active_len += 1;
        }
    }

    fn uploadInjections(self: *Air, slot: u32, k: u32) u32 {
        const base = (slot * max_ticks + k) * max_injections;
        const ring = self.inject_ring.typed(InjectionGpu)[base..][0..max_injections];
        for (self.active[0..self.active_len], 0..) |a, i| {
            ring[i] = .{
                .cx = a.cx,
                .cy = a.cy,
                .radius = a.radius,
                .mass = a.mass,
                .momentum = a.momentum,
                .steps = @min(a.steps_left, self.params.steps),
            };
        }
        return self.active_len;
    }

    fn advanceInjections(self: *Air) void {
        var w: u32 = 0;
        for (self.active[0..self.active_len]) |a| {
            var b = a;
            b.steps_left -|= self.params.steps;
            if (b.steps_left > 0) {
                self.active[w] = b;
                w += 1;
            }
        }
        self.active_len = w;
    }

    const InjectPush = extern struct {
        origin: [2]i32,
        size: [2]u32,
        ring_slot: u32,
        index: u32,
        counts_slot: u32,
        counter: u32,
        node_slot: u32,
        dist_slot: u32,
        seam: [2]i32,
        rho_max: f32,
        mark: u32,
    };

    fn injectBox(a: Active) struct { [2]i32, [2]u32 } {
        const x0: i32 = @intFromFloat(@floor(a.cx - a.radius - 1));
        const y0: i32 = @intFromFloat(@floor(a.cy - a.radius - 1));
        const x1: i32 = @intFromFloat(@ceil(a.cx + a.radius + 1));
        const y1: i32 = @intFromFloat(@ceil(a.cy + a.radius + 1));
        const ax = x0 & ~@as(i32, 15);
        const ay = y0 & ~@as(i32, 15);
        return .{ .{ ax, ay }, .{ @intCast(@min(x1 - ax, size)), @intCast(@min(y1 - ay, size)) } };
    }

    fn injectPush(self: *const Air, frame: *const Frame, k: u32, i: u32, a: Active) InjectPush {
        const origin, const box = injectBox(a);
        return .{
            .origin = origin,
            .size = box,
            .ring_slot = self.inject_ring.slot,
            .index = (frame.slot * max_ticks + k) * max_injections + i,
            .counts_slot = self.inject_counts.slot,
            .counter = i,
            .node_slot = self.node.slot,
            .dist_slot = self.dist[self.parity].slot,
            .seam = self.seam,
            .rho_max = self.params.rho_max,
            .mark = 1,
        };
    }

    fn recordPrep(self: *Air, frame: *Frame, n_inject: u32, k: u32) void {
        const ctx = self.ctx;
        const cmd = frame.cmd;
        frame.fullBarrier();
        const ej = abi.ListHeader{ .count = 0, .capacity = abi.blast_eject_capacity, .dropped = 0, .tick = frame.tick };
        const ev = abi.ListHeader{ .count = 0, .capacity = abi.event_capacity, .dropped = 0, .tick = frame.tick };
        ctx.vkd.cmdUpdateBuffer(cmd, self.ejects.handle, 0, @sizeOf(abi.ListHeader), &ej);
        ctx.vkd.cmdUpdateBuffer(cmd, self.events_buf.handle, 0, @sizeOf(abi.ListHeader), &ev);
        const args = [4]u32{ 0, 1, 1, 0 };
        ctx.vkd.cmdUpdateBuffer(cmd, self.tile_list.handle, 0, @sizeOf(@TypeOf(args)), &args);
        ctx.vkd.cmdFillBuffer(cmd, self.inject_counts.handle, 0, vk.WHOLE_SIZE, 0);
        gpu.memory.memoryBarrier(ctx, cmd, .{ .all_transfer = true }, .{ .transfer_write = true }, .{ .compute_shader = true }, .{ .shader_storage_read = true, .shader_storage_write = true });

        frame.bindCompute(self.pipes[@backingInt(P.prep)]);
        frame.push(extern struct { node: u32, temp: u32, d0: u32, d1: u32, seam: [2]i32, buoyancy: f32, ambient: u32, first: u32, mark: u32 }{
            .node = self.node.slot,
            .temp = self.temp_slot,
            .d0 = self.dist[0].slot,
            .d1 = self.dist[1].slot,
            .seam = self.seam,
            .buoyancy = self.params.buoyancy,
            .ambient = self.params.ambient_temp,
            .first = @intFromBool(self.first),
            .mark = 1,
        });
        frame.dispatch(size / 16, size / 16, 1);
        frame.barrier();

        if (n_inject > 0) {
            frame.bindCompute(self.pipes[@backingInt(P.inject_count)]);
            for (self.active[0..n_inject], 0..) |a, i| {
                const p = self.injectPush(frame, k, @intCast(i), a);
                frame.push(p);
                frame.dispatch((p.size[0] + 15) / 16, (p.size[1] + 15) / 16, 1);
            }
            frame.barrier();
        }

        frame.bindCompute(self.pipes[@backingInt(P.compact)]);
        frame.push(extern struct { all: u32 }{ .all = @intFromBool(self.all_active) });
        frame.dispatch(abi.tiles_per_side / 16, abi.tiles_per_side / 16, 1);
        gpu.memory.memoryBarrier(ctx, cmd, .{ .compute_shader = true }, .{ .shader_storage_write = true }, .{ .compute_shader = true, .draw_indirect = true, .all_transfer = true }, .{ .shader_storage_read = true, .shader_storage_write = true, .indirect_command_read = true, .transfer_read = true });
    }

    fn recordStep(self: *Air, frame: *Frame, n_inject: u32, k: u32, s: u32) void {
        const p = &self.params;
        if (n_inject > 0) {
            frame.bindCompute(self.pipes[@backingInt(P.inject_apply)]);
            for (self.active[0..n_inject], 0..) |a, i| {
                if (s >= @min(a.steps_left, p.steps)) continue;
                const push = self.injectPush(frame, k, @intCast(i), a);
                frame.push(push);
                frame.dispatch((push.size[0] + 15) / 16, (push.size[1] + 15) / 16, 1);
                frame.barrier();
            }
        }
        const last = s + 1 == p.steps;
        const flags: u32 = (if (last) @as(u32, 1) else 0) | (if (s == 0) @as(u32, 2) else 0) | (if (self.all_active) @as(u32, 4) else 0) | 8;
        const tau = @max(p.tau, 0.55);
        frame.bindCompute(self.pipes[@backingInt(P.lbm)]);
        frame.push(extern struct {
            src: u32,
            dst: u32,
            node: u32,
            flags: u32,
            omega: f32,
            rho_min: f32,
            rho_max: f32,
            u_max: f32,
            eps_u: f32,
            px_per_tick: f32,
            seam: [2]i32,
            sponge_width: f32,
            sponge_strength: f32,
            slip: f32,
        }{
            .src = self.dist[self.parity].slot,
            .dst = self.dist[self.parity ^ 1].slot,
            .node = self.node.slot,
            .flags = flags,
            .omega = 1.0 / tau,
            .rho_min = p.rho_min,
            .rho_max = p.rho_max,
            .u_max = p.mach_max / @sqrt(3.0),
            .eps_u = p.eps_u,
            .px_per_tick = 2.0 * @as(f32, @floatFromInt(p.steps)),
            .seam = self.seam,
            .sponge_width = p.sponge_width,
            .sponge_strength = p.sponge_strength,
            .slip = std.math.clamp(p.slip, 0, 1),
        });
        self.dispatchTiles(frame);
        frame.barrier();
        self.parity ^= 1;
    }

    fn dispatchTiles(self: *Air, frame: *Frame) void {
        if (self.all_active) {
            frame.dispatch(abi.tiles_per_side, abi.tiles_per_side, 1);
        } else {
            self.ctx.vkd.cmdDispatchIndirect(frame.cmd, self.tile_list.handle, 0);
        }
    }

    fn recordEffects(self: *Air, frame: *Frame) void {
        const p = &self.params;
        frame.bindCompute(self.pipes[@backingInt(P.effects)]);
        frame.push(extern struct {
            seam: [2]i32,
            node: u32,
            tick: u32,
            flags: u32,
            search: i32,
            blast_scale: f32,
            damage_scale: f32,
            eject_scale: f32,
            eject_push: f32,
            eject_max: f32,
            wall_scale: f32,
        }{
            .seam = self.seam,
            .node = self.node.slot,
            .tick = frame.tick,
            .flags = (if (self.all_active) @as(u32, 1) else 0) | (if (frame.sleep) @as(u32, 2) else 0) | 4 | 8,
            .search = p.wall_search,
            .blast_scale = p.blast_scale,
            .damage_scale = p.damage_scale,
            .eject_scale = p.eject_scale,
            .eject_push = p.eject_push,
            .eject_max = p.eject_max,
            .wall_scale = p.wall_scale,
        });
        self.dispatchTiles(frame);
        frame.barrier();
    }

    fn recordIo(self: *Air, frame: *Frame, r: *Readback, k: u32) void {
        const ctx = self.ctx;
        const cmd = frame.cmd;
        // The renderer's debug overlay modes air_pressure (2) / air_velocity (3).
        if (frame.overlay == gpu.constants.overlay_air_pressure or frame.overlay == gpu.constants.overlay_air_velocity) {
            frame.bindCompute(self.pipes[@backingInt(P.overlay)]);
            frame.push(extern struct { pg: f32, sg: f32, mode: u32 }{
                .pg = self.params.overlay_pressure_gain,
                .sg = self.params.overlay_speed_gain,
                .mode = @intFromBool(frame.overlay == gpu.constants.overlay_air_velocity),
            });
            frame.dispatch(size / 16, size / 16, 1);
        }
        if (r.samples > 0) {
            frame.bindCompute(self.pipes[@backingInt(P.sample)]);
            frame.push(extern struct { req: u32, res: u32, count: u32 }{ .req = r.sample_req.slot, .res = r.sample_res.slot, .count = r.samples });
            frame.dispatch(1, 1, 1);
        }
        if (self.field_readback) {
            frame.bindCompute(self.pipes[@backingInt(P.downsample)]);
            frame.push(extern struct { out: u32 }{ .out = r.field.slot });
            frame.dispatch(abi.field_size / 16, abi.field_size / 16, 1);
            r.field_written = true;
        }
        gpu.memory.memoryBarrier(ctx, cmd, .{ .compute_shader = true }, .{ .shader_storage_write = true }, .{ .all_transfer = true, .compute_shader = true }, .{ .transfer_read = true, .shader_storage_read = true });
        const so = k * stats_stride;
        ctx.vkd.cmdCopyBuffer(cmd, self.ejects.handle, r.stats.handle, &.{.{ .src_offset = 0, .dst_offset = so, .size = 16 }});
        ctx.vkd.cmdCopyBuffer(cmd, self.events_buf.handle, r.stats.handle, &.{.{ .src_offset = 0, .dst_offset = so + 16, .size = 16 }});
        ctx.vkd.cmdCopyBuffer(cmd, self.tile_list.handle, r.stats.handle, &.{.{ .src_offset = 0, .dst_offset = so + 32, .size = 4 }});
        ctx.vkd.cmdCopyBuffer(cmd, self.events_buf.handle, r.events.handle, &.{.{ .src_offset = 0, .dst_offset = k * events_stride, .size = events_stride }});
    }
};
