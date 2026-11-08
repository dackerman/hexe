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
    /// Segment (x0, y0)-(x1, y1), radius `flags >> line_radius_shift`:
    /// every pixel within the radius of the segment (a capsule).
    fill_line = 3,
    /// Particles, not cells (src/sim/particles.zig runs it): origin
    /// (x0, y0), count x1, speed y1 & 0xffff px/s, spread y1 >> 16,
    /// direction flags & 0xfff, cone half-angle (flags >> 12) & 0xfff, both
    /// in 1/4096 turns (0 = +x, 1024 = +y = down).
    spray = 4,
    /// Circle (x0, y0, r = x1): every cell gets temperature y1 degrees C.
    set_temperature = 5,
    /// Circle: flammable cells get the burning flag.
    ignite = 6,
    /// Circle, center speed y1 px/s with quadratic falloff: loose cells fly
    /// as particles, solids with health lose `speed / 4` and fly as rubble
    /// at zero (the interim explosion until the air field, M5).
    eject = 7,
    /// Circle, charge y1. Reserved hook: no effect until the reactions
    /// branch defines the charge encoding (docs/decisions/54-commands-m4.md).
    inject_charge = 8,
};

/// `flags` bits 16-31 of a fill_line: its radius.
pub const line_radius_shift = 16;
/// Eject: speed (px/s) below which a loose cell stays put, and the health
/// damage per px/s of speed (damage = speed >> eject_damage_shift).
pub const eject_min_speed = 40;
pub const eject_damage_shift = 2;

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

/// Most particles one spray command spawns.
pub const max_spray = 65535;

/// A spray of ballistic particles (`CommandList.spray`).
pub const Spray = struct {
    x: i32,
    y: i32,
    material: u8,
    count: u32,
    /// px/s; each particle gets speed +- spread (uniform).
    speed: u16,
    spread: u16 = 0,
    /// Direction in turns (0 = +x, 0.25 = down, 0.75 = up).
    direction: f32 = 0.75,
    /// Half-angle of the cone in turns (0.5 = all directions).
    cone: f32 = 0.05,
};

/// Turns (wrapping) -> 12-bit fixed point.
fn turns(t: f32) u32 {
    const f = t - @floor(t);
    return @as(u32, @intFromFloat(f * 4096.0)) & 0xfff;
}

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

    /// A thick line: every pixel within `radius` of the segment.
    pub fn fillLine(self: *CommandList, x0: i32, y0: i32, x1: i32, y1: i32, radius: i32, material: u8, opts: Options) void {
        self.push(.{
            .kind = @backingInt(Kind.fill_line),
            .material = material,
            .x0 = x0,
            .y0 = y0,
            .x1 = x1,
            .y1 = y1,
            .flags = opts.flags() | (@as(u32, @intCast(std.math.clamp(radius, 0, max_radius))) << line_radius_shift),
            .seed = 0,
        });
    }

    /// Spawn `s.count` ballistic particles (no cells change this tick).
    pub fn spray(self: *CommandList, s: Spray) void {
        if (s.count == 0) return;
        self.push(.{
            .kind = @backingInt(Kind.spray),
            .material = s.material,
            .x0 = s.x,
            .y0 = s.y,
            .x1 = @intCast(@min(s.count, max_spray)),
            .y1 = @bitCast(@as(u32, s.speed) | (@as(u32, s.spread) << 16)),
            .flags = turns(s.direction) | (turns(s.cone) << 12),
            .seed = 0,
        });
    }

    pub fn setTemperature(self: *CommandList, cx: i32, cy: i32, radius: i32, celsius: i32) void {
        self.circleCommand(.set_temperature, cx, cy, radius, 0, celsius);
    }

    pub fn ignite(self: *CommandList, cx: i32, cy: i32, radius: i32) void {
        self.circleCommand(.ignite, cx, cy, radius, 0, 0);
    }

    /// The interim explosion: `speed` px/s at the center.
    pub fn eject(self: *CommandList, cx: i32, cy: i32, radius: i32, speed: u16) void {
        self.circleCommand(.eject, cx, cy, radius, 0, speed);
    }

    /// Reserved hook (no GPU effect yet).
    pub fn injectCharge(self: *CommandList, cx: i32, cy: i32, radius: i32, charge: u8) void {
        self.circleCommand(.inject_charge, cx, cy, radius, 0, charge);
    }

    fn circleCommand(self: *CommandList, kind: Kind, cx: i32, cy: i32, radius: i32, material: u8, y1: i32) void {
        self.push(.{
            .kind = @backingInt(kind),
            .material = material,
            .x0 = cx,
            .y0 = cy,
            .x1 = std.math.clamp(radius, 0, max_radius),
            .y1 = y1,
            .flags = 0,
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
        .fill_line => {
            const r: i32 = @intCast(c.flags >> line_radius_shift);
            x0 = @min(c.x0, c.x1) - r;
            y0 = @min(c.y0, c.y1) - r;
            x1 = @max(c.x0, c.x1) + r + 1;
            y1 = @max(c.y0, c.y1) + r + 1;
        },
        .set_temperature, .ignite, .eject => {
            x0 = c.x0 - c.x1;
            y0 = c.y0 - c.x1;
            x1 = c.x0 + c.x1 + 1;
            y1 = c.y0 + c.x1 + 1;
        },
        // Not per-pixel edits: spray runs in the particle subsystem;
        // inject_charge is a reserved hook.
        .spray, .inject_charge => return null,
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
        .fill_circle, .set_temperature, .ignite, .eject => blk: {
            const dx = x - c.x0;
            const dy = y - c.y0;
            break :blk dx * dx + dy * dy <= c.x1 * c.x1;
        },
        .fill_rect => x >= c.x0 and y >= c.y0 and x < c.x1 and y < c.y1,
        .fill_line => insideCapsule(c.x0, c.y0, c.x1, c.y1, @intCast(c.flags >> line_radius_shift), x, y),
        .spray, .inject_charge => false,
    };
}

/// Distance from (px, py) to segment a-b at most r. Integer, exact; the
/// perpendicular case compares cross^2 <= r^2 |b-a|^2 in 64 bits.
/// Mirrors inside_capsule in shaders/sim/grid/commands.comp.
pub fn insideCapsule(ax: i32, ay: i32, bx: i32, by: i32, r: i32, px: i32, py: i32) bool {
    const ux = bx - ax;
    const uy = by - ay;
    const wx = px - ax;
    const wy = py - ay;
    const len2 = ux * ux + uy * uy;
    const dot = wx * ux + wy * uy;
    if (dot <= 0) return wx * wx + wy * wy <= r * r;
    if (dot >= len2) {
        const qx = px - bx;
        const qy = py - by;
        return qx * qx + qy * qy <= r * r;
    }
    const cross: i64 = @as(i64, ux) * wy - @as(i64, uy) * wx;
    return cross * cross <= @as(i64, r) * r * len2;
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

test "m4 command kinds" {
    var list: CommandList = .{};
    list.begin(3);
    list.fillLine(10, 10, 50, 30, 3, 2, .{});
    list.spray(.{ .x = 100, .y = 100, .material = 2, .count = 500, .speed = 300, .spread = 50 });
    list.eject(200, 200, 12, 600);
    list.setTemperature(0, 0, 4, 500);
    list.ignite(5, 5, 2);
    list.injectCharge(5, 5, 2, 9);
    const line = list.items[0];
    try std.testing.expectEqual(@as(u32, 3), line.flags >> line_radius_shift);
    const lb = bounds(line).?;
    try std.testing.expectEqual(@as(i32, 0), lb.x);
    try std.testing.expect(lb.x + @as(i32, @intCast(lb.w)) >= 54);
    try std.testing.expect(insideShape(line, 30, 20)); // on the segment
    try std.testing.expect(insideShape(line, 30, 23)); // within 3 of it
    try std.testing.expect(!insideShape(line, 30, 25));
    try std.testing.expect(insideShape(line, 7, 10)); // round cap
    try std.testing.expect(!insideShape(line, 6, 10));
    // Spray is not a per-pixel edit; its encoding round-trips.
    const sp = list.items[1];
    try std.testing.expect(bounds(sp) == null);
    try std.testing.expectEqual(@as(i32, 500), sp.x1);
    try std.testing.expectEqual(@as(u32, 300), @as(u32, @bitCast(sp.y1)) & 0xffff);
    try std.testing.expectEqual(@as(u32, 50), @as(u32, @bitCast(sp.y1)) >> 16);
    try std.testing.expectEqual(@as(u32, 3072), sp.flags & 0xfff); // 0.75 turns = up
    try std.testing.expectEqual(@as(u32, 204), (sp.flags >> 12) & 0xfff);
    try std.testing.expect(bounds(list.items[2]) != null);
    try std.testing.expect(insideShape(list.items[2], 212, 200));
    try std.testing.expect(bounds(list.items[5]) == null);
}
