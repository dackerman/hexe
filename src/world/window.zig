//! The toroidal active window: 2048 × 2048 cells = 8 × 8 chunks.
//!
//! Window (torus) coordinates are world coordinates modulo 2048, so a world
//! cell maps to the same window cell no matter where the window is. A chunk
//! (cx, cy) always lives in slot (cx mod 8, cy mod 8). The window `origin`
//! is the chunk coordinate of the resident chunk with the smallest x and y;
//! resident chunks are origin + [0, 8)².
//!
//! Moving the camera shifts the origin by one chunk along one axis at a
//! time: the row or column at the trailing edge is evicted and the new one
//! at the leading edge loads into the same slots.

const std = @import("std");
const chunk = @import("chunk.zig");

pub const chunks_log2 = 3;
pub const chunks: u32 = 1 << chunks_log2; // 8 per side
pub const slot_count: u32 = chunks * chunks; // 64
pub const size_log2 = chunk.size_log2 + chunks_log2;
pub const size: u32 = 1 << size_log2; // 2048 cells per side
const half: i32 = @intCast(size / 2);
const csize: i32 = @intCast(chunk.size);

pub const Slot = struct {
    x: u32,
    y: u32,

    pub fn index(s: Slot) u32 {
        return s.y * chunks + s.x;
    }

    pub fn fromIndex(i: u32) Slot {
        return .{ .x = i % chunks, .y = i / chunks };
    }
};

/// World cell → window cell. Independent of the window origin.
pub inline fn toWindow(world_x: i32, world_y: i32) struct { u32, u32 } {
    return .{ @as(u32, @bitCast(world_x)) & (size - 1), @as(u32, @bitCast(world_y)) & (size - 1) };
}

/// Window cell → world cell, for the window whose top-left resident chunk is
/// `origin`: the unique world cell inside the window that wraps to (wx, wy).
pub inline fn fromWindow(wx: u32, wy: u32, origin: chunk.Coord) struct { i32, i32 } {
    std.debug.assert(wx < size and wy < size);
    const o = origin.originCell();
    return .{ unwrap(wx, o[0]), unwrap(wy, o[1]) };
}

inline fn unwrap(w: u32, lo: i32) i32 {
    const lo_w: u32 = @as(u32, @bitCast(lo)) & (size - 1);
    const delta: u32 = (w -% lo_w) & (size - 1);
    return lo + @as(i32, @intCast(delta));
}

/// Slot that chunk `c` occupies whenever it is resident.
pub inline fn slotOf(c: chunk.Coord) Slot {
    return .{ .x = @as(u32, @bitCast(c.x)) & (chunks - 1), .y = @as(u32, @bitCast(c.y)) & (chunks - 1) };
}

/// Chunk that occupies `s` in the window with top-left chunk `origin`.
pub inline fn chunkAtSlot(s: Slot, origin: chunk.Coord) chunk.Coord {
    const p = fromWindow(s.x * chunk.size, s.y * chunk.size, origin);
    return chunk.coordOfCell(p[0], p[1]);
}

pub inline fn contains(origin: chunk.Coord, c: chunk.Coord) bool {
    return c.x -% origin.x >= 0 and c.x -% origin.x < chunks and
        c.y -% origin.y >= 0 and c.y -% origin.y < chunks;
}

/// Origin that centers the window on the camera, rounded to whole chunks.
/// The camera then sits within ±128 cells of the window center.
pub fn centeredOrigin(cam_x: i32, cam_y: i32) chunk.Coord {
    return .{
        .x = @divFloor(cam_x - half + @divExact(csize, 2), csize),
        .y = @divFloor(cam_y - half + @divExact(csize, 2), csize),
    };
}

/// Like `centeredOrigin` but keeps `current` on an axis until the camera is
/// more than 128 + `hysteresis` cells from the center on that axis, so a
/// camera jittering on a chunk boundary does not thrash.
pub fn desiredOrigin(current: chunk.Coord, cam_x: i32, cam_y: i32, hysteresis: i32) chunk.Coord {
    const centered = centeredOrigin(cam_x, cam_y);
    const limit = @divExact(csize, 2) + hysteresis;
    const cur = current.originCell();
    var out = current;
    if (@abs(cam_x - (cur[0] + half)) > limit) out.x = centered.x;
    if (@abs(cam_y - (cur[1] + half)) > limit) out.y = centered.y;
    return out;
}

pub const Axis = enum { x, y };

/// One row or column shift of the window.
pub const Move = struct {
    axis: Axis,
    /// +1 or −1 along `axis`.
    dir: i32,
    old_origin: chunk.Coord,
    new_origin: chunk.Coord,
    /// evict[i] leaves slots[i] and load[i] enters it.
    evict: [chunks]chunk.Coord,
    load: [chunks]chunk.Coord,
    slots: [chunks]Slot,
};

/// Next single-step move from `current` toward `target`, x before y, or null
/// if they are equal. A caller far from the target calls this repeatedly.
pub fn nextMove(current: chunk.Coord, target: chunk.Coord) ?Move {
    var m: Move = undefined;
    m.old_origin = current;
    m.new_origin = current;
    if (target.x != current.x) {
        m.axis = .x;
        m.dir = if (target.x > current.x) 1 else -1;
        m.new_origin.x += m.dir;
    } else if (target.y != current.y) {
        m.axis = .y;
        m.dir = if (target.y > current.y) 1 else -1;
        m.new_origin.y += m.dir;
    } else return null;

    const n: i32 = @intCast(chunks);
    for (0..chunks) |k| {
        const i: i32 = @intCast(k);
        var gone: chunk.Coord = undefined;
        var came: chunk.Coord = undefined;
        switch (m.axis) {
            .x => {
                gone = .{ .x = if (m.dir > 0) current.x else current.x + n - 1, .y = current.y + i };
                came = .{ .x = if (m.dir > 0) current.x + n else current.x - 1, .y = current.y + i };
            },
            .y => {
                gone = .{ .x = current.x + i, .y = if (m.dir > 0) current.y else current.y + n - 1 };
                came = .{ .x = current.x + i, .y = if (m.dir > 0) current.y + n else current.y - 1 };
            },
        }
        std.debug.assert(std.meta.eql(slotOf(gone), slotOf(came)));
        m.evict[k] = gone;
        m.load[k] = came;
        m.slots[k] = slotOf(came);
    }
    return m;
}

const testing = std.testing;

test "toWindow wraps positive and negative coordinates" {
    try testing.expectEqual(.{ @as(u32, 0), @as(u32, 0) }, toWindow(0, 0));
    try testing.expectEqual(.{ @as(u32, 2047), @as(u32, 2047) }, toWindow(-1, -1));
    try testing.expectEqual(.{ @as(u32, 0), @as(u32, 5) }, toWindow(2048, -2043));
    try testing.expectEqual(.{ @as(u32, 1), @as(u32, 2046) }, toWindow(-4095, 4094));
    try testing.expectEqual(toWindow(123, 456), toWindow(123 + 2048 * 7, 456 - 2048 * 9));
    // Extremes of i32 still map in range.
    const lo = toWindow(std.math.minInt(i32), std.math.maxInt(i32));
    try testing.expectEqual(@as(u32, 0), lo[0]);
    try testing.expectEqual(@as(u32, 2047), lo[1]);
}

test "fromWindow inverts toWindow inside the window, any origin" {
    const origins = [_]chunk.Coord{
        .{ .x = 0, .y = 0 },   .{ .x = -4, .y = -4 }, .{ .x = -1, .y = 3 },
        .{ .x = 5, .y = -11 }, .{ .x = -9, .y = 17 },
    };
    for (origins) |o| {
        const base = o.originCell();
        var dy: i32 = -1;
        while (dy <= 2048) : (dy += 37) {
            var dx: i32 = 0;
            while (dx < 2048) : (dx += 61) {
                const yy = std.math.clamp(dy, 0, 2047);
                const wx = base[0] + dx;
                const wy = base[1] + yy;
                const w = toWindow(wx, wy);
                const back = fromWindow(w[0], w[1], o);
                try testing.expectEqual(wx, back[0]);
                try testing.expectEqual(wy, back[1]);
            }
        }
        // Window corners.
        const tl = fromWindow(toWindow(base[0], base[1])[0], toWindow(base[0], base[1])[1], o);
        try testing.expectEqual(base[0], tl[0]);
        const br_w = toWindow(base[0] + 2047, base[1] + 2047);
        const br = fromWindow(br_w[0], br_w[1], o);
        try testing.expectEqual(base[0] + 2047, br[0]);
        try testing.expectEqual(base[1] + 2047, br[1]);
    }
}

test "slots wrap and chunkAtSlot inverts slotOf" {
    try testing.expectEqual(Slot{ .x = 7, .y = 0 }, slotOf(.{ .x = -1, .y = 8 }));
    try testing.expectEqual(Slot{ .x = 0, .y = 1 }, slotOf(.{ .x = -8, .y = -7 }));
    const o: chunk.Coord = .{ .x = -5, .y = 2 };
    var i: u32 = 0;
    var seen: [slot_count]bool = @splat(false);
    while (i < slot_count) : (i += 1) {
        const s = Slot.fromIndex(i);
        const c = chunkAtSlot(s, o);
        try testing.expect(contains(o, c));
        try testing.expectEqual(s, slotOf(c));
        seen[slotOf(c).index()] = true;
    }
    for (seen) |b| try testing.expect(b);
    try testing.expect(!contains(o, .{ .x = 3, .y = 2 }));
    try testing.expect(contains(o, .{ .x = 2, .y = 9 }));
    try testing.expect(!contains(o, .{ .x = 2, .y = 10 }));
}

test "centered origin and hysteresis" {
    try testing.expectEqual(chunk.Coord{ .x = -4, .y = -4 }, centeredOrigin(0, 0));
    try testing.expectEqual(chunk.Coord{ .x = -4, .y = -4 }, centeredOrigin(127, -128));
    try testing.expectEqual(chunk.Coord{ .x = -3, .y = -5 }, centeredOrigin(128, -129));
    const cur: chunk.Coord = .{ .x = -4, .y = -4 };
    try testing.expectEqual(cur, desiredOrigin(cur, 160, -160, 32));
    try testing.expectEqual(chunk.Coord{ .x = -3, .y = -4 }, desiredOrigin(cur, 161, 0, 32));
    try testing.expectEqual(chunk.Coord{ .x = -4, .y = -5 }, desiredOrigin(cur, 0, -161, 32));
    // Large jumps go straight to the centered target.
    try testing.expectEqual(centeredOrigin(-10000, 9000), desiredOrigin(cur, -10000, 9000, 32));
}

test "nextMove evicts trailing edge into the leading edge's slots" {
    const o: chunk.Coord = .{ .x = -4, .y = -4 };
    const m = nextMove(o, .{ .x = -2, .y = -6 }).?;
    try testing.expectEqual(Axis.x, m.axis);
    try testing.expectEqual(@as(i32, 1), m.dir);
    try testing.expectEqual(chunk.Coord{ .x = -3, .y = -4 }, m.new_origin);
    for (0..chunks) |k| {
        const i: i32 = @intCast(k);
        try testing.expectEqual(chunk.Coord{ .x = -4, .y = -4 + i }, m.evict[k]);
        try testing.expectEqual(chunk.Coord{ .x = 4, .y = -4 + i }, m.load[k]);
        try testing.expectEqual(Slot{ .x = 4, .y = @intCast((k + 4) % 8) }, m.slots[k]);
        try testing.expect(contains(m.old_origin, m.evict[k]) and !contains(m.new_origin, m.evict[k]));
        try testing.expect(contains(m.new_origin, m.load[k]) and !contains(m.old_origin, m.load[k]));
    }
    const up = nextMove(.{ .x = -4, .y = -4 }, .{ .x = -4, .y = -5 }).?;
    try testing.expectEqual(Axis.y, up.axis);
    try testing.expectEqual(chunk.Coord{ .x = -4, .y = 3 }, up.evict[0]);
    try testing.expectEqual(chunk.Coord{ .x = -4, .y = -5 }, up.load[0]);
    try testing.expectEqual(Slot{ .x = 4, .y = 3 }, up.slots[0]);
    try testing.expect(nextMove(o, o) == null);
}
