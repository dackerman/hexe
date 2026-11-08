//! The pixel grid subsystem: owns the cell and owner images, the material
//! table, the activity tiles, and records compaction and Margolus movement.
const std = @import("std");
const gpu = @import("../gpu/gpu.zig");
const vk = gpu.vk;
const cell = @import("cell.zig");
const materials = @import("materials.zig");
const pipeline_mod = @import("pipeline.zig");
const Frame = pipeline_mod.Frame;
const shaders = @import("shaders");

/// Byte size of the tile list buffer: dispatch args (3 words) + pad + list.
pub const tile_list_bytes = 16 + cell.tile_count * 4;

pub const Grid = struct {
    ctx: *gpu.Context,
    cells: gpu.Image,
    owner: gpu.Image,
    materials: gpu.Buffer,
    tile_marks: gpu.Buffer,
    tile_list: gpu.Buffer,
    activity_pipeline: vk.Pipeline,
    movement_pipeline: vk.Pipeline,

    pub fn init(ctx: *gpu.Context, cfg: pipeline_mod.Config, alloc: std.mem.Allocator) !Grid {
        _ = cfg;
        _ = alloc;
        var self: Grid = undefined;
        self.ctx = ctx;
        const world_image = gpu.memory.ImageDesc{
            .width = cell.world_size,
            .height = cell.world_size,
            .format = .r32_uint,
            .usage = .{ .storage = true, .transfer_src = true, .transfer_dst = true },
        };
        self.cells = try gpu.Image.init(ctx, world_image);
        errdefer self.cells.deinit(ctx);
        try self.cells.initLayout(ctx, .general, true);
        self.cells.register(ctx, gpu.constants.slot_img_cells);

        self.owner = try gpu.Image.init(ctx, world_image);
        errdefer self.owner.deinit(ctx);
        try self.owner.initLayout(ctx, .general, true);
        self.owner.register(ctx, gpu.constants.slot_img_owner);

        self.materials = try gpu.Buffer.init(ctx, materials.count * @sizeOf(materials.MaterialGpu), .{ .storage_buffer = true, .transfer_dst = true }, .gpu_only);
        errdefer self.materials.deinit(ctx);
        self.materials.register(ctx, gpu.constants.slot_buf_materials);

        self.tile_marks = try gpu.Buffer.init(ctx, cell.tile_mark_bytes, .{ .storage_buffer = true, .transfer_dst = true, .transfer_src = true }, .gpu_only);
        errdefer self.tile_marks.deinit(ctx);
        self.tile_marks.register(ctx, gpu.constants.slot_buf_tile_marks);

        self.tile_list = try gpu.Buffer.init(ctx, tile_list_bytes, .{ .storage_buffer = true, .indirect_buffer = true, .transfer_dst = true, .transfer_src = true }, .gpu_only);
        errdefer self.tile_list.deinit(ctx);
        self.tile_list.register(ctx, gpu.constants.slot_buf_tile_list);
        try ctx.runOnce(.compute, zeroBuffers, .{ ctx, &self });

        self.activity_pipeline = try gpu.pipelines.createCompute(ctx, &shaders.sim_grid_activity_comp);
        errdefer gpu.pipelines.destroy(ctx, self.activity_pipeline);
        self.movement_pipeline = try gpu.pipelines.createCompute(ctx, &shaders.sim_grid_movement_comp);
        return self;
    }

    fn zeroBuffers(cmd: vk.CommandBuffer, ctx: *gpu.Context, self: *const Grid) void {
        ctx.vkd.cmdFillBuffer(cmd, self.tile_marks.handle, 0, vk.WHOLE_SIZE, 0);
        ctx.vkd.cmdFillBuffer(cmd, self.tile_list.handle, 0, vk.WHOLE_SIZE, 0);
    }

    pub fn deinit(self: *Grid) void {
        const ctx = self.ctx;
        gpu.pipelines.destroy(ctx, self.movement_pipeline);
        gpu.pipelines.destroy(ctx, self.activity_pipeline);
        self.tile_list.deinit(ctx);
        self.tile_marks.deinit(ctx);
        self.materials.deinit(ctx);
        self.owner.deinit(ctx);
        self.cells.deinit(ctx);
    }

    pub fn shared(self: *Grid) pipeline_mod.Shared {
        return .{
            .cells = &self.cells,
            .owner = &self.owner,
            .materials = &self.materials,
            .tile_marks = &self.tile_marks,
            .tile_list = &self.tile_list,
        };
    }

    /// Replace the GPU material table. Waits for the GPU to go idle; call
    /// between frames (hot reload).
    pub fn uploadMaterials(self: *Grid, tables: *const materials.Tables) !void {
        const ctx = self.ctx;
        ctx.waitIdle();
        var staging = try gpu.Buffer.init(ctx, self.materials.size, .{ .transfer_src = true }, .cpu_to_gpu);
        defer staging.deinit(ctx);
        @memcpy(staging.bytes(), tables.materialBytes());
        try ctx.runOnce(.compute, copyWhole, .{ ctx, staging.handle, self.materials.handle, self.materials.size });
    }

    /// Fill the whole cell image with `value` (a world of ambient air:
    /// `materials.ambientAir`). Waits for the GPU.
    pub fn clearCells(self: *Grid, value: u32) !void {
        try self.ctx.runOnce(.compute, recordClear, .{ self.ctx, self.cells.handle, value });
    }

    fn recordClear(cmd: vk.CommandBuffer, ctx: *gpu.Context, image: vk.Image, value: u32) void {
        gpu.memory.memoryBarrier(ctx, cmd, .{ .all_commands = true }, .{ .memory_write = true }, .{ .all_transfer = true }, .{ .transfer_write = true });
        const color = vk.ClearColorValue{ .uint_32 = .{ value, 0, 0, 0 } };
        ctx.vkd.cmdClearColorImage(cmd, image, .general, &color, &.{gpu.memory.color_range});
        gpu.memory.memoryBarrier(ctx, cmd, .{ .all_transfer = true }, .{ .transfer_write = true }, .{ .all_commands = true }, .{ .memory_read = true, .memory_write = true });
    }

    fn copyWhole(cmd: vk.CommandBuffer, ctx: *gpu.Context, src: vk.Buffer, dst: vk.Buffer, size: u64) void {
        ctx.vkd.cmdCopyBuffer(cmd, src, dst, &.{.{ .src_offset = 0, .dst_offset = 0, .size = size }});
    }

    /// Build this tick's active tile list from the marks (or all tiles when
    /// sleep is off) and clear the marks.
    pub fn recordCompaction(self: *Grid, frame: *Frame) void {
        frame.timed("activity", recordCompactionInner, .{ self, frame });
    }

    fn recordCompactionInner(self: *Grid, frame: *Frame) void {
        const ctx = frame.ctx;
        frame.fullBarrier();
        const args = [4]u32{ 0, 1, 1, 0 };
        ctx.vkd.cmdUpdateBuffer(frame.cmd, self.tile_list.handle, 0, @sizeOf(@TypeOf(args)), &args);
        gpu.memory.memoryBarrier(ctx, frame.cmd, .{ .all_transfer = true }, .{ .transfer_write = true }, .{ .compute_shader = true }, .{ .shader_storage_read = true, .shader_storage_write = true });
        frame.bindCompute(self.activity_pipeline);
        frame.push(extern struct { all_active: u32 }{ .all_active = @intFromBool(!frame.sleep) });
        frame.dispatch(cell.tiles_per_side / 16, cell.tiles_per_side / 16, 1);
        gpu.memory.memoryBarrier(ctx, frame.cmd, .{ .compute_shader = true }, .{ .shader_storage_write = true }, .{ .compute_shader = true, .draw_indirect = true, .all_transfer = true }, .{ .shader_storage_read = true, .shader_storage_write = true, .indirect_command_read = true, .transfer_read = true });
    }

    /// One Margolus substep over the active tiles.
    pub fn recordSubstep(self: *Grid, frame: *Frame) void {
        frame.timed("movement", recordSubstepInner, .{ self, frame });
    }

    fn recordSubstepInner(self: *Grid, frame: *Frame) void {
        frame.bindCompute(self.movement_pipeline);
        frame.push(extern struct { tick: u32, substep: u32, mark: u32 }{
            .tick = frame.tick,
            .substep = frame.substep,
            .mark = @intFromBool(frame.sleep),
        });
        frame.dispatchActiveTiles();
        frame.barrier();
    }
};
