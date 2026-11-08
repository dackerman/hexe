//! Tests for bodies.zig: pure helpers first, then Box2D scenarios.

const std = @import("std");
const bodies = @import("bodies.zig");

const testing = std.testing;
const BodyWorld = bodies.BodyWorld;

const steel: u8 = 1;
const wood: u8 = 2;
const concrete: u8 = 3;
const ballast: u8 = 4;

fn testWorld() !BodyWorld {
    var w = try BodyWorld.init(testing.allocator, .{
        .max_bodies = 256,
        .max_body_pixels = 1 << 18,
        .max_bitmap_pixels = 64 * 64,
        .max_beams = 8,
        .max_beam_segments = 32,
        .static_max_w = 512,
        .static_max_h = 512,
    });
    w.setMaterial(steel, bodies.Material.presets.steel);
    w.setMaterial(wood, bodies.Material.presets.wood);
    w.setMaterial(concrete, bodies.Material.presets.concrete);
    w.setMaterial(ballast, .{ .density = 1.0 });
    return w;
}

// -- greedy rectangle decomposition -------------------------------------------

fn checkExactCover(grid: []const u8, w: usize, h: usize, rects: []const bodies.Rect) !void {
    var cover = try testing.allocator.alloc(u8, w * h);
    defer testing.allocator.free(cover);
    @memset(cover, 0);
    for (rects) |r| {
        try testing.expect(r.w > 0 and r.h > 0);
        for (r.y..r.y + r.h) |y| {
            for (r.x..r.x + r.w) |x| cover[y * w + x] += 1;
        }
    }
    for (0..w * h) |i| {
        const want: u8 = @intFromBool(grid[i] != 0);
        try testing.expectEqual(want, cover[i]);
    }
}

test "decomposeRects covers exactly the solid pixels" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rnd = prng.random();
    const w = 37;
    const h = 23;
    var grid: [w * h]u8 = undefined;
    var visited: [w * h]bool = undefined;
    var out: [w * h / 2 + 1]bodies.Rect = undefined;
    for (0..50) |iter| {
        // Mix of sparse noise, dense noise and blobby shapes.
        const p: u32 = @intCast(10 + (iter * 17) % 85);
        for (&grid) |*c| c.* = if (rnd.uintLessThan(u32, 100) < p) rnd.intRangeAtMost(u8, 1, 255) else 0;
        const rects = try bodies.decomposeRects(&grid, w, h, w, &visited, &out);
        try checkExactCover(&grid, w, h, rects);
    }
    // Full grid is one rectangle; empty grid is none.
    @memset(&grid, 7);
    try testing.expectEqual(@as(usize, 1), (try bodies.decomposeRects(&grid, w, h, w, &visited, &out)).len);
    @memset(&grid, 0);
    try testing.expectEqual(@as(usize, 0), (try bodies.decomposeRects(&grid, w, h, w, &visited, &out)).len);
}

test "decomposeRects honors stride and reports overflow" {
    // 4x3 window inside a 6-wide buffer; the outer columns are junk.
    const buf = [_]u8{
        9, 1, 1, 0, 0, 9,
        9, 1, 1, 0, 1, 9,
        9, 0, 0, 0, 1, 9,
    };
    var visited: [12]bool = undefined;
    var out: [8]bodies.Rect = undefined;
    const rects = try bodies.decomposeRects(buf[1..], 4, 3, 6, &visited, &out);
    try testing.expectEqual(@as(usize, 2), rects.len);
    try testing.expectEqual(bodies.Rect{ .x = 0, .y = 0, .w = 2, .h = 2 }, rects[0]);
    try testing.expectEqual(bodies.Rect{ .x = 3, .y = 1, .w = 1, .h = 2 }, rects[1]);
    var tiny: [1]bodies.Rect = undefined;
    try testing.expectError(error.TooManyRects, bodies.decomposeRects(buf[1..], 4, 3, 6, &visited, &tiny));
}

// -- connectivity ---------------------------------------------------------------

test "splitByConnectivity returns 4-connected components with offsets" {
    var scratch = try bodies.SplitScratch.init(testing.allocator, 64, 8);
    defer scratch.deinit(testing.allocator);
    // Diagonal contact does not connect (4-connectivity).
    const bm = [_]u8{
        1, 1, 0, 0, 0, 0,
        1, 0, 0, 3, 3, 0,
        0, 0, 0, 3, 0, 0,
        0, 0, 2, 0, 0, 5,
        0, 0, 2, 2, 0, 5,
    };
    const comps = try bodies.splitByConnectivity(&bm, 6, 5, &scratch);
    try testing.expectEqual(@as(usize, 4), comps.len);

    try testing.expectEqual(@as(u16, 0), comps[0].x);
    try testing.expectEqual(@as(u16, 0), comps[0].y);
    try testing.expectEqual(@as(u16, 2), comps[0].w);
    try testing.expectEqual(@as(u16, 2), comps[0].h);
    try testing.expectEqual(@as(u32, 3), comps[0].pixel_count);
    try testing.expectEqualSlices(u8, &.{ 1, 1, 1, 0 }, comps[0].pixels);

    try testing.expectEqual(@as(u16, 3), comps[1].x);
    try testing.expectEqual(@as(u16, 1), comps[1].y);
    try testing.expectEqualSlices(u8, &.{ 3, 3, 3, 0 }, comps[1].pixels);

    try testing.expectEqual(@as(u16, 2), comps[2].x);
    try testing.expectEqual(@as(u16, 3), comps[2].y);
    try testing.expectEqualSlices(u8, &.{ 2, 0, 2, 2 }, comps[2].pixels);

    try testing.expectEqual(@as(u16, 5), comps[3].x);
    try testing.expectEqual(@as(u16, 3), comps[3].y);
    try testing.expectEqual(@as(u16, 1), comps[3].w);
    try testing.expectEqual(@as(u16, 2), comps[3].h);
    try testing.expectEqualSlices(u8, &.{ 5, 5 }, comps[3].pixels);
}

test "splitByConnectivity masks out other components inside a bounding box" {
    var scratch = try bodies.SplitScratch.init(testing.allocator, 64, 8);
    defer scratch.deinit(testing.allocator);
    // A U shape around an island: the island lies inside the U's box.
    const bm = [_]u8{
        1, 0, 0, 0, 1,
        1, 0, 2, 0, 1,
        1, 0, 0, 0, 1,
        1, 1, 1, 1, 1,
    };
    const comps = try bodies.splitByConnectivity(&bm, 5, 4, &scratch);
    try testing.expectEqual(@as(usize, 2), comps.len);
    try testing.expectEqual(@as(u32, 11), comps[0].pixel_count);
    try testing.expectEqual(@as(u8, 0), comps[0].pixels[1 * 5 + 2]);
    try testing.expectEqual(@as(u32, 1), comps[1].pixel_count);
    try testing.expectEqualSlices(u8, &.{2}, comps[1].pixels);
}

// -- scenarios ------------------------------------------------------------------

/// Ground: solid rows from `top` to the bottom of a 256 × 128 region at (0, 0).
fn groundMask(mask: []u8, w: usize, h: usize, top: usize) void {
    for (0..h) |y| @memset(mask[y * w .. (y + 1) * w], @intFromBool(y >= top));
}

fn stepSeconds(w: *BodyWorld, s: f32) void {
    const n: usize = @intFromFloat(@round(s / bodies.tick_dt));
    for (0..n) |_| w.step();
}

test "box dropped on static ground rests at the right height" {
    var w = try testWorld();
    defer w.deinit();
    const mw = 256;
    const mh = 128;
    var mask: [mw * mh]u8 = undefined;
    groundMask(&mask, mw, mh, 100);

    var px: [10 * 10]u8 = undefined;
    @memset(&px, concrete);
    const box = try w.createPixelBody(.{ .pixels = &px, .w = 10, .h = 10, .x = 120, .y = 20 });
    try testing.expectApproxEqRel(@as(f32, 100 * 0.30), w.getMass(box).?, 1e-4);

    var max_impulse: f32 = 0;
    for (0..180) |_| {
        try w.setStaticCollision(&mask, mw, mh, 0, 0);
        w.step();
        for (w.impacts()) |im| max_impulse = @max(max_impulse, im.normal_impulse);
    }
    const t = w.getTransform(box).?;
    // Bottom edge at y = 100 (top-left origin, 10 px tall), level, at rest.
    try testing.expectApproxEqAbs(@as(f32, 90), t.y, 0.25);
    try testing.expectApproxEqAbs(@as(f32, 0), t.angle, 1e-3);
    try testing.expect(@abs(w.getVelocity(box).?.y) < 1);
    // Fell 70 px: v = sqrt(2·196·70) ≈ 166 px/s, so the landing impulse is
    // about m·v ≈ 30 kg × 166 px/s ≈ 5000 kg·px/s.
    try testing.expectApproxEqRel(@as(f32, 30 * 166), max_impulse, 0.1);
}

test "static collision only rebuilds tiles that changed" {
    var w = try testWorld();
    defer w.deinit();
    const mw = 256;
    const mh = 128;
    var mask: [mw * mh]u8 = undefined;
    groundMask(&mask, mw, mh, 100);
    try w.setStaticCollision(&mask, mw, mh, 0, 0);
    try testing.expectEqual(@as(u32, 8), w.static_stats.tiles);
    try testing.expectEqual(@as(u32, 8), w.static_stats.tiles_rebuilt);
    try w.setStaticCollision(&mask, mw, mh, 0, 0);
    try testing.expectEqual(@as(u32, 0), w.static_stats.tiles_rebuilt);
    mask[110 * mw + 200] = 0; // dig one pixel in tile (3, 1)
    try w.setStaticCollision(&mask, mw, mh, 0, 0);
    try testing.expectEqual(@as(u32, 1), w.static_stats.tiles_rebuilt);
    // A shifted region keeps world-aligned tiles that still match.
    try w.setStaticCollision(mask[64 * mw ..], mw, 64, 0, 64);
    try testing.expectEqual(@as(u32, 4), w.static_stats.tiles);
    try testing.expectEqual(@as(u32, 0), w.static_stats.tiles_rebuilt);
}

const Cantilever = struct {
    beam: bodies.BeamHandle,
    weight: bodies.BodyHandle,
    tip_x: f32,
    tip_y: f32,
};

/// 120 px beam, 4 px thick, 12 segments, welded to the world at (100, 100),
/// with a ballast block of `weight_kg` welded at its free end.
fn cantilever(w: *BodyWorld, material: u8, weight_kg: f32) !Cantilever {
    const beam = try w.createBeam(.{ .x0 = 100, .y0 = 100, .x1 = 220, .y1 = 100, .thickness = 4, .material = material, .segments = 12, .anchor_start = true });
    var px: [8 * 8]u8 = undefined;
    @memset(&px, ballast);
    w.setMaterial(ballast, .{ .density = weight_kg / 64.0 });
    const weight = try w.createPixelBody(.{ .pixels = &px, .w = 8, .h = 8, .x = 220, .y = 100, .origin_x = 4, .origin_y = 4 });
    _ = try w.weld(weight, w.beamSegments(beam)[11], 220, 100);
    return .{ .beam = beam, .weight = weight, .tip_x = 220, .tip_y = 100 };
}

fn tipDeflection(w: *BodyWorld, c: Cantilever) f32 {
    return w.getCenterOfMass(c.weight).?.y - c.tip_y;
}

test "steel cantilever under load sags over time but holds" {
    var w = try testWorld();
    defer w.deinit();
    const c = try cantilever(&w, steel, 200);
    const joints0 = w.beamJointCount(c.beam);
    try testing.expectEqual(@as(usize, 12), joints0);
    stepSeconds(&w, 0.5);
    const d_half = tipDeflection(&w, c);
    stepSeconds(&w, 1.5);
    const d_two = tipDeflection(&w, c);
    try testing.expectEqual(joints0, w.beamJointCount(c.beam));
    try testing.expectEqual(@as(usize, 0), w.jointBreaks().len);
    try testing.expect(d_half > 1);
    try testing.expect(d_two > d_half + 1);
    // Permanent: the root joint has flowed plastically.
    try testing.expect(@abs(w.beamPlasticAngle(c.beam, 0)) > 0.01);
}

test "steel cantilever under five times the load snaps" {
    var w = try testWorld();
    defer w.deinit();
    const c = try cantilever(&w, steel, 1000);
    var breaks: usize = 0;
    for (0..120) |_| {
        w.step();
        breaks += w.jointBreaks().len;
    }
    try testing.expect(w.beamJointCount(c.beam) < 12);
    try testing.expect(breaks > 0);
}

test "wooden beam snaps with little deflection" {
    var w = try testWorld();
    defer w.deinit();
    const c = try cantilever(&w, wood, 40);
    var deflection_at_break: ?f32 = null;
    var last: f32 = 0;
    for (0..120) |_| {
        w.step();
        if (w.jointBreaks().len > 0 and deflection_at_break == null) deflection_at_break = last;
        last = tipDeflection(&w, c);
    }
    try testing.expect(deflection_at_break != null);
    try testing.expect(w.beamJointCount(c.beam) < 12);
    try testing.expect(deflection_at_break.? < 5);
}

test "splitBody turns a cut body into falling pieces" {
    var w = try testWorld();
    defer w.deinit();
    var px: [12 * 4]u8 = undefined;
    @memset(&px, concrete);
    const h = try w.createPixelBody(.{ .pixels = &px, .w = 12, .h = 4, .x = 50, .y = 50, .vx = 30 });
    // Cut column 5 out entirely.
    for (0..4) |y| px[y * 12 + 5] = 0;
    const pieces = try w.splitBody(h, &px, 12, 4, 0, 0);
    try testing.expectEqual(@as(usize, 2), pieces.len);
    try testing.expect(pieces[0].eql(h));
    try testing.expectEqual(@as(u32, 20), w.getPixelCount(pieces[0]).?);
    try testing.expectEqual(@as(u32, 24), w.getPixelCount(pieces[1]).?);
    // The right piece keeps the world position of its pixels.
    const p = w.bitmapToWorld(pieces[1], 0, 0).?;
    try testing.expectApproxEqAbs(@as(f32, 56.5), p.x, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 50.5), p.y, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 30), w.getVelocity(pieces[1]).?.x, 1e-3);
    try testing.expectEqual(@as(usize, 2), w.bodyCount());
}

test "bitmap and world coordinates round-trip on a rotated body" {
    var w = try testWorld();
    defer w.deinit();
    var px: [6 * 3]u8 = undefined;
    @memset(&px, steel);
    const h = try w.createPixelBody(.{ .pixels = &px, .w = 6, .h = 3, .x = 30, .y = 40, .origin_x = 3, .origin_y = 1.5, .angle = 0.7 });
    for (0..3) |j| {
        for (0..6) |i| {
            const p = w.bitmapToWorld(h, @intCast(i), @intCast(j)).?;
            const back = w.worldToBitmap(h, p.x, p.y).?;
            try testing.expectEqual(@as(u16, @intCast(i)), back.x);
            try testing.expectEqual(@as(u16, @intCast(j)), back.y);
        }
    }
    var it = w.rasterIterator();
    const rb = it.next().?;
    try testing.expect(rb.handle.eql(h));
    try testing.expectEqual(@as(usize, 18), rb.pixels.len);
    try testing.expect(it.next() == null);
}

test "blast pushes bodies away and fluid drag slows them" {
    var w = try testWorld();
    defer w.deinit();
    var px: [4 * 4]u8 = undefined;
    @memset(&px, wood);
    const left = try w.createPixelBody(.{ .pixels = &px, .w = 4, .h = 4, .x = 80, .y = 98 });
    const right = try w.createPixelBody(.{ .pixels = &px, .w = 4, .h = 4, .x = 116, .y = 98 });
    const far = try w.createPixelBody(.{ .pixels = &px, .w = 4, .h = 4, .x = 300, .y = 98 });
    w.applyBlast(100, 100, 40, 10);
    w.step();
    try testing.expect(w.getVelocity(left).?.x < -50);
    try testing.expect(w.getVelocity(right).?.x > 50);
    try testing.expectApproxEqAbs(@as(f32, 0), w.getVelocity(far).?.x, 1e-4);

    const v0 = w.getVelocity(right).?.x;
    for (0..30) |_| {
        w.applyFluid(right, .{ .x = 0, .y = 0 }, 2.0, 0, .{ .x = 0, .y = 0 });
        w.step();
    }
    try testing.expect(w.getVelocity(right).?.x < 0.5 * v0);
    try testing.expect(w.getVelocity(right).?.x > 0);

    // Buoyancy equal to weight cancels gravity.
    const m = w.getMass(far).?;
    const y0 = w.getVelocity(far).?.y;
    for (0..30) |_| {
        w.applyFluid(far, .{ .x = 0, .y = 0 }, 0, 0, .{ .x = 0, .y = -m * bodies.gravity_px });
        w.step();
    }
    try testing.expectApproxEqAbs(y0, w.getVelocity(far).?.y, 0.05);
}
