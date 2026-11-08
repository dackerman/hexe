//! Debug subsystem: animated noise written into the cell image (the M0
//! bring-up shader). Enabled by `--scene noise`; replaces the simulation.
const gpu = @import("../gpu/gpu.zig");
const vk = gpu.vk;
const cell = @import("cell.zig");
const Frame = @import("pipeline.zig").Frame;
const shaders = @import("shaders");
/// Noise picks material ids below this (the version one set).
const noise_materials = 31;
const Config = @import("pipeline.zig").Config;
const Allocator = @import("std").mem.Allocator;

pub const Noise = struct {
    ctx: *gpu.Context,
    pipeline: vk.Pipeline,

    pub fn init(ctx: *gpu.Context, cfg: Config, alloc: Allocator) !Noise {
        _ = cfg;
        _ = alloc;
        return .{ .ctx = ctx, .pipeline = try gpu.pipelines.createCompute(ctx, &shaders.debug_noise_comp) };
    }

    pub fn deinit(self: *Noise) void {
        gpu.pipelines.destroy(self.ctx, self.pipeline);
    }

    pub fn record(self: *Noise, frame: *Frame) void {
        frame.timed("noise", recordInner, .{ self, frame });
    }

    fn recordInner(self: *Noise, frame: *Frame) void {
        frame.bindCompute(self.pipeline);
        frame.push(extern struct { tick: u32, count: u32 }{ .tick = frame.tick, .count = noise_materials });
        frame.dispatch(cell.world_size / 16, cell.world_size / 16, 1);
        frame.barrier();
    }
};
