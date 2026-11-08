//! CPU -> GPU command list (docs/01-architecture.md "The CPU-GPU boundary").
//!
//! Input, scenes and (later) gameplay push commands into a `CommandList`
//! during a tick; nothing else changes the world. The engine copies the list
//! into this tick's region of the upload ring and `Applier.record` runs one
//! compute dispatch per command, in list order, before movement.
//!
//! Adding a command kind: add it to `Kind` (and CMD_* in common.glsl), give
//! `bounds` its footprint, handle it in shaders/sim/grid/commands.comp (or a
//! new pass that consumes it), and mirror it in src/sim/reference/grid.zig.
const std = @import("std");
const gpu = @import("../gpu/gpu.zig");
const vk = gpu.vk;
const cell = @import("cell.zig");
const pipeline_mod = @import("pipeline.zig");
const Frame = pipeline_mod.Frame;
const shaders = @import("shaders");

pub const Kind = enum(u32) {
    /// Center (x0, y0), radius x1: every pixel with dx^2 + dy^2 <= r^2.
    fill_circle = 1,
    /// [x0, x1) x [y0, y1).
    fill_rect = 2,
};

/// Only replace air cells (pouring, scenery that must not overwrite).
pub const flag_only_air: u32 = 0x1;
/// Bits 8-15 of `flags`: coverage. 0 = every pixel of the shape; otherwise a
/// pixel is filled when the low byte of its spawn hash is below the coverage.
pub const coverage_shift = 8;

/// GPU encoding, 8 words; `struct Command` in common.glsl.
pub const CommandGpu = extern struct {
    kind: u32,
    material: u32,
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,
    flags: u32,
    /// Feeds the spawn-variant hash; set by the list.
    seed: u32,
};

comptime {
    std.debug.assert(@sizeOf(CommandGpu) == 32);
}

/// Commands per tick; extra pushes are dropped and counted.
pub const capacity = 1024;
pub const max_radius = 1000;

pub const Options = struct {
    only_air: bool = false,
    /// Fraction of the shape's pixels to fill, 1-255 of 256; 0 = all.
    coverage: u8 = 0,

    fn flags(o: Options) u32 {
        return (if (o.only_air) flag_only_air else 0) | (@as(u32, o.coverage) << coverage_shift);
    }
};

pub const CommandList = struct {
    items: [capacity]CommandGpu = undefined,
    len: u32 = 0,
    dropped: u32 = 0,
    seed_base: u32 = 0,

    /// Start the list for `tick`. Seeds derive from (tick, position), so the
    /// same pushes in the same order produce the same world on any side.
    pub fn begin(self: *CommandList, tick: u32) void {
        self.len = 0;
        self.dropped = 0;
        self.seed_base = cell.hashU32(tick +% 0x632b_e5ab);
    }

    pub fn push(self: *CommandList, c: CommandGpu) void {
        if (self.len >= capacity) {
            self.dropped += 1;
            return;
        }
        var cmd = c;
        cmd.seed = self.seed_base +% self.len *% 0x9e37_79b9;
        self.items[self.len] = cmd;
        self.len += 1;
    }

    pub fn fillCircle(self: *CommandList, cx: i32, cy: i32, radius: i32, material: u8, opts: Options) void {
        self.push(.{
            .kind = @backingInt(Kind.fill_circle),
            .material = material,
            .x0 = cx,
            .y0 = cy,
            .x1 = std.math.clamp(radius, 0, max_radius),
            .y1 = 0,
            .flags = opts.flags(),
            .seed = 0,
        });
    }

    pub fn fillRect(self: *CommandList, x0: i32, y0: i32, x1: i32, y1: i32, material: u8, opts: Options) void {
        if (x1 <= x0 or y1 <= y0) return;
        self.push(.{
            .kind = @backingInt(Kind.fill_rect),
            .material = material,
            .x0 = x0,
            .y0 = y0,
            .x1 = x1,
            .y1 = y1,
            .flags = opts.flags(),
            .seed = 0,
        });
    }

    pub fn slice(self: *const CommandList) []const CommandGpu {
        return self.items[0..self.len];
    }
};

/// Pixel box a command touches, in unwrapped world coordinates. The origin
/// is aligned down to 16 so every 16x16 workgroup lies inside one tile.
pub const Box = struct { x: i32, y: i32, w: u32, h: u32 };

pub fn bounds(c: CommandGpu) ?Box {
    var x0: i32 = undefined;
    var y0: i32 = undefined;
    var x1: i32 = undefined; // exclusive
    var y1: i32 = undefined;
    switch (@as(Kind, @fromBackingInt(@intCast(c.kind)))) {
        .fill_circle => {
            x0 = c.x0 - c.x1;
            y0 = c.y0 - c.x1;
            x1 = c.x0 + c.x1 + 1;
            y1 = c.y0 + c.x1 + 1;
        },
        .fill_rect => {
            x0 = c.x0;
            y0 = c.y0;
            x1 = c.x1;
            y1 = c.y1;
        },
    }
    if (x1 <= x0 or y1 <= y0) return null;
    const ax = x0 & ~@as(i32, 15);
    const ay = y0 & ~@as(i32, 15);
    // Never wider than the world: each wrapped pixel is visited once per
    // dispatch, so workgroups never race (max_radius keeps circles inside).
    const limit = cell.world_size;
    return .{
        .x = ax,
        .y = ay,
        .w = @intCast(@min(x1 - ax, limit)),
        .h = @intCast(@min(y1 - ay, limit)),
    };
}

pub fn insideShape(c: CommandGpu, x: i32, y: i32) bool {
    return switch (@as(Kind, @fromBackingInt(@intCast(c.kind)))) {
        .fill_circle => blk: {
            const dx = x - c.x0;
            const dy = y - c.y0;
            break :blk dx * dx + dy * dy <= c.x1 * c.x1;
        },
        .fill_rect => x >= c.x0 and y >= c.y0 and x < c.x1 and y < c.y1,
    };
}

/// Applies the uploaded commands. Owns the upload ring at SLOT_BUF_COMMANDS:
/// frames_in_flight x max_ticks_per_frame regions of `capacity` commands.
pub const Applier = struct {
    ctx: *gpu.Context,
    pipeline: vk.Pipeline,
    ring: gpu.Buffer,

    const regions = pipeline_mod.frames_in_flight * pipeline_mod.max_ticks_per_frame;

    pub fn init(ctx: *gpu.Context, cfg: pipeline_mod.Config, alloc: std.mem.Allocator) !Applier {
        _ = cfg;
        _ = alloc;
        var ring = try gpu.Buffer.init(ctx, regions * capacity * @sizeOf(CommandGpu), .{ .storage_buffer = true }, .cpu_to_gpu);
        errdefer ring.deinit(ctx);
        ring.register(ctx, gpu.constants.slot_buf_commands);
        const pipeline = try gpu.pipelines.createCompute(ctx, &shaders.sim_grid_commands_comp);
        return .{ .ctx = ctx, .pipeline = pipeline, .ring = ring };
    }

    pub fn deinit(self: *Applier) void {
        gpu.pipelines.destroy(self.ctx, self.pipeline);
        self.ring.deinit(self.ctx);
    }

    /// Copy `list` into region (slot, tick_in_frame); returns the index of
    /// its first command in the ring. The region must not be in use by the
    /// GPU (the engine waits for the slot first).
    pub fn upload(self: *Applier, slot: u32, tick_in_frame: u32, list: *const CommandList) u32 {
        std.debug.assert(slot < pipeline_mod.frames_in_flight and tick_in_frame < pipeline_mod.max_ticks_per_frame);
        const base = (slot * pipeline_mod.max_ticks_per_frame + tick_in_frame) * capacity;
        const dst = self.ring.typed(CommandGpu)[base..][0..list.len];
        @memcpy(dst, list.slice());
        return base;
    }

    pub fn record(self: *Applier, frame: *Frame) void {
        if (frame.commands.len == 0) return;
        frame.timed("commands", recordInner, .{ self, frame });
    }

    fn recordInner(self: *Applier, frame: *Frame) void {
        frame.bindCompute(self.pipeline);
        for (frame.commands, 0..) |c, i| {
            const box = bounds(c) orelse continue;
            frame.push(extern struct { x: i32, y: i32, w: u32, h: u32, index: u32, mark: u32 }{
                .x = box.x,
                .y = box.y,
                .w = box.w,
                .h = box.h,
                .index = frame.command_base + @as(u32, @intCast(i)),
                .mark = @intFromBool(frame.sleep),
            });
            frame.dispatch((box.w + 15) / 16, (box.h + 15) / 16, 1);
            frame.barrier();
        }
    }
};

test "command bounds" {
    var list: CommandList = .{};
    list.begin(0);
    list.fillCircle(100, 50, 10, 2, .{});
    list.fillRect(5, 7, 40, 9, 1, .{ .only_air = true });
    const b0 = bounds(list.items[0]).?;
    try std.testing.expectEqual(@as(i32, 80), b0.x);
    try std.testing.expectEqual(@as(i32, 32), b0.y);
    try std.testing.expect(b0.x + @as(i32, @intCast(b0.w)) >= 111);
    const b1 = bounds(list.items[1]).?;
    try std.testing.expectEqual(@as(i32, 0), b1.x);
    try std.testing.expectEqual(@as(u32, 40), b1.w);
    try std.testing.expectEqual(flag_only_air, list.items[1].flags);
    try std.testing.expect(list.items[0].seed != list.items[1].seed);
    try std.testing.expect(insideShape(list.items[0], 110, 50));
    try std.testing.expect(!insideShape(list.items[0], 111, 50));
    try std.testing.expect(bounds(.{ .kind = 2, .material = 0, .x0 = 3, .y0 = 3, .x1 = 3, .y1 = 9, .flags = 0, .seed = 0 }) == null);
}
