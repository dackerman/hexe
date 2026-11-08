//! Headless beam demo: a steel cantilever with a load sags plastically; from
//! t = 2 s a torch cuts into it near the wall, so it sags further and then
//! snaps; the broken part falls to the floor. Prints an ASCII view every 0.5 s.
//!
//!   zig build bodies-demo
//!   zig build bodies-demo -- --material wood --weight 8 --cut-at 0 --seconds 3
//!
//! Options: --material steel|wood|concrete, --weight KG, --cut-at SECONDS
//! (0 = never), --cut-rate FRACTION_OF_THICKNESS_PER_SECOND, --seconds N,
//! --every SECONDS, --quiet (numbers and per-joint loads instead of ASCII),
//! --bench (time static rebuild and stepping with a rubble pile instead),
//! and solver knobs --substeps, --joint-hertz, --joint-damping,
//! --inertia-scale.

const std = @import("std");
const bodies = @import("bodies");

const steel: u8 = 1;
const wood: u8 = 2;
const concrete: u8 = 3;
const ballast: u8 = 4;

// View: world x 80..260, y 60..240, 3 × 3 px per character.
const view_x0 = 80;
const view_y0 = 70;
const view_w = 180;
const view_h = 162;
const cell = 3;
const cols = view_w / cell;
const rows = view_h / cell;

const floor_y = 220;
const wall_x = 100;

pub fn main(init: std.process.Init) !void {
    var out_buf: [16 * 1024]u8 = undefined;
    var fw = std.Io.File.stdout().writer(init.io, &out_buf);
    const out = &fw.interface;

    var material: u8 = steel;
    var weight_kg: f32 = 200;
    var cut_at: f32 = 2.0;
    var cut_rate: f32 = 0.15;
    var seconds: f32 = 6.0;
    var every: f32 = 0.5;
    var quiet = false;
    var substeps: u8 = 4;
    var joint_hertz: f32 = 60;
    var joint_damping: f32 = 2;
    var inertia_scale: f32 = 60;

    var args = init.minimal.args.iterate();
    _ = args.skip();
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--quiet")) {
            quiet = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--bench")) return bench(init, out);
        const v = args.next() orelse return error.MissingValue;
        if (std.mem.eql(u8, a, "--material")) {
            material = if (std.mem.eql(u8, v, "wood")) wood else if (std.mem.eql(u8, v, "concrete")) concrete else steel;
        } else if (std.mem.eql(u8, a, "--weight")) {
            weight_kg = try std.fmt.parseFloat(f32, v);
        } else if (std.mem.eql(u8, a, "--cut-at")) {
            cut_at = try std.fmt.parseFloat(f32, v);
        } else if (std.mem.eql(u8, a, "--cut-rate")) {
            cut_rate = try std.fmt.parseFloat(f32, v);
        } else if (std.mem.eql(u8, a, "--seconds")) {
            seconds = try std.fmt.parseFloat(f32, v);
        } else if (std.mem.eql(u8, a, "--substeps")) {
            substeps = try std.fmt.parseInt(u8, v, 10);
        } else if (std.mem.eql(u8, a, "--joint-hertz")) {
            joint_hertz = try std.fmt.parseFloat(f32, v);
        } else if (std.mem.eql(u8, a, "--inertia-scale")) {
            inertia_scale = try std.fmt.parseFloat(f32, v);
        } else if (std.mem.eql(u8, a, "--joint-damping")) {
            joint_damping = try std.fmt.parseFloat(f32, v);
        } else if (std.mem.eql(u8, a, "--every")) {
            every = try std.fmt.parseFloat(f32, v);
        } else return error.UnknownOption;
    }

    var world = try bodies.BodyWorld.init(init.gpa, .{
        .max_bodies = 512,
        .max_body_pixels = 1 << 20,
        .static_max_w = 512,
        .static_max_h = 512,
        .substeps = substeps,
        .joint_hertz = joint_hertz,
        .joint_damping = joint_damping,
        .beam_inertia_scale = inertia_scale,
    });
    defer world.deinit();
    world.setMaterial(steel, bodies.Material.presets.steel);
    world.setMaterial(wood, bodies.Material.presets.wood);
    world.setMaterial(concrete, bodies.Material.presets.concrete);
    world.setMaterial(ballast, .{ .density = weight_kg / 64.0 });

    // Static scene: a wall on the left up to the beam, and a floor.
    const mw = 320;
    const mh = 256;
    const mask = try init.gpa.alloc(u8, mw * mh);
    defer init.gpa.free(mask);
    for (0..mh) |y| {
        for (0..mw) |x| {
            const wall = x < wall_x and y >= 60 and y < floor_y;
            mask[y * mw + x] = @intFromBool(wall or y >= floor_y);
        }
    }

    const beam = try world.createBeam(.{
        .x0 = wall_x,
        .y0 = 100,
        .x1 = wall_x + 120,
        .y1 = 100,
        .thickness = 4,
        .material = material,
        .segments = 12,
        .anchor_start = true,
    });
    var px: [8 * 8]u8 = undefined;
    @memset(&px, ballast);
    const load = try world.createPixelBody(.{ .pixels = &px, .w = 8, .h = 8, .x = wall_x + 120, .y = 100, .origin_x = 4, .origin_y = 4 });
    _ = try world.weld(load, world.beamSegments(beam)[11], wall_x + 120, 100);

    try out.print("beam: {s}, 120 x 4 px, 12 segments, load {d:.0} kg at the tip; torch cuts from {d:.1} s at {d:.0}% of the thickness per second\n", .{
        switch (material) {
            wood => "wood",
            concrete => "concrete",
            else => "steel",
        },
        weight_kg,
        cut_at,
        cut_rate * 100,
    });

    const ticks: usize = @intFromFloat(@round(seconds / bodies.tick_dt));
    const every_ticks: usize = @max(1, @as(usize, @intFromFloat(@round(every / bodies.tick_dt))));
    const cut_tick: usize = @intFromFloat(@round(cut_at / bodies.tick_dt));
    var max_impulse: f32 = 0;
    for (0..ticks + 1) |tick| {
        if (tick > 0) {
            try world.setStaticCollision(mask, mw, mh, 0, 0);
            if (cut_at > 0 and tick >= cut_tick) {
                const cut_s = @as(f32, @floatFromInt(tick - cut_tick)) * bodies.tick_dt;
                world.weakenBeamAt(beam, wall_x, 100, @max(0.05, 1 - cut_rate * cut_s));
                if (tick == cut_tick) try out.print("t={d:.2}s  torch starts cutting near the wall\n", .{@as(f32, @floatFromInt(tick)) * bodies.tick_dt});
            }
            world.step();
            for (world.jointBreaks()) |b| {
                try out.print("t={d:.2}s  joint {d} snapped at ({d:.0}, {d:.0}), moment {e:.2}\n", .{
                    @as(f32, @floatFromInt(tick)) * bodies.tick_dt, b.joint_index, b.x, b.y, b.moment,
                });
            }
            for (world.impacts()) |im| max_impulse = @max(max_impulse, im.normal_impulse);
        }
        if (tick % every_ticks == 0) {
            const t = @as(f32, @floatFromInt(tick)) * bodies.tick_dt;
            const tip = world.getCenterOfMass(load).?;
            const cut_left: f32 = if (cut_at > 0 and tick >= cut_tick) @max(0.05, 1 - cut_rate * @as(f32, @floatFromInt(tick - cut_tick)) * bodies.tick_dt) else 1;
            try out.print("\nt={d:.1}s  thickness at cut {d:.0}%  joints {d}/12  tip deflection {d:.1} px  root bend {d:.1} deg  max impact {d:.0} kg*px/s\n", .{
                t,
                cut_left * 100,
                world.beamJointCount(beam),
                tip.y - 100,
                std.math.radiansToDegrees(world.beamPlasticAngle(beam, 0)),
                max_impulse,
            });
            if (quiet) {
                for (0..13) |ji| {
                    const l = world.beamJointLoad(beam, ji).?;
                    const segs = world.beamSegments(beam);
                    const ra: f32 = if (ji == 0) 0 else world.getTransform(segs[ji - 1]).?.angle;
                    const rb: f32 = if (ji == 12) ra else world.getTransform(segs[ji]).?.angle;
                    try out.print("  rel={d:.2}deg", .{std.math.radiansToDegrees(rb - ra)});
                    try out.print("  j{d}: {s} M/My={d:.2} F/Ff={d:.2} plastic={d:.1}deg\n", .{ ji, if (l.alive) "ok " else "---", l.moment_ratio, l.force_ratio, std.math.radiansToDegrees(l.plastic_angle) });
                }
            } else try draw(out, &world, mask, mw);
        }
    }
    try out.flush();
}

fn draw(out: *std.Io.Writer, world: *bodies.BodyWorld, mask: []const u8, mw: usize) !void {
    var canvas: [rows][cols]u8 = undefined;
    for (0..rows) |r| {
        for (0..cols) |c| {
            const x = view_x0 + c * cell + cell / 2;
            const y = view_y0 + r * cell + cell / 2;
            canvas[r][c] = if (mask[y * mw + x] != 0) ':' else ' ';
        }
    }
    var it = world.rasterIterator();
    while (it.next()) |rb| {
        const ch: u8 = if (rb.beam != null) '#' else 'W';
        for (0..rb.h) |j| {
            for (0..rb.w) |i| {
                if (rb.pixels[j * rb.w + i] == 0) continue;
                const lx = @as(f32, @floatFromInt(i)) + 0.5 - rb.origin_x;
                const ly = @as(f32, @floatFromInt(j)) + 0.5 - rb.origin_y;
                const p = rb.transform.apply(lx, ly);
                const c = @floor((p.x - view_x0) / cell);
                const r = @floor((p.y - view_y0) / cell);
                if (c < 0 or r < 0 or c >= cols or r >= rows) continue;
                canvas[@intFromFloat(r)][@intFromFloat(c)] = ch;
            }
        }
    }
    for (canvas) |line| {
        var end: usize = cols;
        while (end > 0 and line[end - 1] == ' ') end -= 1;
        try out.print("  {s}\n", .{line[0..end]});
    }
}

/// Rubble pile on noisy terrain: 1024 × 512 mask, 300 bodies of 12 × 12 px
/// with holes, 10 s. Reports mean and worst CPU ms per tick for
/// `setStaticCollision` and `step`. Indicative only; run with ReleaseFast.
fn bench(init: std.process.Init, out: *std.Io.Writer) !void {
    const io = init.io;
    var world = try bodies.BodyWorld.init(init.gpa, .{ .static_max_w = 1024, .static_max_h = 512 });
    defer world.deinit();
    world.setMaterial(concrete, bodies.Material.presets.concrete);
    const mw = 1024;
    const mh = 512;
    const mask = try init.gpa.alloc(u8, mw * mh);
    defer init.gpa.free(mask);
    var prng = std.Random.DefaultPrng.init(7);
    const rnd = prng.random();
    for (0..mh) |y| {
        for (0..mw) |x| {
            const fx: f32 = @floatFromInt(x);
            const ground: f32 = 380 + 30 * @sin(fx * 0.02) + 10 * @sin(fx * 0.11);
            const fy: f32 = @floatFromInt(y);
            mask[y * mw + x] = @intFromBool(fy > ground or x < 8 or x >= mw - 8);
        }
    }
    var px: [12 * 12]u8 = undefined;
    for (0..300) |i| {
        for (&px) |*p| p.* = if (rnd.uintLessThan(u8, 100) < 85) concrete else 0;
        const fx: f32 = @floatFromInt(40 + (i % 60) * 15);
        const fy: f32 = @floatFromInt(40 + (i / 60) * 40);
        const h = world.createPixelBody(.{ .pixels = &px, .w = 12, .h = 12, .x = fx, .y = fy, .angle = rnd.float(f32) }) catch continue;
        // Holes can disconnect the bitmap; keep the pieces as separate bodies.
        _ = try world.splitBody(h, &px, 12, 12, 0, 0);
    }
    const ticks = 600;
    var static_ns: i96 = 0;
    var step_ns: i96 = 0;
    var static_max: i96 = 0;
    var step_max: i96 = 0;
    var rebuilt: u64 = 0;
    for (0..ticks) |tick| {
        // Dig a moving hole so some tiles change every tick.
        const hx = 100 + (tick * 3) % 800;
        for (390..400) |y| @memset(mask[y * mw + hx .. y * mw + hx + 4], 0);
        const t0 = std.Io.Timestamp.now(io, .awake);
        try world.setStaticCollision(mask, mw, mh, 0, 0);
        const t1 = std.Io.Timestamp.now(io, .awake);
        world.step();
        const t2 = std.Io.Timestamp.now(io, .awake);
        const ds = t0.durationTo(t1).nanoseconds;
        const dt = t1.durationTo(t2).nanoseconds;
        static_ns += ds;
        step_ns += dt;
        static_max = @max(static_max, ds);
        step_max = @max(step_max, dt);
        rebuilt += world.static_stats.tiles_rebuilt;
    }
    var awake: usize = 0;
    var it = world.rasterIterator();
    while (it.next()) |rb| awake += @intFromBool(rb.awake);
    const ms = 1e-6;
    try out.print("bench: {d} bodies ({d} awake at end), mask {d}x{d}, {d} ticks\n", .{ world.bodyCount(), awake, mw, mh, ticks });
    try out.print("  setStaticCollision: mean {d:.3} ms, max {d:.3} ms, {d:.1} tiles rebuilt per tick\n", .{
        @as(f64, @floatFromInt(static_ns)) * ms / ticks,
        @as(f64, @floatFromInt(static_max)) * ms,
        @as(f64, @floatFromInt(rebuilt)) / ticks,
    });
    try out.print("  step:               mean {d:.3} ms, max {d:.3} ms\n", .{
        @as(f64, @floatFromInt(step_ns)) * ms / ticks,
        @as(f64, @floatFromInt(step_max)) * ms,
    });
    try out.flush();
}
