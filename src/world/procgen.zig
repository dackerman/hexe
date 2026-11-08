//! CPU procedural generation, one chunk at a time, deterministic per
//! (seed, cx, cy). Every decision is a pure function of world coordinates
//! and the seed, so neighbouring chunks agree at their seams. Pools and
//! structures span chunk borders; each chunk evaluates the base terrain over
//! a margin wide enough to contain every pool or structure that can touch
//! it, then keeps only its own cells. Rules: docs/decisions/04-world-procgen.md.

const std = @import("std");
const chunk = @import("chunk.zig");
const cell = @import("cell.zig");
const hash = @import("hash.zig");
const noise = @import("noise.zig");

/// Material ids, filled by the caller from the material table.
pub const MaterialIds = struct {
    air: u8,
    stone: u8,
    dirt: u8,
    sand: u8,
    water: u8,
    lava: u8,
    wood: u8,
    concrete: u8,
    steel: u8,
    bedrock: u8,
    oil: u8,
    gunpowder: u8,
    moss: u8,
    gravel: u8,
};

/// Initial state byte (health for damageable solids), docs/03-materials.md.
pub const SpawnState = struct {
    stone: u8 = 200,
    concrete: u8 = 180,
    steel: u8 = 255,
    wood: u8 = 120,
};

pub const Params = struct {
    ids: MaterialIds,
    spawn_state: SpawnState = .{},
    /// Mean surface depth in cells; the surface stays within ±amplitude.
    surface_y: i32 = 112,
    surface_amplitude: i32 = 80,
    /// World floor: bedrock from here down (and a noisy band above it).
    floor_y: i32 = 32 * 256,
    /// Below this depth fraction of floor_y, pools are lava instead of water.
    lava_depth_fraction: f32 = 0.6,
    lava_celsius: i32 = 1100,
};

// Pool limits (cells). Margins below are derived from these.
const pool_half_width = 96;
const pool_max_depth = 32;
const pool_drop = 96;
const pool_below = 48;
const pool_max_cells = 6000;
const pool_grid = 64;

/// Density above which a cell is open. Slightly positive so the thin ends
/// of tunnels, narrower than the lattice can represent, close up instead of
/// leaving hairline cracks.
const open_threshold: f32 = 0.012;

const step_log2 = 2;
const step = 1 << step_log2; // density lattice spacing

const margin_x = 200; // ≥ 2·pool_half_width + slack, multiple of `step`
const margin_top = 180; // ≥ pool_drop + pool_below + pool_max_depth + slack
const margin_bottom = 180;
const sw = chunk.size + 2 * margin_x;
const sh = chunk.size + margin_top + margin_bottom;
const lw = sw / step + 1;
const lh = sh / step + 1;
const pw = chunk.size / step + 1;
const moss_radius = 5;

comptime {
    std.debug.assert(margin_x % step == 0 and margin_top % step == 0);
    std.debug.assert(margin_x >= 2 * pool_half_width + 4);
    std.debug.assert(margin_top >= pool_drop + pool_below + pool_max_depth + 2);
    std.debug.assert(margin_bottom >= pool_drop + pool_below + pool_max_depth + 2);
}

const Kind = enum(u8) { air, solid };
const Liquid = enum(u8) { none, water, lava };

const Seeds = struct {
    warp_x: u32,
    warp_y: u32,
    tunnel_a: u32,
    tunnel_b: u32,
    width: u32,
    cavern: u32,
    entrance: u32,
    surface: u32,
    dirt_depth: u32,
    bedrock: u32,
    sand: u32,
    gravel: u32,
    oil: u32,
    pocket: u32,
    rough: u32,
    pools: u32,
    platforms: u32,
    rooms: u32,
    deco: u32,

    fn init(seed: u64) Seeds {
        var s: Seeds = undefined;
        const lo: u32 = @truncate(seed);
        const hi: u32 = @truncate(seed >> 32);
        inline for (@typeInfo(Seeds).@"struct".field_names, 0..) |name, k| {
            @field(s, name) = hash.mix32(lo ^ hash.mix32(hi +% @as(u32, k) *% 0x632be5ab));
        }
        return s;
    }
};

pub const Generator = struct {
    params: Params,
    seed: u64,
    seeds: Seeds,
    // Scratch, sized once at init; `generate` never allocates.
    density: []f32, // lw × lh lattice
    samples: []Sample, // (lw + 2) × (lh + 2) lattice with border
    field: []f32, // sw × sh full-resolution density (≤ 0 is rock)
    kind: []Kind, // sw × sh
    liquid: []Liquid, // sw × sh
    visit: []u32, // sw × sh BFS stamps
    stamp: u32,
    queue: []u32, // pool_max_cells
    pockets: [3][]f32, // pw × pw lattices, chunk only
    near_water: []u8, // chunk.size × (chunk.size + 2·moss_radius)
    surface: []i32, // sw + 1 (one past for the last lattice column)
    dirt_depth: []i32, // sw
    mat: []u8, // chunk.cell_count

    pub fn init(alloc: std.mem.Allocator, seed: u64, params: Params) !Generator {
        var g: Generator = undefined;
        g.params = params;
        g.seed = seed;
        g.seeds = Seeds.init(seed);
        g.stamp = 0;
        g.density = try alloc.alloc(f32, lw * lh);
        errdefer alloc.free(g.density);
        g.samples = try alloc.alloc(Sample, (lw + 2) * (lh + 2));
        errdefer alloc.free(g.samples);
        g.field = try alloc.alloc(f32, sw * sh);
        errdefer alloc.free(g.field);
        g.kind = try alloc.alloc(Kind, sw * sh);
        errdefer alloc.free(g.kind);
        g.liquid = try alloc.alloc(Liquid, sw * sh);
        errdefer alloc.free(g.liquid);
        g.visit = try alloc.alloc(u32, sw * sh);
        errdefer alloc.free(g.visit);
        @memset(g.visit, 0);
        g.queue = try alloc.alloc(u32, pool_max_cells);
        errdefer alloc.free(g.queue);
        var made: usize = 0;
        errdefer for (g.pockets[0..made]) |p| alloc.free(p);
        for (&g.pockets) |*p| {
            p.* = try alloc.alloc(f32, pw * pw);
            made += 1;
        }
        g.near_water = try alloc.alloc(u8, chunk.size * (chunk.size + 2 * moss_radius));
        errdefer alloc.free(g.near_water);
        g.surface = try alloc.alloc(i32, sw + 1);
        errdefer alloc.free(g.surface);
        g.dirt_depth = try alloc.alloc(i32, sw);
        errdefer alloc.free(g.dirt_depth);
        g.mat = try alloc.alloc(u8, chunk.cell_count);
        return g;
    }

    pub fn deinit(g: *Generator, alloc: std.mem.Allocator) void {
        alloc.free(g.density);
        alloc.free(g.samples);
        alloc.free(g.field);
        alloc.free(g.kind);
        alloc.free(g.liquid);
        alloc.free(g.visit);
        alloc.free(g.queue);
        for (g.pockets) |p| alloc.free(p);
        alloc.free(g.near_water);
        alloc.free(g.surface);
        alloc.free(g.dirt_depth);
        alloc.free(g.mat);
        g.* = undefined;
    }

    // -- terrain functions of world coordinates ------------------------------

    pub fn surfaceAt(g: *const Generator, x: i32) i32 {
        const fx: f32 = @floatFromInt(x);
        const big = noise.fbm(fx / 700.0, 0.5, g.seeds.surface, 3);
        const small = noise.simplex(fx / 70.0, 3.5, g.seeds.surface +% 1);
        const amp: f32 = @floatFromInt(g.params.surface_amplitude);
        const raw = @as(f32, @floatFromInt(g.params.surface_y)) + amp * (0.9 * big + 0.1 * small);
        const lo = @max(8, g.params.surface_y - g.params.surface_amplitude);
        const hi = g.params.surface_y + g.params.surface_amplitude;
        return std.math.clamp(@as(i32, @intFromFloat(@floor(raw))), lo, hi);
    }

    fn dirtDepthAt(g: *const Generator, x: i32) i32 {
        const fx: f32 = @floatFromInt(x);
        return @intFromFloat(30.0 + 14.0 * noise.simplex(fx / 160.0, 2.5, g.seeds.dirt_depth));
    }

    fn minSurface(g: *const Generator) i32 {
        return @max(8, g.params.surface_y - g.params.surface_amplitude);
    }

    /// Raw noise values at a lattice point; combined by `combine` once the
    /// lattice neighbours exist (tunnel widths need the noise gradient).
    const Sample = struct {
        na: f32, // primary tunnel noise
        nb: f32, // secondary tunnel noise
        rest: f32, // caverns and gates, already in density units
        half_a: f32, // primary tunnel half-width, cells
        half_b: f32, // secondary tunnel half-width, cells
        sup: f32, // near-surface suppression, subtracted last
    };

    fn sample(g: *const Generator, x: i32, y: i32, surf: i32) Sample {
        const fx: f32 = @floatFromInt(x);
        const fy: f32 = @floatFromInt(y);
        const s = &g.seeds;
        const wx = fx + 56.0 * noise.simplex(fx / 330.0, fy / 330.0, s.warp_x);
        const wy = fy + 36.0 * noise.simplex(fx / 330.0, fy / 330.0, s.warp_y);
        const depth: f32 = @floatFromInt(y - surf);
        const deep = std.math.clamp(depth / @as(f32, @floatFromInt(g.params.floor_y)), 0, 1);
        var out: Sample = undefined;
        // Ridged tunnel networks: the zero set of a smooth noise is a web of
        // connected curves. Dividing |n| by its gradient gives the distance
        // to that curve in cells, so tunnels get a width in cells instead of
        // thinning into hairlines where the noise is steep.
        out.na = noise.simplex(wx / 360.0, wy / 210.0, s.tunnel_a) +
            0.15 * noise.simplex(wx / 90.0, wy / 60.0, s.tunnel_a +% 1);
        out.nb = noise.simplex(wx / 240.0, wy / 260.0, s.tunnel_b);
        const wn = noise.simplex(fx / 800.0, fy / 800.0, s.width);
        out.half_a = 17.0 + 8.0 * wn; // 9..25: mostly walkable for a 34-cell player
        // The secondary network (narrow crawlways) exists only in some regions.
        const gate = std.math.clamp(noise.simplex(fx / 900.0, fy / 900.0, s.tunnel_b +% 2) * 4.0 - 0.4, 0, 1);
        out.half_b = (6.0 + 4.0 * wn) * gate;
        // Caverns: big chambers, larger and more common with depth.
        const cav_threshold = 0.42 - 0.14 * deep;
        out.rest = 1.4 * (noise.fbm(wx / 430.0, wy / 260.0, s.cavern, 2) - cav_threshold);
        // Keep the first ~90 cells under the surface mostly closed, except
        // where an entrance noise opens shafts to the sky.
        out.sup = 0;
        if (depth < 90) {
            const e = std.math.clamp((noise.simplex(fx / 600.0, 0.25, s.entrance) - 0.35) * 3.0, 0, 1);
            out.sup = (90 - depth) / 90.0 * 0.35 * (1 - e);
        }
        return out;
    }

    /// Density units per cell of distance for tunnels; matches the cavern
    /// field's typical slope so edge roughness looks the same on both.
    const tunnel_slope: f32 = 0.008;

    fn tunnel(n: f32, dndx: f32, dndy: f32, half: f32) f32 {
        const grad = @sqrt(dndx * dndx + dndy * dndy);
        const dist = @abs(n) / @max(grad, 1e-5);
        return (half - dist) * tunnel_slope;
    }

    fn bedrockTop(g: *const Generator, x: i32) i32 {
        const fx: f32 = @floatFromInt(x);
        const band = 22.0 + 14.0 * noise.simplex(fx / 90.0, 7.5, g.seeds.bedrock) +
            4.0 * noise.simplex(fx / 13.0, 1.5, g.seeds.bedrock +% 1);
        return g.params.floor_y - @as(i32, @intFromFloat(band));
    }

    // -- scratch indexing ------------------------------------------------------

    inline fn sidx(sx: i32, sy: i32) usize {
        std.debug.assert(sx >= 0 and sx < sw and sy >= 0 and sy < sh);
        return @as(usize, @intCast(sy)) * sw + @as(usize, @intCast(sx));
    }

    // -- generation -----------------------------------------------------------

    /// Fills `out` with chunk `c`. Deterministic per (seed, c.x, c.y).
    pub fn generate(g: *Generator, c: chunk.Coord, out: *chunk.Cells) void {
        const ids = g.params.ids;
        const o = c.originCell();
        const x0 = o[0];
        const y0 = o[1];
        if (y0 + @as(i32, chunk.size) <= g.minSurface() - 64) {
            g.fillUniform(c, out, ids.air);
            return;
        }
        if (y0 >= g.params.floor_y) {
            g.fillUniform(c, out, ids.bedrock);
            return;
        }
        const ox = x0 - margin_x; // scratch origin, world coords
        const oy = y0 - margin_top;

        g.buildBase(ox, oy);
        g.buildPools(x0, y0, ox, oy);
        g.classify(x0, y0, ox, oy);
        g.addMoss(x0, y0, ox, oy);
        g.addPlatforms(x0, y0, ox, oy);
        g.addRooms(x0, y0, ox, oy);
        g.addCaches(x0, y0, ox, oy);
        g.finish(c, out);
    }

    fn fillUniform(g: *Generator, c: chunk.Coord, out: *chunk.Cells, m: u8) void {
        @memset(g.mat, m);
        g.finish(c, out);
    }

    fn buildBase(g: *Generator, ox: i32, oy: i32) void {
        for (g.surface, 0..) |*s, i| s.* = g.surfaceAt(ox + @as(i32, @intCast(i)));
        for (g.dirt_depth, 0..) |*d, i| d.* = g.dirtDepthAt(ox + @as(i32, @intCast(i)));

        // Noise lattice every `step` cells (world aligned since ox, oy are),
        // with a one-point border for central differences.
        for (0..lh + 2) |ly| {
            const wy = oy + (@as(i32, @intCast(ly)) - 1) * step;
            for (0..lw + 2) |lx| {
                const wx = ox + (@as(i32, @intCast(lx)) - 1) * step;
                const surf = if (lx >= 1 and lx <= lw) g.surface[(lx - 1) * step] else g.surfaceAt(wx);
                g.samples[ly * (lw + 2) + lx] = g.sample(wx, wy, surf);
            }
        }
        const sl = lw + 2;
        const inv2: f32 = 1.0 / (2.0 * step);
        for (0..lh) |ly| {
            for (0..lw) |lx| {
                const k = (ly + 1) * sl + lx + 1;
                const c = g.samples[k];
                const l = g.samples[k - 1];
                const r = g.samples[k + 1];
                const u = g.samples[k - sl];
                const d = g.samples[k + sl];
                const ta = tunnel(c.na, (r.na - l.na) * inv2, (d.na - u.na) * inv2, c.half_a);
                const tb = tunnel(c.nb, (r.nb - l.nb) * inv2, (d.nb - u.nb) * inv2, c.half_b);
                g.density[ly * lw + lx] = @max(c.rest, @max(ta, tb)) - c.sup;
            }
        }

        const floor_y = g.params.floor_y;
        const inv: f32 = 1.0 / @as(f32, step);
        for (0..sh) |syu| {
            const sy: i32 = @intCast(syu);
            const wy = oy + sy;
            const ly = syu >> step_log2;
            const fy = @as(f32, @floatFromInt(syu & (step - 1))) * inv;
            for (0..sw) |sxu| {
                const sx: i32 = @intCast(sxu);
                const wx = ox + sx;
                const i = syu * sw + sxu;
                g.liquid[i] = .none;
                const surf = g.surface[sxu];
                if (wy < surf) {
                    g.kind[i] = .air;
                    g.field[i] = 1;
                    continue;
                }
                if (wy >= floor_y - 64 and wy >= g.bedrockTop(wx)) {
                    g.kind[i] = .solid;
                    g.field[i] = -1;
                    continue;
                }
                const lx = sxu >> step_log2;
                const fx = @as(f32, @floatFromInt(sxu & (step - 1))) * inv;
                const d00 = g.density[ly * lw + lx];
                const d10 = g.density[ly * lw + lx + 1];
                const d01 = g.density[(ly + 1) * lw + lx];
                const d11 = g.density[(ly + 1) * lw + lx + 1];
                const top = d00 + (d10 - d00) * fx;
                const bot = d01 + (d11 - d01) * fx;
                var f = top + (bot - top) * fy;
                // Roughen edges only; the perturbation is bounded by 0.0275.
                if (@abs(f - open_threshold) < 0.03) {
                    f += 0.035 * (noise.value(wx, wy, 3, g.seeds.rough) - 0.5) +
                        0.02 * (noise.value(wx, wy, 1, g.seeds.rough +% 1) - 0.5);
                }
                g.field[i] = f;
                g.kind[i] = if (f > open_threshold) .air else .solid;
            }
        }
    }

    inline fn solidAt(g: *const Generator, sx: i32, sy: i32) bool {
        return g.kind[sidx(sx, sy)] == .solid;
    }

    // -- pools -----------------------------------------------------------------

    fn buildPools(g: *Generator, x0: i32, y0: i32, ox: i32, oy: i32) void {
        const cs: i32 = chunk.size;
        const sx_lo = x0 - pool_half_width;
        const sx_hi = x0 + cs + pool_half_width;
        const sy_lo = y0 - pool_drop - pool_below;
        const sy_hi = y0 + cs + pool_max_depth;
        var gy = @divFloor(sy_lo, pool_grid);
        while (gy <= @divFloor(sy_hi, pool_grid)) : (gy += 1) {
            var gx = @divFloor(sx_lo, pool_grid);
            while (gx <= @divFloor(sx_hi, pool_grid)) : (gx += 1) {
                const h = hash.hash2(gx, gy, g.seeds.pools);
                const px = gx * pool_grid + @as(i32, @intCast(h % pool_grid));
                const py = gy * pool_grid + @as(i32, @intCast((h >> 8) % pool_grid));
                if (px < sx_lo or px >= sx_hi or py < sy_lo or py >= sy_hi) continue;
                if (py < g.surface[@intCast(px - ox)]) continue; // no surface ponds
                const chance = (h >> 16) & 0xff;
                const lava_y: i32 = @intFromFloat(@as(f32, @floatFromInt(g.params.floor_y)) * g.params.lava_depth_fraction);
                const liquid: Liquid = if (py > lava_y) .lava else .water;
                const keep: u32 = if (liquid == .lava) 170 else 150;
                if (chance >= keep) continue;
                g.pool(px - ox, py - oy, liquid);
            }
        }
    }

    /// Flood from (sx, fy) through air with y ≥ level inside the pool box.
    /// Returns the cell count, or null if it leaks (reaches the box edge or
    /// exceeds pool_max_cells).
    fn flood(g: *Generator, sx: i32, fy: i32, level: i32) ?usize {
        g.stamp +%= 1;
        if (g.stamp == 0) {
            @memset(g.visit, 0);
            g.stamp = 1;
        }
        const x_lo = sx - pool_half_width;
        const x_hi = sx + pool_half_width;
        const y_hi = fy + pool_below;
        var head: usize = 0;
        var tail: usize = 0;
        const start = sidx(sx, fy);
        g.visit[start] = g.stamp;
        g.queue[tail] = @intCast(start);
        tail += 1;
        while (head < tail) {
            const i = g.queue[head];
            head += 1;
            const x: i32 = @intCast(i % sw);
            const y: i32 = @intCast(i / sw);
            const nbrs = [4][2]i32{ .{ x - 1, y }, .{ x + 1, y }, .{ x, y + 1 }, .{ x, y - 1 } };
            for (nbrs) |n| {
                if (n[1] < level) continue;
                if (n[0] <= x_lo or n[0] >= x_hi or n[1] >= y_hi) {
                    if (!g.solidAt(n[0], n[1])) return null; // leaks out of the box
                    continue;
                }
                const j = sidx(n[0], n[1]);
                if (g.visit[j] == g.stamp or g.kind[j] == .solid) continue;
                if (tail == g.queue.len) return null;
                g.visit[j] = g.stamp;
                g.queue[tail] = @intCast(j);
                tail += 1;
            }
        }
        return tail;
    }

    fn pool(g: *Generator, sx: i32, sy: i32, liquid: Liquid) void {
        if (g.solidAt(sx, sy)) return;
        var fy = sy;
        while (!g.solidAt(sx, fy + 1)) {
            fy += 1;
            if (fy - sy > pool_drop) return;
        }
        // Largest level (k cells above the floor) that does not leak. Leaking
        // is monotonic in k, so binary search.
        if (g.flood(sx, fy, fy) == null) return;
        var lo: i32 = 0; // known good
        var hi: i32 = pool_max_depth + 1; // known bad (or beyond the limit)
        while (hi - lo > 1) {
            const mid = @divFloor(lo + hi, 2);
            if (g.flood(sx, fy, fy - mid) != null) lo = mid else hi = mid;
        }
        if (lo < 3) return; // puddles are not worth it
        // Leave a little air under the spill point so pools sit settled.
        const level = fy - lo + 1;
        const n = g.flood(sx, fy, level).?;
        for (g.queue[0..n]) |i| {
            // Lava wins overlaps so the result is order-independent.
            if (g.liquid[i] != .lava) g.liquid[i] = liquid;
        }
    }

    // -- materials ---------------------------------------------------------------

    fn classify(g: *Generator, x0: i32, y0: i32, ox: i32, oy: i32) void {
        const ids = g.params.ids;
        const s = &g.seeds;
        // Pocket lattices over the chunk only.
        for (0..pw) |ly| {
            const fy: f32 = @floatFromInt(y0 + @as(i32, @intCast(ly * step)));
            for (0..pw) |lx| {
                const fx: f32 = @floatFromInt(x0 + @as(i32, @intCast(lx * step)));
                const k = ly * pw + lx;
                g.pockets[0][k] = noise.fbm(fx / 170.0, fy / 110.0, s.sand, 2);
                g.pockets[1][k] = noise.fbm(fx / 120.0, fy / 100.0, s.gravel, 2);
                g.pockets[2][k] = noise.fbm(fx / 140.0, fy / 90.0, s.oil, 2);
            }
        }
        const floor_y = g.params.floor_y;
        const inv: f32 = 1.0 / @as(f32, step);
        const cs: i32 = chunk.size;
        for (0..chunk.size) |lyu| {
            const ly: i32 = @intCast(lyu);
            const wy = y0 + ly;
            const sy = wy - oy;
            const qy = lyu >> step_log2;
            const ty = @as(f32, @floatFromInt(lyu & (step - 1))) * inv;
            for (0..chunk.size) |lxu| {
                const lx: i32 = @intCast(lxu);
                const wx = x0 + lx;
                const sx = wx - ox;
                const si = sidx(sx, sy);
                const ci = lyu * chunk.size + lxu;
                switch (g.liquid[si]) {
                    .water => {
                        g.mat[ci] = ids.water;
                        continue;
                    },
                    .lava => {
                        g.mat[ci] = ids.lava;
                        continue;
                    },
                    .none => {},
                }
                if (g.kind[si] == .air) {
                    g.mat[ci] = ids.air;
                    continue;
                }
                if (wy >= floor_y - 64 and wy >= g.bedrockTop(wx)) {
                    g.mat[ci] = ids.bedrock;
                    continue;
                }
                const surf = g.surface[@intCast(sx)];
                const depth = wy - surf;
                if (depth < g.dirt_depth[@intCast(sx)]) {
                    g.mat[ci] = ids.dirt;
                    continue;
                }
                const qx = lxu >> step_log2;
                const tx = @as(f32, @floatFromInt(lxu & (step - 1))) * inv;
                var p: [3]f32 = undefined;
                for (0..3) |k| {
                    const a = g.pockets[k];
                    const top = a[qy * pw + qx] + (a[qy * pw + qx + 1] - a[qy * pw + qx]) * tx;
                    const bot = a[(qy + 1) * pw + qx] + (a[(qy + 1) * pw + qx + 1] - a[(qy + 1) * pw + qx]) * tx;
                    p[k] = top + (bot - top) * ty;
                }
                const f = g.field[si];
                const deep = @as(f32, @floatFromInt(depth)) / @as(f32, @floatFromInt(floor_y));
                var m = ids.stone;
                if (p[2] > 0.66 and deep > 0.15 and f < -0.07) {
                    m = ids.oil; // sealed in rock, away from caves
                } else if (p[0] > 0.6 - 0.1 * deep and depth > 50) {
                    m = ids.sand;
                } else if (p[1] > 0.64) {
                    m = ids.gravel;
                } else if (p[1] < -0.58 and deep < 0.3) {
                    m = ids.dirt;
                }
                g.mat[ci] = m;
            }
        }
        _ = cs;
    }

    fn addMoss(g: *Generator, x0: i32, y0: i32, ox: i32, oy: i32) void {
        const ids = g.params.ids;
        const r = moss_radius;
        const rows = chunk.size + 2 * r;
        // Horizontal pass: near_water[row][x] = water within ±r in x.
        for (0..rows) |rowu| {
            const sy = y0 - r + @as(i32, @intCast(rowu)) - oy;
            var count: i32 = 0;
            var sx = x0 - ox - r;
            while (sx < x0 - ox + r) : (sx += 1) {
                if (g.liquid[sidx(sx, sy)] == .water) count += 1;
            }
            for (0..chunk.size) |lxu| {
                const cx = x0 - ox + @as(i32, @intCast(lxu));
                if (g.liquid[sidx(cx + r, sy)] == .water) count += 1;
                g.near_water[rowu * chunk.size + lxu] = if (count > 0) 1 else 0;
                if (g.liquid[sidx(cx - r, sy)] == .water) count -= 1;
            }
        }
        for (0..chunk.size) |lyu| {
            for (0..chunk.size) |lxu| {
                const ci = lyu * chunk.size + lxu;
                if (g.mat[ci] != ids.stone) continue;
                var near = false;
                for (0..2 * r + 1) |k| {
                    if (g.near_water[(lyu + k) * chunk.size + lxu] != 0) {
                        near = true;
                        break;
                    }
                }
                if (!near) continue;
                const wx = x0 + @as(i32, @intCast(lxu));
                const wy = y0 + @as(i32, @intCast(lyu));
                const sx = wx - ox;
                const sy = wy - oy;
                const exposed1 = !g.solidAt(sx - 1, sy) or !g.solidAt(sx + 1, sy) or
                    !g.solidAt(sx, sy - 1) or !g.solidAt(sx, sy + 1);
                const exposed2 = !g.solidAt(sx - 2, sy) or !g.solidAt(sx + 2, sy) or
                    !g.solidAt(sx, sy - 2) or !g.solidAt(sx, sy + 2);
                const roll = noise.rand01(wx, wy, g.seeds.deco);
                if ((exposed1 and roll < 0.85) or (exposed2 and roll < 0.4)) g.mat[ci] = ids.moss;
            }
        }
    }

    // -- structures --------------------------------------------------------------

    inline fn put(g: *Generator, x0: i32, y0: i32, wx: i32, wy: i32, m: u8) void {
        const lx = wx - x0;
        const ly = wy - y0;
        if (lx < 0 or ly < 0 or lx >= chunk.size or ly >= chunk.size) return;
        g.mat[@as(usize, @intCast(ly)) * chunk.size + @as(usize, @intCast(lx))] = m;
    }

    fn addPlatforms(g: *Generator, x0: i32, y0: i32, ox: i32, oy: i32) void {
        const grid = 128;
        const reach = 90;
        const post_reach = 64;
        const cs: i32 = chunk.size;
        const ids = g.params.ids;
        var gy = @divFloor(y0 - post_reach - 8, grid);
        while (gy <= @divFloor(y0 + cs + 4, grid)) : (gy += 1) {
            var gx = @divFloor(x0 - reach - 4, grid);
            while (gx <= @divFloor(x0 + cs + reach + 4, grid)) : (gx += 1) {
                const h = hash.hash2(gx, gy, g.seeds.platforms);
                if ((h >> 24) >= 110) continue;
                const px = gx * grid + @as(i32, @intCast(h % grid));
                const py = gy * grid + @as(i32, @intCast((h >> 8) % grid));
                if (px < x0 - reach - 4 or px >= x0 + cs + reach + 4) continue;
                if (py < y0 - post_reach - 8 or py >= y0 + cs + 4) continue;
                if (py - g.surfaceAt(px) < 50 or py > g.params.floor_y - 200) continue;
                const sx = px - ox;
                const sy = py - oy;
                if (g.solidAt(sx, sy) or g.liquid[sidx(sx, sy)] != .none) continue;
                // Need headroom so it reads as a ledge, not a plug.
                if (g.solidAt(sx, sy - 12)) continue;
                var xl = sx;
                while (!g.solidAt(xl - 1, sy)) {
                    xl -= 1;
                    if (sx - xl >= reach) break;
                }
                var xr = sx;
                while (!g.solidAt(xr + 1, sy)) {
                    xr += 1;
                    if (xr - sx >= reach) break;
                }
                if (sx - xl >= reach or xr - sx >= reach or xr - xl < 16) continue;
                var x = xl;
                while (x <= xr) : (x += 1) {
                    const wx = x + ox;
                    // Broken boards: short gaps, never at the anchored ends.
                    if (x - xl > 4 and xr - x > 4 and hash.hash2(wx >> 2, py, g.seeds.deco +% 7) % 23 == 0) continue;
                    var t: i32 = 0;
                    while (t < 3) : (t += 1) g.put(x0, y0, wx, py + t, ids.wood);
                }
                // Posts down to the floor where it is close.
                x = xl + 6 + @as(i32, @intCast((h >> 4) % 8));
                while (x < xr - 4) : (x += 26) {
                    var y = sy + 3;
                    while (y - sy < post_reach and !g.solidAt(x, y)) y += 1;
                    if (y - sy >= post_reach) continue;
                    var yy = sy + 3;
                    while (yy < y) : (yy += 1) {
                        g.put(x0, y0, x + ox, yy + oy, ids.wood);
                        g.put(x0, y0, x + ox + 1, yy + oy, ids.wood);
                    }
                }
            }
        }
    }

    fn addRooms(g: *Generator, x0: i32, y0: i32, ox: i32, oy: i32) void {
        const gw = 288;
        const gh = 224;
        const half_w = 80;
        const half_h = 56;
        const cs: i32 = chunk.size;
        var gy = @divFloor(y0 - half_h, gh);
        while (gy <= @divFloor(y0 + cs + half_h, gh)) : (gy += 1) {
            var gx = @divFloor(x0 - half_w, gw);
            while (gx <= @divFloor(x0 + cs + half_w, gw)) : (gx += 1) {
                const h = hash.hash2(gx, gy, g.seeds.rooms);
                const h2 = hash.mix32(h);
                const cx = gx * gw + 56 + @as(i32, @intCast(h % (gw - 112)));
                const cy = gy * gh + 40 + @as(i32, @intCast((h >> 10) % (gh - 80)));
                if (cx < x0 - half_w or cx >= x0 + cs + half_w) continue;
                if (cy < y0 - half_h or cy >= y0 + cs + half_h) continue;
                const depth = cy - g.surfaceAt(cx);
                if (depth < 90 or cy > g.params.floor_y - 300) continue;
                if (!g.solidAt(cx - ox, cy - oy)) continue;
                const roll = h2 & 0xff;
                const deep = @as(f32, @floatFromInt(depth)) / @as(f32, @floatFromInt(g.params.floor_y));
                if (deep > 0.18 and roll < 64) {
                    g.ruin(x0, y0, cx, cy, h2);
                } else if (roll < 72) {
                    g.cabin(x0, y0, cx, cy, h2);
                }
            }
        }
    }

    /// Gunpowder caches: small lenses sealed in rock, a fuse waiting for a
    /// stray spark. Only replace rock, never open space.
    fn addCaches(g: *Generator, x0: i32, y0: i32, ox: i32, oy: i32) void {
        const grid = 192;
        const r = 14;
        const cs: i32 = chunk.size;
        const ids = g.params.ids;
        var gy = @divFloor(y0 - r, grid);
        while (gy <= @divFloor(y0 + cs + r, grid)) : (gy += 1) {
            var gx = @divFloor(x0 - r, grid);
            while (gx <= @divFloor(x0 + cs + r, grid)) : (gx += 1) {
                const h = hash.hash2(gx, gy, g.seeds.pocket);
                if ((h >> 24) >= 90) continue;
                const cx = gx * grid + @as(i32, @intCast(h % grid));
                const cy = gy * grid + @as(i32, @intCast((h >> 8) % grid));
                if (cx < x0 - r or cx >= x0 + cs + r or cy < y0 - r or cy >= y0 + cs + r) continue;
                if (cy - g.surfaceAt(cx) < 120 or cy > g.params.floor_y - 200) continue;
                const rx: i32 = 6 + @as(i32, @intCast((h >> 16) % 8));
                const ry: i32 = 3 + @as(i32, @intCast((h >> 19) % 5));
                var y = cy - ry;
                while (y <= cy + ry) : (y += 1) {
                    var x = cx - rx;
                    while (x <= cx + rx) : (x += 1) {
                        const dx = @as(f32, @floatFromInt(x - cx)) / @as(f32, @floatFromInt(rx));
                        const dy = @as(f32, @floatFromInt(y - cy)) / @as(f32, @floatFromInt(ry));
                        if (dx * dx + dy * dy > 1) continue;
                        if (!g.solidAt(x - ox, y - oy)) continue;
                        const lx = x - x0;
                        const ly = y - y0;
                        if (lx < 0 or ly < 0 or lx >= cs or ly >= cs) continue;
                        const ci = @as(usize, @intCast(ly)) * chunk.size + @as(usize, @intCast(lx));
                        if (g.mat[ci] == ids.bedrock or g.mat[ci] == ids.oil) continue;
                        g.mat[ci] = ids.gunpowder;
                    }
                }
            }
        }
    }

    fn crate(g: *Generator, x0: i32, y0: i32, left: i32, floor: i32, w: i32, hgt: i32) void {
        const ids = g.params.ids;
        var y = floor - hgt;
        while (y < floor) : (y += 1) {
            var x = left;
            while (x < left + w) : (x += 1) {
                const edge = x == left or x == left + w - 1 or y == floor - hgt or y == floor - 1;
                g.put(x0, y0, x, y, if (edge) ids.wood else ids.gunpowder);
            }
        }
    }

    /// Wooden cabin buried in rock: plank walls, doorways, maybe a powder crate.
    fn cabin(g: *Generator, x0: i32, y0: i32, cx: i32, cy: i32, h: u32) void {
        const ids = g.params.ids;
        const w: i32 = 64 + @as(i32, @intCast((h >> 8) % 33));
        const ht: i32 = 50 + @as(i32, @intCast((h >> 14) % 15));
        const wall = 3;
        const left = cx - @divFloor(w, 2);
        const top = cy - @divFloor(ht, 2);
        const right = left + w - 1;
        const bottom = top + ht - 1;
        const door_l = (h >> 20) & 1 == 1;
        const door_r = (h >> 21) & 1 == 1 or !door_l;
        const door_h = 38;
        var y = top;
        while (y <= bottom) : (y += 1) {
            var x = left;
            while (x <= right) : (x += 1) {
                const in_wall = x - left < wall or right - x < wall or y - top < wall or bottom - y < wall;
                const in_door = y > bottom - wall - door_h and y <= bottom - wall and
                    ((door_l and x - left < wall) or (door_r and right - x < wall));
                g.put(x0, y0, x, y, if (in_wall and !in_door) ids.wood else ids.air);
            }
        }
        // Inner shelf.
        const shelf_y = top + wall + 14;
        var x = left + wall;
        while (x < left + wall + @divFloor(w, 3)) : (x += 1) g.put(x0, y0, x, shelf_y, ids.wood);
        if ((h >> 22) & 3 != 0) g.crate(x0, y0, right - wall - 16, bottom - wall + 1, 12, 9);
    }

    /// Concrete ruin with steel girders, crumbling walls and a powder cache.
    fn ruin(g: *Generator, x0: i32, y0: i32, cx: i32, cy: i32, h: u32) void {
        const ids = g.params.ids;
        const w: i32 = 100 + @as(i32, @intCast((h >> 8) % 45));
        const ht: i32 = 64 + @as(i32, @intCast((h >> 14) % 33));
        const wall = 5;
        const girder = 3;
        const left = cx - @divFloor(w, 2);
        const top = cy - @divFloor(ht, 2);
        const right = left + w - 1;
        const bottom = top + ht - 1;
        const door_h = 40;
        const pillar_a = left + @divFloor(w, 3);
        const pillar_b = left + @divFloor(2 * w, 3);
        const decay_seed = g.seeds.deco +% h;
        var y = top;
        while (y <= bottom) : (y += 1) {
            var x = left;
            while (x <= right) : (x += 1) {
                const dl = x - left;
                const dr = right - x;
                const dt = y - top;
                const db = bottom - y;
                const in_wall = dl < wall or dr < wall or dt < wall or db < wall;
                var m = ids.air;
                if (in_wall) {
                    const in_door = db >= wall and db < wall + door_h and (dl < wall or dr < wall);
                    m = if (in_door) ids.air else ids.concrete;
                    // Crumbling: holes through the upper walls and roof.
                    if (m == ids.concrete and db > wall and noise.value(x, y, 3, decay_seed) > 0.68) m = ids.air;
                } else if (dt < wall + girder or (db < wall + girder and db >= wall)) {
                    m = ids.steel;
                } else if ((x >= pillar_a and x < pillar_a + 3) or (x >= pillar_b and x < pillar_b + 3)) {
                    // Pillars, some snapped.
                    m = if ((h >> 24) & 1 == 1 and dt > @divFloor(ht, 2)) ids.air else ids.steel;
                }
                g.put(x0, y0, x, y, m);
            }
        }
        // Rubble heap and a powder cache on the floor.
        const floor = bottom - wall - girder + 1;
        var x = left + wall;
        while (x < right - wall) : (x += 1) {
            const heap = @as(i32, @intFromFloat(6.0 * noise.value(x, 0, 3, decay_seed +% 3))) - 2;
            var t: i32 = 0;
            while (t < heap) : (t += 1) g.put(x0, y0, x, floor - 1 - t, ids.gravel);
        }
        if ((h >> 26) & 3 != 0) g.crate(x0, y0, left + wall + 4, floor, 16, 10);
    }

    fn finish(g: *Generator, c: chunk.Coord, out: *chunk.Cells) void {
        const ids = g.params.ids;
        const ss = g.params.spawn_state;
        const lava_t = cell.celsiusToByte(g.params.lava_celsius);
        const o = c.originCell();
        for (out, g.mat, 0..) |*dst, m, i| {
            const lx: i32 = @intCast(i & (chunk.size - 1));
            const ly: i32 = @intCast(i >> chunk.size_log2);
            const temp = if (m == ids.lava) lava_t else cell.ambient_temperature;
            const st: u8 = if (m == ids.stone) ss.stone else if (m == ids.wood) ss.wood else if (m == ids.steel)
                ss.steel
            else if (m == ids.concrete) ss.concrete else 0;
            dst.* = cell.pack(m, temp, st, 0, hash.baseVariant(o[0] + lx, o[1] + ly));
        }
    }
};

/// Ids for tests and the preview tool, in a fixed order.
pub const test_ids: MaterialIds = .{
    .air = 0,
    .stone = 1,
    .dirt = 2,
    .sand = 3,
    .water = 4,
    .lava = 5,
    .wood = 6,
    .concrete = 7,
    .steel = 8,
    .bedrock = 9,
    .oil = 10,
    .gunpowder = 11,
    .moss = 12,
    .gravel = 13,
};

const testing = std.testing;

test "procgen is deterministic per (seed, cx, cy)" {
    const a = testing.allocator;
    var g1 = try Generator.init(a, 1234, .{ .ids = test_ids });
    defer g1.deinit(a);
    var g2 = try Generator.init(a, 1234, .{ .ids = test_ids });
    defer g2.deinit(a);
    var g3 = try Generator.init(a, 1235, .{ .ids = test_ids });
    defer g3.deinit(a);
    const c1 = try a.create(chunk.Cells);
    defer a.destroy(c1);
    const c2 = try a.create(chunk.Cells);
    defer a.destroy(c2);
    const coords = [_]chunk.Coord{ .{ .x = 0, .y = 0 }, .{ .x = -3, .y = 2 }, .{ .x = 5, .y = 9 } };
    for (coords) |c| {
        g1.generate(c, c1);
        // Generate something else in between so leftover scratch cannot leak.
        g2.generate(.{ .x = c.x + 11, .y = c.y + 1 }, c2);
        g2.generate(c, c2);
        try testing.expectEqualSlices(u32, c1, c2);
        g3.generate(c, c2);
        try testing.expect(!std.mem.eql(u32, c1, c2));
    }
}

test "procgen: sky, floor and seams" {
    const a = testing.allocator;
    var g = try Generator.init(a, 99, .{ .ids = test_ids });
    defer g.deinit(a);
    const c1 = try a.create(chunk.Cells);
    defer a.destroy(c1);
    g.generate(.{ .x = 2, .y = -1 }, c1);
    for (c1) |v| try testing.expectEqual(test_ids.air, cell.material(v));
    g.generate(.{ .x = 2, .y = 32 }, c1);
    for (c1) |v| try testing.expectEqual(test_ids.bedrock, cell.material(v));
    // Lava is hot, everything else ambient; variants are not flat.
    g.generate(.{ .x = 1, .y = 3 }, c1);
    var variants: [16]bool = @splat(false);
    for (c1) |v| {
        variants[cell.variant(v)] = true;
        if (cell.material(v) == test_ids.lava) {
            try testing.expect(cell.byteToCelsius(cell.temperature(v)) > 1000);
        } else try testing.expectEqual(cell.ambient_temperature, cell.temperature(v));
    }
    for (variants) |b| try testing.expect(b);
}
