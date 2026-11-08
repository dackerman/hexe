//! GPU material and reaction tables, packed from a loaded `MaterialSet`.
//!
//! Two buffers are uploaded:
//!
//! * the material table, 256 × `MaterialGpu` (176 B each, 45 056 B), indexed
//!   by the cell's material byte;
//! * the reaction table, 256 × 256 × `ReactionEntry` (8 B each, 512 KiB),
//!   indexed `[self][neighbor]`, flat index `self * 256 + neighbor`.
//!
//! Layout rules (both buffers): every scalar is a 32-bit or 8-bit unsigned
//! integer at its natural alignment, with no implicit padding, so the Zig
//! `extern struct` and the GLSL declaration agree byte for byte.
//!
//! `MaterialGpu` is std430- *and* std140-compatible: it contains only
//! `uint` scalars followed by a `uvec4[2]` at a 16-byte-aligned offset, and
//! its size is a multiple of 16, so the array stride is 176 under both
//! rules. Declare it with `glsl_material_struct` below.
//!
//! `ReactionEntry` is read in GLSL as one `uvec2` per entry from a std430
//! storage buffer (`uvec2 reactions[65536]`), bytes extracted with
//! `bitfieldExtract`; std140 would pad each `uvec2` to 16 bytes, so this
//! table is std430 only (or an `R32G32_UINT` 256 × 256 texture).
//!
//! Temperatures are bytes (`°C = 8·t − 40`, see temperature.zig). Material
//! references are ids. "No such rule" is encoded so that the rule cannot
//! fire: melt/boil/ignite at 255 (rules fire on `t > at`), freeze at 0
//! (fires on `t < at`), and the target is the material itself.

const std = @import("std");
const Allocator = std.mem.Allocator;
const materials = @import("materials.zig");
const temperature = @import("temperature.zig");
const MaterialSet = materials.MaterialSet;

/// Bits of `MaterialGpu.flags`.
pub const Flag = struct {
    /// Carries electricity (field propagation).
    pub const conductive: u32 = 1 << 0;
    /// Rendered with partial alpha; light passes.
    pub const translucent: u32 = 1 << 1;
    /// `emissive > 0`: adds light regardless of temperature.
    pub const emissive: u32 = 1 << 2;
    /// Liquid handled by the FLIP solver when awake (`solver = .flip`).
    pub const solver_flip: u32 = 1 << 3;
    /// Has a `flammable` rule.
    pub const flammable: u32 = 1 << 4;
    /// `lifetime > 0`: state byte counts down, then `decays_to`.
    pub const has_lifetime: u32 = 1 << 5;
    /// `health > 0`: state byte is health; damage and burning consume it.
    pub const has_health: u32 = 1 << 6;
    /// Puts out burning neighbors (water).
    pub const extinguisher: u32 = 1 << 7;
    /// Blocks light although not solid (smoke).
    pub const blocks_light: u32 = 1 << 8;
    /// Creation injects mass into the air field (steam).
    pub const feeds_air: u32 = 1 << 9;
    /// Connectivity anchor (bedrock).
    pub const anchor: u32 = 1 << 10;
    /// Ricochets hitting particles (steel, bedrock).
    pub const ricochet: u32 = 1 << 11;
    /// Has a temperature glow range.
    pub const glows: u32 = 1 << 12;
    /// Has a melt rule.
    pub const melts: u32 = 1 << 13;
    /// Has a freeze rule.
    pub const freezes: u32 = 1 << 14;
    /// Has a boil rule.
    pub const boils: u32 = 1 << 15;
    /// Appears in at least one reaction-table entry as self.
    pub const reactive: u32 = 1 << 16;
    /// No material has this id; the entry is the magenta placeholder.
    pub const missing: u32 = 1 << 31;
};

/// One material table entry. Offsets are asserted below and must match
/// `glsl_material_struct`.
pub const MaterialGpu = extern struct {
    /// `materials.Phase`: 0 static, 1 powder, 2 liquid, 3 gas.     @0
    phase: u32,
    /// Integer ordering; heavier displaces lighter. Air is 0.      @4
    density: u32,
    /// Liquid/gas sideways spread per substep, 0–8.                @8
    dispersion: u32,
    /// Powder diagonal-slide chance, 0–255.                        @12
    slide: u32,
    /// State byte written when a cell becomes this material:
    /// `health`, else `lifetime`, else 0.                          @16
    state_init: u32,
    /// Initial health, 0 = indestructible by damage.               @20
    health: u32,
    /// Initial lifetime count in state-byte units, 0 = never.      @24
    lifetime: u32,
    /// Ticks per lifetime decrement (≥ 1). Real lifetime in ticks
    /// is `lifetime * lifetime_period`.                            @28
    lifetime_period: u32,
    /// Material when the lifetime reaches 0.                       @32
    decays_to: u32,
    /// Spawn temperature byte.                                     @36
    temperature: u32,
    /// Heat diffusion rate, 0–255.                                 @40
    conductivity: u32,
    /// Temperature bytes added to neighbors per tick.              @44
    emits_heat: u32,
    /// Melts when `t > melt_at`; 255 = never.                      @48
    melt_at: u32,
    melt_to: u32, //                                                @52
    /// Freezes when `t < freeze_at`; 0 = never.                    @56
    freeze_at: u32,
    freeze_to: u32, //                                              @60
    /// Boils when `t > boil_at`; 255 = never. Wins over melt.      @64
    boil_at: u32,
    boil_to: u32, //                                                @68
    /// Ignites when `t > ignite_at`; 255 = not flammable.          @72
    ignite_at: u32,
    /// State byte set on ignition when the material has no health
    /// (with health, burning consumes health and this equals it).  @76
    burn_fuel: u32,
    /// Ticks per state decrement while burning (≥ 1).              @80
    burn_period: u32,
    /// Material when burning fuel reaches 0.                       @84
    burns_to: u32,
    /// Gas spawned while burning; 0 (air) = none.                  @88
    smoke: u32,
    /// Temperature bytes added to neighbors per tick while burning. @92
    burn_heat: u32,
    /// `materials.Event` appended on ignition, 0 = none.           @96
    burn_event: u32,
    /// `Flag` bits.                                                @100
    flags: u32,
    /// `materials.Impact`: 0 none, 1 splash, 2 spray, 3 chip, 4 dent,
    /// 5 ricochet.                                                 @104
    impact: u32,
    /// Pressure gradient that moves or breaks it; 0 = immune.      @108
    blast_threshold: u32,
    /// `materials.BlastResponse`: 0 fly, 1 chip, 2 break.          @112
    blast_response: u32,
    /// Material that chips and breakage land as (self if none).    @116
    rubble: u32,
    /// How strongly ballistic particles follow the air, 0–255.     @120
    drag: u32,
    /// Light emission, 0–255.                                      @124
    emissive: u32,
    /// Glow starts above this temperature byte (255 = never).      @128
    glow_from: u32,
    /// Glow reaches the hot end of the ramp at this byte.          @132
    glow_to: u32,
    /// Pressure that appends a `pressure` event; 0 = never.        @136
    pressure_event: u32,
    /// Number of authored ramp colors, 4–8; `ramp` repeats them
    /// cyclically to fill all 8 slots, so `ramp[variant & 7]` is
    /// valid as well as `ramp[variant % ramp_len]`.                @140
    ramp_len: u32,
    /// RGBA8 colors, R in the low byte (`unpackUnorm4x8` order).
    /// Alpha is 255, 160 for translucent materials, 0 for air.
    /// GLSL: `uvec4 ramp[2]`.                                      @144
    ramp: [8]u32,
};

comptime {
    std.debug.assert(@sizeOf(MaterialGpu) == 176);
    std.debug.assert(@offsetOf(MaterialGpu, "flags") == 100);
    std.debug.assert(@offsetOf(MaterialGpu, "ramp_len") == 140);
    std.debug.assert(@offsetOf(MaterialGpu, "ramp") == 144);
    std.debug.assert(@offsetOf(MaterialGpu, "ramp") % 16 == 0);
    std.debug.assert(@sizeOf(MaterialGpu) % 16 == 0);
}

/// GLSL mirror of `MaterialGpu`. A test checks it field by field against
/// the Zig struct.
pub const glsl_material_struct =
    \\struct MaterialGpu {
    \\    uint phase;
    \\    uint density;
    \\    uint dispersion;
    \\    uint slide;
    \\    uint state_init;
    \\    uint health;
    \\    uint lifetime;
    \\    uint lifetime_period;
    \\    uint decays_to;
    \\    uint temperature;
    \\    uint conductivity;
    \\    uint emits_heat;
    \\    uint melt_at;
    \\    uint melt_to;
    \\    uint freeze_at;
    \\    uint freeze_to;
    \\    uint boil_at;
    \\    uint boil_to;
    \\    uint ignite_at;
    \\    uint burn_fuel;
    \\    uint burn_period;
    \\    uint burns_to;
    \\    uint smoke;
    \\    uint burn_heat;
    \\    uint burn_event;
    \\    uint flags;
    \\    uint impact;
    \\    uint blast_threshold;
    \\    uint blast_response;
    \\    uint rubble;
    \\    uint drag;
    \\    uint emissive;
    \\    uint glow_from;
    \\    uint glow_to;
    \\    uint pressure_event;
    \\    uint ramp_len;
    \\    uvec4 ramp[2];
    \\};
    \\
;

/// Bits of `ReactionEntry.flags`.
pub const ReactionFlag = struct {
    /// `catalyst` must also be adjacent (otherwise `catalyst` is ignored,
    /// so air can be a catalyst).
    pub const has_catalyst: u8 = 1 << 0;
    /// Set on exactly one of the two mirrored entries of a pair (the one
    /// with `self <= neighbor` id). The cell evaluating that entry appends
    /// `event`; the mirrored cell does not, so one firing makes one event.
    pub const emits_event: u8 = 1 << 1;
};

/// One reaction table entry for the ordered pair (self, neighbor).
/// `chance == 0` means no reaction. Both cells of a pair see mirrored
/// entries with the same chance, temperature range, catalyst and event, so
/// a gather pass where each cell rewrites only itself stays consistent as
/// long as both cells derive their random number from the unordered pair.
///
/// GLSL (`uvec2 e`): self_result = e.x & 0xff, other_result = e.x >> 8 & 0xff,
/// chance = e.x >> 16 & 0xff, min_temp = e.x >> 24, max_temp = e.y & 0xff,
/// catalyst = e.y >> 8 & 0xff, event = e.y >> 16 & 0xff, flags = e.y >> 24.
pub const ReactionEntry = extern struct {
    /// What this cell becomes (its own id = unchanged, 0 = consumed). @0
    self_result: u8,
    /// What the neighbor becomes (its id = unchanged).                @1
    other_result: u8,
    /// Fires when `chance == 255 or hash8 < chance`; 0 = no reaction.  @2
    chance: u8,
    /// Inclusive bounds on the pair temperature byte
    /// `(t_self + t_neighbor) / 2`.                                     @3
    min_temp: u8,
    max_temp: u8, //                                                     @4
    /// Material that must also be adjacent (see `ReactionFlag`).       @5
    catalyst: u8,
    /// `materials.Event`, 0 = none.                                    @6
    event: u8,
    /// `ReactionFlag` bits.                                            @7
    flags: u8,

    pub const none: ReactionEntry = .{
        .self_result = 0,
        .other_result = 0,
        .chance = 0,
        .min_temp = 0,
        .max_temp = 255,
        .catalyst = 0,
        .event = 0,
        .flags = 0,
    };
};

comptime {
    std.debug.assert(@sizeOf(ReactionEntry) == 8);
    std.debug.assert(@offsetOf(ReactionEntry, "flags") == 7);
}

pub const reaction_table_len = materials.max_materials * materials.max_materials;

pub const Tables = struct {
    materials: [materials.max_materials]MaterialGpu,
    /// Flat `[self * 256 + neighbor]`.
    reactions: [reaction_table_len]ReactionEntry,

    pub fn reaction(self: *const Tables, self_id: u8, neighbor: u8) ReactionEntry {
        return self.reactions[@as(usize, self_id) * 256 + neighbor];
    }

    /// The material table as bytes, ready to upload (45 056 B).
    pub fn materialBytes(self: *const Tables) []const u8 {
        return std.mem.sliceAsBytes(&self.materials);
    }

    /// The reaction table as bytes, ready to upload (524 288 B).
    pub fn reactionBytes(self: *const Tables) []const u8 {
        return std.mem.sliceAsBytes(&self.reactions);
    }
};

/// Splits a duration in ticks into a state-byte count and a period so that
/// `count * period ≈ ticks` with `count ≤ 255`. The state byte is 8 bits but
/// lifetimes run to thousands of ticks (smoke: 1200), so the GPU decrements
/// the byte once every `period` ticks. Exact when `ticks ≤ 255` or divisible.
pub fn packTicks(ticks: u32) struct { count: u8, period: u32 } {
    if (ticks == 0) return .{ .count = 0, .period = 1 };
    const period = std.math.divCeil(u32, ticks, 255) catch unreachable;
    const count = std.math.divCeil(u32, ticks, period) catch unreachable;
    return .{ .count = @intCast(count), .period = period };
}

fn rgba(rgb: u32, alpha: u8) u32 {
    const r = rgb >> 16 & 0xff;
    const g = rgb >> 8 & 0xff;
    const b = rgb & 0xff;
    return r | g << 8 | b << 16 | @as(u32, alpha) << 24;
}

/// Alpha used for translucent materials.
pub const translucent_alpha: u8 = 160;

/// Placeholder for ids no material uses: inert, static, magenta/black, so a
/// cell left over after a hot reload removed its material is visible.
pub fn missingEntry(id: u8) MaterialGpu {
    var e = std.mem.zeroes(MaterialGpu);
    e.phase = @backingInt(materials.Phase.static);
    e.density = 65535;
    e.lifetime_period = 1;
    e.decays_to = id;
    e.temperature = temperature.toByte(20);
    e.melt_at = 255;
    e.melt_to = id;
    e.freeze_at = 0;
    e.freeze_to = id;
    e.boil_at = 255;
    e.boil_to = id;
    e.ignite_at = 255;
    e.burn_period = 1;
    e.burns_to = id;
    e.flags = Flag.missing;
    e.rubble = id;
    e.glow_from = 255;
    e.glow_to = 255;
    e.ramp_len = 2;
    for (&e.ramp, 0..) |*c, i| c.* = if (i % 2 == 0) rgba(0xff00ff, 255) else rgba(0x000000, 255);
    return e;
}

/// Packs one material.
pub fn packMaterial(set: *const MaterialSet, m: *const materials.Material) MaterialGpu {
    const d = m.def;
    const id = m.id;
    const toB = temperature.toByte;
    var flags: u32 = 0;
    if (d.conductive) flags |= Flag.conductive;
    if (d.translucent) flags |= Flag.translucent;
    if (d.emissive > 0) flags |= Flag.emissive;
    if (d.solver == .flip) flags |= Flag.solver_flip;
    if (d.flammable != null) flags |= Flag.flammable;
    if (d.lifetime > 0) flags |= Flag.has_lifetime;
    if (d.health > 0) flags |= Flag.has_health;
    if (d.extinguishes) flags |= Flag.extinguisher;
    if (d.blocks_light) flags |= Flag.blocks_light;
    if (d.feeds_air) flags |= Flag.feeds_air;
    if (d.anchor) flags |= Flag.anchor;
    if (d.ricochet or d.impact == .ricochet) flags |= Flag.ricochet;
    if (d.glow != null) flags |= Flag.glows;
    if (d.melt != null) flags |= Flag.melts;
    if (d.freeze != null) flags |= Flag.freezes;
    if (d.boil != null) flags |= Flag.boils;

    const life = packTicks(@intCast(d.lifetime));
    var e: MaterialGpu = .{
        .phase = @backingInt(d.phase),
        .density = @intCast(d.density),
        .dispersion = @intCast(d.dispersion),
        .slide = @intCast(d.slide),
        .state_init = if (d.health > 0) @intCast(d.health) else life.count,
        .health = @intCast(d.health),
        .lifetime = life.count,
        .lifetime_period = life.period,
        .decays_to = set.ref(d.decays_to, id),
        .temperature = toB(d.temperature),
        .conductivity = @intCast(d.conductivity),
        .emits_heat = temperature.deltaToBytes(d.emits_heat),
        .melt_at = if (d.melt) |pc| toB(pc.at) else 255,
        .melt_to = if (d.melt) |pc| set.ref(pc.to, id) else id,
        .freeze_at = if (d.freeze) |pc| toB(pc.at) else 0,
        .freeze_to = if (d.freeze) |pc| set.ref(pc.to, id) else id,
        .boil_at = if (d.boil) |pc| toB(pc.at) else 255,
        .boil_to = if (d.boil) |pc| set.ref(pc.to, id) else id,
        .ignite_at = 255,
        .burn_fuel = 0,
        .burn_period = 1,
        .burns_to = id,
        .smoke = materials.air_id,
        .burn_heat = 0,
        .burn_event = 0,
        .flags = flags,
        .impact = @backingInt(d.impact),
        .blast_threshold = @intCast(d.blast_threshold),
        .blast_response = @backingInt(d.blast_response),
        .rubble = set.ref(d.rubble, id),
        .drag = @intCast(d.drag),
        .emissive = @intCast(d.emissive),
        .glow_from = if (d.glow) |g| toB(g.from) else 255,
        .glow_to = if (d.glow) |g| toB(g.to) else 255,
        .pressure_event = @intCast(d.pressure_event),
        .ramp_len = @intCast(d.ramp.len),
        .ramp = undefined,
    };
    if (d.flammable) |fl| {
        e.ignite_at = toB(fl.ignite_at);
        const ticks: u32 = @intCast(fl.burn_ticks);
        if (d.health > 0) {
            e.burn_fuel = @intCast(d.health);
            e.burn_period = @max(1, (ticks + @as(u32, @intCast(d.health)) / 2) / @as(u32, @intCast(d.health)));
        } else {
            const p = packTicks(ticks);
            e.burn_fuel = p.count;
            e.burn_period = p.period;
        }
        e.burns_to = set.ref(fl.to, id);
        e.smoke = set.ref(fl.smoke, materials.air_id);
        e.burn_heat = temperature.deltaToBytes(fl.heat);
        e.burn_event = @backingInt(fl.event);
    }
    const alpha: u8 = if (id == materials.air_id) 0 else if (d.translucent) translucent_alpha else 255;
    for (&e.ramp, 0..) |*c, i| c.* = rgba(d.ramp[i % d.ramp.len], alpha);
    return e;
}

/// Builds both tables. The caller owns the result (`gpa.destroy`).
pub fn build(gpa: Allocator, set: *const MaterialSet) Allocator.Error!*Tables {
    const t = try gpa.create(Tables);
    for (&t.materials, 0..) |*e, id| e.* = missingEntry(@intCast(id));
    @memset(&t.reactions, ReactionEntry.none);

    for (set.materials) |*m| t.materials[m.id] = packMaterial(set, m);

    for (set.materials) |m| {
        for (m.def.reactions) |r| {
            const a = m.id;
            const b = set.idOf(r.with).?;
            const self_result = set.ref(r.self, a);
            const other_result = set.ref(r.other, b);
            var flags: u8 = 0;
            if (r.catalyst != null) flags |= ReactionFlag.has_catalyst;
            const base: ReactionEntry = .{
                .self_result = self_result,
                .other_result = other_result,
                .chance = @intCast(r.chance),
                .min_temp = if (r.min_temp) |c| temperature.toByte(c) else 0,
                .max_temp = if (r.max_temp) |c| temperature.toByte(c) else 255,
                .catalyst = set.ref(r.catalyst, materials.air_id),
                .event = @backingInt(r.event),
                .flags = flags,
            };
            var ab = base;
            var ba = base;
            ba.self_result = other_result;
            ba.other_result = self_result;
            if (a <= b) ab.flags |= ReactionFlag.emits_event;
            if (b <= a) ba.flags |= ReactionFlag.emits_event;
            t.reactions[@as(usize, a) * 256 + b] = ab;
            t.reactions[@as(usize, b) * 256 + a] = ba;
            t.materials[a].flags |= Flag.reactive;
            t.materials[b].flags |= Flag.reactive;
        }
    }
    return t;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;
const build_options = @import("build_options");

fn loadShipped() !MaterialSet {
    var diag: materials.Diagnostics = .init(testing.allocator);
    defer diag.deinit();
    return materials.loadDir(testing.io, testing.allocator, build_options.materials_dir, &diag) catch |err| {
        std.debug.print("{f}\n", .{diag});
        return err;
    };
}

test "MaterialGpu layout matches the GLSL declaration" {
    // Every field is a uint except the trailing uvec4[2] ramp; walk the GLSL
    // text and the Zig struct together.
    const info = @typeInfo(MaterialGpu).@"struct";
    var lines = std.mem.tokenizeScalar(u8, glsl_material_struct, '\n');
    _ = lines.next(); // struct MaterialGpu {
    var offset: usize = 0;
    inline for (info.field_names, info.field_types) |name, T| {
        const line = std.mem.trim(u8, lines.next().?, " ");
        if (T == u32) {
            try testing.expectEqualStrings("uint " ++ name ++ ";", line);
            try testing.expectEqual(offset, @offsetOf(MaterialGpu, name));
            offset += 4;
        } else {
            try testing.expectEqualStrings("uvec4 " ++ name ++ "[2];", line);
            offset = std.mem.alignForward(usize, offset, 16);
            try testing.expectEqual(offset, @offsetOf(MaterialGpu, name));
            offset += 32;
        }
    }
    try testing.expectEqualStrings("};", lines.next().?);
    try testing.expectEqual(@sizeOf(MaterialGpu), offset);
}

test "packTicks covers long lifetimes in one byte" {
    const cases = [_][3]u32{
        .{ 0, 0, 1 },     .{ 20, 20, 1 },   .{ 255, 255, 1 },  .{ 256, 128, 2 },
        .{ 300, 150, 2 }, .{ 600, 200, 3 }, .{ 1200, 240, 5 }, .{ 3600, 240, 15 },
    };
    for (cases) |c| {
        const p = packTicks(c[0]);
        try testing.expectEqual(@as(u8, @intCast(c[1])), p.count);
        try testing.expectEqual(c[2], p.period);
    }
    var ticks: u32 = 1;
    while (ticks < 65536) : (ticks += 97) {
        const p = packTicks(ticks);
        const real = @as(u32, p.count) * p.period;
        try testing.expect(real >= ticks and real - ticks < p.period);
    }
}

test "tables build from the shipped set" {
    var set = try loadShipped();
    defer set.deinit();
    const t = try build(testing.allocator, &set);
    defer testing.allocator.destroy(t);

    try testing.expectEqual(@as(usize, 256 * 176), t.materialBytes().len);
    try testing.expectEqual(@as(usize, 256 * 256 * 8), t.reactionBytes().len);

    const id = struct {
        fn of(s: *const MaterialSet, n: []const u8) u8 {
            return s.idOf(n).?;
        }
    }.of;
    const water = t.materials[id(&set, "water")];
    try testing.expectEqual(@as(u32, 2), water.phase);
    try testing.expectEqual(@as(u32, 100), water.density);
    try testing.expect(water.flags & Flag.solver_flip != 0);
    try testing.expect(water.flags & Flag.conductive != 0);
    try testing.expectEqual(@as(u32, id(&set, "steam")), water.boil_to);
    try testing.expectEqual(@as(u32, 18), water.boil_at);
    try testing.expectEqual(@as(u32, id(&set, "ice")), water.freeze_to);
    try testing.expectEqual(@as(u32, 5), water.freeze_at);
    try testing.expectEqual(@as(u32, 255), water.melt_at); // none
    // ramp: 5 colors repeated cyclically, translucent alpha, RGBA8 low-byte red.
    try testing.expectEqual(@as(u32, 5), water.ramp_len);
    try testing.expectEqual(@as(u32, 0x1a | 0x3a << 8 | 0x6b << 16 | 160 << 24), water.ramp[0]);
    try testing.expectEqual(water.ramp[0], water.ramp[5]);

    const smoke = t.materials[id(&set, "smoke")];
    try testing.expectEqual(@as(u32, 1200), smoke.lifetime * smoke.lifetime_period);
    try testing.expectEqual(smoke.lifetime, smoke.state_init);
    try testing.expectEqual(@as(u32, 0), smoke.decays_to);

    const wood = t.materials[id(&set, "wood")];
    try testing.expectEqual(@as(u32, 120), wood.state_init);
    try testing.expectEqual(@as(u32, 600), wood.burn_fuel * wood.burn_period);
    try testing.expectEqual(@as(u32, id(&set, "charcoal")), wood.burns_to);
    try testing.expectEqual(@as(u32, id(&set, "smoke")), wood.smoke);
    try testing.expectEqual(@as(u32, temperature.toByte(300)), wood.ignite_at);

    const gunpowder = t.materials[id(&set, "gunpowder")];
    try testing.expectEqual(@as(u32, @backingInt(materials.Event.explode)), gunpowder.burn_event);

    const stone = t.materials[id(&set, "stone")];
    try testing.expectEqual(@as(u32, id(&set, "gravel")), stone.rubble);
    try testing.expectEqual(@as(u32, id(&set, "lava")), stone.melt_to);

    const air = t.materials[0];
    try testing.expectEqual(@as(u32, 0), air.density);
    try testing.expectEqual(@as(u32, 0), air.ramp[0] >> 24);

    // Unused ids are the missing placeholder.
    try testing.expect(t.materials[255].flags & Flag.missing != 0);
    try testing.expect(t.materials[set.materials.len].flags & Flag.missing != 0);

    // Water + lava, declared in water.zon: water -> steam, lava -> stone.
    const wl = t.reaction(id(&set, "water"), id(&set, "lava"));
    try testing.expectEqual(id(&set, "steam"), wl.self_result);
    try testing.expectEqual(id(&set, "stone"), wl.other_result);
    try testing.expectEqual(@as(u8, 255), wl.chance);
    const lw = t.reaction(id(&set, "lava"), id(&set, "water"));
    try testing.expectEqual(id(&set, "stone"), lw.self_result);
    try testing.expectEqual(id(&set, "steam"), lw.other_result);

    // Sand + lava: sand -> molten glass, lava unchanged.
    const sl = t.reaction(id(&set, "sand"), id(&set, "lava"));
    try testing.expectEqual(id(&set, "molten_glass"), sl.self_result);
    try testing.expectEqual(id(&set, "lava"), sl.other_result);

    // Moss growth carries its catalyst.
    const ms = t.reaction(id(&set, "moss"), id(&set, "stone"));
    try testing.expectEqual(id(&set, "water"), ms.catalyst);
    try testing.expect(ms.flags & ReactionFlag.has_catalyst != 0);
    try testing.expectEqual(id(&set, "moss"), ms.other_result);

    // Steam condenses only on cold surfaces.
    const ss = t.reaction(id(&set, "steam"), id(&set, "stone"));
    try testing.expectEqual(temperature.toByte(60), ss.max_temp);

    // Unrelated pair: none.
    try testing.expectEqual(@as(u8, 0), t.reaction(id(&set, "sand"), id(&set, "dirt")).chance);
}

test "reaction table is symmetric" {
    var set = try loadShipped();
    defer set.deinit();
    const t = try build(testing.allocator, &set);
    defer testing.allocator.destroy(t);
    var entries: usize = 0;
    for (0..256) |a| for (0..256) |b| {
        const ab = t.reactions[a * 256 + b];
        const ba = t.reactions[b * 256 + a];
        try testing.expectEqual(ab.chance, ba.chance);
        if (ab.chance == 0) continue;
        entries += 1;
        try testing.expectEqual(ab.self_result, ba.other_result);
        try testing.expectEqual(ab.other_result, ba.self_result);
        try testing.expectEqual(ab.min_temp, ba.min_temp);
        try testing.expectEqual(ab.max_temp, ba.max_temp);
        try testing.expectEqual(ab.catalyst, ba.catalyst);
        try testing.expectEqual(ab.event, ba.event);
        try testing.expectEqual(ab.flags & ReactionFlag.has_catalyst, ba.flags & ReactionFlag.has_catalyst);
        // Exactly one side emits the event (both when a == b).
        const e1 = ab.flags & ReactionFlag.emits_event != 0;
        const e2 = ba.flags & ReactionFlag.emits_event != 0;
        try testing.expect(if (a == b) e1 and e2 else e1 != e2);
    };
    // Every declared reaction produced two entries (none are self-pairs).
    var declared: usize = 0;
    for (set.materials) |m| declared += m.def.reactions.len;
    try testing.expectEqual(declared * 2, entries);
}

test "symmetric expansion from either side gives the same table" {
    const ramp = ".ramp = .{ 1, 2, 3, 4 }";
    var diag: materials.Diagnostics = .init(testing.allocator);
    defer diag.deinit();
    var s1 = try materials.loadSources(testing.allocator, &.{
        .{ .path = "a.zon", .text = ".{ .name = \"a\", .density = 1, " ++ ramp ++ ", .reactions = .{ .{ .with = \"b\", .self = \"c\", .other = \"air\", .chance = 9, .min_temp = 100 } } }" },
        .{ .path = "b.zon", .text = ".{ .name = \"b\", .density = 1, " ++ ramp ++ " }" },
        .{ .path = "c.zon", .text = ".{ .name = \"c\", .density = 1, " ++ ramp ++ " }" },
    }, &diag);
    defer s1.deinit();
    var s2 = try materials.loadSources(testing.allocator, &.{
        .{ .path = "a.zon", .text = ".{ .name = \"a\", .density = 1, " ++ ramp ++ " }" },
        .{ .path = "b.zon", .text = ".{ .name = \"b\", .density = 1, " ++ ramp ++ ", .reactions = .{ .{ .with = \"a\", .self = \"air\", .other = \"c\", .chance = 9, .min_temp = 100 } } }" },
        .{ .path = "c.zon", .text = ".{ .name = \"c\", .density = 1, " ++ ramp ++ " }" },
    }, &diag);
    defer s2.deinit();
    const t1 = try build(testing.allocator, &s1);
    defer testing.allocator.destroy(t1);
    const t2 = try build(testing.allocator, &s2);
    defer testing.allocator.destroy(t2);
    try testing.expectEqualSlices(u8, t1.reactionBytes(), t2.reactionBytes());
    const ab = t1.reaction(1, 2);
    try testing.expectEqual(@as(u8, 3), ab.self_result);
    try testing.expectEqual(@as(u8, 0), ab.other_result);
    try testing.expectEqual(temperature.toByte(100), ab.min_temp);
    try testing.expectEqual(@as(u8, 255), ab.max_temp);
}
