//! `zig build worldgen -- --seed N --out preview.png [--cx X --cy Y --w W --h H] [--flat] [--scale S]`
//!
//! Generates a W×H chunk region (default 4×4 starting at chunk (-2, 0)) and
//! writes a colorized preview image. `.ppm` output is also supported.

const std = @import("std");
const world = @import("world");
const png = @import("png.zig");

const procgen = world.procgen;
const chunk = world.chunk;
const cell = world.cell;
const ids = procgen.test_ids;

const Rgb = [3]u8;

fn hex(v: u24) Rgb {
    return .{ @truncate(v >> 16), @truncate(v >> 8), @truncate(v) };
}

/// Hardcoded preview palette, indexed by procgen.test_ids.
fn colorOf(m: u8) Rgb {
    return switch (m) {
        ids.air => hex(0x101018),
        ids.stone => hex(0x6e6a66),
        ids.dirt => hex(0x6b4a2f),
        ids.sand => hex(0xc9b27a),
        ids.water => hex(0x2a66b5),
        ids.lava => hex(0xff6a1a),
        ids.wood => hex(0x8a5a2b),
        ids.concrete => hex(0x9a9a94),
        ids.steel => hex(0x5c7088),
        ids.bedrock => hex(0x2b2730),
        ids.oil => hex(0x3a2a4a),
        ids.gunpowder => hex(0xd23c3c),
        ids.moss => hex(0x4f8a3a),
        ids.gravel => hex(0x8c857c),
        else => hex(0xff00ff),
    };
}

fn shade(c: Rgb, variant: u4, sky: bool) Rgb {
    if (sky) return hex(0x8fb8de);
    const f: i32 = 88 + @as(i32, variant) * 2; // 88..118 %
    var out: Rgb = undefined;
    for (c, 0..) |v, k| out[k] = @intCast(std.math.clamp(@divTrunc(@as(i32, v) * f, 100), 0, 255));
    return out;
}

fn parseInt(comptime T: type, s: []const u8) !T {
    return std.fmt.parseInt(T, s, 10);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var seed: u64 = 1;
    var out_path: []const u8 = "preview.png";
    var cx0: i32 = -2;
    var cy0: i32 = 0;
    var cw: u32 = 4;
    var ch: u32 = 4;
    var flat = false;
    var scale: u32 = 1;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const next = if (i + 1 < args.len) args[i + 1] else "";
        if (std.mem.eql(u8, a, "--seed")) {
            seed = try parseInt(u64, next);
            i += 1;
        } else if (std.mem.eql(u8, a, "--out")) {
            out_path = next;
            i += 1;
        } else if (std.mem.eql(u8, a, "--cx")) {
            cx0 = try parseInt(i32, next);
            i += 1;
        } else if (std.mem.eql(u8, a, "--cy")) {
            cy0 = try parseInt(i32, next);
            i += 1;
        } else if (std.mem.eql(u8, a, "--w")) {
            cw = try parseInt(u32, next);
            i += 1;
        } else if (std.mem.eql(u8, a, "--h")) {
            ch = try parseInt(u32, next);
            i += 1;
        } else if (std.mem.eql(u8, a, "--scale")) {
            scale = @max(1, try parseInt(u32, next));
            i += 1;
        } else if (std.mem.eql(u8, a, "--flat")) {
            flat = true;
        } else {
            std.debug.print("unknown argument: {s}\n", .{a});
            return error.InvalidArgument;
        }
    }

    var gen = try procgen.Generator.init(gpa, seed, .{ .ids = ids });
    defer gen.deinit(gpa);
    const cells = try gpa.create(chunk.Cells);
    defer gpa.destroy(cells);

    const full_w = cw * chunk.size;
    const full_h = ch * chunk.size;
    const img_w = full_w / scale;
    const img_h = full_h / scale;
    const rgb = try gpa.alloc(u8, @as(usize, img_w) * img_h * 3);
    defer gpa.free(rgb);
    var counts: [256]u64 = @splat(0);

    const t0 = std.Io.Timestamp.now(io, .awake);
    for (0..ch) |ty| {
        for (0..cw) |tx| {
            const c: chunk.Coord = .{ .x = cx0 + @as(i32, @intCast(tx)), .y = cy0 + @as(i32, @intCast(ty)) };
            gen.generate(c, cells);
            for (0..chunk.size) |ly| {
                const py = ty * chunk.size + ly;
                if (py % scale != 0) continue;
                for (0..chunk.size) |lx| {
                    const px = tx * chunk.size + lx;
                    if (px % scale != 0) continue;
                    const v = cells[ly * chunk.size + lx];
                    const m = cell.material(v);
                    counts[m] += 1;
                    const wy = c.y * @as(i32, chunk.size) + @as(i32, @intCast(ly));
                    const sky = m == ids.air and wy < gen.surfaceAt(c.x * @as(i32, chunk.size) + @as(i32, @intCast(lx)));
                    const col = shade(colorOf(m), if (flat) 7 else cell.variant(v), sky);
                    const o = ((py / scale) * img_w + px / scale) * 3;
                    @memcpy(rgb[o..][0..3], &col);
                }
            }
        }
    }
    const t1 = std.Io.Timestamp.now(io, .awake);
    const ns: u64 = @intCast(t0.durationTo(t1).nanoseconds);

    var file = try std.Io.Dir.cwd().createFile(io, out_path, .{});
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var fw = file.writer(io, &buf);
    const w = &fw.interface;
    if (std.mem.endsWith(u8, out_path, ".ppm")) {
        try w.print("P6\n{d} {d}\n255\n", .{ img_w, img_h });
        try w.writeAll(rgb);
    } else {
        try png.encode(gpa, w, img_w, img_h, rgb);
    }
    try w.flush();

    std.debug.print("seed {d}: {d}x{d} chunks from ({d},{d}) in {d} ms ({d:.2} ms/chunk) -> {s}\n", .{
        seed, cw, ch, cx0, cy0, ns / std.time.ns_per_ms, @as(f64, @floatFromInt(ns)) / 1e6 / @as(f64, @floatFromInt(cw * ch)), out_path,
    });
    const names = [_][]const u8{ "air", "stone", "dirt", "sand", "water", "lava", "wood", "concrete", "steel", "bedrock", "oil", "gunpowder", "moss", "gravel" };
    var total: u64 = 0;
    for (counts) |n| total += n;
    for (names, 0..) |n, k| {
        if (counts[k] == 0) continue;
        std.debug.print("  {s:<10} {d:>6.2}%\n", .{ n, @as(f64, @floatFromInt(counts[k])) * 100.0 / @as(f64, @floatFromInt(total)) });
    }
}
