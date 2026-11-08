//! `--world`: the endless procedural world streamed through the 2048²
//! window (docs/decisions/60-stream-gpu-sink.md, 62-stream-prefetch.md,
//! 63-stream-world-mode.md).
//!
//! Owns the chunk store, the background generator and the streaming state,
//! wires them to the GPU sink in `Pipeline.stream`, and handles save/load.
//! Both the windowed app and the headless runner drive it the same way:
//! `tick(camera_center)` once per simulation tick, before `Engine.frame`.
//!
//! Gameplay API (world coordinates are unbounded i32 cells; the GPU window
//! holds world mod 2048):
//!   - `worldToWindow(x, y)` / `windowToWorld(wx, wy)`
//!   - `isResident(x, y)`: the chunk holding cell (x, y) is on the GPU now
//!   - `markDirty(x, y)`: force a chunk to be saved (CPU-side edits)
//!   - `save()`: flush dirty resident chunks and write the save directory
const std = @import("std");
const Io = std.Io;
const world = @import("world");
const Engine = @import("engine.zig").Engine;
const materials = @import("sim/materials.zig");
const Stream = @import("sim/stream.zig").Stream;

const chunk = world.chunk;
const window = world.window;
const procgen = world.procgen;
const Store = world.store.Store;
const Streaming = world.streaming.Streaming;
const Prefetcher = world.prefetch.Prefetcher;

const log = std.log.scoped(.world);

pub const Options = struct {
    seed: u64 = 1,
    /// Save directory: loaded if it holds a save (its seed wins), created
    /// otherwise; written by `save`.
    save_dir: ?[]const u8 = null,
    /// Slots streamed per tick once their chunk is ready.
    ops_per_tick: u32 = 2,
    workers: u32 = 0,
};

/// Builds procgen's ids from the loaded material table by name. Missing
/// names fall back to stone (logged once, listing all of them); lava is
/// then kept at ambient temperature (procgen guards on aliasing).
pub fn materialIds(lib: *const materials.Library) procgen.MaterialIds {
    const stone = lib.id("stone") orelse 1;
    var ids: procgen.MaterialIds = undefined;
    var missing_buf: [256]u8 = undefined;
    var missing: Io.Writer = .fixed(&missing_buf);
    var n_missing: u32 = 0;
    inline for (@typeInfo(procgen.MaterialIds).@"struct".field_names) |name| {
        @field(ids, name) = lib.id(name) orelse blk: {
            missing.print(" {s}", .{name}) catch {};
            n_missing += 1;
            break :blk stone;
        };
    }
    if (n_missing > 0 and !@import("builtin").is_test) log.warn("{d} procgen materials missing from the table, using stone:{s}", .{ n_missing, missing.buffered() });
    return ids;
}

pub const TickStats = struct {
    ticks: u64 = 0,
    sum_ns: u64 = 0,
    max_ns: u64 = 0,
    /// Ticks over 1 ms of main-thread streaming time.
    over_1ms: u64 = 0,
    /// Histogram in 50 µs buckets up to 5 ms, for percentiles.
    hist: [101]u32 = @splat(0),

    fn add(s: *TickStats, ns: u64) void {
        s.ticks += 1;
        s.sum_ns += ns;
        s.max_ns = @max(s.max_ns, ns);
        if (ns > 1_000_000) s.over_1ms += 1;
        s.hist[@min(ns / 50_000, s.hist.len - 1)] += 1;
    }

    pub fn meanMs(s: *const TickStats) f64 {
        return if (s.ticks == 0) 0 else @as(f64, @floatFromInt(s.sum_ns)) / @as(f64, @floatFromInt(s.ticks)) / 1e6;
    }

    /// Upper bound of the bucket holding percentile `p` (0..1), ms.
    pub fn percentileMs(s: *const TickStats, p: f64) f64 {
        const target: u64 = @intFromFloat(@ceil(p * @as(f64, @floatFromInt(s.ticks))));
        var acc: u64 = 0;
        for (s.hist, 0..) |h, i| {
            acc += h;
            if (acc >= target) return @as(f64, @floatFromInt(i + 1)) * 0.05;
        }
        return @as(f64, @floatFromInt(s.max_ns)) / 1e6;
    }
};

pub const Session = struct {
    gpa: std.mem.Allocator,
    io: Io,
    engine: *Engine,
    seed: u64,
    ids: procgen.MaterialIds,
    store: Store,
    prefetch: *Prefetcher,
    st: Streaming,
    save_path: ?[]const u8,
    timing: TickStats = .{},
    last_tick_ns: u64 = 0,

    /// In place. Loads the window around `cam` (default: `spawn`) blocking,
    /// with every worker generating in parallel.
    pub fn init(self: *Session, gpa: std.mem.Allocator, io: Io, engine: *Engine, lib: *const materials.Library, opts: Options, cam: ?[2]i32) !void {
        self.gpa = gpa;
        self.io = io;
        self.engine = engine;
        self.ids = materialIds(lib);
        self.save_path = opts.save_dir;
        self.timing = .{};
        self.last_tick_ns = 0;
        self.seed = opts.seed;

        var save_dir: ?Io.Dir = null;
        defer if (save_dir) |d| d.close(io);
        if (opts.save_dir) |path| {
            save_dir = try Io.Dir.cwd().createDirPathOpen(io, path, .{ .open_options = .{ .iterate = true } });
            if (Store.readHeader(io, save_dir.?, gpa)) |h| {
                self.seed = h.seed;
                log.info("loading save {s} (seed {d})", .{ path, h.seed });
            } else |err| switch (err) {
                error.FileNotFound => {
                    save_dir.?.close(io);
                    save_dir = null;
                    log.info("new save {s} (seed {d})", .{ path, self.seed });
                },
                else => return err,
            }
        }

        const params: procgen.Params = .{ .ids = self.ids };
        self.store = try Store.init(gpa, self.seed, params, .{});
        errdefer self.store.deinit();
        if (save_dir) |d| {
            const n = try self.store.load(io, d);
            log.info("loaded {d} modified chunks", .{n});
        }
        self.prefetch = try Prefetcher.create(gpa, io, self.seed, params, .{ .workers = opts.workers });
        errdefer self.prefetch.destroy();

        const stream = &engine.pipeline.stream;
        try stream.enable(io, engine.sim_timeline, &engine.sim_value);
        const c = cam orelse self.spawn();
        self.st = try Streaming.init(gpa, &self.store, stream.sink(), .{
            .ops_per_tick = opts.ops_per_tick,
            .batch_evict = true,
        }, c[0], c[1]);
        errdefer self.st.deinit(gpa);
        self.st.attachPrefetcher(self.prefetch);
        self.st.cam = c;
        const t0 = Io.Timestamp.now(io, .awake);
        try self.st.loadAll();
        self.updateSeams();
        log.info("window loaded around {d},{d} in {d:.1} ms ({d} workers)", .{
            c[0], c[1], @as(f64, @floatFromInt(t0.untilNow(io, .awake).nanoseconds)) / 1e6, self.prefetch.workerCount(),
        });
    }

    pub fn deinit(self: *Session) void {
        self.st.deinit(self.gpa);
        self.prefetch.destroy();
        self.store.deinit();
    }

    /// Camera center at startup: world x = 0, a little above the surface.
    pub fn spawn(self: *const Session) [2]i32 {
        return .{ 0, self.store.gen.surfaceAt(0) - 40 };
    }

    /// One streaming step for the camera centered at world cell `cam`.
    /// Call once per simulation tick, before the tick is recorded.
    pub fn tick(self: *Session, cam: [2]i32) !void {
        const t0 = Io.Timestamp.now(self.io, .awake);
        _ = try self.st.tick(cam[0], cam[1]);
        self.updateSeams();
        const ns: u64 = @intCast(t0.untilNow(self.io, .awake).nanoseconds);
        self.last_tick_ns = ns;
        self.timing.add(ns);
    }

    /// The window's seams for the GPU (docs/decisions/64-stream-window-seams.md):
    /// left of / above the origin slot, and during a move on both sides of
    /// the row or column being swapped.
    fn updateSeams(self: *Session) void {
        const o = window.slotOf(self.st.origin);
        var sx: [2]?u32 = .{ o.x, null };
        var sy: [2]?u32 = .{ o.y, null };
        if (self.st.move) |m| switch (m.axis) {
            .x => sx = .{ m.slots[0].x, (m.slots[0].x + 1) % window.chunks },
            .y => sy = .{ m.slots[0].y, (m.slots[0].y + 1) % window.chunks },
        };
        self.engine.pipeline.stream.setSeams(sx, sy);
        // The air field's open edge follows the window's origin seam
        // (docs/decisions/71-air-boundaries.md): lattice cells of 2x2 px.
        // TODO(integrate: Air.resetRegion): newly streamed-in chunks keep
        // the air state of the chunk they replaced until it relaxes; a reset
        // of their lattice cells to ambient at upload is not implemented.
        const lattice_per_chunk: i32 = @intCast(chunk.size / 2);
        self.engine.pipeline.air.seam = .{ @as(i32, @intCast(o.x)) * lattice_per_chunk, @as(i32, @intCast(o.y)) * lattice_per_chunk };
    }

    /// Parks every dirty resident chunk and writes the save directory (if
    /// one was given). Returns the number of chunks in the save.
    pub fn save(self: *Session) !u32 {
        const path = self.save_path orelse return 0;
        try self.engine.finish();
        try self.st.flush();
        var dir = try Io.Dir.cwd().createDirPathOpen(self.io, path, .{});
        defer dir.close(self.io);
        try self.store.save(self.io, dir);
        log.info("saved {d} modified chunks ({d} KiB) to {s}", .{ self.store.parkedCount(), self.store.parkedBytes() / 1024, path });
        return self.store.parkedCount();
    }

    // ---- gameplay helpers ----------------------------------------------------

    pub fn worldToWindow(x: i32, y: i32) [2]u32 {
        const w = window.toWindow(x, y);
        return .{ w[0], w[1] };
    }

    /// The world cell currently held at window cell (wx, wy), null while its
    /// slot is being swapped.
    pub fn windowToWorld(self: *const Session, wx: u32, wy: u32) ?[2]i32 {
        return self.st.worldOfWindow(wx, wy);
    }

    pub fn isResident(self: *const Session, x: i32, y: i32) bool {
        return self.st.isResident(chunk.coordOfCell(x, y));
    }

    pub fn markDirty(self: *Session, x: i32, y: i32) void {
        self.st.markDirty(x, y);
    }

    pub fn hudLines(self: *const Session, hud: anytype) void {
        const s = self.st.stats;
        const ss = self.engine.pipeline.stream.stats;
        hud.print("world seed {d}  window origin chunk {d},{d}{s}  stream {d:.3} ms/tick (mean {d:.3})", .{
            self.seed,                                      self.st.origin.x,                                 self.st.origin.y,
            if (self.st.move != null) "  [moving]" else "", @as(f64, @floatFromInt(self.last_tick_ns)) / 1e6, self.timing.meanMs(),
        });
        hud.print("chunks: generated {d}  from save/park {d}  parked {d} ({d} KiB)  downloads {d}  syncs {d}  stalls {d}", .{
            s.generated, s.decompressed, self.store.parkedCount(), self.store.parkedBytes() / 1024, ss.downloads, ss.syncs, s.stalls,
        });
    }

    pub fn report(self: *const Session) void {
        const t = &self.timing;
        const s = self.st.stats;
        const ss = self.engine.pipeline.stream.stats;
        const ps = self.prefetch.stats;
        std.debug.print("world streaming: {d} ticks, main thread mean {d:.4} ms, p99 {d:.2} ms, max {d:.3} ms, ticks > 1 ms: {d}\n", .{
            t.ticks, t.meanMs(), t.percentileMs(0.99), @as(f64, @floatFromInt(t.max_ns)) / 1e6, t.over_1ms,
        });
        std.debug.print("  moves {d}, uploads {d}, prefetched {d}, decompressed {d}, stalls {d}, parked {d} (now {d}, {d} KiB)\n", .{
            s.moves, s.uploads, s.prefetched, s.decompressed, s.stalls, s.parked, self.store.parkedCount(), self.store.parkedBytes() / 1024,
        });
        std.debug.print("  gpu sink: {d} syncs, {d} downloads in {d} copies, {d:.2} ms in syncs; workers {d}: {d} chunks, {d:.2} ms/chunk, {d} evicted, {d} dropped\n", .{
            ss.syncs,                                                                                                       ss.downloads,                ss.download_copies,
            @as(f64, @floatFromInt(ss.sync_ns)) / 1e6,                                                                      self.prefetch.workerCount(), ps.generated,
            if (ps.generated == 0) 0 else @as(f64, @floatFromInt(ps.gen_ns)) / @as(f64, @floatFromInt(ps.generated)) / 1e6, ps.evicted,                  ps.dropped,
        });
    }
};

/// `--cam-path "X0,Y0 -> X1,Y1 over N ticks"`: camera center moving
/// linearly, then holding at the end.
pub const CamPath = struct {
    from: [2]i32,
    to: [2]i32,
    ticks: u32,

    pub fn parse(text: []const u8) !CamPath {
        var it = std.mem.tokenizeAny(u8, text, " ");
        const a = try parsePoint(it.next() orelse return error.BadCamPath);
        if (!std.mem.eql(u8, it.next() orelse "", "->")) return error.BadCamPath;
        const b = try parsePoint(it.next() orelse return error.BadCamPath);
        if (!std.mem.eql(u8, it.next() orelse "", "over")) return error.BadCamPath;
        const n = try std.fmt.parseInt(u32, it.next() orelse return error.BadCamPath, 10);
        return .{ .from = a, .to = b, .ticks = @max(n, 1) };
    }

    fn parsePoint(s: []const u8) ![2]i32 {
        var it = std.mem.splitScalar(u8, s, ',');
        const x = try std.fmt.parseInt(i32, it.next() orelse return error.BadCamPath, 10);
        const y = try std.fmt.parseInt(i32, it.next() orelse return error.BadCamPath, 10);
        return .{ x, y };
    }

    pub fn at(p: CamPath, tick: u64) [2]i32 {
        const t: i64 = @intCast(@min(tick, p.ticks));
        const n: i64 = p.ticks;
        var out: [2]i32 = undefined;
        for (0..2) |k| out[k] = @intCast(p.from[k] + @divTrunc((@as(i64, p.to[k]) - p.from[k]) * t, n));
        return out;
    }
};

test "cam path parses and interpolates" {
    const p = try CamPath.parse("0,0 -> 4000,1500 over 600 ticks");
    try std.testing.expectEqual([2]i32{ 0, 0 }, p.at(0));
    try std.testing.expectEqual([2]i32{ 2000, 750 }, p.at(300));
    try std.testing.expectEqual([2]i32{ 4000, 1500 }, p.at(600));
    try std.testing.expectEqual([2]i32{ 4000, 1500 }, p.at(900));
    try std.testing.expectError(error.BadCamPath, CamPath.parse("0,0 4000,1500"));
}

test "material ids fall back to stone" {
    var lib = try materials.Library.builtin(std.testing.allocator);
    defer lib.deinit(std.testing.allocator);
    const ids = materialIds(&lib);
    try std.testing.expectEqual(@as(u8, 0), ids.air);
    try std.testing.expectEqual(lib.id("sand").?, ids.sand);
    try std.testing.expectEqual(lib.id("water").?, ids.water);
    try std.testing.expectEqual(lib.id("stone").?, ids.lava); // no lava in the builtin set
}

// ---------------------------------------------------------------------------
// Headless driver and GPU self-test.
// ---------------------------------------------------------------------------

const builtin = @import("builtin");
const Cli = @import("main.zig").Cli;
const View = @import("render/world.zig").View;
const commands = @import("sim/commands.zig");
const Profile = @import("profile.zig").Profile;
const app = @import("app.zig");
const sim_cell = @import("sim/cell.zig");

fn parseEdit(text: []const u8, lib: *const materials.Library) !struct { x: i32, y: i32, r: i32, m: u8 } {
    var it = std.mem.splitScalar(u8, text, ',');
    const x = try std.fmt.parseInt(i32, it.next() orelse return error.BadEdit, 10);
    const y = try std.fmt.parseInt(i32, it.next() orelse return error.BadEdit, 10);
    const r = try std.fmt.parseInt(i32, it.next() orelse return error.BadEdit, 10);
    const name = it.next() orelse return error.BadEdit;
    const m = lib.id(name) orelse return error.UnknownMaterial;
    return .{ .x = x, .y = y, .r = r, .m = m };
}

fn initEngine(gpa: std.mem.Allocator, cli: Cli, lib: *const materials.Library) !*Engine {
    const engine = try gpa.create(Engine);
    errdefer gpa.destroy(engine);
    try engine.init(gpa, .{
        .library = lib,
        .validation = cli.validation orelse (builtin.mode == .debug),
        .pipeline = .{ .sleep = cli.sleep },
    });
    return engine;
}

/// `--world --headless`: stream along `--cam-path` (or sit at the spawn),
/// optionally edit, probe, save and screenshot.
pub fn runHeadless(gpa: std.mem.Allocator, io: Io, cli: Cli, lib: *const materials.Library) !u8 {
    const engine = try initEngine(gpa, cli, lib);
    defer gpa.destroy(engine);
    defer engine.deinit();
    var profile: Profile = .{};
    engine.profile = &profile;
    if (cli.world_selftest) return selftest(gpa, io, engine, lib, cli);

    const session = try gpa.create(Session);
    defer gpa.destroy(session);
    const start_cam = if (cli.cam_path) |p| p.at(0) else cli.center;
    try session.init(gpa, io, engine, lib, .{ .seed = cli.seed, .save_dir = cli.save_dir, .ops_per_tick = cli.stream_ops }, start_cam);
    defer session.deinit();

    var edit: commands.CommandList = .{};
    edit.begin(0);
    if (cli.world_edit) |text| {
        const e = try parseEdit(text, lib);
        edit.fillCircle(e.x, e.y, e.r, e.m, .{});
        session.markDirty(e.x, e.y); // also caught by the GPU bits; belt and braces
    }

    var cam = start_cam orelse session.spawn();
    const t0 = Io.Timestamp.now(io, .awake);
    // Paced at 60 ticks/s unless --no-vsync, so the camera moves at its
    // real speed relative to the background generator.
    const paced = cli.vsync;
    const tick_ns: i96 = std.time.ns_per_s / 60;
    for (0..cli.ticks) |t| {
        if (cli.cam_path) |p| cam = p.at(t);
        try session.tick(cam);
        try engine.frame(1, .{ .scene = .empty, .extra = if (t == 0) edit.slice() else &.{} }, null);
        if (paced) {
            const due = tick_ns * @as(i96, @intCast(t + 1));
            const left = due - t0.untilNow(io, .awake).nanoseconds;
            if (left > 0) try Io.Clock.Duration.sleep(.{ .raw = .fromNanoseconds(left), .clock = .awake }, io);
        }
    }
    try engine.finish();
    const elapsed_ms = @as(f64, @floatFromInt(t0.untilNow(io, .awake).nanoseconds)) / 1e6;
    std.debug.print("headless world: {d} ticks in {d:.1} ms wall ({d:.3} ms/tick), camera ends at {d},{d}\n", .{
        cli.ticks, elapsed_ms, elapsed_ms / @as(f64, @floatFromInt(@max(cli.ticks, 1))), cam[0], cam[1],
    });
    session.report();
    for (0..engine.names.count) |i| {
        std.debug.print("  {s:<10} {d:8.4} ms/tick (max {d:.4})\n", .{ engine.names.get(i), profile.mean(i), profile.max[i] });
    }

    if (cli.probe) |p| {
        const cells = try gpa.alloc(u32, sim_cell.world_size * sim_cell.world_size);
        defer gpa.free(cells);
        try engine.readbackCells(cells);
        const w = Session.worldToWindow(p[0], p[1]);
        const v = cells[w[1] * sim_cell.world_size + w[0]];
        const m: u8 = @intCast(sim_cell.material(v));
        std.debug.print("probe {d},{d} (window {d},{d}, resident {}): cell 0x{x:0>8} material {d} ({s})\n", .{
            p[0], p[1], w[0], w[1], session.isResident(p[0], p[1]), v, m, lib.name(m),
        });
    }
    if (cli.save_dir != null) _ = try session.save();
    if (cli.screenshot) |path| try engine.screenshot(io, path, cli.crop);
    if (cli.view_screenshot) |path| {
        const view: View = .{
            .scale = cli.zoom,
            .camera_x = cam[0] - @as(i32, @intCast(cli.width / 2 / cli.zoom)),
            .camera_y = cam[1] - @as(i32, @intCast(cli.height / 2 / cli.zoom)),
        };
        engine.hud.clear();
        app.fillHud(engine, &profile, .{
            .frame_ms = elapsed_ms / @as(f64, @floatFromInt(@max(cli.ticks, 1))),
            .material = "sand",
            .radius = 8,
            .view = view,
            .cursor = cam,
            .material_count = app.palette.len,
            .world = session,
        });
        try engine.screenshotView(io, path, view, cli.width, cli.height);
    }
    return 0;
}

fn check(ok: bool, comptime what: []const u8, args: anytype) !void {
    if (ok) {
        std.debug.print("  ok   " ++ what ++ "\n", args);
    } else {
        std.debug.print("  FAIL " ++ what ++ "\n", args);
        return error.SelfTestFailed;
    }
}

/// Upload → edit via command → takeDirty → download → save → reload, all
/// through the real GPU sink.
fn selftest(gpa: std.mem.Allocator, io: Io, engine: *Engine, lib: *const materials.Library, cli: Cli) !u8 {
    const save_path = cli.save_dir orelse ".zig-cache/stream-selftest";
    Io.Dir.cwd().deleteTree(io, save_path) catch {};
    const session = try gpa.create(Session);
    defer gpa.destroy(session);
    try session.init(gpa, io, engine, lib, .{ .seed = cli.seed, .save_dir = save_path }, null);
    const ids = lib.ids();
    defer session.deinit();
    const sink = engine.pipeline.stream.sink();
    std.debug.print("stream self-test (seed {d}, save {s})\n", .{ session.seed, save_path });

    const cam = session.spawn();
    for (0..20) |_| {
        try session.tick(cam);
        try engine.frame(1, .{ .scene = .empty }, null);
    }
    // Clear whatever settling dirtied.
    for (0..window.slot_count) |i| {
        const s = window.Slot.fromIndex(@intCast(i));
        _ = sink.takeDirty(s.x, s.y);
    }
    // A sky chunk above the spawn: nothing moves there.
    const sky = chunk.coordOfCell(cam[0], cam[1] - 512);
    try check(session.st.isResident(sky), "sky chunk {d},{d} resident", .{ sky.x, sky.y });
    const o = sky.originCell();
    const ex = o[0] + 128;
    const ey = o[1] + 128;
    const slot = window.slotOf(sky);
    try check(!sink.takeDirty(slot.x, slot.y), "untouched sky chunk is clean", .{});

    // 1. Edit with a command.
    var list: commands.CommandList = .{};
    list.begin(0);
    list.fillCircle(ex, ey, 10, ids.stone, .{});
    try engine.frame(1, .{ .scene = .empty, .extra = list.slice() }, null);
    try engine.frame(1, .{ .scene = .empty }, null);
    try check(sink.takeDirty(slot.x, slot.y), "command edit sets the slot's dirty bit", .{});
    try check(!sink.takeDirty(slot.x, slot.y), "takeDirty clears it", .{});
    const cells = try gpa.create(chunk.Cells);
    defer gpa.destroy(cells);
    sink.downloadChunk(slot.x, slot.y, cells);
    const center = cells[chunk.index(128, 128)];
    try check(world.cell.material(center) == ids.stone, "download has the edit (0x{x:0>8})", .{center});
    try check(world.cell.material(cells[chunk.index(0, 0)]) == ids.air, "download keeps the sky around it", .{});

    // 2. Upload a pattern: not dirty, reads back exactly.
    const pattern = try gpa.create(chunk.Cells);
    defer gpa.destroy(pattern);
    pattern.* = cells.*;
    for (0..chunk.size) |x| pattern[chunk.index(@intCast(x), 40)] = world.cell.pack(ids.stone, 8, 200, 0, @truncate(x));
    sink.uploadChunk(slot.x, slot.y, pattern);
    for (0..3) |_| try engine.frame(1, .{ .scene = .empty }, null);
    try check(!sink.takeDirty(slot.x, slot.y), "an upload is not a change", .{});
    sink.downloadChunk(slot.x, slot.y, cells);
    try check(std.mem.eql(u32, cells, pattern), "uploaded chunk reads back bit-exact", .{});

    // 3. Edit again, save, reload in a fresh store.
    list.begin(1);
    list.fillCircle(ex + 40, ey, 6, ids.stone, .{});
    try engine.frame(1, .{ .scene = .empty, .extra = list.slice() }, null);
    try engine.frame(1, .{ .scene = .empty }, null);
    session.st.slots[slot.index()].cpu_dirty = false;
    const saved = try session.save();
    try check(saved >= 1, "save wrote {d} modified chunk(s)", .{saved});
    sink.downloadChunk(slot.x, slot.y, cells); // what the GPU holds now
    var dir = try Io.Dir.cwd().openDir(io, save_path, .{ .iterate = true });
    defer dir.close(io);
    const h = try Store.readHeader(io, dir, gpa);
    try check(h.seed == session.seed, "save header seed {d}", .{h.seed});
    var store = try Store.init(gpa, h.seed, .{ .ids = session.ids }, .{ .parked_bytes = 16 << 20, .max_parked_chunks = 256 });
    defer store.deinit();
    const n = try store.load(io, dir);
    try check(n == saved, "reloaded {d} chunks", .{n});
    const back = try gpa.create(chunk.Cells);
    defer gpa.destroy(back);
    try check(try store.fetch(sky, back) == .parked, "edited chunk comes from the save", .{});
    var mismatches: u32 = 0;
    for (cells, back, 0..) |a, b, i| {
        if (chunk.normalized(sky, @intCast(i), a) != b) mismatches += 1;
    }
    try check(mismatches == 0, "reloaded chunk equals the GPU's cells ({d} mismatches)", .{mismatches});
    try check(world.cell.material(back[chunk.index(168, 128)]) == ids.stone, "second edit survived the save", .{});
    std.debug.print("stream self-test passed\n", .{});
    return 0;
}
