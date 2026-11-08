//! What the bodies layer needs to know about the grid, behind a small
//! interface so the readback behind it can change.
//!
//! `TerrainSource` answers two questions for a rectangle of world pixels
//! (unwrapped coordinates, wrapped onto the torus):
//! - `solidMask(region)`: 1 where a body collides (static or powder phase,
//!   not body-owned, not particle-backed), else 0. Feeds `setStaticCollision`.
//! - `materials(region)`: the material id per pixel, with body-owned cells
//!   reported as `body_owned` (255). Feeds connectivity and the default fluid
//!   force sampler.
//! Both reflect the grid some ticks ago (`readTick`), never the current tick.
//! Callers `request` the regions they will query this tick, then `prepare`.
//!
//! `SyncReadback` is today's implementation: requested regions are rounded to
//! 64x64 world tiles and copied out of the cell image with one synchronous
//! `vkCmdCopyImageToBuffer` (the caller must have waited for the GPU), then
//! scattered into a world-sized CPU cache. The particles layer's async
//! `Mirror` (1-bit solid mask of the window + material regions, one tick
//! late) replaces it by implementing the same vtable: `request` registers the
//! material regions, `prepare` is a no-op, `solidMask` reads the 1-bit mask
//! (its definition of solid must match the one above). See
//! docs/decisions/92-bodies-gpu-terrain-source.md.
const std = @import("std");
const gpu = @import("../gpu/gpu.zig");
const vk = gpu.vk;
const cell = @import("cell.zig");
const materials = @import("materials.zig");

/// Material id reported by `materials()` for body-owned cells (no shipped
/// material uses id 255).
pub const body_owned: u8 = 255;

pub const Region = struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,

    pub fn area(r: Region) usize {
        return @as(usize, r.w) * r.h;
    }

    /// Smallest region covering both.
    pub fn merge(a: Region, b: Region) Region {
        const x0 = @min(a.x, b.x);
        const y0 = @min(a.y, b.y);
        const x1 = @max(a.x + @as(i32, @intCast(a.w)), b.x + @as(i32, @intCast(b.w)));
        const y1 = @max(a.y + @as(i32, @intCast(a.h)), b.y + @as(i32, @intCast(b.h)));
        return .{ .x = x0, .y = y0, .w = @intCast(x1 - x0), .h = @intCast(y1 - y0) };
    }

    pub fn grow(r: Region, m: i32) Region {
        return .{ .x = r.x - m, .y = r.y - m, .w = @intCast(@as(i32, @intCast(r.w)) + 2 * m), .h = @intCast(@as(i32, @intCast(r.h)) + 2 * m) };
    }

    pub fn contains(r: Region, x: i32, y: i32) bool {
        return x >= r.x and y >= r.y and x < r.x + @as(i32, @intCast(r.w)) and y < r.y + @as(i32, @intCast(r.h));
    }

    pub fn overlaps(a: Region, b: Region) bool {
        return a.x < b.x + @as(i32, @intCast(b.w)) and b.x < a.x + @as(i32, @intCast(a.w)) and
            a.y < b.y + @as(i32, @intCast(b.h)) and b.y < a.y + @as(i32, @intCast(a.h));
    }
};

pub const TerrainSource = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        request: *const fn (ptr: *anyopaque, region: Region) void,
        prepare: *const fn (ptr: *anyopaque) anyerror!void,
        solidMask: *const fn (ptr: *anyopaque, region: Region, out: []u8) void,
        materials: *const fn (ptr: *anyopaque, region: Region, out: []u8) void,
        /// Number of ticks whose results the data reflects (the first tick
        /// not yet visible).
        readTick: *const fn (ptr: *anyopaque) u32,
    };

    pub fn request(self: TerrainSource, region: Region) void {
        self.vtable.request(self.ptr, region);
    }
    pub fn prepare(self: TerrainSource) !void {
        try self.vtable.prepare(self.ptr);
    }
    /// `out.len >= region.area()`, row-major.
    pub fn solidMask(self: TerrainSource, region: Region, out: []u8) void {
        std.debug.assert(out.len >= region.area());
        self.vtable.solidMask(self.ptr, region, out);
    }
    pub fn materials(self: TerrainSource, region: Region, out: []u8) void {
        std.debug.assert(out.len >= region.area());
        self.vtable.materials(self.ptr, region, out);
    }
    pub fn readTick(self: TerrainSource) u32 {
        return self.vtable.readTick(self.ptr);
    }
};

/// Collision-solid by phase: static and powder phases.
pub fn solidPhases(table_gpu: []const materials.MaterialGpu) [256]bool {
    var out: [256]bool = @splat(false);
    for (table_gpu, 0..) |m, i| {
        out[i] = i != materials.air and (m.phase == @backingInt(materials.Phase.static) or m.phase == @backingInt(materials.Phase.powder));
    }
    return out;
}

pub const tile_px = 64;
const tiles_per_side = cell.world_size / tile_px;
const tile_count = tiles_per_side * tiles_per_side;

pub const SyncReadback = struct {
    ctx: *gpu.Context,
    cells: *const gpu.Image,
    staging: gpu.Buffer,
    /// Last read value of every cell (only requested tiles are fresh).
    cache: []u32,
    /// `solidMask` values for `cache`, updated with it.
    solid_cache: []u8,
    requested: [tile_count]bool = @splat(false),
    /// `completed_tick` + 1 at the time each tile was last copied (0 = never):
    /// a tile already fresh for this completed tick is not copied again.
    fresh: [tile_count]u32 = @splat(0),
    list: [tile_count]u16 = undefined,
    list_len: u32 = 0,
    copies: [tile_count]vk.BufferImageCopy = undefined,
    solid: [256]bool = @splat(false),
    read_tick: u32 = 0,
    /// Set by the owner before `prepare`: ticks whose results the GPU has
    /// finished (the caller waited for them).
    completed_tick: u32 = 0,
    /// Tiles copied by the last `prepare`.
    last_tiles: u32 = 0,

    const staging_tiles = 256;

    pub fn init(ctx: *gpu.Context, cells_image: *const gpu.Image, alloc: std.mem.Allocator) !SyncReadback {
        const cache = try alloc.alloc(u32, cell.world_size * cell.world_size);
        errdefer alloc.free(cache);
        @memset(cache, 0);
        const solid_cache = try alloc.alloc(u8, cell.world_size * cell.world_size);
        errdefer alloc.free(solid_cache);
        @memset(solid_cache, 0);
        const staging = try gpu.Buffer.init(ctx, staging_tiles * tile_px * tile_px * 4, .{ .transfer_dst = true }, .gpu_to_cpu);
        return .{ .ctx = ctx, .cells = cells_image, .staging = staging, .cache = cache, .solid_cache = solid_cache };
    }

    pub fn deinit(self: *SyncReadback, alloc: std.mem.Allocator) void {
        self.staging.deinit(self.ctx);
        alloc.free(self.cache);
        alloc.free(self.solid_cache);
    }

    pub fn setMaterials(self: *SyncReadback, table_gpu: []const materials.MaterialGpu) void {
        self.solid = solidPhases(table_gpu);
    }

    pub fn source(self: *SyncReadback) TerrainSource {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: TerrainSource.VTable = .{
        .request = requestFn,
        .prepare = prepareFn,
        .solidMask = solidMaskFn,
        .materials = materialsFn,
        .readTick = readTickFn,
    };

    fn requestFn(ptr: *anyopaque, r: Region) void {
        const self: *SyncReadback = @ptrCast(@alignCast(ptr));
        if (r.w == 0 or r.h == 0) return;
        const tx0 = @divFloor(r.x, tile_px);
        const ty0 = @divFloor(r.y, tile_px);
        const tx1 = @divFloor(r.x + @as(i32, @intCast(r.w)) - 1, tile_px);
        const ty1 = @divFloor(r.y + @as(i32, @intCast(r.h)) - 1, tile_px);
        var ty = ty0;
        while (ty <= @min(ty1, ty0 + tiles_per_side - 1)) : (ty += 1) {
            var tx = tx0;
            while (tx <= @min(tx1, tx0 + tiles_per_side - 1)) : (tx += 1) {
                const wx: u32 = @intCast(@mod(tx, tiles_per_side));
                const wy: u32 = @intCast(@mod(ty, tiles_per_side));
                const t = wy * tiles_per_side + wx;
                if (!self.requested[t] and self.fresh[t] != self.completed_tick +% 1) {
                    self.requested[t] = true;
                    self.list[self.list_len] = @intCast(t);
                    self.list_len += 1;
                }
            }
        }
    }

    fn prepareFn(ptr: *anyopaque) anyerror!void {
        const self: *SyncReadback = @ptrCast(@alignCast(ptr));
        self.read_tick = self.completed_tick;
        self.last_tiles = self.list_len;
        var done: u32 = 0;
        while (done < self.list_len) {
            const n = @min(self.list_len - done, staging_tiles);
            for (0..n) |i| {
                const t = self.list[done + i];
                self.copies[i] = .{
                    .buffer_offset = i * tile_px * tile_px * 4,
                    .buffer_row_length = 0,
                    .buffer_image_height = 0,
                    .image_subresource = .{ .aspect_mask = .{ .color = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
                    .image_offset = .{ .x = @intCast((t % tiles_per_side) * tile_px), .y = @intCast((t / tiles_per_side) * tile_px), .z = 0 },
                    .image_extent = .{ .width = tile_px, .height = tile_px, .depth = 1 },
                };
            }
            try self.ctx.runOnce(.compute, recordCopies, .{ self.ctx, self.cells, &self.staging, self.copies[0..n] });
            const src = self.staging.typed(u32);
            for (0..n) |i| {
                const t = self.list[done + i];
                const ox = (t % tiles_per_side) * tile_px;
                const oy = (t / tiles_per_side) * tile_px;
                const skip = cell.flag_body | cell.flag_particle;
                for (0..tile_px) |row| {
                    const at = (oy + row) * cell.world_size + ox;
                    const dst = self.cache[at..][0..tile_px];
                    @memcpy(dst, src[i * tile_px * tile_px + row * tile_px ..][0..tile_px]);
                    for (dst, self.solid_cache[at..][0..tile_px]) |c, *v| v.* = @intFromBool(c & skip == 0 and self.solid[c & 0xff]);
                }
            }
            done += n;
        }
        for (self.list[0..self.list_len]) |t| {
            self.requested[t] = false;
            self.fresh[t] = self.completed_tick +% 1;
        }
        self.list_len = 0;
    }

    fn recordCopies(cmd: vk.CommandBuffer, ctx: *gpu.Context, image: *const gpu.Image, staging: *gpu.Buffer, copies: []const vk.BufferImageCopy) void {
        gpu.memory.memoryBarrier(ctx, cmd, .{ .all_commands = true }, .{ .memory_write = true }, .{ .all_transfer = true }, .{ .transfer_read = true });
        ctx.vkd.cmdCopyImageToBuffer(cmd, image.handle, .general, staging.handle, copies);
        gpu.memory.memoryBarrier(ctx, cmd, .{ .all_transfer = true }, .{ .transfer_write = true }, .{ .host = true }, .{ .host_read = true });
    }

    pub fn cellAt(self: *const SyncReadback, x: i32, y: i32) u32 {
        const wx: usize = @intCast(@as(u32, @bitCast(x)) & cell.world_mask);
        const wy: usize = @intCast(@as(u32, @bitCast(y)) & cell.world_mask);
        return self.cache[wy * cell.world_size + wx];
    }

    fn solidMaskFn(ptr: *anyopaque, r: Region, out: []u8) void {
        const self: *SyncReadback = @ptrCast(@alignCast(ptr));
        for (0..r.h) |j| {
            const wy: usize = @intCast(@as(u32, @bitCast(r.y + @as(i32, @intCast(j)))) & cell.world_mask);
            const row = self.solid_cache[wy * cell.world_size ..][0..cell.world_size];
            const o = out[j * r.w ..][0..r.w];
            // Row copy in at most two pieces (torus seam), whole wraps for w > world.
            var done: usize = 0;
            var wx: usize = @intCast(@as(u32, @bitCast(r.x)) & cell.world_mask);
            while (done < o.len) {
                const n = @min(o.len - done, cell.world_size - wx);
                @memcpy(o[done..][0..n], row[wx..][0..n]);
                done += n;
                wx = 0;
            }
        }
    }

    fn materialsFn(ptr: *anyopaque, r: Region, out: []u8) void {
        const self: *SyncReadback = @ptrCast(@alignCast(ptr));
        for (0..r.h) |j| {
            const wy: usize = @intCast(@as(u32, @bitCast(r.y + @as(i32, @intCast(j)))) & cell.world_mask);
            const row = self.cache[wy * cell.world_size ..][0..cell.world_size];
            const o = out[j * r.w ..][0..r.w];
            var wx: usize = @intCast(@as(u32, @bitCast(r.x)) & cell.world_mask);
            for (o) |*v| {
                const c = row[wx];
                v.* = if (c & cell.flag_body != 0) body_owned else @intCast(c & 0xff);
                wx = (wx + 1) & cell.world_mask;
            }
        }
    }

    fn readTickFn(ptr: *anyopaque) u32 {
        const self: *SyncReadback = @ptrCast(@alignCast(ptr));
        return self.read_tick;
    }
};

test "region merge and grow" {
    const a: Region = .{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const b: Region = .{ .x = 5, .y = -5, .w = 10, .h = 10 };
    const m = a.merge(b);
    try std.testing.expectEqual(@as(i32, -5), m.y);
    try std.testing.expectEqual(@as(u32, 15), m.w);
    try std.testing.expectEqual(@as(u32, 15), m.h);
    try std.testing.expect(a.overlaps(b));
    try std.testing.expect(!a.overlaps(.{ .x = 10, .y = 0, .w = 1, .h = 1 }));
    try std.testing.expectEqual(@as(u32, 14), a.grow(2).w);
}
