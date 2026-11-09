//! Bodies in the world (M7): the CPU orchestration between the Box2D layer
//! (`bodies` module, src/sim/bodies.zig), the grid (through a `TerrainSource`)
//! and the GPU rasterizer (`bodies_gpu.zig`).
//!
//! Per tick, before the GPU records it (`Bodies.tick`, called by the engine):
//!  1. Destruction events: every fill-air circle or rect in this tick's
//!     command list (the eject tool), plus `notifyDestruction` calls. Bodies
//!     overlapping one lose those pixels at once (`splitBody`; beam segments
//!     also weaken their joints) and get a blast impulse. The event is kept
//!     for connectivity until the readback shows its result.
//!  2. Terrain: request the regions around bodies, ready events, beam
//!     placements and anchors from the terrain source, then `prepare`.
//!  3. Connectivity on ready events (bounded regions): loose static islands
//!     become pixel bodies (their cells are extracted on the GPU), tiny ones
//!     rubble.
//!  4. Beam placements, anchor checks, static collision for the region
//!     around bodies, fluid forces, `step`, impact breakup, joint-break
//!     sparks, torus recentering.
//!  5. The GPU region: changed bodies' instances, last tick's instances of
//!     moved or dead bodies (clear), extractions, point writes, new bitmaps.
//!
//! Bodies are off unless `pipeline.Config.bodies` is set; when off nothing
//! here runs and no pass touches cells (the determinism scene).
//! Decisions: docs/decisions/90-99.
const std = @import("std");
const bodies = @import("bodies");
const gpu = @import("../gpu/gpu.zig");
const cell = @import("cell.zig");
const commands = @import("commands.zig");
const materials = @import("materials.zig");
const bm = @import("bodies_materials.zig");
const ts = @import("terrain_source.zig");
const bgpu = @import("bodies_gpu.zig");
const pipeline_mod = @import("pipeline.zig");
const Frame = pipeline_mod.Frame;

const Allocator = std.mem.Allocator;
const BodyHandle = bodies.BodyHandle;
const BeamHandle = bodies.BeamHandle;
const Region = ts.Region;
const none = bm.none;
/// Explosion impulse on bodies: radius multiplier of the charge radius and
/// impulse per body pixel per unit overpressure (standard explosion 1.5:
/// a concrete crate gets about 170 px/s, wood about 800).
const blast_reach: f32 = 4;
const blast_impulse: f32 = 40;

const log = std.log.scoped(.bodies);

/// A place where the world lost material this tick: eject and fill-air
/// commands, explosions (`notifyDestruction`). Feeds body cuts, blast
/// impulses and the connectivity pass.
pub const DestructionEvent = struct {
    x: i32,
    y: i32,
    radius: i32,
    /// Exact footprint of a fill-rect command, [x0, x1) x [y0, y1).
    rect: ?[4]i32 = null,
    /// Blast strength (impulse per body pixel at the center); null = from
    /// the radius (`Config.blast_per_radius`).
    strength: ?f32 = null,
    tick: u32 = 0,
    /// Cluster this event joined in the current tick's `buildClusters`
    /// (`no_cluster`: not ready, or no cluster slot left).
    cluster: u16 = no_cluster,

    pub const no_cluster = std.math.maxInt(u16);

    /// Same test as commands.comp applies to the pixel containing (px, py).
    pub fn contains(e: DestructionEvent, px: f32, py: f32) bool {
        const ix: i32 = @intFromFloat(@floor(px));
        const iy: i32 = @intFromFloat(@floor(py));
        if (e.rect) |r| return ix >= r[0] and ix < r[2] and iy >= r[1] and iy < r[3];
        const dx = ix - e.x;
        const dy = iy - e.y;
        return dx * dx + dy * dy <= e.radius * e.radius;
    }

    pub fn bounds(e: DestructionEvent) Region {
        if (e.rect) |r| return .{ .x = r[0], .y = r[1], .w = @intCast(@max(r[2] - r[0], 1)), .h = @intCast(@max(r[3] - r[1], 1)) };
        return .{ .x = e.x - e.radius, .y = e.y - e.radius, .w = @intCast(2 * e.radius + 1), .h = @intCast(2 * e.radius + 1) };
    }
};

/// What a fluid does to one body this tick (see `BodyWorld.applyFluid`).
pub const FluidSample = struct {
    velocity: bodies.Vec2 = .{ .x = 0, .y = 0 },
    /// Linear drag toward `velocity`, kg/s.
    drag: f32 = 0,
    /// kg px^2/s.
    angular_drag: f32 = 0,
    /// Force, kg px/s^2 (buoyancy is negative y).
    buoyancy: bodies.Vec2 = .{ .x = 0, .y = 0 },
};

/// Entry point for the air field and the liquid solver: `sample` is called
/// once per live body per tick, before the step; null = no fluid force.
pub const FluidSampler = struct {
    ctx: ?*anyopaque = null,
    sample: *const fn (ctx: ?*anyopaque, sim: *BodySim, body: bodies.RasterBody) ?FluidSample,
};

pub const Config = struct {
    world: bodies.Config = .{
        .max_bodies = 4096,
        .max_body_pixels = 1 << 22,
        .max_bitmap_pixels = 256 * 256,
        .max_beams = 256,
        .max_beam_segments = 64,
        .static_max_w = 2048,
        .static_max_h = 2048,
    },
    /// Side of the square read around a destruction event for connectivity.
    connectivity_region: u32 = 256,
    /// Events whose regions overlap are analyzed together up to this side
    /// (448^2: about 0.8 ms in ReleaseFast on the dev machine).
    max_connectivity_region: u32 = 448,
    /// Connectivity time per tick; clusters past it wait for the next tick.
    connectivity_budget_ms: f64 = 1.0,
    /// Loose components smaller than this become rubble, not bodies.
    min_body_pixels: u32 = 4,
    /// Collision region around each body beyond its bounding circle, px.
    collision_margin: f32 = 32,
    /// Blast strength per command radius px (impulse per body pixel).
    blast_per_radius: f32 = 1.5,
    /// Blast reach as a multiple of the command radius.
    blast_reach: f32 = 1.5,
    /// Broken bodies smaller than this dissolve entirely into rubble.
    dissolve_pixels: u32 = 150,
    /// Impacts this many times over the threshold dissolve the whole body.
    dissolve_severity: f32 = 4,
    /// Pieces of a broken body smaller than this dissolve into rubble.
    min_piece_pixels: u32 = 60,
    /// Speed (px/s per unit of severity) the pieces of a broken body get
    /// away from the impact point.
    shatter_kick: f32 = 35,
    sparks_per_break: u32 = 12,
    /// Bodies are kept within half a world of this point (torus frame).
    center_x: f32 = cell.world_size / 2,
    center_y: f32 = cell.world_size / 2,
    /// Terrain around sleeping bodies is re-read every this many ticks.
    sleeping_refresh: u32 = 4,
    max_events: u32 = 512,
    /// A destruction event the connectivity pass has not finished this many
    /// ticks after the readback caught up with it is dropped (decision 143):
    /// a backlog of events can delay real ones by at most this much.
    max_event_age: u32 = 60,
    /// An erase whose footprint spans this many pixels in x or y (the whole
    /// window) is a build, not a destruction: no event (decision 143).
    build_extent: u32 = cell.world_size,
    max_beam_requests: u32 = 64,
    max_pending: u32 = 256,
    pending_bytes: u32 = 1 << 20,
};

pub const TickInfo = struct { tick: u32, slot: u32, tick_in_frame: u32 };

pub const TickStats = struct {
    cpu_ms: f64 = 0,
    readback_ms: f64 = 0,
    connectivity_ms: f64 = 0,
    static_ms: f64 = 0,
    fluid_ms: f64 = 0,
    step_ms: f64 = 0,
    events_ms: f64 = 0,
    upload_ms: f64 = 0,
    bodies: u32 = 0,
    rastered: u32 = 0,
    cleared: u32 = 0,
    extracts: u32 = 0,
    uploads: u32 = 0,
    upload_bytes: u32 = 0,
    tiles_read: u32 = 0,
    points: u32 = 0,
    dropped: u32 = 0,
};

pub const Totals = struct {
    ticks: u64 = 0,
    cpu_ms: f64 = 0,
    cpu_ms_max: f64 = 0,
    readback_ms: f64 = 0,
    /// Sums of the per-phase TickStats times.
    static_ms: f64 = 0,
    fluid_ms: f64 = 0,
    step_ms: f64 = 0,
    events_ms: f64 = 0,
    upload_ms: f64 = 0,
    connectivity_ms: f64 = 0,
    connectivity_ms_max: f64 = 0,
    connectivity_runs: u32 = 0,
    events: u32 = 0,
    extracted: u32 = 0,
    rubble_components: u32 = 0,
    broken: u32 = 0,
    dissolved: u32 = 0,
    joint_breaks: u32 = 0,
    anchors_released: u32 = 0,
    beams_placed: u32 = 0,
    beams_rejected: u32 = 0,
    sparks: u32 = 0,
    rubble_points: u32 = 0,
    dropped: u32 = 0,
    /// Destruction events dropped unprocessed after `max_event_age`.
    expired: u32 = 0,
};

const BeamRequest = struct { x0: f32, y0: f32, x1: f32, y1: f32, material: u8, thickness: u16 };

/// What the GPU last rasterized for a body slot, and which bitmap the atlas
/// holds for it.
const Placement = struct {
    valid: bool = false,
    gen: u32 = 0,
    version: u32 = 0,
    inst: bgpu.BodyInstance = undefined,
    up_valid: bool = false,
    up_gen: u32 = 0,
    up_version: u32 = 0,
    up_off: u32 = 0,
    up_len: u32 = 0,
};

/// Loose terrain turned into a body whose cells the readback still shows
/// as static: masked out of collision and connectivity until it catches up.
const Pending = struct { x: i32, y: i32, w: u16, h: u16, off: u32, tick: u32 };

const Extract = struct { handle: BodyHandle, version: u32, x: i32, y: i32, w: u16, h: u16, pending: u32 };

pub const BodySim = struct {
    alloc: Allocator,
    cfg: Config,
    world: bodies.BodyWorld,
    mats: bm.Table,
    terrain: ts.TerrainSource,

    incoming: []DestructionEvent,
    incoming_len: usize = 0,
    events: []DestructionEvent,
    event_len: usize = 0,
    beam_requests: []BeamRequest,
    beam_request_len: usize = 0,
    clusters: [64]Region = undefined,
    cluster_len: usize = 0,

    last: []Placement,
    version: []u32,
    seen: []u32,
    broken_tick: []u32,
    pass: u32 = 0,

    pending: []Pending,
    pending_len: usize = 0,
    pending_px: []u8,
    pending_used: u32 = 0,
    extracts: []Extract,
    extract_len: usize = 0,
    clears: []bgpu.BodyInstance,

    mask: []u8,
    region_mats: []u8,
    conn: []u8,
    split: bodies.SplitScratch,
    bitmap: []u8,
    handles: []BodyHandle,

    prng: std.Random.DefaultPrng,
    center_x: f32,
    center_y: f32,
    fluid_sampler: ?FluidSampler = null,
    writer: ?*bgpu.RegionWriter = null,
    tick_now: u32 = 0,
    stats: TickStats = .{},
    totals: Totals = .{},

    pub fn create(alloc: Allocator, cfg: Config, terrain: ts.TerrainSource) !*BodySim {
        const self = try alloc.create(BodySim);
        errdefer alloc.destroy(self);
        var world = try bodies.BodyWorld.init(alloc, cfg.world);
        errdefer world.deinit();
        const nb = cfg.world.max_bodies;
        const conn_max = cfg.max_connectivity_region * cfg.max_connectivity_region;
        self.* = .{
            .alloc = alloc,
            .cfg = cfg,
            .world = world,
            .mats = .{},
            .terrain = terrain,
            .incoming = try alloc.alloc(DestructionEvent, cfg.max_events),
            .events = try alloc.alloc(DestructionEvent, cfg.max_events),
            .beam_requests = try alloc.alloc(BeamRequest, cfg.max_beam_requests),
            .last = try alloc.alloc(Placement, nb),
            .version = try alloc.alloc(u32, nb),
            .seen = try alloc.alloc(u32, nb),
            .broken_tick = try alloc.alloc(u32, nb),
            .pending = try alloc.alloc(Pending, cfg.max_pending),
            .pending_px = try alloc.alloc(u8, cfg.pending_bytes),
            .extracts = try alloc.alloc(Extract, cfg.max_pending),
            .clears = try alloc.alloc(bgpu.BodyInstance, bgpu.caps.instances),
            .mask = try alloc.alloc(u8, @as(usize, cfg.world.static_max_w) * cfg.world.static_max_h),
            .region_mats = try alloc.alloc(u8, @max(conn_max, cfg.world.max_bitmap_pixels * 2)),
            .conn = try alloc.alloc(u8, conn_max),
            .split = try bodies.SplitScratch.init(alloc, conn_max, 4096),
            .bitmap = try alloc.alloc(u8, cfg.world.max_bitmap_pixels),
            .handles = try alloc.alloc(BodyHandle, nb),
            .prng = std.Random.DefaultPrng.init(0xb0d1e5),
            .center_x = cfg.center_x,
            .center_y = cfg.center_y,
        };
        @memset(self.last, .{});
        @memset(self.version, 0);
        @memset(self.seen, 0);
        @memset(self.broken_tick, std.math.maxInt(u32));
        return self;
    }

    pub fn destroy(self: *BodySim) void {
        const a = self.alloc;
        self.world.deinit();
        a.free(self.incoming);
        a.free(self.events);
        a.free(self.beam_requests);
        a.free(self.last);
        a.free(self.version);
        a.free(self.seen);
        a.free(self.broken_tick);
        a.free(self.pending);
        a.free(self.pending_px);
        a.free(self.extracts);
        a.free(self.clears);
        a.free(self.mask);
        a.free(self.region_mats);
        a.free(self.conn);
        self.split.deinit(a);
        a.free(self.bitmap);
        a.free(self.handles);
        a.destroy(self);
    }

    pub fn setMaterials(self: *BodySim, set: *const materials.MaterialSet, tables: *const materials.Tables) void {
        self.mats = bm.Table.build(set, tables);
        self.mats.apply(&self.world);
    }

    // =====================================================================
    // Gameplay API

    /// A solid square of `material` (default concrete), centered at (x, y).
    pub fn spawnCrate(self: *BodySim, x: f32, y: f32, size: u16, material: ?u8) !BodyHandle {
        return self.spawnBox(x, y, size, size, material orelse self.mats.roles.concrete);
    }

    /// A slab (default stone) w x h, centered at (x, y), falling.
    pub fn dropSlab(self: *BodySim, x: f32, y: f32, w: u16, h: u16, material: ?u8) !BodyHandle {
        return self.spawnBox(x, y, w, h, material orelse self.mats.roles.stone);
    }

    pub fn spawnBox(self: *BodySim, x: f32, y: f32, w: u16, h: u16, material: u8) !BodyHandle {
        const area = @as(usize, w) * h;
        if (area == 0 or area > self.bitmap.len) return error.BitmapTooLarge;
        if (material == none or !self.mats.info[material].static) return error.NotABodyMaterial;
        @memset(self.bitmap[0..area], material);
        return self.world.createPixelBody(.{
            .pixels = self.bitmap[0..area],
            .w = w,
            .h = h,
            .x = x,
            .y = y,
            .origin_x = @as(f32, @floatFromInt(w)) * 0.5,
            .origin_y = @as(f32, @floatFromInt(h)) * 0.5,
        });
    }

    /// Any bitmap body (row-major material ids, 0 = empty).
    pub fn spawnBody(self: *BodySim, desc: bodies.BodyWorld.PixelBodyDesc) !BodyHandle {
        return self.world.createPixelBody(desc);
    }

    /// A beam (default steel, 6 px thick) between two world points, placed
    /// at the next tick once the terrain there has been read. An endpoint
    /// inside static solid is moved to the solid's face and welded there.
    pub fn placeBeam(self: *BodySim, x0: f32, y0: f32, x1: f32, y1: f32, material: ?u8, thickness: u16) void {
        if (self.beam_request_len == self.beam_requests.len) return;
        self.beam_requests[self.beam_request_len] = .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1, .material = material orelse self.mats.roles.steel, .thickness = thickness };
        self.beam_request_len += 1;
    }

    /// Something removed material at (x, y) within radius r (explosions,
    /// spells, reactions). Handled at the start of the next tick like an
    /// eject command: body cuts, blast, connectivity.
    pub fn notifyDestruction(self: *BodySim, x: i32, y: i32, r: i32) void {
        self.notifyEvent(.{ .x = x, .y = y, .radius = r });
    }

    pub fn notifyEvent(self: *BodySim, e: DestructionEvent) void {
        if (self.incoming_len == self.incoming.len) {
            self.totals.dropped += 1;
            return;
        }
        self.incoming[self.incoming_len] = e;
        self.incoming_len += 1;
    }

    /// The body whose bitmap covers world pixel (x, y), if any.
    pub fn bodyAt(self: *const BodySim, x: f32, y: f32) ?BodyHandle {
        var it = self.world.rasterIterator();
        while (it.next()) |rb| {
            const p = self.world.worldToBitmap(rb.handle, x, y) orelse continue;
            if (rb.pixels[@as(usize, p.y) * rb.w + p.x] != 0) return rb.handle;
        }
        return null;
    }

    pub fn bodyCount(self: *const BodySim) usize {
        return self.world.bodyCount();
    }

    pub fn setCenter(self: *BodySim, x: f32, y: f32) void {
        self.center_x = x;
        self.center_y = y;
    }

    // =====================================================================
    // Tick

    pub fn needsTerrain(self: *const BodySim) bool {
        return self.world.bodyCount() > 0 or self.event_len > 0 or self.incoming_len > 0 or self.beam_request_len > 0;
    }

    pub fn tick(self: *BodySim, g: *bgpu.BodiesGpu, list: *const commands.CommandList, info: TickInfo) !void {
        const t0 = nowNs();
        self.stats = .{};
        self.pass +%= 1;
        self.tick_now = info.tick;
        self.extract_len = 0;
        var w = g.beginRegion(info.slot, info.tick_in_frame, info.tick);
        self.writer = &w;
        defer self.writer = null;

        // 1. Destruction events.
        for (list.slice()) |c| {
            const shape = std.enums.fromInt(commands.Kind, c.kind & commands.shape_mask) orelse continue;
            const erase = c.kind >> commands.action_shift == @backingInt(commands.Action.fill) and c.material & 0xff == materials.air;
            switch (shape) {
                .fill_circle => if (erase) self.notifyEvent(.{ .x = c.x0, .y = c.y0, .radius = c.x1 }),
                .fill_rect => if (erase and c.x1 - c.x0 < self.cfg.build_extent and c.y1 - c.y0 < self.cfg.build_extent) {
                    const hw = @divTrunc(c.x1 - c.x0, 2);
                    const hh = @divTrunc(c.y1 - c.y0, 2);
                    self.notifyEvent(.{ .x = c.x0 + hw, .y = c.y0 + hh, .radius = @intFromFloat(@sqrt(@as(f32, @floatFromInt(hw * hw + hh * hh)))), .rect = .{ c.x0, c.y0, c.x1, c.y1 } });
                },
                // Cells fly: cut bodies there, then connectivity.
                .eject => self.notifyEvent(.{ .x = c.x0, .y = c.y0, .radius = c.x1 }),
                // An explosion (game/explode.zig): impulse on the bodies
                // around it, scaled by its overpressure, and a destruction
                // event at the charge (docs/decisions/115-integrate-explode.md).
                .inject_pressure => {
                    const density: f32 = @bitCast(c.material);
                    if (density <= 0) continue;
                    self.world.applyBlast(@floatFromInt(c.x0), @floatFromInt(c.y0), @as(f32, @floatFromInt(c.x1)) * blast_reach, density * blast_impulse);
                    self.notifyEvent(.{ .x = c.x0, .y = c.y0, .radius = c.x1 });
                },
                else => {},
            }
        }
        for (self.incoming[0..self.incoming_len]) |e| self.destroyAt(e);
        self.incoming_len = 0;

        // 2. Terrain: around bodies, beam placements and anchors; then the
        //    regions of the events the readback has caught up with.
        if (self.needsTerrain()) {
            const tr = nowNs();
            self.requestTerrain();
            try self.terrain.prepare();
            self.buildClusters(self.terrain.readTick());
            if (self.cluster_len > 0) {
                for (self.clusters[0..self.cluster_len]) |c| self.terrain.request(c);
                try self.terrain.prepare();
            }
            self.stats.readback_ms = msSince(tr);
        }
        const read_tick = self.terrain.readTick();
        self.expirePending(read_tick);

        // 3. Connectivity.
        if (self.cluster_len > 0) {
            const tc = nowNs();
            self.processEvents(read_tick);
            self.stats.connectivity_ms = msSince(tc);
        }

        // 4. Physics.
        self.processBeamRequests();
        self.checkAnchors();
        if (self.world.bodyCount() > 0) {
            const tsx = nowNs();
            try self.updateStatic();
            self.stats.static_ms = msSince(tsx);
            const tf = nowNs();
            self.applyFluidForces(self.fluid_sampler orelse default_fluid);
            self.stats.fluid_ms = msSince(tf);
            const tst = nowNs();
            self.world.step();
            self.stats.step_ms = msSince(tst);
            const te = nowNs();
            self.processImpacts();
            self.processJointBreaks();
            self.recenter();
            self.stats.events_ms = msSince(te);
        }

        // 5. GPU upload.
        const tu = nowNs();
        self.buildUpload(&w);
        self.stats.upload_ms = msSince(tu);
        self.stats.bodies = @intCast(self.world.bodyCount());
        self.stats.points = w.data.points;
        self.stats.cpu_ms = msSince(t0) - self.stats.readback_ms;
        const t = &self.totals;
        t.ticks += 1;
        t.cpu_ms += self.stats.cpu_ms;
        t.cpu_ms_max = @max(t.cpu_ms_max, self.stats.cpu_ms);
        t.readback_ms += self.stats.readback_ms;
        t.static_ms += self.stats.static_ms;
        t.fluid_ms += self.stats.fluid_ms;
        t.step_ms += self.stats.step_ms;
        t.events_ms += self.stats.events_ms;
        t.upload_ms += self.stats.upload_ms;
        t.dropped += self.stats.dropped;
    }

    // -- destruction ---------------------------------------------------------

    fn destroyAt(self: *BodySim, e0: DestructionEvent) void {
        var e = e0;
        e.tick = self.tick_now;
        self.totals.events += 1;
        self.cutBodies(e);
        const fr: f32 = @floatFromInt(e.radius);
        self.world.applyBlast(@floatFromInt(e.x), @floatFromInt(e.y), fr * self.cfg.blast_reach, e.strength orelse self.cfg.blast_per_radius * fr);
        if (self.event_len < self.events.len) {
            self.events[self.event_len] = e;
            self.event_len += 1;
        } else self.totals.dropped += 1;
    }

    /// Remove the pixels of every body inside the event's footprint.
    fn cutBodies(self: *BodySim, e: DestructionEvent) void {
        const eb = e.bounds();
        var n: usize = 0;
        var it = self.world.rasterIterator();
        while (it.next()) |rb| {
            const s = &self.world.slots[rb.handle.index];
            const r: i32 = @intFromFloat(@ceil(s.radius));
            const br: Region = .{ .x = @as(i32, @intFromFloat(rb.transform.x)) - r - 1, .y = @as(i32, @intFromFloat(rb.transform.y)) - r - 1, .w = @intCast(2 * r + 3), .h = @intCast(2 * r + 3) };
            if (!br.overlaps(eb)) continue;
            self.handles[n] = rb.handle;
            n += 1;
        }
        for (self.handles[0..n]) |h| self.cutBody(h, e);
    }

    fn cutBody(self: *BodySim, h: BodyHandle, e: DestructionEvent) void {
        const b = self.world.getBitmap(h) orelse return;
        const xf = self.world.getTransform(h).?;
        const area = @as(usize, b.w) * b.h;
        const px = self.bitmap[0..area];
        @memcpy(px, b.pixels);
        var removed: u32 = 0;
        for (0..b.h) |j| {
            for (0..b.w) |i| {
                if (px[j * b.w + i] == 0) continue;
                const p = xf.apply(@as(f32, @floatFromInt(i)) + 0.5 - b.origin_x, @as(f32, @floatFromInt(j)) + 0.5 - b.origin_y);
                if (e.contains(p.x, p.y)) {
                    px[j * b.w + i] = 0;
                    removed += 1;
                }
            }
        }
        if (removed == 0) return;
        if (self.world.beamOf(h)) |beam| self.weakenCutSegment(beam, px, b.w, b.h, xf);
        self.world.wakeBody(h);
        const ox = b.origin_x;
        const oy = b.origin_y;
        const pieces = self.world.splitBody(h, px, b.w, b.h, ox, oy) catch |err| {
            log.warn("cut: splitBody failed: {s}", .{@errorName(err)});
            return;
        };
        self.afterSplit(pieces, null);
    }

    /// A cut through beam segment `h`: both of its joints keep the fraction
    /// of thickness left in the most damaged column (moment capacity goes with
    /// its square, `weakenBeamAt`); a severed segment breaks both.
    fn weakenCutSegment(self: *BodySim, beam: BeamHandle, px: []const u8, w: u16, hh: u16, xf: bodies.Transform) void {
        const bi = self.world.beamInfo(beam) orelse return;
        var min_fill: u32 = hh;
        for (0..w) |i| {
            var fill: u32 = 0;
            for (0..hh) |j| fill += @intFromBool(px[j * w + i] != 0);
            min_fill = @min(min_fill, fill);
        }
        const remaining = @as(f32, @floatFromInt(min_fill)) / @as(f32, @floatFromInt(bi.thickness));
        const a = xf.apply(0, 0);
        const b = xf.apply(@floatFromInt(bi.seg_len), 0);
        self.world.weakenBeamAt(beam, a.x, a.y, remaining);
        self.world.weakenBeamAt(beam, b.x, b.y, remaining);
    }

    /// Bookkeeping after `splitBody`: bump bitmap versions and dissolve
    /// pieces too small to live on.
    fn afterSplit(self: *BodySim, pieces_in: []const BodyHandle, rubble: ?u8) void {
        var local: [64]BodyHandle = undefined;
        const n = @min(pieces_in.len, local.len);
        @memcpy(local[0..n], pieces_in[0..n]);
        if (pieces_in.len > local.len) log.warn("split into {d} pieces; {d} not tracked", .{ pieces_in.len, pieces_in.len - local.len });
        for (local[0..n]) |p| {
            if (!self.world.isValid(p)) continue;
            self.version[p.index] +%= 1;
            self.broken_tick[p.index] = self.tick_now;
            const count = self.world.getPixelCount(p) orelse continue;
            const limit: u32 = if (rubble != null) self.cfg.min_piece_pixels else self.cfg.min_body_pixels;
            if (count < limit) self.dissolve(p);
        }
    }

    // -- terrain -------------------------------------------------------------

    fn bodyRegion(self: *const BodySim, rb: bodies.RasterBody) Region {
        const s = &self.world.slots[rb.handle.index];
        const v = self.world.getVelocity(rb.handle) orelse bodies.Vec2{ .x = 0, .y = 0 };
        const reach = s.radius + self.cfg.collision_margin + (@abs(v.x) + @abs(v.y)) * bodies.tick_dt * 2;
        const r: i32 = @intFromFloat(@ceil(reach));
        const cx: i32 = @intFromFloat(@floor(rb.transform.x));
        const cy: i32 = @intFromFloat(@floor(rb.transform.y));
        return .{ .x = cx - r, .y = cy - r, .w = @intCast(2 * r + 1), .h = @intCast(2 * r + 1) };
    }

    fn requestTerrain(self: *BodySim) void {
        var it = self.world.rasterIterator();
        while (it.next()) |rb| {
            // Around sleeping bodies every few ticks (staggered): terrain
            // changes under them are noticed a little later.
            if (!rb.awake and (rb.handle.index +% self.tick_now) % self.cfg.sleeping_refresh != 0) continue;
            self.terrain.request(self.bodyRegion(rb));
        }
        for (self.beam_requests[0..self.beam_request_len]) |r| self.terrain.request(lineRegion(r.x0, r.y0, r.x1, r.y1, 8));
        for (self.world.beams, 0..) |b, bi| {
            if (!b.live) continue;
            const h: BeamHandle = .{ .index = @intCast(bi), .gen = b.gen };
            for ([_]bodies.BodyWorld.BeamEnd{ .start, .end }) |end| {
                if (self.anchorProbe(h, end)) |p| self.terrain.request(.{ .x = p[0] - 2, .y = p[1] - 2, .w = 5, .h = 5 });
            }
        }
    }

    /// The connectivity region of one event: `connectivity_region` square
    /// around it, grown to cover its footprint, clamped to
    /// `max_connectivity_region` per side (centered on the event).
    fn eventRegion(self: *const BodySim, e: DestructionEvent) Region {
        const side: i32 = @intCast(self.cfg.connectivity_region);
        const max_side = self.cfg.max_connectivity_region;
        const half = @divTrunc(side, 2);
        var r: Region = .{ .x = e.x - half, .y = e.y - half, .w = @intCast(side), .h = @intCast(side) };
        r = r.merge(e.bounds().grow(32));
        if (r.w > max_side) r = .{ .x = e.x - @as(i32, @intCast(max_side / 2)), .y = r.y, .w = max_side, .h = r.h };
        if (r.h > max_side) r = .{ .x = r.x, .y = e.y - @as(i32, @intCast(max_side / 2)), .w = r.w, .h = max_side };
        return r;
    }

    /// Group the events the readback has caught up with into regions.
    fn buildClusters(self: *BodySim, read_tick: u32) void {
        self.cluster_len = 0;
        const max_side = self.cfg.max_connectivity_region;
        for (self.events[0..self.event_len]) |*e| {
            e.cluster = DestructionEvent.no_cluster;
            if (e.tick >= read_tick) continue;
            const r = self.eventRegion(e.*);
            for (self.clusters[0..self.cluster_len], 0..) |*c, ci| {
                if (!c.overlaps(r)) continue;
                const m = c.merge(r);
                if (m.w <= max_side and m.h <= max_side) {
                    c.* = m;
                    e.cluster = @intCast(ci);
                    break;
                }
            }
            if (e.cluster == DestructionEvent.no_cluster and self.cluster_len < self.clusters.len) {
                self.clusters[self.cluster_len] = r;
                e.cluster = @intCast(self.cluster_len);
                self.cluster_len += 1;
            }
        }
    }

    fn expirePending(self: *BodySim, read_tick: u32) void {
        var n: usize = 0;
        for (self.pending[0..self.pending_len]) |p| {
            if (p.tick >= read_tick) {
                self.pending[n] = p;
                n += 1;
            }
        }
        self.pending_len = n;
        if (n == 0) self.pending_used = 0;
    }

    fn addPending(self: *BodySim, x: i32, y: i32, w: u16, h: u16, px: []const u8) ?u32 {
        const area: u32 = @as(u32, w) * h;
        if (self.pending_len == self.pending.len or self.pending_used + area > self.pending_px.len) {
            self.totals.dropped += 1;
            return null;
        }
        const off = self.pending_used;
        @memcpy(self.pending_px[off..][0..area], px[0..area]);
        self.pending_used += area;
        self.pending[self.pending_len] = .{ .x = x, .y = y, .w = w, .h = h, .off = off, .tick = self.tick_now };
        self.pending_len += 1;
        return @intCast(self.pending_len - 1);
    }

    /// Zero `buf` (region `r`) where a pending extraction's bitmap is set.
    fn maskPending(self: *const BodySim, r: Region, buf: []u8) void {
        for (self.pending[0..self.pending_len]) |p| {
            const pr: Region = .{ .x = p.x, .y = p.y, .w = p.w, .h = p.h };
            if (!pr.overlaps(r)) continue;
            const bmp = self.pending_px[p.off..][0 .. @as(usize, p.w) * p.h];
            for (0..p.h) |j| {
                const wy = p.y + @as(i32, @intCast(j));
                if (wy < r.y or wy >= r.y + @as(i32, @intCast(r.h))) continue;
                for (0..p.w) |i| {
                    if (bmp[j * p.w + i] == 0) continue;
                    const wx = p.x + @as(i32, @intCast(i));
                    if (wx < r.x or wx >= r.x + @as(i32, @intCast(r.w))) continue;
                    buf[@as(usize, @intCast(wy - r.y)) * r.w + @as(usize, @intCast(wx - r.x))] = 0;
                }
            }
        }
    }

    // -- connectivity ----------------------------------------------------------

    /// Connectivity over the clusters of ready events; events the readback
    /// has not caught up with stay queued.
    fn processEvents(self: *BodySim, read_tick: u32) void {
        const t0 = nowNs();
        var done: usize = 0;
        while (done < self.cluster_len) {
            if (done > 0 and msSince(t0) >= self.cfg.connectivity_budget_ms) break;
            self.connectivity(self.clusters[done]);
            done += 1;
        }
        var n: usize = 0;
        for (self.events[0..self.event_len]) |e| {
            // Kept until the cluster that holds its (clamped) region has run.
            // It used to wait while any queued cluster overlapped its whole
            // footprint, so a map-wide carve was never done and kept
            // connectivity busy forever (decision 143).
            var keep = e.tick >= read_tick or e.cluster == DestructionEvent.no_cluster or e.cluster >= done;
            if (keep and e.tick < read_tick and read_tick - e.tick > self.cfg.max_event_age) {
                keep = false;
                self.totals.expired += 1;
            }
            if (keep) {
                self.events[n] = e;
                n += 1;
            }
        }
        self.cluster_len = 0;
        self.event_len = n;
    }

    /// Islands of static solid in region `r` that touch neither the region
    /// border nor an anchor material (bedrock) come loose: bodies, or rubble
    /// when tiny. One flood fill from the border and anchor pixels marks
    /// everything anchored; only the bounding box of what is left is split
    /// into components, so the large anchored terrain is never labelled or
    /// copied (docs/decisions/93-bodies-gpu-connectivity.md).
    pub fn connectivity(self: *BodySim, r: Region) void {
        const t0 = nowNs();
        defer {
            const ms = msSince(t0);
            self.totals.connectivity_ms += ms;
            self.totals.connectivity_ms_max = @max(self.totals.connectivity_ms_max, ms);
            self.totals.connectivity_runs += 1;
        }
        const area = r.area();
        const w: usize = r.w;
        const h: usize = r.h;
        const mats = self.region_mats[0..area];
        self.terrain.materials(r, mats);
        self.maskPending(r, mats);
        // conn: static material id, 0 = not static; anchored pixels are
        // zeroed by the flood below.
        const conn = self.conn[0..area];
        for (mats, conn) |m, *c| {
            c.* = if (m != materials.air and m != ts.body_owned and self.mats.info[m].static) m else 0;
        }
        const stack = self.split.stack;
        var sp: usize = 0;
        const seed = struct {
            fn f(cn: []u8, st: []u32, n: *usize, i: usize) void {
                if (cn[i] == 0) return;
                cn[i] = 0;
                st[n.*] = @intCast(i);
                n.* += 1;
            }
        }.f;
        for (0..w) |x| {
            seed(conn, stack, &sp, x);
            seed(conn, stack, &sp, (h - 1) * w + x);
        }
        for (0..h) |y| {
            seed(conn, stack, &sp, y * w);
            seed(conn, stack, &sp, y * w + w - 1);
        }
        for (conn, 0..) |m, i| {
            if (m != 0 and self.mats.info[m].breakup.anchor) seed(conn, stack, &sp, i);
        }
        while (sp > 0) {
            sp -= 1;
            const i = stack[sp];
            const x = i % w;
            if (x > 0) seed(conn, stack, &sp, i - 1);
            if (x + 1 < w) seed(conn, stack, &sp, i + 1);
            if (i >= w) seed(conn, stack, &sp, i - w);
            if (i + w < area) seed(conn, stack, &sp, i + w);
        }
        // What is left is loose.
        var x0: usize = w;
        var y0: usize = h;
        var x1: usize = 0;
        var y1: usize = 0;
        for (0..h) |y| {
            const row = conn[y * w ..][0..w];
            for (row, 0..) |m, x| {
                if (m == 0) continue;
                x0 = @min(x0, x);
                x1 = @max(x1, x);
                y0 = @min(y0, y);
                y1 = @max(y1, y);
            }
        }
        if (x0 > x1) return;
        const bw = x1 - x0 + 1;
        const bh = y1 - y0 + 1;
        // Compact the loose box in place at the start of `conn` (rows move
        // forward only, so this never overwrites unread data).
        for (0..bh) |j| std.mem.copyForwards(u8, conn[j * bw ..][0..bw], conn[(y0 + j) * w + x0 ..][0..bw]);
        const comps = bodies.splitByConnectivity(conn[0 .. bw * bh], @intCast(bw), @intCast(bh), &self.split) catch |err| {
            log.warn("connectivity {d}x{d} at {d},{d}: {s}", .{ r.w, r.h, r.x, r.y, @errorName(err) });
            return;
        };
        for (comps) |c| {
            const wx = r.x + @as(i32, @intCast(x0)) + @as(i32, c.x);
            const wy = r.y + @as(i32, @intCast(y0)) + @as(i32, c.y);
            if (c.pixel_count < self.cfg.min_body_pixels) {
                self.componentToRubble(c, wx, wy);
            } else if (@as(u32, c.w) * c.h <= self.cfg.world.max_bitmap_pixels) {
                self.componentToBody(c, wx, wy);
            } else {
                log.warn("loose component {d}x{d} too large for a body; left in place", .{ c.w, c.h });
            }
        }
    }

    fn componentToRubble(self: *BodySim, c: bodies.Component, wx: i32, wy: i32) void {
        const w = self.writer orelse return;
        if (w.pointsLeft() < c.pixel_count * 2) return;
        for (0..c.h) |j| {
            for (0..c.w) |i| {
                const m = c.pixels[j * c.w + i];
                if (m == 0) continue;
                const x = wx + @as(i32, @intCast(i));
                const y = wy + @as(i32, @intCast(j));
                const rub = self.mats.info[m].breakup.rubble;
                if (rub != none) {
                    w.addPoint(bgpu.BodyPoint.make(x, y, rub, m, bgpu.point_replace, 0, 0)) catch {};
                } else {
                    w.addPoint(bgpu.BodyPoint.make(x, y, materials.air, m, bgpu.point_replace, 0, 0)) catch {};
                    w.addPoint(bgpu.BodyPoint.make(x, y, m, 0, bgpu.point_eject, 0, 0)) catch {};
                }
            }
        }
        self.totals.rubble_components += 1;
    }

    fn componentToBody(self: *BodySim, c: bodies.Component, wx: i32, wy: i32) void {
        if (self.extract_len == self.extracts.len) return;
        const h = self.world.createPixelBody(.{
            .pixels = c.pixels,
            .w = c.w,
            .h = c.h,
            .x = @floatFromInt(wx),
            .y = @floatFromInt(wy),
        }) catch |err| {
            log.warn("loose component {d}x{d}: {s}", .{ c.w, c.h, @errorName(err) });
            return;
        };
        const pend = self.addPending(wx, wy, c.w, c.h, c.pixels) orelse std.math.maxInt(u32);
        self.version[h.index] +%= 1;
        self.extracts[self.extract_len] = .{ .handle = h, .version = self.version[h.index], .x = wx, .y = wy, .w = c.w, .h = c.h, .pending = pend };
        self.extract_len += 1;
        self.totals.extracted += 1;
    }

    // -- beams -----------------------------------------------------------------

    fn staticAt(self: *const BodySim, r: Region, buf: []const u8, x: i32, y: i32) bool {
        if (!r.contains(x, y)) return false;
        const m = buf[@as(usize, @intCast(y - r.y)) * r.w + @as(usize, @intCast(x - r.x))];
        return m != materials.air and m != ts.body_owned and self.mats.info[m].static;
    }

    fn processBeamRequests(self: *BodySim) void {
        for (self.beam_requests[0..self.beam_request_len]) |req| self.placeBeamNow(req);
        self.beam_request_len = 0;
    }

    fn placeBeamNow(self: *BodySim, req: BeamRequest) void {
        const r = lineRegion(req.x0, req.y0, req.x1, req.y1, 8);
        if (r.area() > self.region_mats.len) {
            self.totals.beams_rejected += 1;
            return;
        }
        const buf = self.region_mats[0..r.area()];
        self.terrain.materials(r, buf);
        const dx = req.x1 - req.x0;
        const dy = req.y1 - req.y0;
        const len = @sqrt(dx * dx + dy * dy);
        if (len < 8 or req.material == none) {
            self.totals.beams_rejected += 1;
            return;
        }
        const ux = dx / len;
        const uy = dy / len;
        // Walk each end out of the solid it starts in.
        var s: f32 = 0;
        while (s < len and self.staticAt(r, buf, @intFromFloat(@floor(req.x0 + ux * s)), @intFromFloat(@floor(req.y0 + uy * s)))) s += 1;
        var e: f32 = len;
        while (e > s and self.staticAt(r, buf, @intFromFloat(@floor(req.x0 + ux * e)), @intFromFloat(@floor(req.y0 + uy * e)))) e -= 1;
        if (e - s < 8) {
            self.totals.beams_rejected += 1;
            return;
        }
        const span = e - s;
        const segments: u16 = @intFromFloat(std.math.clamp(@round(span / 10), 2, @as(f32, @floatFromInt(self.cfg.world.max_beam_segments))));
        _ = self.world.createBeam(.{
            .x0 = req.x0 + ux * s,
            .y0 = req.y0 + uy * s,
            .x1 = req.x0 + ux * e,
            .y1 = req.y0 + uy * e,
            .thickness = req.thickness,
            .material = req.material,
            .segments = segments,
            .anchor_start = s > 0,
            .anchor_end = e < len,
        }) catch |err| {
            log.warn("beam: {s}", .{@errorName(err)});
            self.totals.beams_rejected += 1;
            return;
        };
        self.totals.beams_placed += 1;
    }

    /// World pixel just inside the wall an anchored beam end is welded to.
    fn anchorProbe(self: *BodySim, h: BeamHandle, end: bodies.BodyWorld.BeamEnd) ?[2]i32 {
        const info = self.world.beamInfo(h) orelse return null;
        const ji: usize = if (end == .start) 0 else info.segments;
        const load = self.world.beamJointLoad(h, ji) orelse return null;
        if (!load.alive) return null;
        const segs = self.world.beamSegments(h);
        const seg = if (end == .start) segs[0] else segs[info.segments - 1];
        const xf = self.world.getTransform(seg) orelse return null;
        const lx: f32 = if (end == .start) -2 else @as(f32, @floatFromInt(info.seg_len)) + 2;
        const p = xf.apply(lx, 0);
        return .{ @intFromFloat(@floor(p.x)), @intFromFloat(@floor(p.y)) };
    }

    /// Release anchors whose wall is gone.
    fn checkAnchors(self: *BodySim) void {
        for (self.world.beams, 0..) |b, bi| {
            if (!b.live) continue;
            const h: BeamHandle = .{ .index = @intCast(bi), .gen = b.gen };
            for ([_]bodies.BodyWorld.BeamEnd{ .start, .end }) |end| {
                const p = self.anchorProbe(h, end) orelse continue;
                var probe: [9]u8 = undefined;
                const r: Region = .{ .x = p[0] - 1, .y = p[1] - 1, .w = 3, .h = 3 };
                self.terrain.materials(r, &probe);
                var solid = false;
                for (probe) |m| solid = solid or (m != materials.air and m != ts.body_owned and self.mats.info[m].static);
                if (!solid) {
                    self.world.releaseBeamAnchor(h, end);
                    self.totals.anchors_released += 1;
                }
            }
        }
    }

    // -- physics ---------------------------------------------------------------

    fn updateStatic(self: *BodySim) !void {
        var it = self.world.rasterIterator();
        var region: ?Region = null;
        while (it.next()) |rb| {
            const r = self.bodyRegion(rb);
            region = if (region) |a| a.merge(r) else r;
        }
        var r = region orelse return;
        r.w = @min(r.w, self.cfg.world.static_max_w);
        r.h = @min(r.h, self.cfg.world.static_max_h);
        const mask = self.mask[0..r.area()];
        self.terrain.solidMask(r, mask);
        self.maskPending(r, mask);
        try self.world.setStaticCollision(mask, r.w, r.h, r.x, r.y);
    }

    pub fn applyFluidForces(self: *BodySim, sampler: FluidSampler) void {
        var it = self.world.rasterIterator();
        while (it.next()) |rb| {
            const f = sampler.sample(sampler.ctx, self, rb) orelse continue;
            self.world.applyFluid(rb.handle, f.velocity, f.drag, f.angular_drag, f.buoyancy);
        }
    }

    fn processImpacts(self: *BodySim) void {
        for (self.world.impacts()) |imp| {
            for ([_]?BodyHandle{ imp.body_a, imp.body_b }) |maybe| {
                const h = maybe orelse continue;
                self.considerBreak(h, imp);
            }
        }
    }

    fn considerBreak(self: *BodySim, h: BodyHandle, imp: bodies.Impact) void {
        if (!self.world.isValid(h) or self.world.beamOf(h) != null) return;
        if (self.broken_tick[h.index] == self.tick_now) return;
        const b = self.world.getBitmap(h) orelse return;
        const mass = self.world.getMass(h) orelse return;
        const mat = self.world.slots[h.index].material;
        const info = self.mats.info[mat];
        const dv = imp.normal_impulse / @max(mass, 1e-3);
        const thr = info.breakup.break_dv * bm.shapeFactor(@floatFromInt(b.w), @floatFromInt(b.h));
        if (!(dv > thr)) return;
        self.broken_tick[h.index] = self.tick_now;
        self.breakBody(h, imp.x, imp.y, dv / thr);
    }

    /// Shatter a body at world (x, y): crush a disc around the impact to
    /// rubble, crack it across its long axis (how a slab landing flat fails)
    /// and radially from the impact, split the rest by connectivity, dissolve
    /// small pieces, and kick the pieces apart. Small bodies and very hard
    /// hits dissolve entirely into rubble cells.
    pub fn breakBody(self: *BodySim, h: BodyHandle, x: f32, y: f32, severity: f32) void {
        const b = self.world.getBitmap(h) orelse return;
        const count = self.world.getPixelCount(h) orelse return;
        const mat = self.world.slots[h.index].material;
        const rub = self.mats.info[mat].breakup.rubble;
        self.totals.broken += 1;
        if (count < self.cfg.dissolve_pixels or severity > self.cfg.dissolve_severity) {
            self.dissolve(h);
            return;
        }
        const w = self.writer orelse return;
        const xf = self.world.getTransform(h).?;
        const v0 = self.world.getVelocity(h).?;
        const area = @as(usize, b.w) * b.h;
        const px = self.bitmap[0..area];
        @memcpy(px, b.pixels);
        const l = xf.applyInverse(x, y);
        const fw: f32 = @floatFromInt(b.w);
        const fh: f32 = @floatFromInt(b.h);
        const bx = std.math.clamp(l.x + b.origin_x, 0, fw - 0.5);
        const by = std.math.clamp(l.y + b.origin_y, 0, fh - 0.5);
        const rand = self.prng.random();
        // Crush disc.
        const crush = std.math.clamp(2 + 3 * severity, 3, 14);
        for (0..b.h) |j| {
            for (0..b.w) |i| {
                const ddx = @as(f32, @floatFromInt(i)) + 0.5 - bx;
                const ddy = @as(f32, @floatFromInt(j)) + 0.5 - by;
                if (ddx * ddx + ddy * ddy <= crush * crush) self.removePixel(w, px, b, xf, i, j, rub);
            }
        }
        // Transverse cracks, evenly spread with jitter along the long axis.
        const along_x = b.w >= b.h;
        const long = @max(fw, fh);
        const short = @max(@min(fw, fh), 1);
        const n_t: u32 = @intFromFloat(std.math.clamp(@floor(long / short * 0.5 * severity), 1, 10));
        for (1..n_t + 1) |k| {
            const u = (@as(f32, @floatFromInt(k)) + (rand.float(f32) - 0.5) * 0.6) / @as(f32, @floatFromInt(n_t + 1)) * long;
            const tilt = (rand.float(f32) - 0.5) * 0.8;
            const start_x = if (along_x) u else -1;
            const start_y = if (along_x) -1 else u;
            const angle = if (along_x) std.math.pi / 2.0 + tilt else tilt;
            self.crack(w, px, b, xf, start_x, start_y, angle, 0.15, rub, rand);
        }
        // Radial cracks from the impact.
        for (0..2) |_| self.crack(w, px, b, xf, bx, by, rand.float(f32) * std.math.tau, 0.25, rub, rand);
        const pieces = self.world.splitBody(h, px, b.w, b.h, b.origin_x, b.origin_y) catch |err| {
            log.warn("break: splitBody failed: {s}", .{@errorName(err)});
            return;
        };
        var local: [64]BodyHandle = undefined;
        const n = @min(pieces.len, local.len);
        @memcpy(local[0..n], pieces[0..n]);
        self.afterSplit(local[0..n], rub);
        // Kick the surviving pieces apart: away from the impact, a hop, a spin.
        for (local[0..n]) |p| {
            const c = self.world.getCenterOfMass(p) orelse continue;
            var dx = c.x - x;
            var dy = c.y - y;
            const d = @max(@sqrt(dx * dx + dy * dy), 1);
            dx /= d;
            dy /= d;
            const kick = self.cfg.shatter_kick * severity * (0.5 + rand.float(f32));
            self.world.setVelocity(p, .{ .x = v0.x * 0.2 + dx * kick, .y = v0.y * 0.2 + dy * kick * 0.3 - kick * 0.6 }, (rand.float(f32) - 0.5) * 2 * severity);
        }
    }

    /// Remove a 2 px wide random walk from (sx, sy) in bitmap coordinates.
    fn crack(self: *BodySim, w: *bgpu.RegionWriter, px: []u8, b: bodies.BodyWorld.Bitmap, xf: bodies.Transform, sx: f32, sy: f32, angle0: f32, wander: f32, rub: u8, rand: std.Random) void {
        const fw: f32 = @floatFromInt(b.w);
        const fh: f32 = @floatFromInt(b.h);
        var a = angle0;
        var cx = sx;
        var cy = sy;
        const steps: usize = @intFromFloat((fw + fh) * 4);
        var entered = false;
        for (0..steps) |_| {
            cx += @cos(a) * 0.5;
            cy += @sin(a) * 0.5;
            a += (rand.float(f32) - 0.5) * wander;
            const inside = cx >= 0 and cy >= 0 and cx < fw and cy < fh;
            if (!inside) {
                if (entered) break;
                continue;
            }
            entered = true;
            const ix: usize = @intFromFloat(cx);
            const iy: usize = @intFromFloat(cy);
            self.removePixel(w, px, b, xf, ix, iy, rub);
            // Second pixel across the walk direction.
            const ox: f32 = cx - @sin(a);
            const oy: f32 = cy + @cos(a);
            if (ox >= 0 and oy >= 0 and ox < fw and oy < fh) self.removePixel(w, px, b, xf, @intFromFloat(ox), @intFromFloat(oy), rub);
        }
    }

    fn removePixel(self: *BodySim, w: *bgpu.RegionWriter, px: []u8, b: bodies.BodyWorld.Bitmap, xf: bodies.Transform, i: usize, j: usize, rub: u8) void {
        const k = j * b.w + i;
        const m = px[k];
        if (m == 0) return;
        px[k] = 0;
        const p = xf.apply(@as(f32, @floatFromInt(i)) + 0.5 - b.origin_x, @as(f32, @floatFromInt(j)) + 0.5 - b.origin_y);
        const x: i32 = @intFromFloat(@floor(p.x));
        const y: i32 = @intFromFloat(@floor(p.y));
        if (rub != none) {
            w.addPoint(bgpu.BodyPoint.make(x, y, rub, 0, bgpu.point_into_air, 0, 0)) catch return;
            self.totals.rubble_points += 1;
        } else {
            w.addPoint(bgpu.BodyPoint.make(x, y, m, 0, bgpu.point_eject, 0, 0)) catch return;
        }
    }

    /// Turn a whole body back into grid cells: its rubble material (powder,
    /// so the grid takes over) where the material has one, else debris in
    /// the eject queue.
    pub fn dissolve(self: *BodySim, h: BodyHandle) void {
        const w = self.writer orelse return;
        const b = self.world.getBitmap(h) orelse return;
        const count = self.world.getPixelCount(h) orelse return;
        if (w.pointsLeft() < count) return;
        const xf = self.world.getTransform(h).?;
        const v = self.world.getVelocity(h).?;
        for (0..b.h) |j| {
            for (0..b.w) |i| {
                const m = b.pixels[j * b.w + i];
                if (m == 0) continue;
                const p = xf.apply(@as(f32, @floatFromInt(i)) + 0.5 - b.origin_x, @as(f32, @floatFromInt(j)) + 0.5 - b.origin_y);
                const x: i32 = @intFromFloat(@floor(p.x));
                const y: i32 = @intFromFloat(@floor(p.y));
                const rub = self.mats.info[m].breakup.rubble;
                if (rub != none) {
                    w.addPoint(bgpu.BodyPoint.make(x, y, rub, 0, bgpu.point_into_air, v.x, v.y)) catch {};
                    self.totals.rubble_points += 1;
                } else {
                    w.addPoint(bgpu.BodyPoint.make(x, y, m, 0, bgpu.point_eject, v.x, v.y)) catch {};
                }
            }
        }
        self.world.destroyBody(h);
        self.totals.dissolved += 1;
    }

    fn processJointBreaks(self: *BodySim) void {
        const w = self.writer orelse return;
        const rand = self.prng.random();
        for (self.world.jointBreaks()) |jb| {
            self.totals.joint_breaks += 1;
            const b = &self.world.beams[jb.beam.index];
            for (0..self.cfg.sparks_per_break) |_| {
                const a = rand.float(f32) * std.math.tau;
                const sp = 80 + rand.float(f32) * 220;
                w.addPoint(bgpu.BodyPoint.make(@intFromFloat(@floor(jb.x)), @intFromFloat(@floor(jb.y)), b.material, 0, bgpu.point_eject, @cos(a) * sp, @sin(a) * sp)) catch break;
                self.totals.sparks += 1;
            }
        }
    }

    /// Keep every body within half a world of the center: bodies live in
    /// unwrapped coordinates (Box2D does not wrap), the grid wraps, so a
    /// shift by the world size changes nothing on screen. Beams move as a
    /// whole; anchored ends are re-welded at the shifted position.
    fn recenter(self: *BodySim) void {
        const W: f32 = cell.world_size;
        var it = self.world.rasterIterator();
        while (it.next()) |rb| {
            if (rb.beam != null) continue;
            const sx = wrapShift(rb.transform.x - self.center_x, W);
            const sy = wrapShift(rb.transform.y - self.center_y, W);
            if (sx != 0 or sy != 0) self.world.translateBody(rb.handle, sx, sy);
        }
        for (self.world.beams, 0..) |b, bi| {
            if (!b.live) continue;
            const h: BeamHandle = .{ .index = @intCast(bi), .gen = b.gen };
            const segs = self.world.beamSegments(h);
            var ref: ?bodies.Transform = null;
            for (segs) |s| {
                ref = self.world.getTransform(s);
                if (ref != null) break;
            }
            const t = ref orelse continue;
            const sx = wrapShift(t.x - self.center_x, W);
            const sy = wrapShift(t.y - self.center_y, W);
            if (sx == 0 and sy == 0) continue;
            const info = self.world.beamInfo(h).?;
            const start_anchored = (self.world.beamJointLoad(h, 0) orelse continue).alive;
            const end_anchored = (self.world.beamJointLoad(h, info.segments) orelse continue).alive;
            if (start_anchored) self.world.releaseBeamAnchor(h, .start);
            if (end_anchored) self.world.releaseBeamAnchor(h, .end);
            for (segs) |s| self.world.translateBody(s, sx, sy);
            if (start_anchored) self.world.anchorBeam(h, .start) catch {};
            if (end_anchored) self.world.anchorBeam(h, .end) catch {};
        }
    }

    // -- GPU upload ------------------------------------------------------------

    fn buildUpload(self: *BodySim, w: *bgpu.RegionWriter) void {
        var n_clear: usize = 0;
        var it = self.world.rasterIterator();
        const base: usize = @intFromPtr(self.world.pixels.ptr);
        while (it.next()) |rb| {
            const i = rb.handle.index;
            self.seen[i] = self.pass;
            const pl = &self.last[i];
            const gen = rb.handle.gen;
            const off: u32 = @intCast(@intFromPtr(rb.pixels.ptr) - base);
            const len: u32 = @intCast(rb.pixels.len);
            const ver = self.version[i];
            if (!(pl.up_valid and pl.up_gen == gen and pl.up_version == ver and pl.up_off == off and pl.up_len == len)) {
                w.uploadBitmap(off, rb.pixels) catch {
                    self.stats.dropped += 1;
                    continue;
                };
                pl.up_valid = true;
                pl.up_gen = gen;
                pl.up_version = ver;
                pl.up_off = off;
                pl.up_len = len;
                self.stats.uploads += 1;
                self.stats.upload_bytes += len;
            }
            const v = self.world.getVelocity(rb.handle) orelse bodies.Vec2{ .x = 0, .y = 0 };
            const inst = makeInstance(rb, i + 1, off, v, self.world.getAngularVelocity(rb.handle) orelse 0);
            if (pl.valid and pl.gen == gen and pl.version == ver and pl.inst.samePlacement(inst)) continue;
            w.addInstance(inst) catch {
                self.stats.dropped += 1;
                continue;
            };
            self.stats.rastered += 1;
            if (pl.valid and n_clear < self.clears.len) {
                self.clears[n_clear] = pl.inst;
                n_clear += 1;
            }
            pl.valid = true;
            pl.gen = gen;
            pl.version = ver;
            pl.inst = inst;
        }
        // Bodies that died since last tick.
        for (self.last, 0..) |*pl, i| {
            if (!pl.valid or self.seen[i] == self.pass) continue;
            if (n_clear < self.clears.len) {
                self.clears[n_clear] = pl.inst;
                n_clear += 1;
            }
            pl.valid = false;
            pl.up_valid = false;
        }
        w.beginClear();
        for (self.clears[0..n_clear]) |c| {
            w.addInstance(c) catch {
                self.stats.dropped += 1;
                continue;
            };
            self.stats.cleared += 1;
        }
        w.beginExtract();
        for (self.extracts[0..self.extract_len]) |e| {
            if (self.world.isValid(e.handle) and self.version[e.handle.index] == e.version) {
                const off = self.world.pixelOffset(e.handle).?;
                w.addInstance(identityInstance(e.x, e.y, e.w, e.h, off, e.handle.index + 1)) catch {
                    self.stats.dropped += 1;
                    continue;
                };
                self.stats.extracts += 1;
            } else if (e.pending != std.math.maxInt(u32)) {
                // Split or destroyed in the tick it came loose: clear its
                // cells point by point from the pending copy.
                const p = self.pending[e.pending];
                const bmp = self.pending_px[p.off..][0 .. @as(usize, p.w) * p.h];
                for (0..p.h) |j| {
                    for (0..p.w) |ii| {
                        const m = bmp[j * p.w + ii];
                        if (m == 0) continue;
                        w.addPoint(bgpu.BodyPoint.make(p.x + @as(i32, @intCast(ii)), p.y + @as(i32, @intCast(j)), materials.air, m, bgpu.point_replace, 0, 0)) catch {};
                    }
                }
            }
        }
    }
};

/// The instance that rasterizes `rb` this tick (see bodies.glsl for the
/// fixed-point mapping).
pub fn makeInstance(rb: bodies.RasterBody, id: u32, atlas_off: u32, v: bodies.Vec2, omega: f32) bgpu.BodyInstance {
    const t = rb.transform;
    const c: f64 = t.cos;
    const s: f64 = t.sin;
    const ox: f64 = rb.origin_x;
    const oy: f64 = rb.origin_y;
    const fw: f64 = @floatFromInt(rb.w);
    const fh: f64 = @floatFromInt(rb.h);
    var minx: f64 = std.math.inf(f64);
    var miny: f64 = std.math.inf(f64);
    var maxx: f64 = -std.math.inf(f64);
    var maxy: f64 = -std.math.inf(f64);
    for ([_][2]f64{ .{ -ox, -oy }, .{ fw - ox, -oy }, .{ -ox, fh - oy }, .{ fw - ox, fh - oy } }) |l| {
        const wx = @as(f64, t.x) + c * l[0] - s * l[1];
        const wy = @as(f64, t.y) + s * l[0] + c * l[1];
        minx = @min(minx, wx);
        miny = @min(miny, wy);
        maxx = @max(maxx, wx);
        maxy = @max(maxy, wy);
    }
    const ax0: i32 = @divFloor(@as(i32, @intFromFloat(@floor(minx))) - 1, 16) * 16;
    const ay0: i32 = @divFloor(@as(i32, @intFromFloat(@floor(miny))) - 1, 16) * 16;
    const ax1: i32 = @as(i32, @intFromFloat(@ceil(maxx))) + 1;
    const ay1: i32 = @as(i32, @intFromFloat(@ceil(maxy))) + 1;
    const aw: u32 = @intCast(std.math.clamp(ax1 - ax0, 1, 0xffff));
    const ah: u32 = @intCast(std.math.clamp(ay1 - ay0, 1, 0xffff));
    const dx = @as(f64, @floatFromInt(ax0)) + 0.5 - t.x;
    const dy = @as(f64, @floatFromInt(ay0)) + 0.5 - t.y;
    const lx = c * dx + s * dy + ox;
    const ly = -s * dx + c * dy + oy;
    return .{
        .ax = ax0,
        .ay = ay0,
        .aabb_size = aw | (ah << 16),
        .id = id,
        .l0x = fixed(lx),
        .l0y = fixed(ly),
        .cs = fixed(c),
        .sn = fixed(s),
        .bitmap_size = @as(u32, rb.w) | (@as(u32, rb.h) << 16),
        .atlas_offset = atlas_off,
        .vx = v.x,
        .vy = v.y,
        .angular_velocity = omega,
    };
}

/// Unrotated bitmap with its top-left pixel at world (x, y) (extraction).
pub fn identityInstance(x: i32, y: i32, w: u16, h: u16, atlas_off: u32, id: u32) bgpu.BodyInstance {
    const ax = @divFloor(x, 16) * 16;
    const ay = @divFloor(y, 16) * 16;
    const aw: u32 = @intCast(x + @as(i32, w) - ax);
    const ah: u32 = @intCast(y + @as(i32, h) - ay);
    return .{
        .ax = ax,
        .ay = ay,
        .aabb_size = aw | (ah << 16),
        .id = id,
        .l0x = ((ax - x) << 16) + 0x8000,
        .l0y = ((ay - y) << 16) + 0x8000,
        .cs = 1 << 16,
        .sn = 0,
        .bitmap_size = @as(u32, w) | (@as(u32, h) << 16),
        .atlas_offset = atlas_off,
    };
}

fn fixed(v: f64) i32 {
    return @intFromFloat(std.math.clamp(@round(v * 65536.0), -2147483648.0, 2147483647.0));
}

fn wrapShift(d: f32, W: f32) f32 {
    if (d > W / 2) return -W * @ceil((d - W / 2) / W);
    if (d < -W / 2) return W * @ceil((-d - W / 2) / W);
    return 0;
}

fn lineRegion(x0: f32, y0: f32, x1: f32, y1: f32, m: i32) Region {
    const ax: i32 = @intFromFloat(@floor(@min(x0, x1)));
    const ay: i32 = @intFromFloat(@floor(@min(y0, y1)));
    const bx: i32 = @intFromFloat(@ceil(@max(x0, x1)));
    const by: i32 = @intFromFloat(@ceil(@max(y0, y1)));
    return .{ .x = ax - m, .y = ay - m, .w = @intCast(bx - ax + 2 * m + 1), .h = @intCast(by - ay + 2 * m + 1) };
}

pub fn nowNs() u64 {
    var tspec: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &tspec);
    return @as(u64, @intCast(tspec.sec)) * std.time.ns_per_s + @as(u64, @intCast(tspec.nsec));
}

fn msSince(t0: u64) f64 {
    return @as(f64, @floatFromInt(nowNs() - t0)) / 1e6;
}

// ---------------------------------------------------------------------------
// Default fluid sampler: cellular liquids from the terrain readback.

/// Buoyancy and drag from liquid cells next to the body: a row of the body
/// counts as submerged when a liquid cell borders its body-owned run on
/// either side. Replaced by the liquid solver's sampler in M6 integration.
pub const default_fluid: FluidSampler = .{ .sample = cellularFluid };

fn cellularFluid(_: ?*anyopaque, sim: *BodySim, rb: bodies.RasterBody) ?FluidSample {
    const inst = makeInstance(rb, 0, 0, .{ .x = 0, .y = 0 }, 0);
    const r: Region = .{ .x = inst.ax - 1, .y = inst.ay - 1, .w = inst.aabbW() + 2, .h = inst.aabbH() + 2 };
    if (r.area() > sim.region_mats.len) return null;
    const info = &sim.mats.info;
    // Liquid anywhere on the box's border? (Cheap reject for dry bodies.)
    var edge: [2 * 0x10000 + 4]u8 = undefined;
    var any = false;
    const strips = [_]Region{
        .{ .x = r.x, .y = r.y, .w = r.w, .h = 1 },
        .{ .x = r.x, .y = r.y + @as(i32, @intCast(r.h)) - 1, .w = r.w, .h = 1 },
        .{ .x = r.x, .y = r.y, .w = 1, .h = r.h },
        .{ .x = r.x + @as(i32, @intCast(r.w)) - 1, .y = r.y, .w = 1, .h = r.h },
    };
    for (strips) |st| {
        if (st.area() > edge.len) return null;
        sim.terrain.materials(st, edge[0..st.area()]);
        for (edge[0..st.area()]) |m| any = any or (m != ts.body_owned and info[m].liquid);
    }
    if (!any) return null;
    const buf = sim.region_mats[0..r.area()];
    sim.terrain.materials(r, buf);
    var submerged: f32 = 0;
    var rho_sum: f32 = 0;
    for (0..r.h) |j| {
        const row = buf[j * r.w ..][0..r.w];
        var i: usize = 0;
        while (i < r.w) {
            if (row[i] != ts.body_owned) {
                i += 1;
                continue;
            }
            const a = i;
            while (i < r.w and row[i] == ts.body_owned) i += 1;
            const left: u8 = if (a > 0) row[a - 1] else 0;
            const right: u8 = if (i < r.w) row[i] else 0;
            const rho = @max(info[left].liquid_density, info[right].liquid_density);
            if (rho > 0) {
                const run: f32 = @floatFromInt(i - a);
                submerged += run;
                rho_sum += rho * run;
            }
        }
    }
    if (submerged == 0) return null;
    const count: f32 = @floatFromInt(sim.world.getPixelCount(rb.handle) orelse return null);
    const mass = sim.world.getMass(rb.handle) orelse return null;
    const frac = @min(submerged / @max(count, 1), 1);
    const sub = @min(submerged, count);
    const rho = rho_sum / submerged;
    const fw: f32 = @floatFromInt(rb.w);
    const fh: f32 = @floatFromInt(rb.h);
    return .{
        .drag = 2.0 * mass * frac,
        .angular_drag = 2.0 * mass * (fw * fw + fh * fh) / 12.0 * frac,
        .buoyancy = .{ .x = 0, .y = -rho * sub * bodies.gravity_px },
    };
}

// ---------------------------------------------------------------------------
// The pipeline subsystem

/// Bodies as a pipeline subsystem: owns the GPU rasterizer, the CPU body
/// simulation and today's terrain source (synchronous readback).
pub const Bodies = struct {
    alloc: Allocator,
    gpu_: bgpu.BodiesGpu,
    sync: *ts.SyncReadback,
    sim: *BodySim,

    pub fn init(ctx: *gpu.Context, cfg: pipeline_mod.Config, alloc: Allocator, cells_image: *const gpu.Image) !Bodies {
        _ = cfg;
        const sim_cfg: Config = .{};
        var g = try bgpu.BodiesGpu.init(ctx, .{ .atlas_bytes = sim_cfg.world.max_body_pixels }, alloc);
        errdefer g.deinit(alloc);
        const sync = try alloc.create(ts.SyncReadback);
        errdefer alloc.destroy(sync);
        sync.* = try ts.SyncReadback.init(ctx, cells_image, alloc);
        errdefer sync.deinit(alloc);
        const sim = try BodySim.create(alloc, sim_cfg, sync.source());
        return .{ .alloc = alloc, .gpu_ = g, .sync = sync, .sim = sim };
    }

    pub fn deinit(self: *Bodies) void {
        self.sim.destroy();
        self.sync.deinit(self.alloc);
        self.alloc.destroy(self.sync);
        self.gpu_.deinit(self.alloc);
    }

    pub fn setMaterials(self: *Bodies, lib: *const materials.Library) void {
        self.sync.setMaterials(lib.tables.materials[0..]);
        self.sim.setMaterials(&lib.set, lib.tables);
    }

    /// Engine, before recording a frame: ticks below `completed_tick` have
    /// been submitted, so a readback taken now (on the compute queue, after
    /// them) shows their results.
    pub fn beginFrame(self: *Bodies, completed_tick: u32) void {
        self.sync.completed_tick = completed_tick;
    }

    /// Engine, per tick, after the tick's command list is complete and
    /// before `Pipeline.recordTick`.
    pub fn tick(self: *Bodies, list: *const commands.CommandList, info: TickInfo) !void {
        try self.sim.tick(&self.gpu_, list, info);
    }

    /// Pipeline slot "rasterize bodies (M7)".
    pub fn record(self: *Bodies, frame: *Frame) void {
        self.gpu_.record(frame);
    }
};

test "identity instance maps pixel centers onto the bitmap" {
    const inst = identityInstance(37, -5, 10, 4, 0, 1);
    try std.testing.expectEqual(@as(i32, 32), inst.ax);
    try std.testing.expectEqual(@as(i32, -16), inst.ay);
    // World pixel 37 is AABB column 5: bitmap x = (l0x + 5 * cs) >> 16 = 0.
    try std.testing.expectEqual(@as(i32, 0), (inst.l0x + 5 * inst.cs) >> 16);
    try std.testing.expectEqual(@as(i32, -1), (inst.l0x + 4 * inst.cs) >> 16);
    try std.testing.expectEqual(@as(i32, 0), (inst.l0y + 11 * inst.cs) >> 16);
    try std.testing.expect(inst.aabbW() >= 15 and inst.aabbH() >= 15);
}

test "makeInstance covers a rotated body" {
    var px: [12 * 6]u8 = @splat(1);
    const angle: f32 = 0.6;
    const rb: bodies.RasterBody = .{
        .handle = .{ .index = 0, .gen = 0 },
        .transform = .{ .x = 100.3, .y = 50.7, .angle = angle, .cos = @cos(angle), .sin = @sin(angle) },
        .origin_x = 6,
        .origin_y = 3,
        .w = 12,
        .h = 6,
        .pixels = &px,
        .awake = true,
        .beam = null,
    };
    const inst = makeInstance(rb, 1, 0, .{ .x = 0, .y = 0 }, 0);
    try std.testing.expect(@mod(inst.ax, 16) == 0 and @mod(inst.ay, 16) == 0);
    // Count covered world pixels the way raster.comp does.
    var covered: u32 = 0;
    for (0..inst.aabbH()) |j| {
        for (0..inst.aabbW()) |i| {
            const ii: i32 = @intCast(i);
            const jj: i32 = @intCast(j);
            const bx = (inst.l0x + ii * inst.cs + jj * inst.sn) >> 16;
            const by = (inst.l0y - ii * inst.sn + jj * inst.cs) >> 16;
            if (bx >= 0 and by >= 0 and bx < 12 and by < 6) covered += 1;
        }
    }
    // Area is preserved to within the boundary pixels.
    try std.testing.expect(covered >= 72 - 12 and covered <= 72 + 12);
}

test "wrap shift" {
    try std.testing.expectEqual(@as(f32, 0), wrapShift(1000, 2048));
    try std.testing.expectEqual(@as(f32, -2048), wrapShift(1100, 2048));
    try std.testing.expectEqual(@as(f32, 2048), wrapShift(-1500, 2048));
    try std.testing.expectEqual(@as(f32, -4096), wrapShift(4000, 2048));
}
