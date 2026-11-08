//! Debug subsystem: animated noise written into the cell image (the M0
//! bring-up shader). Enabled by `--scene noise`; replaces the simulation.
const gpu = @import("../gpu/gpu.zig");
const vk = gpu.vk;
const cell = @import("cell.zig");
const Frame = @import("pipeline.zig").Frame;
const shaders = @import("shaders");
const builtin_materials = @import("materials_builtin.zig");

pub const Noise = struct {
    pipeline: vk.Pipeline,

    pub fn init(ctx: *gpu.Context) !Noise {
        return .{ .pipeline = try gpu.pipelines.createCompute(ctx, &shaders.debug_noise_comp) };
    }

    pub fn deinit(self: *Noise, ctx: *gpu.Context) void {
        gpu.pipelines.destroy(ctx, self.pipeline);
    }

    pub fn record(self: *Noise, frame: *Frame) void {
        frame.timed("noise", recordInner, .{ self, frame });
    }

    fn recordInner(self: *Noise, frame: *Frame) void {
        frame.bindCompute(self.pipeline);
        frame.push(extern struct { tick: u32, count: u32 }{ .tick = frame.tick, .count = builtin_materials.descs.len });
        frame.dispatch(cell.world_size / 16, cell.world_size / 16, 1);
        frame.barrier();
    }
};
