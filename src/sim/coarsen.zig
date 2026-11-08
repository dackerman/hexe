//! Obstacle coarsening (docs/04-fluids.md "Shared: obstacle coarsening"):
//! once per tick after movement, every 2 x 2 pixel block of the window is
//! reduced to the number of solid pixels (static phase or body-owned, 0-4)
//! and liquid pixels (0-4), for the air field and the liquid solver, plus
//! the mean temperature byte for the air field's buoyancy.
//!
//! Outputs (R8_UINT, 1024 x 1024, GENERAL layout):
//!   solid   SLOT_IMG_SOLID_COARSE   (`Frame.shared.solid_coarse`)
//!   liquid  SLOT_IMG_LIQUID_COARSE  (`Frame.shared.liquid_coarse`)
//!   temp    dynamic slot, private to the air field (`temp.slot`)
//! The pass reads the cell image only, so it never affects the grid and
//! runs whether or not the air field is enabled. Body velocity per block
//! (for moving boundaries) is not produced yet; see
//! docs/decisions/70-air-field-abi.md.
const std = @import("std");
const gpu = @import("../gpu/gpu.zig");
const vk = gpu.vk;
const air_abi = @import("air_abi.zig");
const pipeline_mod = @import("pipeline.zig");
const Frame = pipeline_mod.Frame;
const shaders = @import("shaders");

pub const Coarsen = struct {
    ctx: *gpu.Context,
    solid: gpu.Image,
    liquid: gpu.Image,
    temp: gpu.Image,
    pipeline: vk.Pipeline,

    pub fn init(ctx: *gpu.Context, cfg: pipeline_mod.Config, alloc: std.mem.Allocator) !Coarsen {
        _ = cfg;
        _ = alloc;
        var self: Coarsen = undefined;
        self.ctx = ctx;
        const desc = gpu.memory.ImageDesc{
            .width = air_abi.size,
            .height = air_abi.size,
            .format = .r8_uint,
            .usage = .{ .storage = true, .transfer_src = true, .transfer_dst = true },
        };
        self.solid = try gpu.Image.init(ctx, desc);
        errdefer self.solid.deinit(ctx);
        try self.solid.initLayout(ctx, .general, true);
        self.solid.register(ctx, gpu.constants.slot_img_solid_coarse);

        self.liquid = try gpu.Image.init(ctx, desc);
        errdefer self.liquid.deinit(ctx);
        try self.liquid.initLayout(ctx, .general, true);
        self.liquid.register(ctx, gpu.constants.slot_img_liquid_coarse);

        self.temp = try gpu.Image.init(ctx, desc);
        errdefer self.temp.deinit(ctx);
        try self.temp.initLayout(ctx, .general, true);
        self.temp.register(ctx, try ctx.descriptors.allocImageSlot());

        self.pipeline = try gpu.pipelines.createCompute(ctx, &shaders.sim_coarsen_comp);
        return self;
    }

    pub fn deinit(self: *Coarsen) void {
        const ctx = self.ctx;
        gpu.pipelines.destroy(ctx, self.pipeline);
        self.temp.deinit(ctx);
        self.liquid.deinit(ctx);
        self.solid.deinit(ctx);
    }

    pub fn record(self: *Coarsen, frame: *Frame) void {
        frame.timed("coarsen", recordInner, .{ self, frame });
    }

    fn recordInner(self: *Coarsen, frame: *Frame) void {
        frame.bindCompute(self.pipeline);
        frame.push(extern struct { temp_slot: u32 }{ .temp_slot = self.temp.slot });
        frame.dispatch(air_abi.size / 16, air_abi.size / 16, 1);
        frame.barrier();
    }
};
