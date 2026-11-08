//! The simulation pipeline: the ordered list of subsystems and the `Frame`
//! passed to each one's `record` (docs/08-engineering.md "Subsystem and pass
//! interface").
//!
//! A subsystem is a struct with
//!     pub fn init(ctx: *gpu.Context, cfg: Config, alloc: Allocator) !Self
//!     pub fn record(self: *Self, frame: *Frame) void          (once per tick)
//!   and/or
//!     pub fn recordSubstep(self: *Self, frame: *Frame) void   (once per substep)
//!     pub fn deinit(self: *Self) void
//! It keeps `ctx` and owns the GPU resources it creates (allocate at init,
//! never in record). It records compute work into
//! `frame.cmd`, wraps it in `frame.timed("name", ...)` so it shows in the HUD,
//! `--profile` and `zig build bench`, and ends with `frame.barrier()` when the
//! next pass reads what it wrote. The descriptor set is already bound.
//!
//! Adding a layer: add a field to `Pipeline`, init/deinit it in the delimited
//! sections below, and call it from `recordTick` at its place in the
//! architecture's frame order.
const std = @import("std");
const gpu = @import("../gpu/gpu.zig");
const vk = gpu.vk;
const cell = @import("cell.zig");
const commands = @import("commands.zig");
const Grid = @import("grid.zig").Grid;
const Noise = @import("noise.zig").Noise;
const materials = @import("materials.zig");

pub const frames_in_flight = 2;
/// Most ticks recorded into one frame (catch-up after a slow frame).
pub const max_ticks_per_frame = 4;

pub const Config = struct {
    /// Activity tiles: only tiles that changed (and their neighbors) are
    /// simulated. Off = every tile every tick.
    sleep: bool = true,
    /// Debug: replace the simulation with animated noise (M0 bring-up).
    noise: bool = false,
};

/// World-wide GPU resources every pass may use. All live at fixed bindless
/// slots (SLOT_IMG_*, SLOT_BUF_* in common.glsl), so shaders reach them
/// without push constants; the handles are here for barriers, copies and
/// readback.
pub const Shared = struct {
    /// R32_UINT cell image, GENERAL layout (SLOT_IMG_CELLS).
    cells: *gpu.Image,
    /// R32_UINT owner image, GENERAL layout (SLOT_IMG_OWNER).
    owner: *gpu.Image,
    /// MaterialGpu[256] (SLOT_BUF_MATERIALS).
    materials: *gpu.Buffer,
    /// Activity marks + this tick's active flags (SLOT_BUF_TILE_MARKS).
    tile_marks: *gpu.Buffer,
    /// Indirect dispatch args + active tile list (SLOT_BUF_TILE_LIST).
    tile_list: *gpu.Buffer,
    /// Coarsened solid mask for the fluid solvers; produced from M5 on.
    solid_mask: ?*gpu.Image = null,
};

pub const Frame = struct {
    ctx: *gpu.Context,
    /// Compute command buffer for this tick (compute queue).
    cmd: vk.CommandBuffer,
    tick: u32,
    /// Current substep while inside the substep loop, else 0.
    substep: u32 = 0,
    /// Frame-in-flight slot, for per-slot resources.
    slot: u32,
    shared: *const Shared,
    timer: *gpu.timestamps.Recorder,
    /// This tick's commands as uploaded; `command_base` is the index of the
    /// first one in the GPU command ring.
    commands: []const commands.CommandGpu,
    command_base: u32,
    /// Activity tiles enabled: passes that change cells must mark tiles.
    sleep: bool,
    /// Current debug overlay (OVERLAY_* in common.glsl, src/render/overlay.zig).
    /// A pass that feeds an image overlay writes SLOT_IMG_DEBUG_OVERLAY only
    /// while this equals its id.
    overlay: u32 = 0,

    /// Run `func(args...)` between two timestamps named `name`.
    pub fn timed(self: *Frame, name: []const u8, comptime func: anytype, args: anytype) void {
        const scope = self.timer.begin(self.ctx, self.cmd, name);
        @call(.auto, func, args);
        self.timer.end(self.ctx, self.cmd, scope);
    }

    /// Compute writes -> compute reads/writes.
    pub fn barrier(self: *Frame) void {
        gpu.memory.computeBarrier(self.ctx, self.cmd);
    }

    /// Everything before -> everything after (use around transfers).
    pub fn fullBarrier(self: *Frame) void {
        gpu.memory.memoryBarrier(
            self.ctx,
            self.cmd,
            .{ .all_commands = true },
            .{ .memory_write = true },
            .{ .all_commands = true },
            .{ .memory_read = true, .memory_write = true },
        );
    }

    pub fn bindCompute(self: *Frame, pipeline: vk.Pipeline) void {
        self.ctx.vkd.cmdBindPipeline(self.cmd, .compute, pipeline);
    }

    pub fn push(self: *Frame, value: anytype) void {
        gpu.pipelines.push(self.ctx, self.cmd, value);
    }

    pub fn dispatch(self: *Frame, x: u32, y: u32, z: u32) void {
        self.ctx.vkd.cmdDispatch(self.cmd, x, y, z);
    }

    /// One 16x16 workgroup per active tile, indirect over the tile list built
    /// by this tick's compaction. Shaders find their tile with
    /// `TILE_LIST.tiles[gl_WorkGroupID.x]`.
    pub fn dispatchActiveTiles(self: *Frame) void {
        self.ctx.vkd.cmdDispatchIndirect(self.cmd, self.shared.tile_list.handle, 0);
    }
};

pub const Pipeline = struct {
    config: Config,
    shared: Shared,
    // ---- subsystems (owners of their GPU resources) ----
    grid: Grid,
    applier: commands.Applier,
    noise: Noise,
    // ---- end subsystems ----

    /// In place: `shared` points into `self`.
    pub fn init(self: *Pipeline, ctx: *gpu.Context, config: Config, alloc: std.mem.Allocator, table: *const materials.Table) !void {
        self.config = config;
        // ---- subsystem init (order: grid first, it owns the shared images) ----
        self.grid = try Grid.init(ctx, config, alloc);
        errdefer self.grid.deinit();
        try self.grid.uploadMaterials(table);
        self.applier = try commands.Applier.init(ctx, config, alloc);
        errdefer self.applier.deinit();
        self.noise = try Noise.init(ctx, config, alloc);
        errdefer self.noise.deinit();
        // ---- end subsystem init ----
        self.shared = self.grid.shared();
    }

    pub fn deinit(self: *Pipeline) void {
        // ---- subsystem deinit (reverse order) ----
        self.noise.deinit();
        self.applier.deinit();
        self.grid.deinit();
        // ---- end subsystem deinit ----
    }

    /// Record one tick, in the order of docs/01-architecture.md "Frame pipeline".
    pub fn recordTick(self: *Pipeline, frame: *Frame) void {
        if (self.config.noise) {
            self.noise.record(frame);
            return;
        }
        // ---- tick order ----
        // 2. apply edits
        self.applier.record(frame);
        //    rasterize bodies (M7)
        // 7'. activity compaction: tiles marked last tick and by this tick's
        //     edits form this tick's active list (docs/decisions/10-activity-tiles.md)
        self.grid.recordCompaction(frame);
        // 3. 8 x { reactions and heat gather (M3); Margolus movement }
        var s: u32 = 0;
        while (s < cell.substeps) : (s += 1) {
            frame.substep = s;
            self.grid.recordSubstep(frame);
        }
        frame.substep = 0;
        // 4. coarsen solid mask (M5)
        // 5. air field (M5)
        // 6. liquid solver, particles (M4, M6)
        // 7. readback buffers, event queue (M4)
        // ---- end tick order ----
    }
};
