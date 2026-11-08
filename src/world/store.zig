//! Chunk store: owns the generator and the parked chunks.
//!
//! A chunk is in one of three states:
//!   - not generated: no data anywhere; `fetch` runs procgen.
//!   - parked: modified at some point, held compressed in RAM (and on disk
//!     after a save). `fetch` decompresses it.
//!   - resident: in a window slot on the GPU (tracked by streaming.zig). A
//!     resident chunk may also still have a parked copy; streaming replaces
//!     it on eviction only if the GPU dirtied the chunk.
//!
//! Parked data lives in a fixed pool of 4 KiB blocks chained per chunk, and
//! the coordinate map is sized at init, so `fetch` and `park` never allocate.
//! Save layout: docs/decisions/03-world-save-layout.md.

const std = @import("std");
const Io = std.Io;
const chunk = @import("chunk.zig");
const procgen = @import("procgen.zig");

pub const Config = struct {
    /// Capacity of the parked-chunk pool in bytes (rounded down to blocks).
    parked_bytes: usize = 64 << 20,
    /// Maximum number of distinct parked chunks.
    max_parked_chunks: u32 = 8192,
};

pub const block_size = 4096;
const no_block = std.math.maxInt(u32);
/// Blocks one chunk can need in the worst case (raw fallback).
pub const max_blocks_per_chunk = (chunk.max_compressed_len + block_size - 1) / block_size;

pub const save_version: u32 = 1;
pub const header_file = "world.zon";
const file_magic = "HXCK";
const file_header_len = 4 + 2 + 2 + 4 + 4 + 4;

pub const Codec = enum { rle_xor_variant };

/// Contents of `world.zon`.
pub const Header = struct {
    version: u32,
    seed: u64,
    chunk_size: u32 = chunk.size,
    codec: Codec = .rle_xor_variant,
};

pub const Source = enum { parked, generated };

pub const ParkError = error{ ParkedPoolFull, TooManyParkedChunks };

const Entry = struct { first: u32, len: u32 };

pub const Store = struct {
    alloc: std.mem.Allocator,
    seed: u64,
    gen: procgen.Generator,
    blocks: []u8,
    next: []u32,
    free_head: u32,
    free_count: u32,
    map: std.AutoHashMapUnmanaged(chunk.Coord, Entry),
    max_chunks: u32,
    scratch: []u8, // compress output
    gather: []u8, // contiguous copy of a parked blob, also file I/O buffer

    pub fn init(alloc: std.mem.Allocator, seed: u64, params: procgen.Params, cfg: Config) !Store {
        const nblocks: u32 = @intCast(cfg.parked_bytes / block_size);
        std.debug.assert(nblocks >= max_blocks_per_chunk);
        var s: Store = undefined;
        s.alloc = alloc;
        s.seed = seed;
        s.gen = try procgen.Generator.init(alloc, seed, params);
        errdefer s.gen.deinit(alloc);
        s.blocks = try alloc.alloc(u8, @as(usize, nblocks) * block_size);
        errdefer alloc.free(s.blocks);
        s.next = try alloc.alloc(u32, nblocks);
        errdefer alloc.free(s.next);
        for (s.next, 0..) |*n, i| n.* = if (i + 1 < nblocks) @intCast(i + 1) else no_block;
        s.free_head = 0;
        s.free_count = nblocks;
        s.map = .empty;
        try s.map.ensureTotalCapacity(alloc, cfg.max_parked_chunks);
        errdefer s.map.deinit(alloc);
        s.max_chunks = cfg.max_parked_chunks;
        s.scratch = try alloc.alloc(u8, chunk.compress_scratch_len);
        errdefer alloc.free(s.scratch);
        s.gather = try alloc.alloc(u8, chunk.max_compressed_len + file_header_len);
        return s;
    }

    pub fn deinit(s: *Store) void {
        const a = s.alloc;
        s.gen.deinit(a);
        a.free(s.blocks);
        a.free(s.next);
        s.map.deinit(a);
        a.free(s.scratch);
        a.free(s.gather);
        s.* = undefined;
    }

    pub fn isParked(s: *const Store, c: chunk.Coord) bool {
        return s.map.contains(c);
    }

    pub fn parkedCount(s: *const Store) u32 {
        return s.map.count();
    }

    pub fn parkedBytes(s: *const Store) usize {
        var n: usize = 0;
        var it = s.map.valueIterator();
        while (it.next()) |e| n += e.len;
        return n;
    }

    /// True if one more chunk can be parked whatever its size.
    pub fn canPark(s: *const Store, c: chunk.Coord) bool {
        const existing: u32 = if (s.map.get(c)) |e| blocksFor(e.len) else 0;
        if (existing == 0 and s.map.count() >= s.max_chunks) return false;
        return s.free_count + existing >= max_blocks_per_chunk;
    }

    fn blocksFor(len: u32) u32 {
        return @intCast((len + block_size - 1) / block_size);
    }

    /// Loads chunk `c` into `out`: decompressed if parked, else generated.
    pub fn fetch(s: *Store, c: chunk.Coord, out: *chunk.Cells) chunk.DecodeError!Source {
        if (s.map.get(c)) |e| {
            const blob = s.gatherBlob(e);
            try chunk.decompress(c, blob, out);
            return .parked;
        }
        s.gen.generate(c, out);
        return .generated;
    }

    fn gatherBlob(s: *Store, e: Entry) []u8 {
        var b = e.first;
        var off: usize = 0;
        while (off < e.len) {
            const n = @min(block_size, e.len - off);
            @memcpy(s.gather[off..][0..n], s.blocks[@as(usize, b) * block_size ..][0..n]);
            off += n;
            b = s.next[b];
        }
        return s.gather[0..e.len];
    }

    /// Compresses and parks `cells` as chunk `c`, replacing any older copy.
    pub fn park(s: *Store, c: chunk.Coord, cells: *const chunk.Cells) ParkError!void {
        const blob = chunk.compress(c, cells, s.scratch);
        try s.parkBlob(c, blob);
    }

    fn parkBlob(s: *Store, c: chunk.Coord, blob: []const u8) ParkError!void {
        const need = blocksFor(@intCast(blob.len));
        const old = s.map.get(c);
        const reclaim: u32 = if (old) |e| blocksFor(e.len) else 0;
        if (old == null and s.map.count() >= s.max_chunks) return error.TooManyParkedChunks;
        if (s.free_count + reclaim < need) return error.ParkedPoolFull;
        if (old) |e| s.freeChain(e);
        var first: u32 = no_block;
        var prev: u32 = no_block;
        var off: usize = 0;
        while (off < blob.len or first == no_block) {
            const b = s.free_head;
            std.debug.assert(b != no_block);
            s.free_head = s.next[b];
            s.free_count -= 1;
            s.next[b] = no_block;
            if (prev == no_block) first = b else s.next[prev] = b;
            prev = b;
            const n = @min(block_size, blob.len - off);
            @memcpy(s.blocks[@as(usize, b) * block_size ..][0..n], blob[off..][0..n]);
            off += n;
            if (blob.len == 0) break;
        }
        s.map.putAssumeCapacity(c, .{ .first = first, .len = @intCast(blob.len) });
    }

    fn freeChain(s: *Store, e: Entry) void {
        var b = e.first;
        var n = @max(1, blocksFor(e.len));
        while (n > 0) : (n -= 1) {
            const nxt = s.next[b];
            s.next[b] = s.free_head;
            s.free_head = b;
            s.free_count += 1;
            b = nxt;
        }
    }

    /// Forgets a parked chunk; the next fetch regenerates it.
    pub fn unpark(s: *Store, c: chunk.Coord) void {
        if (s.map.fetchRemove(c)) |kv| s.freeChain(kv.value);
    }

    // -- save / load --------------------------------------------------------

    /// Writes `world.zon` and one `cx_cy.chunk` per parked chunk into `dir`.
    /// Resident chunks must be flushed into the store first
    /// (`Streaming.flush`). Existing chunk files for chunks no longer parked
    /// are left alone; every chunk that was loaded from a save stays parked,
    /// so nothing stale can shadow newer data.
    pub fn save(s: *Store, io: Io, dir: Io.Dir) !void {
        var name_buf: [32]u8 = undefined;
        var it = s.map.iterator();
        while (it.next()) |kv| {
            const c = kv.key_ptr.*;
            const e = kv.value_ptr.*;
            const blob = s.gatherBlob(e);
            // Header goes in front of the blob: shift is avoided by writing
            // the header and the blob as two writes.
            var head: [file_header_len]u8 = undefined;
            @memcpy(head[0..4], file_magic);
            std.mem.writeInt(u16, head[4..6], @intCast(save_version), .little);
            std.mem.writeInt(u16, head[6..8], 0, .little);
            std.mem.writeInt(i32, head[8..12], c.x, .little);
            std.mem.writeInt(i32, head[12..16], c.y, .little);
            std.mem.writeInt(u32, head[16..20], @intCast(blob.len), .little);
            const name = try std.fmt.bufPrint(&name_buf, "{d}_{d}.chunk", .{ c.x, c.y });
            var file = try dir.createFile(io, name, .{});
            defer file.close(io);
            try file.writeStreamingAll(io, &head);
            try file.writeStreamingAll(io, blob);
        }
        var zon_buf: [256]u8 = undefined;
        const zon = try std.fmt.bufPrint(&zon_buf,
            \\.{{
            \\    .version = {d},
            \\    .seed = {d},
            \\    .chunk_size = {d},
            \\    .codec = .{s},
            \\}}
            \\
        , .{ save_version, s.seed, chunk.size, @tagName(Codec.rle_xor_variant) });
        try dir.writeFile(io, .{ .sub_path = header_file, .data = zon });
    }

    /// Parses `world.zon` in `dir`.
    pub fn readHeader(io: Io, dir: Io.Dir, gpa: std.mem.Allocator) !Header {
        var buf: [1024]u8 = undefined;
        const text = try dir.readFile(io, header_file, buf[0 .. buf.len - 1]);
        buf[text.len] = 0;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        var diag: std.zon.parse.Diagnostics = undefined;
        const h = std.zon.parse.fromSlice(Header, .{
            .gpa = gpa,
            .arena = arena.allocator(),
            .source = buf[0..text.len :0],
            .diagnostics = &diag,
        }) catch return error.BadSaveHeader;
        if (h.version != save_version or h.chunk_size != chunk.size) return error.UnsupportedSave;
        return h;
    }

    /// Loads every chunk file in `dir` (opened with `.iterate = true`) into
    /// the parked pool. The store must have been created with the save's
    /// seed (see `readHeader`). Returns the number of chunks loaded.
    pub fn load(s: *Store, io: Io, dir: Io.Dir) !u32 {
        var count: u32 = 0;
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".chunk")) continue;
            const data = try dir.readFile(io, entry.name, s.gather);
            if (data.len < file_header_len or !std.mem.eql(u8, data[0..4], file_magic)) return error.CorruptChunk;
            if (std.mem.readInt(u16, data[4..6], .little) != save_version) return error.UnsupportedSave;
            const c: chunk.Coord = .{
                .x = std.mem.readInt(i32, data[8..12], .little),
                .y = std.mem.readInt(i32, data[12..16], .little),
            };
            const len = std.mem.readInt(u32, data[16..20], .little);
            if (data.len != file_header_len + len) return error.CorruptChunk;
            // Copy out of `gather` before parkBlob touches the pool.
            @memcpy(s.scratch[0..len], data[file_header_len..]);
            try s.parkBlob(c, s.scratch[0..len]);
            count += 1;
        }
        return count;
    }
};

const testing = std.testing;

fn testStore(seed: u64, cfg: Config) !Store {
    return Store.init(testing.allocator, seed, .{ .ids = procgen.test_ids }, cfg);
}

test "park, fetch, replace and unpark" {
    var s = try testStore(5, .{ .parked_bytes = 2 << 20, .max_parked_chunks = 16 });
    defer s.deinit();
    const a = try testing.allocator.create(chunk.Cells);
    defer testing.allocator.destroy(a);
    const b = try testing.allocator.create(chunk.Cells);
    defer testing.allocator.destroy(b);
    const c: chunk.Coord = .{ .x = -1, .y = 2 };

    try testing.expectEqual(Source.generated, try s.fetch(c, a));
    const free0 = s.free_count;
    a[1234] = 0x0101_0203; // an edit (non-air, so lossless)
    try s.park(c, a);
    try testing.expect(s.isParked(c));
    try testing.expectEqual(Source.parked, try s.fetch(c, b));
    try testing.expectEqualSlices(u32, a, b);

    // Replace with incompressible data: chain grows, still round-trips.
    var prng = std.Random.DefaultPrng.init(3);
    for (a) |*v| v.* = prng.random().int(u32) | 1;
    try s.park(c, a);
    try testing.expectEqual(free0 - max_blocks_per_chunk, s.free_count);
    _ = try s.fetch(c, b);
    try testing.expectEqualSlices(u32, a, b);

    s.unpark(c);
    try testing.expect(!s.isParked(c));
    try testing.expectEqual(free0, s.free_count);
    try testing.expectEqual(Source.generated, try s.fetch(c, b));
}

test "pool limits are reported, not exceeded" {
    var s = try testStore(5, .{ .parked_bytes = max_blocks_per_chunk * block_size, .max_parked_chunks = 2 });
    defer s.deinit();
    const a = try testing.allocator.create(chunk.Cells);
    defer testing.allocator.destroy(a);
    @memset(a, 0); // air: compresses to one run
    try s.park(.{ .x = 0, .y = 0 }, a);
    try s.park(.{ .x = 1, .y = 0 }, a);
    try testing.expectError(error.TooManyParkedChunks, s.park(.{ .x = 2, .y = 0 }, a));
    try testing.expect(!s.canPark(.{ .x = 2, .y = 0 }));
    var prng = std.Random.DefaultPrng.init(4);
    for (a) |*v| v.* = prng.random().int(u32) | 1;
    try testing.expectError(error.ParkedPoolFull, s.park(.{ .x = 1, .y = 0 }, a));
    // Failed park leaves the old copy intact.
    _ = try s.fetch(.{ .x = 1, .y = 0 }, a);
    for (a) |v| try testing.expectEqual(@as(u8, 0), @as(u8, @truncate(v)));
    // Many replace cycles do not leak blocks or map slots.
    @memset(a, 0);
    for (0..1000) |i| {
        const c: chunk.Coord = .{ .x = @intCast(i % 2), .y = 0 };
        s.unpark(c);
        try s.park(c, a);
    }
    try testing.expectEqual(@as(u32, 2), s.parkedCount());
}

test "save and load round-trip" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;
    const a = try testing.allocator.create(chunk.Cells);
    defer testing.allocator.destroy(a);
    const b = try testing.allocator.create(chunk.Cells);
    defer testing.allocator.destroy(b);
    const coords = [_]chunk.Coord{ .{ .x = 0, .y = 1 }, .{ .x = -7, .y = 3 }, .{ .x = 123456, .y = -2 } };
    {
        var s = try testStore(0xdead_beef_1234, .{ .parked_bytes = 4 << 20, .max_parked_chunks = 16 });
        defer s.deinit();
        for (coords, 0..) |c, k| {
            _ = try s.fetch(c, a);
            for (0..200) |i| a[i * 300 + k] = procgen.test_ids.wood;
            try s.park(c, a);
        }
        try s.save(io, tmp.dir);
    }
    const h = try Store.readHeader(io, tmp.dir, testing.allocator);
    try testing.expectEqual(@as(u64, 0xdead_beef_1234), h.seed);
    try testing.expectEqual(save_version, h.version);
    var s = try testStore(h.seed, .{ .parked_bytes = 4 << 20, .max_parked_chunks = 16 });
    defer s.deinit();
    try testing.expectEqual(@as(u32, 3), try s.load(io, tmp.dir));
    var ref = try testStore(h.seed, .{ .parked_bytes = 1 << 20, .max_parked_chunks = 1 });
    defer ref.deinit();
    for (coords, 0..) |c, k| {
        try testing.expectEqual(Source.parked, try s.fetch(c, b));
        _ = try ref.fetch(c, a);
        for (0..200) |i| a[i * 300 + k] = procgen.test_ids.wood;
        for (a, b, 0..) |x, y, i| try testing.expectEqual(chunk.normalized(c, @intCast(i), x), y);
    }
    // An unmodified chunk is not in the save and regenerates identically.
    try testing.expectEqual(Source.generated, try s.fetch(.{ .x = 1, .y = 1 }, b));
}
