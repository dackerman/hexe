//! CPU rigid-body layer: Box2D v3 integration, pixel-bitmap bodies, static
//! collision from the solid mask, and beams that bend plastically and snap.
//!
//! Units (docs/decisions/02-body-units.md):
//! - World units are grid pixels. 1 px = 5 cm, so Box2D's length scale is set
//!   to 20 units per meter with `b2SetLengthUnitsPerMeter` before the world is
//!   created; its slop, speculative margin and speed limits scale with it.
//! - y points down, like the grid. Gravity is (0, +196) px/s².
//! - Mass in kg. A pixel is a 5 cm cube, so material density is kg per pixel
//!   (steel ≈ 0.98, concrete ≈ 0.30, wood ≈ 0.075).
//! - Force kg·px/s², impulse kg·px/s, torque kg·px²/s², angle radians. A
//!   positive angle turns +x toward +y, which is clockwise on screen.
//!
//! Tick order the game follows: `setStaticCollision` (from last tick's
//! readback), `applyBlast`/`applyFluid`, `step`, then read `impacts`,
//! `jointBreaks` and `rasterIterator` to build the GPU rasterize commands.
//!
//! Allocation: everything is sized from `Config` in `init`. Per-tick paths
//! (`step`, `setStaticCollision`, forces, events, iteration) allocate nothing
//! on our side; Box2D allocates internally for its own shapes and contacts.
//! Body creation and splitting draw from preallocated pools and fail with
//! `error.OutOf*` when a pool is exhausted.

const std = @import("std");
const b2 = @import("box2d");

const Allocator = std.mem.Allocator;

/// Fixed simulation tick (docs/06-decisions.md D9).
pub const tick_dt: f32 = 1.0 / 60.0;
/// Box2D length units per meter: 1 px = 5 cm.
pub const px_per_meter: f32 = 20.0;
/// Gravity in px/s², +y down.
pub const gravity_px: f32 = 196.0;

pub const Vec2 = struct {
    x: f32,
    y: f32,

    fn b(v: Vec2) b2.b2Vec2 {
        return .{ .x = v.x, .y = v.y };
    }
    fn from(v: b2.b2Vec2) Vec2 {
        return .{ .x = v.x, .y = v.y };
    }
};

/// Body pose. `x, y` is the body origin in world pixels; a body-local point
/// (lx, ly) maps to world (x + c·lx − s·ly, y + s·lx + c·ly).
pub const Transform = struct {
    x: f32,
    y: f32,
    angle: f32,
    cos: f32,
    sin: f32,

    pub fn apply(t: Transform, lx: f32, ly: f32) Vec2 {
        return .{ .x = t.x + t.cos * lx - t.sin * ly, .y = t.y + t.sin * lx + t.cos * ly };
    }
    pub fn applyInverse(t: Transform, wx: f32, wy: f32) Vec2 {
        const dx = wx - t.x;
        const dy = wy - t.y;
        return .{ .x = t.cos * dx + t.sin * dy, .y = -t.sin * dx + t.cos * dy };
    }
};

// ---------------------------------------------------------------------------
// Materials

/// Beam joint behavior. Moments scale with thickness² (section modulus of a
/// rectangle per unit depth), forces with thickness. Values are in kg/s² for
/// moments (so M = k·t² is kg·px²/s² with t in px) and kg/(px·s²)·px for
/// forces (F = k·t, kg·px/s²). See docs/decisions/04-beam-yield-fracture.md.
pub const BeamProps = struct {
    /// Bending moment per thickness² above which the joint flows plastically.
    yield_moment: f32,
    /// Bending moment per thickness² above which the joint breaks.
    fracture_moment: f32,
    /// Joint force (tension/shear) per thickness above which the joint breaks.
    fracture_force: f32,
    /// Ductility: accumulated plastic bend (rad) at which a joint tears.
    fracture_plastic_angle: f32 = std.math.inf(f32),
    /// Fracture tests a moving average of |moment| and |force| with this
    /// weight per tick (1 = instantaneous). Ductile materials ride out
    /// one-tick contact spikes and bend instead; brittle ones break on them.
    fracture_smoothing: f32 = 1,
    /// Plastic flow rate: rest-angle change in rad/s per unit of relative
    /// overstress (|M|/M_yield − 1).
    flow_rate: f32,
    /// Cap on rest-angle change per tick, rad.
    max_flow_per_tick: f32 = 0.02,
    /// Weld angular stiffness in Hz; 0 = as stiff as the solver allows.
    angular_hertz: f32 = 0,
    angular_damping: f32 = 1,
};

pub const Material = struct {
    /// kg per pixel (a 5 cm cube).
    density: f32 = 0.25,
    friction: f32 = 0.6,
    restitution: f32 = 0.0,
    beam: BeamProps = presets.generic_beam,

    pub const presets = struct {
        const generic_beam: BeamProps = .{
            .yield_moment = 1.0e5,
            .fracture_moment = 1.5e5,
            .fracture_force = 2.0e6,
            .flow_rate = 0.5,
        };
        /// High yield, fracture 2.5x higher, ductile: creeps plastically once
        /// yielded and tears after about 30° of plastic bend at one joint.
        pub const steel: Material = .{
            .density = 0.98,
            .friction = 0.5,
            .restitution = 0.05,
            .beam = .{
                .yield_moment = 5.0e5,
                .fracture_moment = 1.25e6,
                .fracture_force = 2.0e7,
                .fracture_plastic_angle = 0.5,
                .fracture_smoothing = 0.15,
                .flow_rate = 0.08,
                .max_flow_per_tick = 0.003,
            },
        };
        /// Low yield, fracture just above it: snaps without much bending.
        pub const wood: Material = .{
            .density = 0.075,
            .friction = 0.7,
            .restitution = 0.1,
            .beam = .{
                .yield_moment = 6.0e4,
                .fracture_moment = 6.6e4,
                .fracture_force = 2.0e6,
                .fracture_plastic_angle = 0.1,
                .fracture_smoothing = 0.6,
                .flow_rate = 0.3,
                .max_flow_per_tick = 0.005,
            },
        };
        /// Brittle: no plastic range, breaks at yield; weak in tension.
        pub const concrete: Material = .{
            .density = 0.30,
            .friction = 0.8,
            .restitution = 0.0,
            .beam = .{
                .yield_moment = 1.0e5,
                .fracture_moment = 1.0e5,
                .fracture_force = 3.0e5,
                .flow_rate = 0.0,
            },
        };
    };
};

// ---------------------------------------------------------------------------
// Greedy rectangle decomposition

pub const Rect = struct { x: u16, y: u16, w: u16, h: u16 };

/// Cover the nonzero cells of `grid` (w × h, row stride `stride`) exactly with
/// disjoint axis-aligned rectangles. Greedy: scan rows top to bottom, at each
/// uncovered solid cell extend right as far as possible, then down while the
/// whole span stays solid and uncovered. `visited` needs w·h entries.
pub fn decomposeRects(
    grid: []const u8,
    w: usize,
    h: usize,
    stride: usize,
    visited: []bool,
    out: []Rect,
) error{TooManyRects}![]Rect {
    std.debug.assert(visited.len >= w * h);
    std.debug.assert(h == 0 or grid.len >= (h - 1) * stride + w);
    @memset(visited[0 .. w * h], false);
    var n: usize = 0;
    for (0..h) |y| {
        var x: usize = 0;
        while (x < w) : (x += 1) {
            if (grid[y * stride + x] == 0 or visited[y * w + x]) continue;
            var rw: usize = 1;
            while (x + rw < w and grid[y * stride + x + rw] != 0 and !visited[y * w + x + rw]) rw += 1;
            var rh: usize = 1;
            grow: while (y + rh < h) {
                const row = y + rh;
                for (x..x + rw) |xx| {
                    if (grid[row * stride + xx] == 0 or visited[row * w + xx]) break :grow;
                }
                rh += 1;
            }
            for (y..y + rh) |yy| @memset(visited[yy * w + x .. yy * w + x + rw], true);
            if (n == out.len) return error.TooManyRects;
            out[n] = .{ .x = @intCast(x), .y = @intCast(y), .w = @intCast(rw), .h = @intCast(rh) };
            n += 1;
            x += rw - 1;
        }
    }
    return out[0..n];
}

// ---------------------------------------------------------------------------
// Connectivity split

pub const Component = struct {
    /// Offset of this component's bitmap inside the source bitmap.
    x: u16,
    y: u16,
    w: u16,
    h: u16,
    pixel_count: u32,
    /// w × h material ids, 0 = empty. Points into `SplitScratch`.
    pixels: []u8,
};

/// Preallocated working memory for `splitByConnectivity`.
pub const SplitScratch = struct {
    labels: []u32,
    stack: []u32,
    pixels: []u8,
    components: []Component,

    /// `max_pixels`: largest source bitmap (w·h). Output pixel storage is
    /// 2 × max_pixels, enough unless component bounding boxes overlap heavily.
    pub fn init(alloc: Allocator, max_pixels: usize, max_components: usize) !SplitScratch {
        const labels = try alloc.alloc(u32, max_pixels);
        errdefer alloc.free(labels);
        const stack = try alloc.alloc(u32, max_pixels);
        errdefer alloc.free(stack);
        const pixels = try alloc.alloc(u8, 2 * max_pixels);
        errdefer alloc.free(pixels);
        const components = try alloc.alloc(Component, max_components);
        return .{ .labels = labels, .stack = stack, .pixels = pixels, .components = components };
    }

    pub fn deinit(self: *SplitScratch, alloc: Allocator) void {
        alloc.free(self.labels);
        alloc.free(self.stack);
        alloc.free(self.pixels);
        alloc.free(self.components);
        self.* = undefined;
    }
};

pub const SplitError = error{ BitmapTooLarge, TooManyComponents, OutOfSplitScratch };

/// Split a bitmap into its 4-connected components of nonzero pixels. Each
/// component gets its own tight bitmap plus its offset in the source.
/// Components are ordered by their first pixel in row-major order. The
/// result lives in `scratch` until the next call.
pub fn splitByConnectivity(bitmap: []const u8, w: u16, h: u16, scratch: *SplitScratch) SplitError![]const Component {
    const n: usize = @as(usize, w) * h;
    if (n > scratch.labels.len) return error.BitmapTooLarge;
    std.debug.assert(bitmap.len >= n);
    const labels = scratch.labels[0..n];
    @memset(labels, 0);
    var count: usize = 0;
    for (0..n) |start| {
        if (bitmap[start] == 0 or labels[start] != 0) continue;
        if (count == scratch.components.len) return error.TooManyComponents;
        const label: u32 = @intCast(count + 1);
        var x0: usize = start % w;
        var x1: usize = x0;
        const y0: usize = start / w;
        var y1: usize = y0;
        var pc: u32 = 0;
        var sp: usize = 0;
        scratch.stack[sp] = @intCast(start);
        sp += 1;
        labels[start] = label;
        while (sp > 0) {
            sp -= 1;
            const i = scratch.stack[sp];
            pc += 1;
            const x = i % w;
            const y = i / w;
            x0 = @min(x0, x);
            x1 = @max(x1, x);
            y1 = @max(y1, y);
            const neighbors = [4]?u32{
                if (x > 0) i - 1 else null,
                if (x + 1 < w) i + 1 else null,
                if (y > 0) i - w else null,
                if (y + 1 < h) i + w else null,
            };
            for (neighbors) |maybe| {
                const j = maybe orelse continue;
                if (bitmap[j] != 0 and labels[j] == 0) {
                    labels[j] = label;
                    scratch.stack[sp] = j;
                    sp += 1;
                }
            }
        }
        scratch.components[count] = .{
            .x = @intCast(x0),
            .y = @intCast(y0),
            .w = @intCast(x1 - x0 + 1),
            .h = @intCast(y1 - y0 + 1),
            .pixel_count = pc,
            .pixels = &.{},
        };
        count += 1;
    }
    var used: usize = 0;
    for (scratch.components[0..count], 0..) |*c, ci| {
        const area = @as(usize, c.w) * c.h;
        if (used + area > scratch.pixels.len) return error.OutOfSplitScratch;
        c.pixels = scratch.pixels[used .. used + area];
        used += area;
        const label: u32 = @intCast(ci + 1);
        for (0..c.h) |yy| {
            for (0..c.w) |xx| {
                const src = (c.y + yy) * @as(usize, w) + c.x + xx;
                c.pixels[yy * c.w + xx] = if (labels[src] == label) bitmap[src] else 0;
            }
        }
    }
    return scratch.components[0..count];
}

// ---------------------------------------------------------------------------
// Pixel storage: first-fit span allocator over one preallocated buffer

const SpanAllocator = struct {
    const Span = struct { off: u32, len: u32 };
    free_spans: []Span,
    count: usize,

    /// The free list never holds more than (live allocations + 1) spans, so
    /// `max_allocs + 1` entries is enough.
    fn init(alloc: Allocator, total: u32, max_allocs: usize) !SpanAllocator {
        const spans = try alloc.alloc(Span, max_allocs + 1);
        spans[0] = .{ .off = 0, .len = total };
        return .{ .free_spans = spans, .count = if (total > 0) 1 else 0 };
    }

    fn deinit(self: *SpanAllocator, alloc: Allocator) void {
        alloc.free(self.free_spans);
    }

    fn allocSpan(self: *SpanAllocator, len: u32) ?u32 {
        std.debug.assert(len > 0);
        for (self.free_spans[0..self.count], 0..) |*s, i| {
            if (s.len < len) continue;
            const off = s.off;
            s.off += len;
            s.len -= len;
            if (s.len == 0) {
                std.mem.copyForwards(Span, self.free_spans[i .. self.count - 1], self.free_spans[i + 1 .. self.count]);
                self.count -= 1;
            }
            return off;
        }
        return null;
    }

    fn freeSpan(self: *SpanAllocator, off: u32, len: u32) void {
        var i: usize = 0;
        while (i < self.count and self.free_spans[i].off < off) i += 1;
        const merge_prev = i > 0 and self.free_spans[i - 1].off + self.free_spans[i - 1].len == off;
        const merge_next = i < self.count and off + len == self.free_spans[i].off;
        if (merge_prev and merge_next) {
            self.free_spans[i - 1].len += len + self.free_spans[i].len;
            std.mem.copyForwards(Span, self.free_spans[i .. self.count - 1], self.free_spans[i + 1 .. self.count]);
            self.count -= 1;
        } else if (merge_prev) {
            self.free_spans[i - 1].len += len;
        } else if (merge_next) {
            self.free_spans[i].off = off;
            self.free_spans[i].len += len;
        } else {
            std.debug.assert(self.count < self.free_spans.len);
            std.mem.copyBackwards(Span, self.free_spans[i + 1 .. self.count + 1], self.free_spans[i..self.count]);
            self.free_spans[i] = .{ .off = off, .len = len };
            self.count += 1;
        }
    }
};

// ---------------------------------------------------------------------------
// Public handles and event records

pub const BodyHandle = struct {
    index: u32,
    gen: u32,
    pub fn eql(a: BodyHandle, other: BodyHandle) bool {
        return a.index == other.index and a.gen == other.gen;
    }
};

pub const BeamHandle = struct {
    index: u32,
    gen: u32,
};

pub const JointId = b2.b2JointId;

/// A contact whose normal impulse this step exceeded `Config.impact_impulse`.
/// A null body is static terrain.
pub const Impact = struct {
    body_a: ?BodyHandle,
    body_b: ?BodyHandle,
    /// World point, px.
    x: f32,
    y: f32,
    /// Unit normal from A to B.
    normal_x: f32,
    normal_y: f32,
    /// Collision impulse needed to stop the approach: reduced mass ×
    /// approach speed, kg·px/s. Box2D's soft contacts spread the actual
    /// impulse over a few steps, so this is the stable measure to threshold.
    normal_impulse: f32,
    /// Normal impulse Box2D applied in this step alone, kg·px/s.
    solver_impulse: f32,
    /// Approach speed before the step, px/s.
    approach_speed: f32,
};

/// A beam joint that exceeded its fracture threshold this step.
pub const JointBreak = struct {
    beam: BeamHandle,
    /// Index into the beam's joint list: 0 = start anchor, k (1..segments-1)
    /// = between segment k-1 and k, `segments` = end anchor.
    joint_index: u16,
    x: f32,
    y: f32,
    /// |moment| and |force| that broke it.
    moment: f32,
    force: f32,
};

/// Everything the GPU rasterize pass needs for one body. Pixel (i, j) of
/// the bitmap has body-local center (i + 0.5 − origin_x, j + 0.5 − origin_y);
/// `transform.apply` maps it to world pixels.
pub const RasterBody = struct {
    handle: BodyHandle,
    transform: Transform,
    origin_x: f32,
    origin_y: f32,
    w: u16,
    h: u16,
    /// Row-major material ids, 0 = empty.
    pixels: []const u8,
    awake: bool,
    beam: ?BeamHandle,
};

pub const Config = struct {
    substeps: u8 = 4,
    /// Position-correction stiffness of rigid joint constraints (Box2D
    /// `constraintHertz`), Hz, and its damping ratio.
    joint_hertz: f32 = 60,
    joint_damping: f32 = 2,
    /// Beam segments get their rotational inertia multiplied by this. Box2D's
    /// soft "rigid" joints have an angular stiffness of roughly
    /// I_segment / h², far too low for a long chain of light segments to
    /// carry a bending moment; inflating segment inertia stiffens the chain
    /// while changing the whole beam's inertia only slightly (it is dominated
    /// by the parallel-axis term). See docs/decisions/04-beam-yield-fracture.md.
    beam_inertia_scale: f32 = 60,
    max_bodies: u32 = 4096,
    /// Total bitmap bytes across all live bodies.
    max_body_pixels: u32 = 1 << 22,
    /// Largest single bitmap (w·h) accepted by body creation and splitting.
    max_bitmap_pixels: u32 = 256 * 256,
    max_split_components: u32 = 512,
    max_beams: u32 = 256,
    max_beam_segments: u16 = 64,
    /// Largest static mask region accepted by `setStaticCollision`.
    static_max_w: u32 = 2048,
    static_max_h: u32 = 2048,
    /// Static collision is rebuilt per tile of this many pixels, and only
    /// when a tile's content hash changes.
    static_tile: u16 = 64,
    /// Coarse granularity (px) for tiles with no body nearby. A coarse cell
    /// is solid when at least half of its pixels are.
    static_coarse: u8 = 4,
    /// Tiles within this distance of a body's bounding circle are built at
    /// exact pixel resolution.
    static_fine_margin: f32 = 24,
    /// Box2D hit-event speed threshold, px/s.
    hit_speed_threshold: f32 = 20,
    /// Impacts whose `normal_impulse` is below this are not reported, kg·px/s.
    impact_impulse: f32 = 500,
    max_impacts: u32 = 1024,
    max_joint_breaks: u32 = 256,
};

pub const Error = error{
    EmptyBitmap,
    BitmapTooLarge,
    OutOfBodySlots,
    OutOfBodyPixels,
    OutOfBeamSlots,
    TooManySegments,
    TooManyRects,
    InvalidHandle,
    InvalidBeam,
    RegionTooLarge,
} || SplitError;

// ---------------------------------------------------------------------------
// BodyWorld

const no_beam = std.math.maxInt(u32);

const BodySlot = struct {
    id: b2.b2BodyId = undefined,
    gen: u32 = 0,
    live: bool = false,
    beam: u32 = no_beam,
    pix_off: u32 = 0,
    w: u16 = 0,
    h: u16 = 0,
    origin_x: f32 = 0,
    origin_y: f32 = 0,
    pixel_count: u32 = 0,
    /// Bounding radius about the body origin, px.
    radius: f32 = 0,
    material: u8 = 0,
    user: u32 = 0,
};

const BeamJoint = struct {
    id: b2.b2JointId = undefined,
    alive: bool = false,
    /// Multiplier on the material thresholds (1 = intact). Cuts lower it.
    strength: f32 = 1,
    /// Accumulated plastic rest-angle change, rad.
    plastic_angle: f32 = 0,
    /// Last step's |moment| and |force| as fractions of the yield moment and
    /// the fracture force (0 while asleep).
    moment_ratio: f32 = 0,
    force_ratio: f32 = 0,
    /// Smoothed |moment| and |force| for the fracture test.
    moment_avg: f32 = 0,
    force_avg: f32 = 0,
};

const BeamSlot = struct {
    live: bool = false,
    gen: u32 = 0,
    material: u8 = 0,
    thickness: u16 = 0,
    segments: u16 = 0,
    seg_len: u16 = 0,
    x0: f32 = 0,
    y0: f32 = 0,
    angle: f32 = 0,
};

const TileSlot = struct {
    valid: bool = false,
    has_body: bool = false,
    tx: i32 = 0,
    ty: i32 = 0,
    hash: u64 = 0,
    seen: u32 = 0,
    body: b2.b2BodyId = undefined,
};

pub const StaticStats = struct {
    tiles: u32 = 0,
    tiles_rebuilt: u32 = 0,
    shapes_created: u32 = 0,
};

pub const BodyWorld = struct {
    alloc: Allocator,
    cfg: Config,
    world: b2.b2WorldId,
    /// Shapeless static body that beam anchors and `weld(…, null, …)` attach to.
    anchor: b2.b2BodyId,
    materials: [256]Material,

    slots: []BodySlot,
    free_slots: []u32,
    free_slot_count: usize,
    pixels: []u8,
    spans: SpanAllocator,

    beams: []BeamSlot,
    beam_segs: []BodyHandle,
    beam_joints: []BeamJoint,

    tiles: []TileSlot,
    tiles_nx: u32,
    tiles_ny: u32,
    tile_fine: []bool,
    static_pass: u32 = 0,
    static_stats: StaticStats = .{},

    visited: []bool,
    coarse: []u8,
    rects: []Rect,
    shape_ids: []b2.b2ShapeId,
    split: SplitScratch,
    split_bitmap: []u8,
    new_handles: []BodyHandle,

    impact_buf: []Impact,
    impact_count: usize = 0,
    impacts_dropped: usize = 0,
    break_buf: []JointBreak,
    break_count: usize = 0,
    tick: u64 = 0,

    pub fn init(alloc: Allocator, cfg: Config) !BodyWorld {
        std.debug.assert(cfg.static_tile > 0 and cfg.static_coarse > 0);
        b2.b2SetLengthUnitsPerMeter(px_per_meter);
        var def = b2.b2DefaultWorldDef();
        def.gravity = .{ .x = 0, .y = gravity_px };
        def.hitEventThreshold = cfg.hit_speed_threshold;
        const world = b2.b2CreateWorld(&def);
        errdefer b2.b2DestroyWorld(world);

        var adef = b2.b2DefaultBodyDef();
        adef.type = b2.b2_staticBody;
        const anchor = b2.b2CreateBody(world, &adef);

        const slots = try alloc.alloc(BodySlot, cfg.max_bodies);
        errdefer alloc.free(slots);
        @memset(slots, .{});
        const free_slots = try alloc.alloc(u32, cfg.max_bodies);
        errdefer alloc.free(free_slots);
        for (free_slots, 0..) |*f, i| f.* = @intCast(cfg.max_bodies - 1 - i);
        const pixels = try alloc.alloc(u8, cfg.max_body_pixels);
        errdefer alloc.free(pixels);
        var spans = try SpanAllocator.init(alloc, cfg.max_body_pixels, cfg.max_bodies);
        errdefer spans.deinit(alloc);

        const beams = try alloc.alloc(BeamSlot, cfg.max_beams);
        errdefer alloc.free(beams);
        @memset(beams, .{});
        const beam_segs = try alloc.alloc(BodyHandle, cfg.max_beams * cfg.max_beam_segments);
        errdefer alloc.free(beam_segs);
        const beam_joints = try alloc.alloc(BeamJoint, cfg.max_beams * (@as(usize, cfg.max_beam_segments) + 1));
        errdefer alloc.free(beam_joints);
        @memset(beam_joints, .{});

        const tiles_nx = cfg.static_max_w / cfg.static_tile + 2;
        const tiles_ny = cfg.static_max_h / cfg.static_tile + 2;
        const tiles = try alloc.alloc(TileSlot, tiles_nx * tiles_ny);
        errdefer alloc.free(tiles);
        @memset(tiles, .{});
        const tile_fine = try alloc.alloc(bool, tiles_nx * tiles_ny);
        errdefer alloc.free(tile_fine);

        const tile_px = @as(usize, cfg.static_tile) * cfg.static_tile;
        const grid_max = @max(tile_px, cfg.max_bitmap_pixels);
        const visited = try alloc.alloc(bool, grid_max);
        errdefer alloc.free(visited);
        const coarse = try alloc.alloc(u8, tile_px);
        errdefer alloc.free(coarse);
        const rects = try alloc.alloc(Rect, grid_max / 2 + 1);
        errdefer alloc.free(rects);
        const shape_ids = try alloc.alloc(b2.b2ShapeId, grid_max / 2 + 1);
        errdefer alloc.free(shape_ids);
        var split = try SplitScratch.init(alloc, cfg.max_bitmap_pixels, cfg.max_split_components);
        errdefer split.deinit(alloc);
        const split_bitmap = try alloc.alloc(u8, cfg.max_bitmap_pixels);
        errdefer alloc.free(split_bitmap);
        const new_handles = try alloc.alloc(BodyHandle, cfg.max_split_components);
        errdefer alloc.free(new_handles);
        const impact_buf = try alloc.alloc(Impact, cfg.max_impacts);
        errdefer alloc.free(impact_buf);
        const break_buf = try alloc.alloc(JointBreak, cfg.max_joint_breaks);
        errdefer alloc.free(break_buf);

        var materials: [256]Material = undefined;
        @memset(&materials, .{});

        return .{
            .alloc = alloc,
            .cfg = cfg,
            .world = world,
            .anchor = anchor,
            .materials = materials,
            .slots = slots,
            .free_slots = free_slots,
            .free_slot_count = cfg.max_bodies,
            .pixels = pixels,
            .spans = spans,
            .beams = beams,
            .beam_segs = beam_segs,
            .beam_joints = beam_joints,
            .tiles = tiles,
            .tiles_nx = tiles_nx,
            .tiles_ny = tiles_ny,
            .tile_fine = tile_fine,
            .visited = visited,
            .coarse = coarse,
            .rects = rects,
            .shape_ids = shape_ids,
            .split = split,
            .split_bitmap = split_bitmap,
            .new_handles = new_handles,
            .impact_buf = impact_buf,
            .break_buf = break_buf,
        };
    }

    pub fn deinit(self: *BodyWorld) void {
        b2.b2DestroyWorld(self.world);
        const a = self.alloc;
        a.free(self.slots);
        a.free(self.free_slots);
        a.free(self.pixels);
        self.spans.deinit(a);
        a.free(self.beams);
        a.free(self.beam_segs);
        a.free(self.beam_joints);
        a.free(self.tiles);
        a.free(self.tile_fine);
        a.free(self.visited);
        a.free(self.coarse);
        a.free(self.rects);
        a.free(self.shape_ids);
        self.split.deinit(a);
        a.free(self.split_bitmap);
        a.free(self.new_handles);
        a.free(self.impact_buf);
        a.free(self.break_buf);
        self.* = undefined;
    }

    pub fn setMaterial(self: *BodyWorld, id: u8, m: Material) void {
        self.materials[id] = m;
    }

    // -- stepping -----------------------------------------------------------

    /// Advance one fixed tick (1/60 s, `Config.substeps` sub-steps), then run
    /// beam yield/fracture and collect impact events.
    pub fn step(self: *BodyWorld) void {
        self.impact_count = 0;
        self.impacts_dropped = 0;
        self.break_count = 0;
        b2.b2World_Step(self.world, tick_dt, self.cfg.substeps);
        self.tick += 1;
        self.updateBeams();
        self.collectImpacts();
    }

    pub fn impacts(self: *const BodyWorld) []const Impact {
        return self.impact_buf[0..self.impact_count];
    }

    pub fn jointBreaks(self: *const BodyWorld) []const JointBreak {
        return self.break_buf[0..self.break_count];
    }

    fn handleFromB2(self: *const BodyWorld, id: b2.b2BodyId) ?BodyHandle {
        const ud = @intFromPtr(b2.b2Body_GetUserData(id));
        if (ud == 0) return null;
        const index: u32 = @intCast(ud - 1);
        const s = &self.slots[index];
        if (!s.live) return null;
        return .{ .index = index, .gen = s.gen };
    }

    fn collectImpacts(self: *BodyWorld) void {
        const ev = b2.b2World_GetContactEvents(self.world);
        const n: usize = @intCast(ev.hitCount);
        for (ev.hitEvents[0..n]) |e| {
            if (!b2.b2Shape_IsValid(e.shapeIdA) or !b2.b2Shape_IsValid(e.shapeIdB)) continue;
            const ba = b2.b2Shape_GetBody(e.shapeIdA);
            const bb = b2.b2Shape_GetBody(e.shapeIdB);
            var solver_impulse: f32 = 0;
            if (b2.b2Contact_IsValid(e.contactId)) {
                const data = b2.b2Contact_GetData(e.contactId);
                const pc: usize = @intCast(data.manifold.pointCount);
                for (data.manifold.points[0..pc]) |p| solver_impulse += p.totalNormalImpulse;
            }
            const ma = bodyMassOrInf(ba);
            const mb = bodyMassOrInf(bb);
            const m_red = if (std.math.isInf(ma)) mb else if (std.math.isInf(mb)) ma else ma * mb / (ma + mb);
            const impulse = if (std.math.isInf(m_red)) solver_impulse else e.approachSpeed * m_red;
            if (impulse < self.cfg.impact_impulse) continue;
            if (self.impact_count == self.impact_buf.len) {
                self.impacts_dropped += 1;
                continue;
            }
            self.impact_buf[self.impact_count] = .{
                .body_a = self.handleFromB2(ba),
                .body_b = self.handleFromB2(bb),
                .x = e.point.x,
                .y = e.point.y,
                .normal_x = e.normal.x,
                .normal_y = e.normal.y,
                .normal_impulse = impulse,
                .solver_impulse = solver_impulse,
                .approach_speed = e.approachSpeed,
            };
            self.impact_count += 1;
        }
    }

    fn bodyMassOrInf(id: b2.b2BodyId) f32 {
        if (b2.b2Body_GetType(id) != b2.b2_dynamicBody) return std.math.inf(f32);
        return b2.b2Body_GetMass(id);
    }

    // -- bodies -------------------------------------------------------------

    pub const PixelBodyDesc = struct {
        /// w × h material ids, row-major, 0 = empty. Copied.
        pixels: []const u8,
        w: u16,
        h: u16,
        /// World position of the body origin, px.
        x: f32,
        y: f32,
        /// Body origin in bitmap pixel coordinates (0,0 = top-left corner).
        origin_x: f32 = 0,
        origin_y: f32 = 0,
        angle: f32 = 0,
        vx: f32 = 0,
        vy: f32 = 0,
        angular_velocity: f32 = 0,
        /// Continuous collision against other dynamic bodies.
        bullet: bool = false,
        user: u32 = 0,
    };

    pub fn createPixelBody(self: *BodyWorld, desc: PixelBodyDesc) Error!BodyHandle {
        return self.createBodyInternal(desc, no_beam);
    }

    pub fn destroyBody(self: *BodyWorld, h: BodyHandle) void {
        const s = self.slotPtr(h) orelse return;
        b2.b2DestroyBody(s.id);
        self.releaseSlot(h.index);
    }

    fn releaseSlot(self: *BodyWorld, index: u32) void {
        const s = &self.slots[index];
        self.spans.freeSpan(s.pix_off, @as(u32, s.w) * s.h);
        s.live = false;
        s.gen +%= 1;
        self.free_slots[self.free_slot_count] = index;
        self.free_slot_count += 1;
    }

    fn slotPtr(self: *BodyWorld, h: BodyHandle) ?*BodySlot {
        if (h.index >= self.slots.len) return null;
        const s = &self.slots[h.index];
        if (!s.live or s.gen != h.gen) return null;
        return s;
    }

    fn slotConst(self: *const BodyWorld, h: BodyHandle) ?*const BodySlot {
        if (h.index >= self.slots.len) return null;
        const s = &self.slots[h.index];
        if (!s.live or s.gen != h.gen) return null;
        return s;
    }

    pub fn isValid(self: *const BodyWorld, h: BodyHandle) bool {
        return self.slotConst(h) != null;
    }

    pub fn bodyCount(self: *const BodyWorld) usize {
        return self.slots.len - self.free_slot_count;
    }

    const MassProps = struct { mass: f32, cx: f32, cy: f32, inertia: f32, dominant: u8, count: u32, radius: f32 };

    fn computeMass(self: *const BodyWorld, pixels: []const u8, w: u16, h: u16, ox: f32, oy: f32) MassProps {
        var hist: [256]u32 = @splat(0);
        var m: f64 = 0;
        var mx: f64 = 0;
        var my: f64 = 0;
        var mi: f64 = 0;
        var count: u32 = 0;
        for (0..h) |j| {
            for (0..w) |i| {
                const id = pixels[j * w + i];
                if (id == 0) continue;
                hist[id] += 1;
                count += 1;
                const pm: f64 = self.materials[id].density;
                const lx: f64 = @as(f64, @floatFromInt(i)) + 0.5 - ox;
                const ly: f64 = @as(f64, @floatFromInt(j)) + 0.5 - oy;
                m += pm;
                mx += pm * lx;
                my += pm * ly;
                mi += pm * (lx * lx + ly * ly + 1.0 / 6.0);
            }
        }
        var dominant: u8 = 0;
        for (hist, 0..) |c, id| {
            if (c > hist[dominant]) dominant = @intCast(id);
        }
        const cx = if (m > 0) mx / m else 0;
        const cy = if (m > 0) my / m else 0;
        const fw: f32 = @floatFromInt(w);
        const fh: f32 = @floatFromInt(h);
        var r2: f32 = 0;
        for ([_][2]f32{ .{ 0, 0 }, .{ fw, 0 }, .{ 0, fh }, .{ fw, fh } }) |c| {
            const dx = c[0] - ox;
            const dy = c[1] - oy;
            r2 = @max(r2, dx * dx + dy * dy);
        }
        return .{
            .mass = @floatCast(m),
            .cx = @floatCast(cx),
            .cy = @floatCast(cy),
            .inertia = @floatCast(@max(mi - m * (cx * cx + cy * cy), 1e-6)),
            .dominant = dominant,
            .count = count,
            .radius = @sqrt(r2),
        };
    }

    /// Create the shapes of a body from its bitmap and set its mass. Shapes
    /// are a compound of boxes from `decomposeRects`; mass, center and
    /// inertia are summed per pixel from material densities.
    fn buildShapes(self: *BodyWorld, id: b2.b2BodyId, pixels: []const u8, w: u16, h: u16, ox: f32, oy: f32, mp: MassProps, is_beam: bool) Error!void {
        const rects = try decomposeRects(pixels, w, h, w, self.visited, self.rects);
        const mat = self.materials[mp.dominant];
        var sdef = b2.b2DefaultShapeDef();
        sdef.density = 1;
        sdef.updateBodyMass = false;
        sdef.enableHitEvents = true;
        sdef.material.friction = mat.friction;
        sdef.material.restitution = mat.restitution;
        for (rects) |r| {
            const hw = @as(f32, @floatFromInt(r.w)) * 0.5;
            const hh = @as(f32, @floatFromInt(r.h)) * 0.5;
            const c: b2.b2Vec2 = .{ .x = @as(f32, @floatFromInt(r.x)) + hw - ox, .y = @as(f32, @floatFromInt(r.y)) + hh - oy };
            const poly = b2.b2MakeOffsetBox(hw, hh, c, .{ .c = 1, .s = 0 });
            _ = b2.b2CreatePolygonShape(id, &sdef, &poly);
        }
        b2.b2Body_SetMassData(id, .{ .mass = mp.mass, .center = .{ .x = mp.cx, .y = mp.cy }, .rotationalInertia = if (is_beam) mp.inertia * self.cfg.beam_inertia_scale else mp.inertia });
    }

    fn createBodyInternal(self: *BodyWorld, desc: PixelBodyDesc, beam: u32) Error!BodyHandle {
        const area: u32 = @as(u32, desc.w) * desc.h;
        if (area == 0) return error.EmptyBitmap;
        if (area > self.cfg.max_bitmap_pixels) return error.BitmapTooLarge;
        std.debug.assert(desc.pixels.len >= area);
        const mp = self.computeMass(desc.pixels, desc.w, desc.h, desc.origin_x, desc.origin_y);
        if (mp.count == 0) return error.EmptyBitmap;
        if (self.free_slot_count == 0) return error.OutOfBodySlots;
        const off = self.spans.allocSpan(area) orelse return error.OutOfBodyPixels;
        self.free_slot_count -= 1;
        const index = self.free_slots[self.free_slot_count];
        const s = &self.slots[index];
        @memcpy(self.pixels[off .. off + area], desc.pixels[0..area]);

        var bdef = b2.b2DefaultBodyDef();
        bdef.type = b2.b2_dynamicBody;
        bdef.position = .{ .x = desc.x, .y = desc.y };
        bdef.rotation = b2.b2MakeRot(desc.angle);
        bdef.linearVelocity = .{ .x = desc.vx, .y = desc.vy };
        bdef.angularVelocity = desc.angular_velocity;
        bdef.isBullet = desc.bullet;
        bdef.userData = @ptrFromInt(@as(usize, index) + 1);
        const id = b2.b2CreateBody(self.world, &bdef);

        s.* = .{
            .id = id,
            .gen = s.gen,
            .live = true,
            .beam = beam,
            .pix_off = off,
            .w = desc.w,
            .h = desc.h,
            .origin_x = desc.origin_x,
            .origin_y = desc.origin_y,
            .pixel_count = mp.count,
            .radius = mp.radius,
            .material = mp.dominant,
            .user = desc.user,
        };
        const handle: BodyHandle = .{ .index = index, .gen = s.gen };
        self.buildShapes(id, self.pixels[off .. off + area], desc.w, desc.h, desc.origin_x, desc.origin_y, mp, beam != no_beam) catch |err| {
            self.destroyBody(handle);
            return err;
        };
        return handle;
    }

    /// Replace a body's bitmap after cells were destroyed (or added) and
    /// split it into 4-connected pieces. The first piece keeps the handle,
    /// the body origin and any joints; the others become new free bodies with
    /// the same pose and the velocity of the original at their centers. An
    /// all-empty bitmap destroys the body. `origin_x/y` are where the body
    /// origin sits in the new bitmap. Returns the handles of all pieces (the
    /// first is `h` unless the body was destroyed), valid until the next call.
    pub fn splitBody(self: *BodyWorld, h: BodyHandle, pixels: []const u8, w: u16, hh: u16, origin_x: f32, origin_y: f32) Error![]const BodyHandle {
        const s = self.slotPtr(h) orelse return error.InvalidHandle;
        const comps = try splitByConnectivity(pixels, w, hh, &self.split);
        if (comps.len == 0) {
            self.destroyBody(h);
            return self.new_handles[0..0];
        }
        const xf = self.getTransformId(s.id);
        const av = b2.b2Body_GetAngularVelocity(s.id);
        const old_id = s.id;
        const user = s.user;
        var n: usize = 1;
        for (comps[1..]) |c| {
            const desc: PixelBodyDesc = .{
                .pixels = c.pixels,
                .w = c.w,
                .h = c.h,
                .x = xf.x,
                .y = xf.y,
                .origin_x = origin_x - @as(f32, @floatFromInt(c.x)),
                .origin_y = origin_y - @as(f32, @floatFromInt(c.y)),
                .angle = xf.angle,
                .user = user,
            };
            const nh = try self.createBodyInternal(desc, no_beam);
            const nid = self.slots[nh.index].id;
            const pv = b2.b2Body_GetWorldPointVelocity(old_id, b2.b2Body_GetWorldCenter(nid));
            b2.b2Body_SetLinearVelocity(nid, pv);
            b2.b2Body_SetAngularVelocity(nid, av);
            self.new_handles[n] = nh;
            n += 1;
        }
        // Rebuild the first piece in place. Allocate before freeing so a
        // failure leaves the body as it was.
        const c0 = comps[0];
        const s0 = self.slotPtr(h).?;
        const area: u32 = @as(u32, c0.w) * c0.h;
        const off = self.spans.allocSpan(area) orelse return error.OutOfBodyPixels;
        self.spans.freeSpan(s0.pix_off, @as(u32, s0.w) * s0.h);
        @memcpy(self.pixels[off .. off + area], c0.pixels);
        const ox = origin_x - @as(f32, @floatFromInt(c0.x));
        const oy = origin_y - @as(f32, @floatFromInt(c0.y));
        const mp = self.computeMass(c0.pixels, c0.w, c0.h, ox, oy);
        // Velocity of the old motion at the new center of mass.
        const new_com = xf.apply(mp.cx, mp.cy);
        const v0 = b2.b2Body_GetWorldPointVelocity(old_id, .{ .x = new_com.x, .y = new_com.y });
        const shape_cap: c_int = @intCast(self.shape_ids.len);
        while (true) {
            const ns: usize = @intCast(b2.b2Body_GetShapes(old_id, self.shape_ids.ptr, shape_cap));
            if (ns == 0) break;
            for (self.shape_ids[0..ns]) |sid| b2.b2DestroyShape(sid, false);
        }
        s0.pix_off = off;
        s0.w = c0.w;
        s0.h = c0.h;
        s0.origin_x = ox;
        s0.origin_y = oy;
        s0.pixel_count = mp.count;
        s0.radius = mp.radius;
        s0.material = mp.dominant;
        try self.buildShapes(old_id, self.pixels[off .. off + area], c0.w, c0.h, ox, oy, mp, s0.beam != no_beam);
        b2.b2Body_SetLinearVelocity(old_id, v0);
        b2.b2Body_SetAngularVelocity(old_id, av);
        self.new_handles[0] = h;
        return self.new_handles[0..n];
    }

    // -- queries ------------------------------------------------------------

    fn getTransformId(_: *const BodyWorld, id: b2.b2BodyId) Transform {
        const t = b2.b2Body_GetTransform(id);
        return .{ .x = t.p.x, .y = t.p.y, .angle = b2.b2Rot_GetAngle(t.q), .cos = t.q.c, .sin = t.q.s };
    }

    pub fn getTransform(self: *const BodyWorld, h: BodyHandle) ?Transform {
        const s = self.slotConst(h) orelse return null;
        return self.getTransformId(s.id);
    }

    pub const Bitmap = struct { pixels: []const u8, w: u16, h: u16, origin_x: f32, origin_y: f32 };

    pub fn getBitmap(self: *const BodyWorld, h: BodyHandle) ?Bitmap {
        const s = self.slotConst(h) orelse return null;
        const area = @as(usize, s.w) * s.h;
        return .{ .pixels = self.pixels[s.pix_off .. s.pix_off + area], .w = s.w, .h = s.h, .origin_x = s.origin_x, .origin_y = s.origin_y };
    }

    pub fn getVelocity(self: *const BodyWorld, h: BodyHandle) ?Vec2 {
        const s = self.slotConst(h) orelse return null;
        return Vec2.from(b2.b2Body_GetLinearVelocity(s.id));
    }

    pub fn getAngularVelocity(self: *const BodyWorld, h: BodyHandle) ?f32 {
        const s = self.slotConst(h) orelse return null;
        return b2.b2Body_GetAngularVelocity(s.id);
    }

    pub fn getCenterOfMass(self: *const BodyWorld, h: BodyHandle) ?Vec2 {
        const s = self.slotConst(h) orelse return null;
        return Vec2.from(b2.b2Body_GetWorldCenter(s.id));
    }

    pub fn getMass(self: *const BodyWorld, h: BodyHandle) ?f32 {
        const s = self.slotConst(h) orelse return null;
        return b2.b2Body_GetMass(s.id);
    }

    pub fn getPixelCount(self: *const BodyWorld, h: BodyHandle) ?u32 {
        const s = self.slotConst(h) orelse return null;
        return s.pixel_count;
    }

    pub fn getUser(self: *const BodyWorld, h: BodyHandle) ?u32 {
        const s = self.slotConst(h) orelse return null;
        return s.user;
    }

    pub fn isAwake(self: *const BodyWorld, h: BodyHandle) bool {
        const s = self.slotConst(h) orelse return false;
        return b2.b2Body_IsAwake(s.id);
    }

    // -- integration helpers (M7 world integration, src/sim/bodies_sim.zig) --

    /// Shift a body by (dx, dy) keeping its rotation and velocity. Used to
    /// keep bodies in an unwrapped frame near the camera on the torus; jointed
    /// bodies must be shifted together (joints keep local frames).
    pub fn translateBody(self: *BodyWorld, h: BodyHandle, dx: f32, dy: f32) void {
        const s = self.slotPtr(h) orelse return;
        const t = b2.b2Body_GetTransform(s.id);
        b2.b2Body_SetTransform(s.id, .{ .x = t.p.x + dx, .y = t.p.y + dy }, t.q);
    }

    pub fn setVelocity(self: *BodyWorld, h: BodyHandle, v: Vec2, angular_velocity: f32) void {
        const s = self.slotPtr(h) orelse return;
        b2.b2Body_SetLinearVelocity(s.id, v.b());
        b2.b2Body_SetAngularVelocity(s.id, angular_velocity);
    }

    pub fn wakeBody(self: *BodyWorld, h: BodyHandle) void {
        const s = self.slotPtr(h) orelse return;
        b2.b2Body_SetAwake(s.id, true);
    }

    /// Byte offset of a body's bitmap in `pixels` (the GPU atlas mirrors it).
    pub fn pixelOffset(self: *const BodyWorld, h: BodyHandle) ?u32 {
        const s = self.slotConst(h) orelse return null;
        return s.pix_off;
    }

    /// The beam a body is a segment of.
    pub fn beamOf(self: *const BodyWorld, h: BodyHandle) ?BeamHandle {
        const s = self.slotConst(h) orelse return null;
        if (s.beam == no_beam) return null;
        return .{ .index = s.beam, .gen = self.beams[s.beam].gen };
    }

    pub const BeamInfo = struct { material: u8, thickness: u16, segments: u16, seg_len: u16 };

    pub fn beamInfo(self: *BodyWorld, h: BeamHandle) ?BeamInfo {
        const b = self.beamPtr(h) orelse return null;
        return .{ .material = b.material, .thickness = b.thickness, .segments = b.segments, .seg_len = b.seg_len };
    }

    /// Index of a body among its beam's segments.
    pub fn beamSegmentIndex(self: *BodyWorld, beam: BeamHandle, h: BodyHandle) ?usize {
        for (self.beamSegments(beam), 0..) |sh, k| {
            if (sh.eql(h)) return k;
        }
        return null;
    }

    /// World pixel → bitmap pixel of body `h`, or null if outside its bitmap.
    pub fn worldToBitmap(self: *const BodyWorld, h: BodyHandle, wx: f32, wy: f32) ?struct { x: u16, y: u16 } {
        const s = self.slotConst(h) orelse return null;
        const l = self.getTransformId(s.id).applyInverse(wx, wy);
        const fx = @floor(l.x + s.origin_x);
        const fy = @floor(l.y + s.origin_y);
        if (fx < 0 or fy < 0 or fx >= @as(f32, @floatFromInt(s.w)) or fy >= @as(f32, @floatFromInt(s.h))) return null;
        return .{ .x = @intFromFloat(fx), .y = @intFromFloat(fy) };
    }

    /// World position of the center of bitmap pixel (i, j) of body `h`.
    pub fn bitmapToWorld(self: *const BodyWorld, h: BodyHandle, i: u16, j: u16) ?Vec2 {
        const s = self.slotConst(h) orelse return null;
        const lx = @as(f32, @floatFromInt(i)) + 0.5 - s.origin_x;
        const ly = @as(f32, @floatFromInt(j)) + 0.5 - s.origin_y;
        return self.getTransformId(s.id).apply(lx, ly);
    }

    pub const RasterIterator = struct {
        world: *const BodyWorld,
        i: usize = 0,

        pub fn next(it: *RasterIterator) ?RasterBody {
            const w = it.world;
            while (it.i < w.slots.len) {
                const index = it.i;
                it.i += 1;
                const s = &w.slots[index];
                if (!s.live) continue;
                const area = @as(usize, s.w) * s.h;
                return .{
                    .handle = .{ .index = @intCast(index), .gen = s.gen },
                    .transform = w.getTransformId(s.id),
                    .origin_x = s.origin_x,
                    .origin_y = s.origin_y,
                    .w = s.w,
                    .h = s.h,
                    .pixels = w.pixels[s.pix_off .. s.pix_off + area],
                    .awake = b2.b2Body_IsAwake(s.id),
                    .beam = if (s.beam == no_beam) null else .{ .index = s.beam, .gen = w.beams[s.beam].gen },
                };
            }
            return null;
        }
    };

    /// Every live body (pixel bodies and beam segments) in slot order.
    pub fn rasterIterator(self: *const BodyWorld) RasterIterator {
        return .{ .world = self };
    }

    // -- joints ---------------------------------------------------------------

    /// Rigid, unbreakable weld of `a` to `b` (null = the world) at a world
    /// point. For attaching loads, hinges of scenery, tests.
    pub fn weld(self: *BodyWorld, a: BodyHandle, b: ?BodyHandle, x: f32, y: f32) Error!JointId {
        const sa = self.slotPtr(a) orelse return error.InvalidHandle;
        const idb = if (b) |hb| (self.slotPtr(hb) orelse return error.InvalidHandle).id else self.anchor;
        return self.makeWeld(sa.id, idb, x, y, 0, 1);
    }

    pub fn destroyJoint(_: *BodyWorld, j: JointId) void {
        if (b2.b2Joint_IsValid(j)) b2.b2DestroyJoint(j);
    }

    /// Weld with zero joint angle in the current pose, anchored at world (x, y).
    fn makeWeld(self: *BodyWorld, ida: b2.b2BodyId, idb: b2.b2BodyId, x: f32, y: f32, angular_hertz: f32, angular_damping: f32) JointId {
        const ta = b2.b2Body_GetTransform(ida);
        const tb = b2.b2Body_GetTransform(idb);
        const p: b2.b2Vec2 = .{ .x = x, .y = y };
        var def = b2.b2DefaultWeldJointDef();
        def.base.bodyIdA = ida;
        def.base.bodyIdB = idb;
        def.base.localFrameA = .{ .p = b2.b2Body_GetLocalPoint(ida, p), .q = .{ .c = 1, .s = 0 } };
        // Frame B's rotation is chosen so both frames coincide in world now.
        def.base.localFrameB = .{ .p = b2.b2Body_GetLocalPoint(idb, p), .q = b2.b2InvMulRot(tb.q, ta.q) };
        def.angularHertz = angular_hertz;
        def.angularDampingRatio = angular_damping;
        def.linearHertz = 0;
        def.base.constraintHertz = self.cfg.joint_hertz;
        def.base.constraintDampingRatio = self.cfg.joint_damping;
        return b2.b2CreateWeldJoint(self.world, &def);
    }

    // -- beams ----------------------------------------------------------------

    pub const BeamDesc = struct {
        x0: f32,
        y0: f32,
        x1: f32,
        y1: f32,
        thickness: u16,
        material: u8,
        segments: u16,
        /// Weld the start/end to the world (a wall). Anchor joints yield and
        /// break like the others; they are where a cantilever's moment peaks.
        anchor_start: bool = false,
        anchor_end: bool = false,
        user: u32 = 0,
    };

    /// Build a beam from (x0,y0) to (x1,y1) as `segments` box bodies joined by
    /// soft welds. Segment length is rounded to whole pixels so the segment
    /// bitmaps tile exactly; the far end moves by under `segments`/2 px.
    pub fn createBeam(self: *BodyWorld, desc: BeamDesc) Error!BeamHandle {
        if (desc.segments == 0 or desc.segments > self.cfg.max_beam_segments) return error.TooManySegments;
        if (desc.thickness == 0) return error.EmptyBitmap;
        const bi = for (self.beams, 0..) |b, i| {
            if (!b.live) break i;
        } else return error.OutOfBeamSlots;
        const dx = desc.x1 - desc.x0;
        const dy = desc.y1 - desc.y0;
        const len = @sqrt(dx * dx + dy * dy);
        const seg_len: u16 = @intFromFloat(@max(1, @round(len / @as(f32, @floatFromInt(desc.segments)))));
        const area = @as(u32, seg_len) * desc.thickness;
        if (area > self.cfg.max_bitmap_pixels) return error.BitmapTooLarge;
        if (area > self.split_bitmap.len) return error.BitmapTooLarge;
        const angle = std.math.atan2(dy, dx);
        const ux = if (len > 0) dx / len else 1;
        const uy = if (len > 0) dy / len else 0;

        const bm = self.split_bitmap[0..area];
        @memset(bm, desc.material);
        const beam = &self.beams[bi];
        beam.* = .{
            .live = true,
            .gen = beam.gen,
            .material = desc.material,
            .thickness = desc.thickness,
            .segments = desc.segments,
            .seg_len = seg_len,
            .x0 = desc.x0,
            .y0 = desc.y0,
            .angle = angle,
        };
        const handle: BeamHandle = .{ .index = @intCast(bi), .gen = beam.gen };
        const segs = self.beamSegs(bi);
        const joints = self.beamJoints(bi);
        @memset(joints, .{});
        const fl: f32 = @floatFromInt(seg_len);
        for (0..desc.segments) |k| {
            const along = fl * @as(f32, @floatFromInt(k));
            segs[k] = self.createBodyInternal(.{
                .pixels = bm,
                .w = seg_len,
                .h = desc.thickness,
                .x = desc.x0 + ux * along,
                .y = desc.y0 + uy * along,
                .origin_x = 0,
                .origin_y = @as(f32, @floatFromInt(desc.thickness)) * 0.5,
                .angle = angle,
                .user = desc.user,
            }, @intCast(bi)) catch |err| {
                for (segs[0..k]) |sh| self.destroyBody(sh);
                beam.live = false;
                beam.gen +%= 1;
                return err;
            };
        }
        const props = self.materials[desc.material].beam;
        for (1..desc.segments) |k| {
            const along = fl * @as(f32, @floatFromInt(k));
            joints[k] = .{
                .id = self.makeWeld(self.slots[segs[k - 1].index].id, self.slots[segs[k].index].id, desc.x0 + ux * along, desc.y0 + uy * along, props.angular_hertz, props.angular_damping),
                .alive = true,
            };
        }
        if (desc.anchor_start) self.anchorBeam(handle, .start) catch unreachable;
        if (desc.anchor_end) self.anchorBeam(handle, .end) catch unreachable;
        return handle;
    }

    pub const BeamEnd = enum { start, end };

    /// Weld a beam end to the world at its current position.
    pub fn anchorBeam(self: *BodyWorld, h: BeamHandle, end: BeamEnd) Error!void {
        const beam = self.beamPtr(h) orelse return error.InvalidBeam;
        const bi = h.index;
        const segs = self.beamSegs(bi);
        const joints = self.beamJoints(bi);
        const ji: usize = if (end == .start) 0 else beam.segments;
        if (joints[ji].alive and b2.b2Joint_IsValid(joints[ji].id)) return;
        const seg = if (end == .start) segs[0] else segs[beam.segments - 1];
        const s = self.slotPtr(seg) orelse return error.InvalidHandle;
        const lx: f32 = if (end == .start) 0 else @floatFromInt(beam.seg_len);
        const p = self.getTransformId(s.id).apply(lx, 0);
        const props = self.materials[beam.material].beam;
        // Anchor body is A so frame A carries the rest angle like the others.
        joints[ji] = .{ .id = self.makeWeld(self.anchor, s.id, p.x, p.y, props.angular_hertz, props.angular_damping), .alive = true };
    }

    /// Detach a beam end from the world (its wall was destroyed).
    pub fn releaseBeamAnchor(self: *BodyWorld, h: BeamHandle, end: BeamEnd) void {
        const beam = self.beamPtr(h) orelse return;
        const joints = self.beamJoints(h.index);
        const ji: usize = if (end == .start) 0 else beam.segments;
        if (joints[ji].alive and b2.b2Joint_IsValid(joints[ji].id)) b2.b2DestroyJoint(joints[ji].id);
        joints[ji].alive = false;
    }

    /// Spec-shaped constructor: no anchors.
    pub fn createBeamSimple(self: *BodyWorld, x0: f32, y0: f32, x1: f32, y1: f32, thickness_px: u16, material: u8, segments: u16) Error!BeamHandle {
        return self.createBeam(.{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1, .thickness = thickness_px, .material = material, .segments = segments });
    }

    pub fn destroyBeam(self: *BodyWorld, h: BeamHandle) void {
        const beam = self.beamPtr(h) orelse return;
        for (self.beamJoints(h.index)[0 .. @as(usize, beam.segments) + 1]) |*j| {
            if (j.alive and b2.b2Joint_IsValid(j.id)) b2.b2DestroyJoint(j.id);
            j.alive = false;
        }
        for (self.beamSegs(h.index)[0..beam.segments]) |sh| self.destroyBody(sh);
        beam.live = false;
        beam.gen +%= 1;
    }

    fn beamPtr(self: *BodyWorld, h: BeamHandle) ?*BeamSlot {
        if (h.index >= self.beams.len) return null;
        const b = &self.beams[h.index];
        if (!b.live or b.gen != h.gen) return null;
        return b;
    }

    fn beamSegs(self: *BodyWorld, bi: usize) []BodyHandle {
        const n = self.cfg.max_beam_segments;
        return self.beam_segs[bi * n .. (bi + 1) * n];
    }

    fn beamJoints(self: *BodyWorld, bi: usize) []BeamJoint {
        const n = @as(usize, self.cfg.max_beam_segments) + 1;
        return self.beam_joints[bi * n .. (bi + 1) * n];
    }

    /// Segment bodies of a beam, start to end. Segments destroyed by gameplay
    /// show up as invalid handles.
    pub fn beamSegments(self: *BodyWorld, h: BeamHandle) []const BodyHandle {
        const beam = self.beamPtr(h) orelse return &.{};
        return self.beamSegs(h.index)[0..beam.segments];
    }

    /// Joints still holding, anchors included.
    pub fn beamJointCount(self: *BodyWorld, h: BeamHandle) usize {
        const beam = self.beamPtr(h) orelse return 0;
        var n: usize = 0;
        for (self.beamJoints(h.index)[0 .. @as(usize, beam.segments) + 1]) |j| {
            if (j.alive and b2.b2Joint_IsValid(j.id)) n += 1;
        }
        return n;
    }

    /// Accumulated plastic bend at joint `ji` (see `JointBreak.joint_index`).
    pub fn beamPlasticAngle(self: *BodyWorld, h: BeamHandle, ji: usize) f32 {
        const beam = self.beamPtr(h) orelse return 0;
        if (ji > beam.segments) return 0;
        return self.beamJoints(h.index)[ji].plastic_angle;
    }

    pub const JointLoad = struct {
        alive: bool,
        /// |moment| / yield moment; above 1 the joint bends permanently.
        moment_ratio: f32,
        /// |force| / fracture force.
        force_ratio: f32,
        plastic_angle: f32,
        strength: f32,
    };

    /// Load state of joint `ji` after the last step (for creak sounds,
    /// debug overlays, tests).
    pub fn beamJointLoad(self: *BodyWorld, h: BeamHandle, ji: usize) ?JointLoad {
        const beam = self.beamPtr(h) orelse return null;
        if (ji > beam.segments) return null;
        const j = self.beamJoints(h.index)[ji];
        return .{
            .alive = j.alive and b2.b2Joint_IsValid(j.id),
            .moment_ratio = j.moment_ratio,
            .force_ratio = j.force_ratio,
            .plastic_angle = j.plastic_angle,
            .strength = j.strength,
        };
    }

    /// Scale the strength of the beam joint nearest to world (x, y), e.g.
    /// when cells are cut out of the beam there: `remaining` is the fraction
    /// of thickness left (moment capacity scales with its square).
    pub fn weakenBeamAt(self: *BodyWorld, h: BeamHandle, x: f32, y: f32, remaining: f32) void {
        const beam = self.beamPtr(h) orelse return;
        const joints = self.beamJoints(h.index);
        var best: ?usize = null;
        var best_d: f32 = std.math.inf(f32);
        for (joints[0 .. @as(usize, beam.segments) + 1], 0..) |j, ji| {
            if (!j.alive or !b2.b2Joint_IsValid(j.id)) continue;
            const p = b2.b2Body_GetWorldPoint(b2.b2Joint_GetBodyB(j.id), b2.b2Joint_GetLocalFrameB(j.id).p);
            const d = (p.x - x) * (p.x - x) + (p.y - y) * (p.y - y);
            if (d < best_d) {
                best_d = d;
                best = ji;
            }
        }
        if (best) |ji| {
            const r = std.math.clamp(remaining, 0, 1);
            joints[ji].strength = @min(joints[ji].strength, r * r);
        }
    }

    /// Post-step joint processing: fracture above the fracture thresholds,
    /// plastic flow of the rest angle above yield.
    fn updateBeams(self: *BodyWorld) void {
        for (self.beams, 0..) |*beam, bi| {
            if (!beam.live) continue;
            const props = self.materials[beam.material].beam;
            const t: f32 = @floatFromInt(beam.thickness);
            const joints = self.beamJoints(bi);
            for (joints[0 .. @as(usize, beam.segments) + 1], 0..) |*j, ji| {
                if (!j.alive) continue;
                if (!b2.b2Joint_IsValid(j.id)) {
                    j.alive = false;
                    continue;
                }
                const bb = b2.b2Joint_GetBodyB(j.id);
                if (!b2.b2Body_IsAwake(bb)) continue;
                const torque = b2.b2Joint_GetConstraintTorque(j.id);
                const fv = b2.b2Joint_GetConstraintForce(j.id);
                const force = @sqrt(fv.x * fv.x + fv.y * fv.y);
                const m_abs = @abs(torque);
                const m_yield = props.yield_moment * t * t * j.strength;
                const m_frac = props.fracture_moment * t * t * j.strength;
                const f_frac = props.fracture_force * t * j.strength;
                j.moment_ratio = m_abs / m_yield;
                j.force_ratio = force / f_frac;
                const a = props.fracture_smoothing;
                j.moment_avg += a * (m_abs - j.moment_avg);
                j.force_avg += a * (force - j.force_avg);
                if (j.moment_avg > m_frac or j.force_avg > f_frac or @abs(j.plastic_angle) > props.fracture_plastic_angle) {
                    if (self.break_count < self.break_buf.len) {
                        const p = b2.b2Body_GetWorldPoint(bb, b2.b2Joint_GetLocalFrameB(j.id).p);
                        self.break_buf[self.break_count] = .{
                            .beam = .{ .index = @intCast(bi), .gen = beam.gen },
                            .joint_index = @intCast(ji),
                            .x = p.x,
                            .y = p.y,
                            .moment = m_abs,
                            .force = force,
                        };
                        self.break_count += 1;
                    }
                    b2.b2DestroyJoint(j.id);
                    j.alive = false;
                    continue;
                }
                if (m_abs > m_yield and props.flow_rate > 0) {
                    // The joint torque on B opposes the elastic error, so the
                    // rest angle moves against the torque's sign. Rotating
                    // frame A by +d lowers the joint angle by d.
                    const over = m_abs / m_yield - 1;
                    const d = @min(props.flow_rate * over * tick_dt, props.max_flow_per_tick);
                    const delta = if (torque > 0) -d else d;
                    var fa = b2.b2Joint_GetLocalFrameA(j.id);
                    fa.q = b2.b2MulRot(fa.q, b2.b2MakeRot(delta));
                    b2.b2Joint_SetLocalFrameA(j.id, fa);
                    j.plastic_angle += delta;
                }
            }
        }
    }

    // -- forces ---------------------------------------------------------------

    /// Radial impulse from a blast. Each body within `radius` of `center`
    /// (measured to its bounding circle) gets `strength` × falloff ×
    /// pixel_count kg·px/s along the line from the center to its center of
    /// mass; falloff is linear to zero at `radius`. `strength` is impulse per
    /// body pixel at the center, so the Δv of a body is about
    /// strength / density.
    pub fn applyBlast(self: *BodyWorld, cx: f32, cy: f32, radius: f32, strength: f32) void {
        if (radius <= 0) return;
        for (self.slots) |s| {
            if (!s.live) continue;
            const c = b2.b2Body_GetWorldCenter(s.id);
            const dx = c.x - cx;
            const dy = c.y - cy;
            const d = @sqrt(dx * dx + dy * dy);
            const d_eff = @max(0, d - s.radius * 0.5);
            if (d_eff >= radius) continue;
            const f = 1 - d_eff / radius;
            const mag = strength * f * @as(f32, @floatFromInt(s.pixel_count));
            const dir: Vec2 = if (d > 1e-3) .{ .x = dx / d, .y = dy / d } else .{ .x = 0, .y = -1 };
            b2.b2Body_ApplyLinearImpulseToCenter(s.id, .{ .x = dir.x * mag, .y = dir.y * mag }, true);
        }
    }

    /// Fluid coupling for the coming step: linear drag toward the fluid
    /// velocity (kg/s; clamped so it cannot reverse the relative velocity in
    /// one tick), angular drag (kg·px²/s), and a buoyancy force (kg·px/s²,
    /// typically (0, −ρ_fluid·submerged_px·196)). Call before `step`.
    pub fn applyFluid(self: *BodyWorld, h: BodyHandle, fluid_velocity: Vec2, drag: f32, angular_drag: f32, buoyancy_force: Vec2) void {
        const s = self.slotPtr(h) orelse return;
        const m = b2.b2Body_GetMass(s.id);
        const v = b2.b2Body_GetLinearVelocity(s.id);
        const k = @min(drag, m / tick_dt);
        const fx = k * (fluid_velocity.x - v.x) + buoyancy_force.x;
        const fy = k * (fluid_velocity.y - v.y) + buoyancy_force.y;
        b2.b2Body_ApplyForceToCenter(s.id, .{ .x = fx, .y = fy }, true);
        if (angular_drag > 0) {
            const inertia = b2.b2Body_GetRotationalInertia(s.id);
            const ka = @min(angular_drag, inertia / tick_dt);
            b2.b2Body_ApplyTorque(s.id, -ka * b2.b2Body_GetAngularVelocity(s.id), true);
        }
    }

    // -- static collision -----------------------------------------------------

    /// Rebuild static collision from an 8-bit solid mask (nonzero = solid) of
    /// the region whose top-left pixel is at world (origin_x, origin_y). The
    /// mask must not contain body-owned cells. The region is cut into
    /// world-aligned tiles; a tile is rebuilt only when its content, its
    /// coverage or its fine/coarse mode changed. Tiles near a body are exact
    /// per pixel, the rest coarse. Tiles outside this region are removed.
    pub fn setStaticCollision(self: *BodyWorld, mask: []const u8, w: u32, h: u32, origin_x: i32, origin_y: i32) Error!void {
        if (w > self.cfg.static_max_w or h > self.cfg.static_max_h) return error.RegionTooLarge;
        std.debug.assert(mask.len >= @as(usize, w) * h);
        self.static_pass +%= 1;
        self.static_stats = .{};
        if (w == 0 or h == 0) {
            self.sweepTiles();
            return;
        }
        const T: i32 = self.cfg.static_tile;
        const tx0 = @divFloor(origin_x, T);
        const ty0 = @divFloor(origin_y, T);
        const tx1 = @divFloor(origin_x + @as(i32, @intCast(w)) - 1, T);
        const ty1 = @divFloor(origin_y + @as(i32, @intCast(h)) - 1, T);
        const ntx: usize = @intCast(tx1 - tx0 + 1);
        const nty: usize = @intCast(ty1 - ty0 + 1);
        std.debug.assert(ntx * nty <= self.tile_fine.len);

        // Which tiles have a body nearby.
        const fine = self.tile_fine[0 .. ntx * nty];
        @memset(fine, false);
        const margin = self.cfg.static_fine_margin;
        for (self.slots) |s| {
            if (!s.live) continue;
            const p = b2.b2Body_GetPosition(s.id);
            const r = s.radius + margin;
            const bx0 = @max(tx0, @as(i32, @intFromFloat(@floor((p.x - r) / @as(f32, @floatFromInt(T))))));
            const bx1 = @min(tx1, @as(i32, @intFromFloat(@floor((p.x + r) / @as(f32, @floatFromInt(T))))));
            const by0 = @max(ty0, @as(i32, @intFromFloat(@floor((p.y - r) / @as(f32, @floatFromInt(T))))));
            const by1 = @min(ty1, @as(i32, @intFromFloat(@floor((p.y + r) / @as(f32, @floatFromInt(T))))));
            var ty = by0;
            while (ty <= by1) : (ty += 1) {
                var tx = bx0;
                while (tx <= bx1) : (tx += 1) {
                    fine[@as(usize, @intCast(ty - ty0)) * ntx + @as(usize, @intCast(tx - tx0))] = true;
                }
            }
        }

        var ty = ty0;
        while (ty <= ty1) : (ty += 1) {
            var tx = tx0;
            while (tx <= tx1) : (tx += 1) {
                // Tile ∩ region, in mask coordinates.
                const wx0 = @max(tx * T, origin_x);
                const wy0 = @max(ty * T, origin_y);
                const wx1 = @min(tx * T + T, origin_x + @as(i32, @intCast(w)));
                const wy1 = @min(ty * T + T, origin_y + @as(i32, @intCast(h)));
                const mx0: usize = @intCast(wx0 - origin_x);
                const my0: usize = @intCast(wy0 - origin_y);
                const mw: usize = @intCast(wx1 - wx0);
                const mh: usize = @intCast(wy1 - wy0);
                const is_fine = fine[@as(usize, @intCast(ty - ty0)) * ntx + @as(usize, @intCast(tx - tx0))];

                var hasher = std.hash.Wyhash.init(0x6865_7865);
                const hdr = [_]i32{ wx0, wy0, @intCast(mw), @intCast(mh), @intFromBool(is_fine) };
                hasher.update(std.mem.asBytes(&hdr));
                for (0..mh) |yy| {
                    const row = (my0 + yy) * w + mx0;
                    hasher.update(mask[row .. row + mw]);
                }
                const hash = hasher.final();

                const sx: u32 = @intCast(@mod(tx, @as(i32, @intCast(self.tiles_nx))));
                const sy: u32 = @intCast(@mod(ty, @as(i32, @intCast(self.tiles_ny))));
                const slot = &self.tiles[sy * self.tiles_nx + sx];
                self.static_stats.tiles += 1;
                if (slot.valid and slot.tx == tx and slot.ty == ty and slot.hash == hash) {
                    slot.seen = self.static_pass;
                    continue;
                }
                if (slot.valid and slot.has_body) b2.b2DestroyBody(slot.body);
                slot.* = .{ .valid = true, .tx = tx, .ty = ty, .hash = hash, .seen = self.static_pass };
                try self.buildTile(slot, mask[my0 * w + mx0 ..], mw, mh, w, wx0, wy0, if (is_fine) 1 else self.cfg.static_coarse);
                self.static_stats.tiles_rebuilt += 1;
            }
        }
        self.sweepTiles();
    }

    fn sweepTiles(self: *BodyWorld) void {
        for (self.tiles) |*slot| {
            if (slot.valid and slot.seen != self.static_pass) {
                if (slot.has_body) b2.b2DestroyBody(slot.body);
                slot.* = .{};
            }
        }
    }

    fn buildTile(self: *BodyWorld, slot: *TileSlot, sub: []const u8, mw: usize, mh: usize, stride: usize, wx0: i32, wy0: i32, g: usize) Error!void {
        var rects: []Rect = undefined;
        if (g <= 1) {
            rects = try decomposeRects(sub, mw, mh, stride, self.visited, self.rects);
        } else {
            const cw = (mw + g - 1) / g;
            const ch = (mh + g - 1) / g;
            for (0..ch) |cy| {
                for (0..cw) |cx| {
                    var solid: usize = 0;
                    var total: usize = 0;
                    for (cy * g..@min(cy * g + g, mh)) |yy| {
                        for (cx * g..@min(cx * g + g, mw)) |xx| {
                            total += 1;
                            if (sub[yy * stride + xx] != 0) solid += 1;
                        }
                    }
                    self.coarse[cy * cw + cx] = @intFromBool(2 * solid >= total and solid > 0);
                }
            }
            rects = try decomposeRects(self.coarse[0 .. cw * ch], cw, ch, cw, self.visited, self.rects);
            for (rects) |*r| {
                const x = @as(usize, r.x) * g;
                const y = @as(usize, r.y) * g;
                r.* = .{
                    .x = @intCast(x),
                    .y = @intCast(y),
                    .w = @intCast(@min(@as(usize, r.w) * g, mw - x)),
                    .h = @intCast(@min(@as(usize, r.h) * g, mh - y)),
                };
            }
        }
        if (rects.len == 0) return;
        var bdef = b2.b2DefaultBodyDef();
        bdef.type = b2.b2_staticBody;
        bdef.position = .{ .x = @floatFromInt(wx0), .y = @floatFromInt(wy0) };
        const body = b2.b2CreateBody(self.world, &bdef);
        var sdef = b2.b2DefaultShapeDef();
        sdef.material.friction = 0.7;
        for (rects) |r| {
            const hw = @as(f32, @floatFromInt(r.w)) * 0.5;
            const hh = @as(f32, @floatFromInt(r.h)) * 0.5;
            const poly = b2.b2MakeOffsetBox(hw, hh, .{ .x = @as(f32, @floatFromInt(r.x)) + hw, .y = @as(f32, @floatFromInt(r.y)) + hh }, .{ .c = 1, .s = 0 });
            _ = b2.b2CreatePolygonShape(body, &sdef, &poly);
        }
        slot.has_body = true;
        slot.body = body;
        self.static_stats.shapes_created += @intCast(rects.len);
    }
};

/// Spec-shaped namespaces over `BodyWorld` methods.
pub const PixelBody = struct {
    pub fn create(world: *BodyWorld, desc: BodyWorld.PixelBodyDesc) Error!BodyHandle {
        return world.createPixelBody(desc);
    }
};

pub const Beam = struct {
    pub fn create(world: *BodyWorld, x0: f32, y0: f32, x1: f32, y1: f32, thickness_px: u16, material: u8, segments: u16) Error!BeamHandle {
        return world.createBeamSimple(x0, y0, x1, y1, thickness_px, material, segments);
    }
};

// ---------------------------------------------------------------------------
// Tests

test {
    _ = @import("bodies_test.zig");
}

test "SpanAllocator reuses and coalesces freed spans" {
    var sa = try SpanAllocator.init(std.testing.allocator, 100, 4);
    defer sa.deinit(std.testing.allocator);
    const a = sa.allocSpan(30).?;
    const b = sa.allocSpan(30).?;
    const c = sa.allocSpan(30).?;
    try std.testing.expectEqual(@as(?u32, null), sa.allocSpan(20));
    sa.freeSpan(a, 30);
    sa.freeSpan(c, 30);
    try std.testing.expectEqual(@as(usize, 2), sa.count);
    sa.freeSpan(b, 30);
    try std.testing.expectEqual(@as(usize, 1), sa.count);
    try std.testing.expectEqual(@as(?u32, 0), sa.allocSpan(100));
}
