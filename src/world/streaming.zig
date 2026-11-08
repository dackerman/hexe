//! Streaming glue: keeps the 8 × 8 resident chunks of the toroidal window
//! in step with the camera, one row or column of chunks at a time.
//!
//! Per tick: if no window move is in progress, compare the camera with the
//! window center (with hysteresis) and start at most one single-step move.
//! Then process up to `ops_per_tick` slots of the move: evict the old chunk
//! (download from the GPU and park it in the store if it is dirty), fetch the
//! new one (decompress if parked, generate otherwise) and upload it. Nothing
//! here allocates after `init`.

const std = @import("std");
const chunk = @import("chunk.zig");
const window = @import("window.zig");
const store_mod = @import("store.zig");
const Store = store_mod.Store;

/// Implemented by the GPU side. Slots are window chunk slots, 0..7 each.
pub const UploadSink = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Copy 256 × 256 cells into the cell image at slot (x, y), i.e.
        /// window cells [x·256, x·256+256) × [y·256, y·256+256). Also clears
        /// the slot's dirty bit and anything per-slot the sim keeps (activity,
        /// owner image) as the GPU side sees fit. The pointer is only valid
        /// for the duration of the call.
        uploadChunk: *const fn (ctx: *anyopaque, slot_x: u32, slot_y: u32, cells: *const chunk.Cells) void,
        /// Copy the slot's current cells back. Called only for dirty slots,
        /// right before the slot is reused. Must return settled data:
        /// liquid particles frozen into cells, body-owned cells resolved.
        downloadChunk: *const fn (ctx: *anyopaque, slot_x: u32, slot_y: u32, out: *chunk.Cells) void,
        /// Return whether any cell of the slot changed since its last upload
        /// or the last call for this slot, and clear the bit.
        takeDirty: *const fn (ctx: *anyopaque, slot_x: u32, slot_y: u32) bool,
    };

    pub inline fn uploadChunk(s: UploadSink, slot_x: u32, slot_y: u32, cells: *const chunk.Cells) void {
        s.vtable.uploadChunk(s.ptr, slot_x, slot_y, cells);
    }
    pub inline fn downloadChunk(s: UploadSink, slot_x: u32, slot_y: u32, out: *chunk.Cells) void {
        s.vtable.downloadChunk(s.ptr, slot_x, slot_y, out);
    }
    pub inline fn takeDirty(s: UploadSink, slot_x: u32, slot_y: u32) bool {
        return s.vtable.takeDirty(s.ptr, slot_x, slot_y);
    }
};

pub const Config = struct {
    /// Cells beyond ±128 of the window center before the window moves.
    hysteresis: i32 = 32,
    /// Slots (evict + load) processed per tick. One generated chunk costs
    /// about 6 ms in ReleaseFast; 1 keeps a tick's streaming cost bounded and
    /// still finishes a column in 8 ticks, far faster than the camera can
    /// cross the ≥ 768-cell margin the window keeps.
    ops_per_tick: u32 = 1,
};

pub const Stats = struct {
    generated: u64 = 0,
    decompressed: u64 = 0,
    parked: u64 = 0,
    uploads: u64 = 0,
    downloads: u64 = 0,
    moves: u64 = 0,
};

pub const TickReport = struct {
    /// A move is in progress (some slots may still hold the old chunks).
    moving: bool,
    /// Slots processed this tick.
    ops: u32,
};

const SlotInfo = struct {
    coord: chunk.Coord,
    valid: bool = false,
    cpu_dirty: bool = false,
};

pub const Streaming = struct {
    store: *Store,
    sink: UploadSink,
    cfg: Config,
    /// Window origin; during a move, the origin the move started from.
    origin: chunk.Coord,
    slots: [window.slot_count]SlotInfo,
    move: ?window.Move,
    move_next: u32,
    buf: *chunk.Cells,
    stats: Stats,

    /// Sets up the window centered on the camera. Call `loadAll` next.
    pub fn init(alloc: std.mem.Allocator, st: *Store, sink: UploadSink, cfg: Config, cam_x: i32, cam_y: i32) !Streaming {
        return .{
            .store = st,
            .sink = sink,
            .cfg = cfg,
            .origin = window.centeredOrigin(cam_x, cam_y),
            .slots = @splat(.{ .coord = .{ .x = 0, .y = 0 } }),
            .move = null,
            .move_next = 0,
            .buf = try alloc.create(chunk.Cells),
            .stats = .{},
        };
    }

    pub fn deinit(s: *Streaming, alloc: std.mem.Allocator) void {
        alloc.destroy(s.buf);
        s.* = undefined;
    }

    /// Fills every slot for the current origin. Blocking; for startup and
    /// after `teleport`.
    pub fn loadAll(s: *Streaming) !void {
        for (0..window.slot_count) |i| {
            const slot = window.Slot.fromIndex(@intCast(i));
            try s.loadSlot(slot, window.chunkAtSlot(slot, s.origin));
        }
    }

    /// Advances streaming by one tick for the camera at world cell (x, y).
    pub fn tick(s: *Streaming, cam_x: i32, cam_y: i32) !TickReport {
        if (s.move == null) {
            const target = window.desiredOrigin(s.origin, cam_x, cam_y, s.cfg.hysteresis);
            s.move = window.nextMove(s.origin, target) orelse return .{ .moving = false, .ops = 0 };
            s.move_next = 0;
            s.stats.moves += 1;
        }
        const m = &s.move.?;
        var ops: u32 = 0;
        while (s.move_next < window.chunks and ops < s.cfg.ops_per_tick) {
            const k = s.move_next;
            try s.evictSlot(m.slots[k], m.evict[k]);
            try s.loadSlot(m.slots[k], m.load[k]);
            s.move_next += 1;
            ops += 1;
        }
        if (s.move_next == window.chunks) {
            s.origin = m.new_origin;
            s.move = null;
        }
        return .{ .moving = s.move != null, .ops = ops };
    }

    fn evictSlot(s: *Streaming, slot: window.Slot, expect: chunk.Coord) !void {
        const info = &s.slots[slot.index()];
        std.debug.assert(info.valid and info.coord.eql(expect));
        // Check capacity before taking the dirty bit so a failure leaves
        // everything as it was.
        if (!s.store.canPark(info.coord)) return error.ParkedPoolFull;
        const dirty = s.sink.takeDirty(slot.x, slot.y) or info.cpu_dirty;
        if (dirty) {
            s.sink.downloadChunk(slot.x, slot.y, s.buf);
            s.stats.downloads += 1;
            try s.store.park(info.coord, s.buf);
            s.stats.parked += 1;
        }
        info.valid = false;
        info.cpu_dirty = false;
    }

    fn loadSlot(s: *Streaming, slot: window.Slot, c: chunk.Coord) !void {
        switch (try s.store.fetch(c, s.buf)) {
            .parked => s.stats.decompressed += 1,
            .generated => s.stats.generated += 1,
        }
        s.sink.uploadChunk(slot.x, slot.y, s.buf);
        s.stats.uploads += 1;
        s.slots[slot.index()] = .{ .coord = c, .valid = true };
    }

    /// Parks every dirty resident chunk (download + compress) without
    /// unloading it. Call before `Store.save`.
    pub fn flush(s: *Streaming) !void {
        for (&s.slots, 0..) |*info, i| {
            if (!info.valid) continue;
            const slot = window.Slot.fromIndex(@intCast(i));
            if (!s.store.canPark(info.coord)) return error.ParkedPoolFull;
            if (s.sink.takeDirty(slot.x, slot.y) or info.cpu_dirty) {
                s.sink.downloadChunk(slot.x, slot.y, s.buf);
                s.stats.downloads += 1;
                try s.store.park(info.coord, s.buf);
                s.stats.parked += 1;
                info.cpu_dirty = false;
            }
        }
    }

    /// Jumps the window to a new camera position: parks dirty chunks,
    /// recenters and reloads everything. Blocking.
    pub fn teleport(s: *Streaming, cam_x: i32, cam_y: i32) !void {
        try s.flush();
        s.move = null;
        s.origin = window.centeredOrigin(cam_x, cam_y);
        try s.loadAll();
    }

    /// Marks the chunk holding world cell (x, y) as modified from the CPU
    /// side (for edits the GPU dirty bit would not see).
    pub fn markDirty(s: *Streaming, world_x: i32, world_y: i32) void {
        const c = chunk.coordOfCell(world_x, world_y);
        const info = &s.slots[window.slotOf(c).index()];
        if (info.valid and info.coord.eql(c)) info.cpu_dirty = true;
    }

    /// Whether chunk `c` is in its slot right now (true even mid-move for
    /// slots already swapped).
    pub fn isResident(s: *const Streaming, c: chunk.Coord) bool {
        const info = s.slots[window.slotOf(c).index()];
        return info.valid and info.coord.eql(c);
    }

    /// Chunk currently held by a slot, if any.
    pub fn chunkInSlot(s: *const Streaming, slot: window.Slot) ?chunk.Coord {
        const info = s.slots[slot.index()];
        return if (info.valid) info.coord else null;
    }

    /// World cell held at window cell (wx, wy), exact even mid-move.
    pub fn worldOfWindow(s: *const Streaming, wx: u32, wy: u32) ?[2]i32 {
        const slot: window.Slot = .{ .x = wx >> chunk.size_log2, .y = wy >> chunk.size_log2 };
        const c = s.chunkInSlot(slot) orelse return null;
        const o = c.originCell();
        return .{ o[0] + @as(i32, @intCast(wx & (chunk.size - 1))), o[1] + @as(i32, @intCast(wy & (chunk.size - 1))) };
    }
};

// ---------------------------------------------------------------------------
// Test double for the GPU side.
// ---------------------------------------------------------------------------

/// CPU stand-in for the GPU cell image: 64 chunk buffers plus dirty bits.
pub const TestSink = struct {
    gpu: *[window.slot_count]chunk.Cells,
    dirty: [window.slot_count]bool = @splat(false),
    uploads: u32 = 0,
    downloads: u32 = 0,

    pub fn init(alloc: std.mem.Allocator) !TestSink {
        const gpu = try alloc.create([window.slot_count]chunk.Cells);
        @memset(std.mem.sliceAsBytes(gpu), 0xaa);
        return .{ .gpu = gpu };
    }

    pub fn deinit(t: *TestSink, alloc: std.mem.Allocator) void {
        alloc.destroy(t.gpu);
    }

    pub fn sink(t: *TestSink) UploadSink {
        return .{ .ptr = t, .vtable = &.{
            .uploadChunk = upload,
            .downloadChunk = download,
            .takeDirty = takeDirty,
        } };
    }

    /// Simulates a GPU edit of window cell (wx, wy).
    pub fn edit(t: *TestSink, wx: u32, wy: u32, value: u32) void {
        const slot: window.Slot = .{ .x = wx >> chunk.size_log2, .y = wy >> chunk.size_log2 };
        t.gpu[slot.index()][chunk.index(wx & (chunk.size - 1), wy & (chunk.size - 1))] = value;
        t.dirty[slot.index()] = true;
    }

    pub fn at(t: *const TestSink, wx: u32, wy: u32) u32 {
        const slot: window.Slot = .{ .x = wx >> chunk.size_log2, .y = wy >> chunk.size_log2 };
        return t.gpu[slot.index()][chunk.index(wx & (chunk.size - 1), wy & (chunk.size - 1))];
    }

    fn upload(ctx: *anyopaque, x: u32, y: u32, cells: *const chunk.Cells) void {
        const t: *TestSink = @ptrCast(@alignCast(ctx));
        const i = (window.Slot{ .x = x, .y = y }).index();
        t.gpu[i] = cells.*;
        t.dirty[i] = false;
        t.uploads += 1;
    }

    fn download(ctx: *anyopaque, x: u32, y: u32, out: *chunk.Cells) void {
        const t: *TestSink = @ptrCast(@alignCast(ctx));
        out.* = t.gpu[(window.Slot{ .x = x, .y = y }).index()];
        t.downloads += 1;
    }

    fn takeDirty(ctx: *anyopaque, x: u32, y: u32) bool {
        const t: *TestSink = @ptrCast(@alignCast(ctx));
        const i = (window.Slot{ .x = x, .y = y }).index();
        defer t.dirty[i] = false;
        return t.dirty[i];
    }
};

const testing = std.testing;
const procgen = @import("procgen.zig");
const cell = @import("cell.zig");
const hash = @import("hash.zig");

// High in the sky every chunk is air, so generation is a memset and the
// tests stay fast in Debug; cell variants still differ per world position.
const sky_y: i32 = -100_000;

const Fixture = struct {
    store: Store,
    tsink: TestSink,
    st: Streaming,

    fn init(f: *Fixture, cfg: Config, cam_x: i32, cam_y: i32) !void {
        const a = testing.allocator;
        f.store = try Store.init(a, 42, .{ .ids = procgen.test_ids }, .{ .parked_bytes = 4 << 20, .max_parked_chunks = 64 });
        f.tsink = try TestSink.init(a);
        f.st = try Streaming.init(a, &f.store, f.tsink.sink(), cfg, cam_x, cam_y);
        try f.st.loadAll();
    }

    fn deinit(f: *Fixture) void {
        f.st.deinit(testing.allocator);
        f.tsink.deinit(testing.allocator);
        f.store.deinit();
    }

    /// Spot-checks that every valid slot holds its own chunk's cells.
    fn expectWindowMatches(f: *Fixture) !void {
        for (0..window.slot_count) |i| {
            const slot = window.Slot.fromIndex(@intCast(i));
            const c = f.st.chunkInSlot(slot) orelse continue;
            const o = c.originCell();
            // Spot-check corners: air with this chunk's base variant.
            for ([_][2]u32{ .{ 0, 0 }, .{ 255, 0 }, .{ 0, 255 }, .{ 255, 255 }, .{ 17, 200 } }) |p| {
                const got = f.tsink.gpu[i][chunk.index(p[0], p[1])];
                const want_v = hash.baseVariant(o[0] + @as(i32, @intCast(p[0])), o[1] + @as(i32, @intCast(p[1])));
                if (cell.material(got) == procgen.test_ids.air) try testing.expectEqual(want_v, cell.variant(got));
            }
        }
    }
};

test "initial load fills all 64 slots" {
    var f: Fixture = undefined;
    try f.init(.{}, 0, sky_y);
    defer f.deinit();
    try testing.expectEqual(@as(u32, 64), f.tsink.uploads);
    try testing.expectEqual(chunk.Coord{ .x = -4, .y = @divFloor(sky_y - 1024 + 128, 256) }, f.st.origin);
    for (0..window.slot_count) |i| try testing.expect(f.st.chunkInSlot(window.Slot.fromIndex(@intCast(i))) != null);
    try f.expectWindowMatches();
    // A tick with the camera still near the center does nothing.
    const r = try f.st.tick(100, sky_y);
    try testing.expectEqual(@as(u32, 0), r.ops);
    try testing.expectEqual(@as(u32, 64), f.tsink.uploads);
}

test "crossing a chunk boundary swaps one column into the vacated slots" {
    var f: Fixture = undefined;
    const cy = sky_y - @mod(sky_y, 256); // a chunk-aligned y so the window is centered
    try f.init(.{ .ops_per_tick = 8 }, 0, cy);
    defer f.deinit();
    const o0 = f.st.origin;
    try testing.expectEqual(@as(i32, -4), o0.x);
    // Within hysteresis: no move.
    _ = try f.st.tick(160, cy);
    try testing.expectEqual(o0, f.st.origin);
    // Past it: exactly one column, all eight slots in one tick.
    const r = try f.st.tick(161, cy);
    try testing.expectEqual(@as(u32, 8), r.ops);
    try testing.expect(!r.moving);
    try testing.expectEqual(chunk.Coord{ .x = -3, .y = o0.y }, f.st.origin);
    try testing.expectEqual(@as(u32, 72), f.tsink.uploads);
    try testing.expectEqual(@as(u32, 0), f.tsink.downloads); // nothing was dirty
    for (0..8) |k| {
        const y = o0.y + @as(i32, @intCast(k));
        try testing.expect(!f.st.isResident(.{ .x = -4, .y = y }));
        try testing.expect(f.st.isResident(.{ .x = 4, .y = y }));
        try testing.expectEqual(chunk.Coord{ .x = 4, .y = y }, f.st.chunkInSlot(window.slotOf(.{ .x = 4, .y = y })).?);
    }
    try f.expectWindowMatches();
    // World ↔ window mapping agrees with the slot table after the move.
    const w = window.toWindow(4 * 256 + 5, cy + 9);
    const back = f.st.worldOfWindow(w[0], w[1]).?;
    try testing.expectEqual(@as(i32, 4 * 256 + 5), back[0]);
    try testing.expectEqual(cy + 9, back[1]);
    // Moving up crosses on the other axis: one row.
    _ = try f.st.tick(161, cy - 161);
    try testing.expectEqual(chunk.Coord{ .x = -3, .y = o0.y - 1 }, f.st.origin);
    try testing.expectEqual(@as(u32, 80), f.tsink.uploads);
}

test "one slot per tick, one row or column at a time" {
    var f: Fixture = undefined;
    const cy = sky_y - @mod(sky_y, 256);
    try f.init(.{ .ops_per_tick = 1 }, 0, cy);
    defer f.deinit();
    const o0 = f.st.origin;
    // A far jump still only advances one column per 8 ticks.
    for (0..7) |_| {
        const r = try f.st.tick(5000, cy + 3000);
        try testing.expect(r.moving);
        try testing.expectEqual(@as(u32, 1), r.ops);
    }
    try testing.expectEqual(o0, f.st.origin);
    // Mid-move, swapped slots already report the new chunk.
    try testing.expect(f.st.isResident(.{ .x = 4, .y = o0.y }));
    try testing.expect(!f.st.isResident(.{ .x = -4, .y = o0.y }));
    try testing.expect(f.st.isResident(.{ .x = -4, .y = o0.y + 7 }));
    const r = try f.st.tick(5000, cy + 3000);
    try testing.expect(!r.moving);
    try testing.expectEqual(chunk.Coord{ .x = o0.x + 1, .y = o0.y }, f.st.origin);
    try testing.expectEqual(@as(u32, 64 + 8), f.tsink.uploads);
}

test "dirty chunks are downloaded, parked and come back" {
    var f: Fixture = undefined;
    const cy = sky_y - @mod(sky_y, 256);
    try f.init(.{ .ops_per_tick = 8 }, 0, cy);
    defer f.deinit();
    // The GPU edits a cell in chunk (-4, cy/256) (leftmost column).
    const wx: i32 = -4 * 256 + 10;
    const wy: i32 = cy + 20;
    const w = window.toWindow(wx, wy);
    const wood = cell.pack(procgen.test_ids.wood, cell.ambient_temperature, 120, 0, 3);
    f.tsink.edit(w[0], w[1], wood);
    // And the CPU marks a chunk dirty without the GPU bit.
    const cpu_c: chunk.Coord = .{ .x = -4, .y = f.st.origin.y + 1 };
    f.st.markDirty(-4 * 256, (f.st.origin.y + 1) * 256);

    _ = try f.st.tick(161, cy); // evicts column x = -4
    try testing.expectEqual(@as(u32, 2), f.tsink.downloads);
    try testing.expect(f.store.isParked(chunk.coordOfCell(wx, wy)));
    try testing.expect(f.store.isParked(cpu_c));
    try testing.expectEqual(@as(u32, 2), f.store.parkedCount());

    // The vacated slot now holds chunk x = 4 at the same window cell.
    try testing.expect(f.tsink.at(w[0], w[1]) != wood);

    // Walk back: x = -4 is fetched from the parked copy, edit intact.
    _ = try f.st.tick(0, cy);
    _ = try f.st.tick(0, cy); // already centered again: no-op
    try testing.expectEqual(@as(i32, -4), f.st.origin.x);
    try testing.expect(f.st.isResident(chunk.coordOfCell(wx, wy)));
    try testing.expectEqual(wood, f.tsink.at(w[0], w[1]));
    try testing.expectEqual(@as(u64, 2), f.st.stats.decompressed);

    // Clean eviction keeps the parked copy without downloading again.
    const before = f.tsink.downloads;
    _ = try f.st.tick(161, cy);
    try testing.expectEqual(before, f.tsink.downloads);
    try testing.expect(f.store.isParked(chunk.coordOfCell(wx, wy)));
}

test "flush parks dirty resident chunks for saving" {
    var f: Fixture = undefined;
    try f.init(.{}, 0, sky_y);
    defer f.deinit();
    f.tsink.edit(5, 5, cell.pack(procgen.test_ids.stone, 8, 200, 0, 1));
    try f.st.flush();
    try testing.expectEqual(@as(u32, 1), f.store.parkedCount());
    try testing.expectEqual(@as(u32, 1), f.tsink.downloads);
    try f.st.flush(); // bit was taken; nothing new
    try testing.expectEqual(@as(u32, 1), f.tsink.downloads);
}
