//! GPU timestamp queries with per-pass names.
//!
//! A `Recorder` owns one query pool and is used by one frame-in-flight slot.
//! `begin`/`end` bracket GPU work under a pass name; after the slot's work
//! has completed, `collect` sums the elapsed time per name into `Timings`
//! and resets the pool. Names are interned in a shared `Names` table (no
//! allocation), so the same pass recorded several times per frame (one per
//! substep, one per tick) accumulates into one entry.
const std = @import("std");
const vk = @import("vulkan");
const Context = @import("context.zig").Context;

pub const max_names = 32;
pub const max_scopes = 256;

pub const Names = struct {
    items: [max_names][]const u8 = undefined,
    count: u32 = 0,

    pub fn intern(self: *Names, name: []const u8) u8 {
        for (self.items[0..self.count], 0..) |n, i| {
            if (n.ptr == name.ptr or std.mem.eql(u8, n, name)) return @intCast(i);
        }
        std.debug.assert(self.count < max_names);
        if (self.count >= max_names) return max_names - 1;
        self.items[self.count] = name;
        self.count += 1;
        return @intCast(self.count - 1);
    }

    pub fn get(self: *const Names, id: usize) []const u8 {
        return self.items[id];
    }
};

/// Milliseconds per pass name, indexed like `Names`.
pub const Timings = struct {
    ms: [max_names]f64 = @splat(0),
    /// How many scopes contributed to each entry.
    count: [max_names]u32 = @splat(0),

    pub fn clear(self: *Timings) void {
        self.* = .{};
    }
};

pub const Scope = struct { index: u32 };

pub const Recorder = struct {
    pool: vk.QueryPool,
    names: *Names,
    scope_names: [max_scopes]u8 = undefined,
    scopes: u32 = 0,
    overflowed: bool = false,

    pub fn init(ctx: *Context, names: *Names) !Recorder {
        const pool = try ctx.vkd.createQueryPool(ctx.device, &.{
            .query_type = .timestamp,
            .query_count = max_scopes * 2,
        }, null);
        ctx.vkd.resetQueryPool(ctx.device, pool, 0, max_scopes * 2);
        return .{ .pool = pool, .names = names };
    }

    pub fn deinit(self: *Recorder, ctx: *Context) void {
        ctx.vkd.destroyQueryPool(ctx.device, self.pool, null);
    }

    pub fn begin(self: *Recorder, ctx: *const Context, cmd: vk.CommandBuffer, name: []const u8) Scope {
        if (self.scopes >= max_scopes) {
            self.overflowed = true;
            return .{ .index = std.math.maxInt(u32) };
        }
        const i = self.scopes;
        self.scopes += 1;
        self.scope_names[i] = self.names.intern(name);
        ctx.vkd.cmdWriteTimestamp2(cmd, .{ .all_commands = true }, self.pool, i * 2);
        return .{ .index = i };
    }

    pub fn end(self: *Recorder, ctx: *const Context, cmd: vk.CommandBuffer, scope: Scope) void {
        if (scope.index == std.math.maxInt(u32)) return;
        ctx.vkd.cmdWriteTimestamp2(cmd, .{ .all_commands = true }, self.pool, scope.index * 2 + 1);
    }

    /// Call only after all work recorded with this recorder has completed.
    /// Adds this slot's timings into `out` and resets for reuse.
    pub fn collect(self: *Recorder, ctx: *Context, out: *Timings) !void {
        if (self.scopes > 0) {
            var raw: [max_scopes * 2]u64 = undefined;
            const n = self.scopes * 2;
            _ = try ctx.vkd.getQueryPoolResults(ctx.device, self.pool, 0, n, n * @sizeOf(u64), &raw, @sizeOf(u64), .{ .@"64" = true, .wait = true });
            for (0..self.scopes) |i| {
                const t0 = raw[i * 2];
                const t1 = raw[i * 2 + 1];
                const ticks: f64 = @floatFromInt(t1 -% t0);
                const id = self.scope_names[i];
                out.ms[id] += ticks * ctx.timestamp_period / 1.0e6;
                out.count[id] += 1;
            }
            ctx.vkd.resetQueryPool(ctx.device, self.pool, 0, n);
        }
        self.scopes = 0;
    }
};
