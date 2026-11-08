//! The renderer's material table (`RenderMaterial`, shaders/render/render.glsl),
//! derived on the CPU from the simulation's material table.
//!
//! Render shaders never read the sim layout (shaders/common.glsl
//! `MaterialGpu`, the data layer's 192-byte packing since the integration,
//! docs/decisions/110-integrate-material-layout.md): when it changes shape,
//! only `derive` changes.
//! Light absorption and visual translucency are not sim fields; they are
//! derived from phase and flags with per-name art overrides
//! (docs/decisions/101-render-materials.md).
const std = @import("std");
const sim_materials = @import("../sim/materials.zig");

pub const flag_translucent: u32 = 1;
pub const flag_emissive: u32 = 2;
pub const flag_glows: u32 = 4;
pub const flag_blocks_light: u32 = 8;
pub const flag_flicker: u32 = 16;
pub const flag_liquid: u32 = 32;
pub const flag_gas: u32 = 64;
pub const flag_air: u32 = 128;

pub const RenderMaterial = extern struct {
    ramp: [8]u32,
    /// ramp_len | phase << 8 | flags << 16
    info: u32,
    /// emissive | absorb << 8 | alpha << 16 | texture << 24
    light: u32,
    /// glow_from | glow_to << 8 | hot_index << 16
    glow: u32,
    pad: u32 = 0,
};

comptime {
    std.debug.assert(@sizeOf(RenderMaterial) == 48);
}

pub const Table = [sim_materials.count]RenderMaterial;

/// Art direction the sim schema does not carry: how much light a material
/// absorbs per pixel, how opaque it looks, flicker. Keyed by material name.
const Override = struct {
    name: []const u8,
    absorb: ?u8 = null,
    alpha: ?u8 = null,
    texture: ?u8 = null,
    flicker: bool = false,
    blocks_light: bool = false,
};

const overrides = [_]Override{
    .{ .name = "water", .absorb = 9, .alpha = 150, .texture = 0 },
    .{ .name = "glass", .absorb = 12, .alpha = 80, .texture = 10 },
    .{ .name = "ice", .absorb = 20, .alpha = 170, .texture = 10 },
    .{ .name = "steam", .absorb = 5, .alpha = 70 },
    .{ .name = "smoke", .absorb = 34, .alpha = 185, .blocks_light = true },
    .{ .name = "acid_gas", .absorb = 10, .alpha = 110 },
    .{ .name = "flame", .absorb = 60, .alpha = 225, .flicker = true },
    .{ .name = "lava", .absorb = 255, .alpha = 255, .texture = 0 },
    .{ .name = "oil", .absorb = 150, .alpha = 235 },
    .{ .name = "acid", .absorb = 30, .alpha = 170 },
};

fn findOverride(name: []const u8) ?Override {
    for (overrides) |o| if (std.mem.eql(u8, o.name, name)) return o;
    return null;
}

fn luma(rgba: u32) u32 {
    const r = rgba & 0xff;
    const g = (rgba >> 8) & 0xff;
    const b = (rgba >> 16) & 0xff;
    return 2 * r + 7 * g + b;
}

pub fn derive(name: []const u8, m: *const sim_materials.MaterialGpu) RenderMaterial {
    const phase: sim_materials.Phase = @fromBackingInt(@intCast(m.phase));
    const is_air = std.mem.eql(u8, name, "air");
    const translucent = m.flags & sim_materials.Flag.translucent != 0;
    var flags: u32 = 0;
    var absorb: u8 = 255;
    var alpha: u8 = 255;
    var texture: u8 = 0;
    switch (phase) {
        .static => {
            texture = 26;
            if (translucent) {
                absorb = 16;
                alpha = 110;
            }
        },
        .powder => texture = 10,
        .liquid => {
            flags |= flag_liquid;
            if (translucent) {
                absorb = 12;
                alpha = 150;
            } else absorb = 200;
        },
        .gas => {
            flags |= flag_gas;
            absorb = 6;
            alpha = if (translucent) 120 else 200;
        },
    }
    if (is_air) {
        flags |= flag_air;
        absorb = 0;
        alpha = 0;
    }
    var blocks = absorb >= 128 or m.flags & sim_materials.Flag.blocks_light != 0;
    if (findOverride(name)) |o| {
        if (o.absorb) |v| absorb = v;
        if (o.alpha) |v| alpha = v;
        if (o.texture) |v| texture = v;
        if (o.flicker) flags |= flag_flicker;
        blocks = blocks or o.blocks_light;
    }
    if (alpha < 255) flags |= flag_translucent;
    if (blocks) flags |= flag_blocks_light;
    if (m.emissive > 0) flags |= flag_emissive;
    const glows = m.glow_from < m.glow_to;
    if (glows) flags |= flag_glows;

    const len: u32 = std.math.clamp(m.ramp_len, 1, 8);
    var hot: u32 = 0;
    for (0..len) |i| {
        if (luma(m.ramp[i]) > luma(m.ramp[hot])) hot = @intCast(i);
    }
    var ramp: [8]u32 = undefined;
    for (&ramp, 0..) |*r, i| r.* = m.ramp[i % len];
    return .{
        .ramp = ramp,
        .info = len | ((m.phase & 0xff) << 8) | (flags << 16),
        .light = (m.emissive & 0xff) | (@as(u32, absorb) << 8) | (@as(u32, alpha) << 16) | (@as(u32, texture) << 24),
        .glow = @as(u32, if (glows) m.glow_from else 255) | (@as(u32, if (glows) m.glow_to else 255) << 8) | (hot << 16),
    };
}

/// Every id: named materials by name, unused ids from their (magenta)
/// placeholder entry.
pub fn build(out: *Table, lib: *const sim_materials.Library) void {
    for (out, 0..) |*r, i| r.* = derive(lib.name(@intCast(i)), &lib.tables.materials[i]);
}

test "derived render materials" {
    const gpa = std.testing.allocator;
    var diag: sim_materials.Diagnostics = .init(gpa);
    defer diag.deinit();
    var lib = try sim_materials.Library.loadDir(std.testing.io, gpa, sim_materials.default_dir, &diag);
    defer lib.deinit(gpa);
    var out: Table = undefined;
    build(&out, &lib);
    const stone = out[lib.id("stone").?];
    try std.testing.expect(stone.info >> 16 & flag_blocks_light != 0);
    try std.testing.expectEqual(@as(u32, 255), stone.light >> 16 & 0xff);
    const water = out[lib.id("water").?];
    try std.testing.expect(water.info >> 16 & flag_translucent != 0);
    try std.testing.expect(water.info >> 16 & flag_blocks_light == 0);
    const air = out[0];
    try std.testing.expectEqual(@as(u32, 0), air.light >> 8 & 0xffff);
    const lava = out[lib.id("lava").?];
    try std.testing.expect(lava.info >> 16 & flag_glows != 0);
    try std.testing.expect(lava.info >> 16 & flag_emissive != 0);
    const flame = out[lib.id("flame").?];
    try std.testing.expect(flame.info >> 16 & flag_flicker != 0);
    const smoke = out[lib.id("smoke").?];
    try std.testing.expect(smoke.info >> 16 & flag_blocks_light != 0);
}

test "render.glsl mirror" {
    const constants = @import("../gpu/constants.zig");
    const src = @embedFile("render_glsl");
    var defines: [64]constants.Define = undefined;
    const n = constants.parseDefines(src, &defines);
    const renderer = @import("renderer.zig");
    const sprites = @import("sprites.zig");
    const mirrors = .{
        .{ "RFLAG_TRANSLUCENT", flag_translucent },
        .{ "RFLAG_EMISSIVE", flag_emissive },
        .{ "RFLAG_GLOWS", flag_glows },
        .{ "RFLAG_BLOCKS_LIGHT", flag_blocks_light },
        .{ "RFLAG_FLICKER", flag_flicker },
        .{ "RFLAG_LIQUID", flag_liquid },
        .{ "RFLAG_GAS", flag_gas },
        .{ "RFLAG_AIR", flag_air },
        .{ "RENDER_MATERIAL_WORDS", @sizeOf(RenderMaterial) / 4 },
        .{ "RFRAME_LIGHT_MODE_MASK", renderer.frame_flag_light_mode_mask },
        .{ "LIGHT_MODE_CASCADES", @backingInt(renderer.LightMode.cascades) },
        .{ "LIGHT_MODE_SIMPLE", @backingInt(renderer.LightMode.simple) },
        .{ "LIGHT_MODE_OFF", @backingInt(renderer.LightMode.off) },
        .{ "RFRAME_BLOOM", renderer.frame_flag_bloom },
        .{ "RFRAME_VIGNETTE", renderer.frame_flag_vignette },
        .{ "RFRAME_SKY", renderer.frame_flag_sky },
        .{ "RFRAME_TEXTURE", renderer.frame_flag_texture },
        .{ "RFRAME_OVERLAY_ADDITIVE", renderer.frame_flag_overlay_additive },
        .{ "MAX_LIGHTS", renderer.max_lights },
        .{ "MAX_CASCADES", renderer.max_cascades },
        .{ "SCENE_MIPS", renderer.scene_mips },
        .{ "QUAD_SPRITE", sprites.kind_sprite },
        .{ "QUAD_RECT", sprites.kind_rect },
        .{ "QUAD_LINE", sprites.kind_line },
        .{ "QUAD_FLAG_FLIP_X", sprites.flag_flip_x },
        .{ "QUAD_FLAG_LIT", sprites.flag_lit },
        .{ "MAX_QUADS", sprites.max_quads },
    };
    for (defines[0..n]) |d| {
        var found = false;
        inline for (mirrors) |m| {
            if (std.mem.eql(u8, m[0], d.name)) {
                found = true;
                if (@as(u64, m[1]) != d.value) {
                    std.debug.print("render.glsl mirror mismatch: {s} = {d}, CPU {d}\n", .{ d.name, d.value, @as(u64, m[1]) });
                    return error.MirrorMismatch;
                }
            }
        }
        if (!found) {
            std.debug.print("render.glsl define {s} has no CPU mirror\n", .{d.name});
            return error.MirrorMissing;
        }
    }
    try std.testing.expectEqual(@as(usize, mirrors.len), n);
}
