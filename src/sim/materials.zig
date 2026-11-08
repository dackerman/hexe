//! Material table: the GPU layout (`MaterialGpu`), the loader-facing
//! description in real units (`MaterialDesc`), and `pack` between them.
//!
//! A data loader (src/data/, ZON files) fills `MaterialDesc` values with
//! names already resolved to ids, calls `Table.add` for each, and hands the
//! table to `Grid.uploadMaterials`. Derived fields (sort key, default
//! vertical chance, temperature bytes, packed colors) are computed by `pack`
//! so the loader never has to know the GPU encoding.
//!
//! GPU layout: 128 bytes (32 words) per material, std430, little endian,
//! documented word by word in shaders/common.glsl next to `struct
//! MaterialGpu`. Temperatures are stored as temperature bytes
//! (degrees C = 8*t - 40); material references are ids where `none` (255)
//! means "no transition"; colors are RGBA8 with R in the low byte.
const std = @import("std");
const cell = @import("cell.zig");

pub const count = 256;
/// "No material" in transition fields. Id 255 is reserved for it.
pub const none: u8 = 255;
pub const air: u8 = 0;
pub const ramp_max = 8;

pub const Phase = enum(u8) { static = 0, powder = 1, liquid = 2, gas = 3 };
pub const Solver = enum(u8) { cellular = 0, flip = 1 };
pub const Impact = enum(u8) { none = 0, splash, spray, chip, dent, ricochet };
pub const BlastResponse = enum(u8) { none = 0, fly, chip, @"break" };

pub const flag_conductive: u32 = 0x1;
pub const flag_translucent: u32 = 0x2;
pub const flag_flammable: u32 = 0x4;
pub const flag_emissive: u32 = 0x8;

/// Movement ordering (see `sortKey`).
pub const sort_key_air: u16 = 256;
pub const sort_key_dense_base: u16 = 512;
pub const sort_key_static: u16 = 65535;

pub const MaterialGpu = extern struct {
    // w0: move
    phase: u8,
    dispersion: u8,
    slide: u8,
    vertical_chance: u8,
    // w1: density
    density: u16,
    sort_key: u16,
    // w2
    flags: u32,
    // w3: misc0
    solver: u8,
    health: u8,
    conductivity: u8,
    emissive: u8,
    // w4: misc1
    lifetime: u16,
    decays_to: u8,
    initial_state: u8,
    // w5: misc2
    spawn_temp: u8,
    emits_heat: u8,
    impact: u8,
    blast_response: u8,
    // w6: misc3
    blast_threshold: u16,
    drag: u8,
    ramp_len: u8,
    // w7: change0
    melt_at: u8,
    melt_to: u8,
    freeze_at: u8,
    freeze_to: u8,
    // w8: change1
    boil_at: u8,
    boil_to: u8,
    ignite_at: u8,
    burn_to: u8,
    // w9: burn
    burn_ticks: u16,
    smoke_to: u8,
    glow_from: u8,
    // w10: glow
    glow_to: u8,
    reserved10: [3]u8 = @splat(0),
    // w11-15
    reserved0: [5]u32 = @splat(0),
    // w16-23
    ramp: [ramp_max]u32,
    // w24-31
    reserved1: [8]u32 = @splat(0),

    /// Placeholder for unused ids: static, never moves, magenta.
    pub const unused: MaterialGpu = pack(.{ .name = "", .phase = .static, .ramp = &.{0xff00ff} });

    pub inline fn moveWord(self: *const MaterialGpu) u32 {
        return @as(u32, self.phase) | (@as(u32, self.dispersion) << 8) | (@as(u32, self.slide) << 16) | (@as(u32, self.vertical_chance) << 24);
    }
};

comptime {
    std.debug.assert(@sizeOf(MaterialGpu) == 128);
    const words = .{
        .{ "phase", 0 },    .{ "density", 1 },    .{ "flags", 2 },           .{ "solver", 3 },
        .{ "lifetime", 4 }, .{ "spawn_temp", 5 }, .{ "blast_threshold", 6 }, .{ "melt_at", 7 },
        .{ "boil_at", 8 },  .{ "burn_ticks", 9 }, .{ "glow_to", 10 },        .{ "reserved0", 11 },
        .{ "ramp", 16 },    .{ "reserved1", 24 },
    };
    for (words) |w| std.debug.assert(@offsetOf(MaterialGpu, w[0]) == w[1] * 4);
}

pub const Transition = struct {
    /// Degrees C.
    at: i32,
    to: u8,
};

pub const Flammable = struct {
    ignite_at: i32,
    burn_ticks: u16,
    to: u8,
    smoke: u8 = none,
};

pub const Glow = struct { from: i32, to: i32 };

/// One material in real units, mirroring the ZON schema in
/// docs/03-materials.md (CPU-only fields such as on_contact and reactions
/// live elsewhere). Material references are already-resolved ids.
pub const MaterialDesc = struct {
    name: []const u8,
    phase: Phase,
    solver: Solver = .cellular,
    density: u16 = 0,
    /// 0-8 sideways cells per substep worth of spread chance (liquids, gases).
    dispersion: u8 = 0,
    /// 0-255 powder diagonal slide chance per substep.
    slide: u8 = 0,
    /// 0-255 chance per substep to move vertically; null derives it from
    /// phase and density (`defaultVerticalChance`).
    vertical_chance: ?u8 = null,
    health: u8 = 0,
    lifetime: u16 = 0,
    decays_to: u8 = none,
    /// Spawn temperature, degrees C.
    temperature: i32 = 20,
    conductivity: u8 = 40,
    emits_heat: u8 = 0,
    melt: ?Transition = null,
    freeze: ?Transition = null,
    boil: ?Transition = null,
    flammable: ?Flammable = null,
    conductive: bool = false,
    impact: Impact = .none,
    blast_threshold: u16 = 0,
    blast_response: BlastResponse = .none,
    drag: u8 = 0,
    emissive: u8 = 0,
    glow: ?Glow = null,
    translucent: bool = false,
    /// 1-8 colors as 0xRRGGBB (the schema allows 4-8; air uses 1).
    ramp: []const u32,
};

/// Movement ordering key. A cell sinks into a fluid cell below it with a
/// strictly lower key: gases order by density below air, so they rise; every
/// liquid and powder outranks air and orders by density among themselves.
pub fn sortKey(phase: Phase, density: u16, is_air: bool) u16 {
    if (is_air) return sort_key_air;
    return switch (phase) {
        .static => sort_key_static,
        .gas => @min(density, sort_key_air - 1),
        .powder, .liquid => @min(@as(u32, sort_key_dense_base) + density, sort_key_static - 1),
    };
}

/// Powders and liquids fall every substep they can; gases rise with a chance
/// that drops with density (smoke, density 8: 64/256).
pub fn defaultVerticalChance(phase: Phase, density: u16) u8 {
    return switch (phase) {
        .static => 0,
        .powder, .liquid => 255,
        .gas => @intCast(std.math.clamp(160 - 12 * @as(i32, density), 24, 200)),
    };
}

/// 0xRRGGBB -> RGBA8 with R in the low byte, alpha 255.
pub fn rgba8(rgb: u32) u32 {
    const r = (rgb >> 16) & 0xff;
    const g = (rgb >> 8) & 0xff;
    const b = rgb & 0xff;
    return r | (g << 8) | (b << 16) | (0xff << 24);
}

fn tempByte(celsius: i32) u8 {
    return @intCast(cell.celsiusToTemp(celsius));
}

pub fn pack(d: MaterialDesc) MaterialGpu {
    std.debug.assert(d.ramp.len >= 1 and d.ramp.len <= ramp_max);
    var ramp: [ramp_max]u32 = @splat(0);
    for (d.ramp, 0..) |c, i| ramp[i] = rgba8(c);
    var flags: u32 = 0;
    if (d.conductive) flags |= flag_conductive;
    if (d.translucent) flags |= flag_translucent;
    if (d.flammable != null) flags |= flag_flammable;
    if (d.emissive > 0) flags |= flag_emissive;
    const is_air = std.mem.eql(u8, d.name, "air");
    return .{
        .phase = @backingInt(d.phase),
        .dispersion = d.dispersion,
        .slide = d.slide,
        .vertical_chance = d.vertical_chance orelse defaultVerticalChance(d.phase, d.density),
        .density = d.density,
        .sort_key = sortKey(d.phase, d.density, is_air),
        .flags = flags,
        .solver = @backingInt(d.solver),
        .health = d.health,
        .conductivity = d.conductivity,
        .emissive = d.emissive,
        .lifetime = d.lifetime,
        .decays_to = d.decays_to,
        // State byte at spawn: health for damageable materials, else the
        // lifetime clamped to a byte. Reactions (M3) own its meaning.
        .initial_state = if (d.health > 0) d.health else @intCast(@min(d.lifetime, 255)),
        .spawn_temp = tempByte(d.temperature),
        .emits_heat = d.emits_heat,
        .impact = @backingInt(d.impact),
        .blast_response = @backingInt(d.blast_response),
        .blast_threshold = d.blast_threshold,
        .drag = d.drag,
        .ramp_len = @intCast(d.ramp.len),
        .melt_at = if (d.melt) |t| tempByte(t.at) else 255,
        .melt_to = if (d.melt) |t| t.to else none,
        .freeze_at = if (d.freeze) |t| tempByte(t.at) else 0,
        .freeze_to = if (d.freeze) |t| t.to else none,
        .boil_at = if (d.boil) |t| tempByte(t.at) else 255,
        .boil_to = if (d.boil) |t| t.to else none,
        .ignite_at = if (d.flammable) |f| tempByte(f.ignite_at) else 255,
        .burn_to = if (d.flammable) |f| f.to else none,
        .burn_ticks = if (d.flammable) |f| f.burn_ticks else 0,
        .smoke_to = if (d.flammable) |f| f.smoke else none,
        .glow_from = if (d.glow) |g| tempByte(g.from) else 255,
        .glow_to = if (d.glow) |g| tempByte(g.to) else 255,
        .ramp = ramp,
    };
}

/// The material table as uploaded to the GPU, plus CPU-side names.
pub const Table = struct {
    gpu: [count]MaterialGpu = @splat(MaterialGpu.unused),
    names: [count][]const u8 = @splat(""),
    len: u32 = 0,

    /// Append a material; ids are assigned in order, starting with air = 0.
    pub fn add(self: *Table, d: MaterialDesc) !u8 {
        if (self.len >= none) return error.TooManyMaterials;
        if (self.len == 0 and !std.mem.eql(u8, d.name, "air")) return error.AirMustBeFirst;
        const id: u8 = @intCast(self.len);
        self.gpu[id] = pack(d);
        self.names[id] = d.name;
        self.len += 1;
        return id;
    }

    pub fn byName(self: *const Table, name: []const u8) ?u8 {
        for (self.names[0..self.len], 0..) |n, i| {
            if (std.mem.eql(u8, n, name)) return @intCast(i);
        }
        return null;
    }
};

test "sort key ordering" {
    const smoke = sortKey(.gas, 8, false);
    const steam = sortKey(.gas, 5, false);
    const air_key = sortKey(.gas, 0, true);
    const water = sortKey(.liquid, 100, false);
    const oil = sortKey(.liquid, 80, false);
    const sand = sortKey(.powder, 150, false);
    const ash = sortKey(.powder, 30, false);
    try std.testing.expect(steam < smoke and smoke < air_key); // gases rise through air
    try std.testing.expect(air_key < oil and oil < water and water < sand); // oil floats, sand sinks
    try std.testing.expect(ash < water); // ash floats on water
    try std.testing.expect(sortKey(.static, 300, false) == sort_key_static);
}

test "pack layout" {
    const m = pack(.{
        .name = "x",
        .phase = .liquid,
        .density = 100,
        .dispersion = 5,
        .temperature = 20,
        .boil = .{ .at = 100, .to = 7 },
        .ramp = &.{ 0x112233, 0x445566 },
    });
    const words: *const [32]u32 = @ptrCast(&m);
    try std.testing.expectEqual(@as(u32, 2 | (5 << 8) | (255 << 24)), words[0]);
    try std.testing.expectEqual(@as(u32, 100 | ((512 + 100) << 16)), words[1]);
    try std.testing.expectEqual(@as(u32, 0xff332211), words[16]);
    try std.testing.expectEqual(@as(u32, 2), words[6] >> 24); // ramp_len
    try std.testing.expectEqual(@as(u32, 7), words[5] & 0xff); // spawn temp byte of 20 C
    try std.testing.expectEqual(@as(u32, 7), (words[8] >> 8) & 0xff); // boil_to
    try std.testing.expectEqual(m.moveWord(), words[0]);
}
