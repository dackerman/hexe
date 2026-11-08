//! Background chunk generation: a pool of worker threads, each with its own
//! `procgen.Generator`, filling a fixed set of chunk buffers that the
//! streaming layer asks for ahead of time (docs/decisions/62-stream-prefetch.md).
//!
//! The main thread only calls `request` (cheap, never blocks on procgen),
//! `acquire` / `release` (take a finished chunk without copying) and, at
//! startup or after a teleport, `wait`. Workers pick the queued request with
//! the best priority. When every buffer is in use, a new request evicts the
//! least recently requested queued or finished entry of equal or worse
//! priority; entries being generated or acquired are never evicted. Nothing
//! allocates after `init`.

const std = @import("std");
const Io = std.Io;
const chunk = @import("chunk.zig");
const procgen = @import("procgen.zig");

pub const Config = struct {
    /// Worker threads; 0 = CPU count − 1, capped at `max_workers`.
    workers: u32 = 0,
    /// Each worker owns a Generator with ~5 MiB of scratch, and generation
    /// at the camera's pace needs a handful at most; the cap bounds memory.
    max_workers: u32 = 15,
    /// Chunk buffers (256 KiB each).
    capacity: u32 = 64,
};

const State = enum(u8) { free, queued, generating, ready };

const Entry = struct {
    coord: chunk.Coord = .{ .x = 0, .y = 0 },
    state: State = .free,
    /// Lower is more urgent.
    priority: u8 = 0,
    acquired: bool = false,
    /// Request clock at the last `request` for this coord (LRU and FIFO).
    stamp: u64 = 0,
};

pub const Stats = struct {
    requested: u64 = 0,
    generated: u64 = 0,
    evicted: u64 = 0,
    dropped: u64 = 0,
    /// Worker time spent in procgen, nanoseconds.
    gen_ns: u64 = 0,
};

pub const Prefetcher = struct {
    alloc: std.mem.Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    work: Io.Condition = .init,
    done: Io.Condition = .init,
    entries: []Entry,
    cells: []chunk.Cells,
    gens: []procgen.Generator,
    threads: []std.Thread,
    quit: bool = false,
    clock: u64 = 0,
    stats: Stats = .{},

    /// Heap-allocated: the workers hold a pointer to it.
    pub fn create(alloc: std.mem.Allocator, io: Io, seed: u64, params: procgen.Params, cfg: Config) !*Prefetcher {
        const p = try alloc.create(Prefetcher);
        errdefer alloc.destroy(p);
        const cpus: u32 = @intCast(std.Thread.getCpuCount() catch 2);
        const n = if (cfg.workers != 0) cfg.workers else std.math.clamp(cpus -| 1, 1, cfg.max_workers);
        p.* = .{
            .alloc = alloc,
            .io = io,
            .entries = try alloc.alloc(Entry, cfg.capacity),
            .cells = &.{},
            .gens = &.{},
            .threads = &.{},
        };
        errdefer alloc.free(p.entries);
        @memset(p.entries, .{});
        p.cells = try alloc.alloc(chunk.Cells, cfg.capacity);
        errdefer alloc.free(p.cells);
        p.gens = try alloc.alloc(procgen.Generator, n);
        errdefer alloc.free(p.gens);
        var made: usize = 0;
        errdefer for (p.gens[0..made]) |*g| g.deinit(alloc);
        for (p.gens) |*g| {
            g.* = try procgen.Generator.init(alloc, seed, params);
            made += 1;
        }
        p.threads = try alloc.alloc(std.Thread, n);
        errdefer alloc.free(p.threads);
        var spawned: usize = 0;
        errdefer {
            p.stop(p.threads[0..spawned]);
        }
        for (p.threads, 0..) |*t, i| {
            t.* = try std.Thread.spawn(.{}, worker, .{ p, &p.gens[i] });
            spawned += 1;
        }
        return p;
    }

    pub fn destroy(p: *Prefetcher) void {
        const alloc = p.alloc;
        p.stop(p.threads);
        for (p.gens) |*g| g.deinit(alloc);
        alloc.free(p.threads);
        alloc.free(p.gens);
        alloc.free(p.cells);
        alloc.free(p.entries);
        alloc.destroy(p);
    }

    fn stop(p: *Prefetcher, threads: []std.Thread) void {
        p.mutex.lockUncancelable(p.io);
        p.quit = true;
        p.work.broadcast(p.io);
        p.mutex.unlock(p.io);
        for (threads) |t| t.join();
    }

    pub fn workerCount(p: *const Prefetcher) usize {
        return p.threads.len;
    }

    fn find(p: *Prefetcher, c: chunk.Coord) ?usize {
        for (p.entries, 0..) |e, i| {
            if (e.state != .free and e.coord.eql(c)) return i;
        }
        return null;
    }

    /// Asks for chunk `c` to be generated in the background. Refreshes the
    /// priority (keeps the more urgent one) and LRU stamp of an existing
    /// request. Never blocks on generation.
    pub fn request(p: *Prefetcher, c: chunk.Coord, priority: u8) void {
        p.mutex.lockUncancelable(p.io);
        defer p.mutex.unlock(p.io);
        _ = p.requestLocked(c, priority);
    }

    fn requestLocked(p: *Prefetcher, c: chunk.Coord, priority: u8) ?usize {
        p.clock += 1;
        if (p.find(c)) |i| {
            const e = &p.entries[i];
            e.stamp = p.clock;
            if (priority < e.priority) e.priority = priority;
            return i;
        }
        const slot = p.freeSlot(priority) orelse {
            p.stats.dropped += 1;
            return null;
        };
        p.entries[slot] = .{ .coord = c, .state = .queued, .priority = priority, .stamp = p.clock };
        p.stats.requested += 1;
        p.work.signal(p.io);
        return slot;
    }

    /// A free entry, or the stalest evictable one no more urgent than
    /// `priority` (finished entries go before queued ones).
    fn freeSlot(p: *Prefetcher, priority: u8) ?usize {
        var best: ?usize = null;
        for (p.entries, 0..) |e, i| {
            if (e.state == .free) return i;
            if (e.acquired or e.state == .generating or e.priority < priority) continue;
            if (best) |b| {
                const o = p.entries[b];
                // Worse priority first, then finished before queued, then oldest.
                const worse = e.priority > o.priority or (e.priority == o.priority and
                    ((e.state == .ready and o.state != .ready) or (e.state == o.state and e.stamp < o.stamp)));
                if (worse) best = i;
            } else best = i;
        }
        if (best != null) p.stats.evicted += 1;
        return best;
    }

    /// Whether chunk `c` is generated and waiting.
    pub fn isReady(p: *Prefetcher, c: chunk.Coord) bool {
        p.mutex.lockUncancelable(p.io);
        defer p.mutex.unlock(p.io);
        const i = p.find(c) orelse return false;
        return p.entries[i].state == .ready;
    }

    /// The generated cells of `c` if ready, pinned until `release(c)`.
    pub fn acquire(p: *Prefetcher, c: chunk.Coord) ?*const chunk.Cells {
        p.mutex.lockUncancelable(p.io);
        defer p.mutex.unlock(p.io);
        const i = p.find(c) orelse return null;
        if (p.entries[i].state != .ready) return null;
        p.entries[i].acquired = true;
        return &p.cells[i];
    }

    /// Blocks until `c` is generated (requesting it at top priority) and
    /// pins it like `acquire`. For startup and teleports only.
    pub fn wait(p: *Prefetcher, c: chunk.Coord) !*const chunk.Cells {
        p.mutex.lockUncancelable(p.io);
        defer p.mutex.unlock(p.io);
        while (true) {
            const i = p.requestLocked(c, 0) orelse {
                // Everything pinned or generating: wait for a worker.
                p.done.waitUncancelable(p.io, &p.mutex);
                continue;
            };
            if (p.entries[i].state == .ready) {
                p.entries[i].acquired = true;
                return &p.cells[i];
            }
            p.done.waitUncancelable(p.io, &p.mutex);
        }
    }

    /// Frees the entry of an acquired chunk.
    pub fn release(p: *Prefetcher, c: chunk.Coord) void {
        p.mutex.lockUncancelable(p.io);
        defer p.mutex.unlock(p.io);
        const i = p.find(c) orelse return;
        std.debug.assert(p.entries[i].acquired);
        p.entries[i] = .{};
    }

    /// Drops a queued or finished entry for `c` (e.g. it got parked).
    pub fn forget(p: *Prefetcher, c: chunk.Coord) void {
        p.mutex.lockUncancelable(p.io);
        defer p.mutex.unlock(p.io);
        const i = p.find(c) orelse return;
        const e = &p.entries[i];
        if (e.acquired or e.state == .generating) return;
        e.* = .{};
    }

    fn worker(p: *Prefetcher, gen: *procgen.Generator) void {
        p.mutex.lockUncancelable(p.io);
        defer p.mutex.unlock(p.io);
        while (true) {
            if (p.quit) return;
            const i = p.nextJob() orelse {
                p.work.waitUncancelable(p.io, &p.mutex);
                continue;
            };
            const e = &p.entries[i];
            e.state = .generating;
            const c = e.coord;
            p.mutex.unlock(p.io);
            const t0 = Io.Timestamp.now(p.io, .awake);
            gen.generate(c, &p.cells[i]);
            const ns: u64 = @intCast(t0.untilNow(p.io, .awake).nanoseconds);
            p.mutex.lockUncancelable(p.io);
            std.debug.assert(e.coord.eql(c) and e.state == .generating);
            e.state = .ready;
            p.stats.generated += 1;
            p.stats.gen_ns += ns;
            p.done.broadcast(p.io);
        }
    }

    fn nextJob(p: *Prefetcher) ?usize {
        var best: ?usize = null;
        for (p.entries, 0..) |e, i| {
            if (e.state != .queued) continue;
            if (best) |b| {
                const o = p.entries[b];
                if (e.priority < o.priority or (e.priority == o.priority and e.stamp < o.stamp)) best = i;
            } else best = i;
        }
        return best;
    }
};

const testing = std.testing;

test "prefetcher generates what the generator would, off the main thread" {
    const a = testing.allocator;
    const params: procgen.Params = .{ .ids = procgen.test_ids };
    var p = try Prefetcher.create(a, testing.io, 7, params, .{ .workers = 3, .capacity = 6 });
    defer p.destroy();
    var g = try procgen.Generator.init(a, 7, params);
    defer g.deinit(a);
    const ref = try a.create(chunk.Cells);
    defer a.destroy(ref);

    // Sky chunks are cheap in Debug; one real terrain chunk checks equality.
    const coords = [_]chunk.Coord{ .{ .x = 0, .y = -50 }, .{ .x = 1, .y = -50 }, .{ .x = -1, .y = 0 } };
    for (coords) |c| p.request(c, 1);
    for (coords) |c| {
        const cells = try p.wait(c);
        g.generate(c, ref);
        try testing.expectEqualSlices(u32, ref, cells);
        p.release(c);
        try testing.expect(p.acquire(c) == null);
    }
    try testing.expectEqual(@as(u64, 3), p.stats.generated);
}

test "prefetcher evicts stale requests, never pinned ones" {
    const a = testing.allocator;
    var p = try Prefetcher.create(a, testing.io, 1, .{ .ids = procgen.test_ids }, .{ .workers = 1, .capacity = 2 });
    defer p.destroy();
    const c0: chunk.Coord = .{ .x = 0, .y = -40 };
    const c1: chunk.Coord = .{ .x = 1, .y = -40 };
    const c2: chunk.Coord = .{ .x = 2, .y = -40 };
    _ = try p.wait(c0); // pinned
    p.request(c1, 3);
    _ = try p.wait(c1);
    p.release(c1);
    p.request(c1, 3);
    // c1 queued again at low priority; an urgent request takes its entry.
    p.request(c2, 0);
    const pinned = p.acquire(c0);
    try testing.expect(pinned != null);
    _ = try p.wait(c2);
    p.release(c2);
    p.release(c0);
}
