//! Entity contact effects and status effects (docs/03-materials.md "Entity
//! contact effects", docs/decisions/123-gameplay-status-effects.md).
//!
//! Each tick an entity scans the cells of its box plus a one-pixel border
//! from the readback region around it (`Touch`) and `Status.apply` turns
//! that into damage and timers. The player and both enemy kinds share this
//! code. Pure CPU data: tested without a GPU.
const std = @import("std");
const data = @import("data");

pub const Contact = data.materials.Contact;

/// Per-material contact table, built once from the loaded library.
pub const ContactTable = struct {
    contact: [256]Contact = @splat(.{}),
    /// Phase per id (0 static, 1 powder, 2 liquid, 3 gas).
    phase: [256]u8 = @splat(3),
    flammable: [256]bool = @splat(false),
    flame: u8 = 0,
    smoke: u8 = 0,
    water: u8 = 0,

    pub fn build(set: *const data.materials.MaterialSet) ContactTable {
        var t: ContactTable = .{};
        t.phase[0] = 3;
        for (set.materials) |m| {
            t.contact[m.id] = m.def.on_contact;
            t.phase[m.id] = @backingInt(m.def.phase);
            t.flammable[m.id] = m.def.flammable != null;
        }
        t.flame = set.idOf("flame") orelse 0;
        t.smoke = set.idOf("smoke") orelse 0;
        t.water = set.idOf("water") orelse 0;
        return t;
    }
};

pub const phase_static = 0;
pub const phase_powder = 1;
pub const phase_liquid = 2;
pub const phase_gas = 3;

/// What an entity touches this tick (box plus a 1 px border).
pub const Touch = struct {
    /// Region data was available (else only the masks were used).
    known: bool = false,
    cells: u32 = 0,
    /// Liquid cells inside the box (mask), and the fraction.
    liquid: u32 = 0,
    liquid_fraction: f32 = 0,
    /// The head point is in a drowning liquid / in smoke.
    head_drown: bool = false,
    head_blind: bool = false,
    /// Strongest effects among touched materials, scaled by how many cells
    /// touch (a full effect from `full_cells` cells on).
    burn: f32 = 0,
    corrode: f32 = 0,
    slow: f32 = 0,
    ignite: bool = false,
    extinguish: bool = false,
    wet: bool = false,
    oily: bool = false,
    slippery: bool = false,
    bloody: bool = false,
    buoyant: bool = false,
    /// Charged conductive cells touched (electricity).
    charged: u32 = 0,
    /// Burning cells touched (fire spreads to entities).
    burning: u32 = 0,
};

/// Cells of a material that give its full contact effect.
pub const full_cells = 6;

/// Accumulates a `Touch` from cell lookups.
pub const TouchBuilder = struct {
    counts: [256]u16 = @splat(0),
    touch: Touch = .{},

    pub fn add(self: *TouchBuilder, material: u8, info: u8) void {
        self.counts[material] +|= 1;
        self.touch.cells += 1;
        if (info & 0x1 != 0) self.touch.charged += 1;
        if (info & 0x2 != 0) self.touch.burning += 1;
    }

    pub fn finish(self: *TouchBuilder, table: *const ContactTable) Touch {
        var t = self.touch;
        for (self.counts, 0..) |n, m| {
            if (n == 0 or m == 0) continue;
            const c = table.contact[m];
            const k: f32 = @min(1.0, @as(f32, @floatFromInt(n)) / full_cells);
            t.burn = @max(t.burn, c.burn * k);
            t.corrode = @max(t.corrode, c.corrode * k);
            t.slow = @max(t.slow, c.slow * k);
            if (n >= 2) {
                t.ignite = t.ignite or c.ignite;
                t.extinguish = t.extinguish or c.extinguish;
                t.wet = t.wet or c.wet;
                t.oily = t.oily or c.oily;
                t.slippery = t.slippery or c.slippery;
                t.bloody = t.bloody or c.bloody;
                t.buoyant = t.buoyant or c.buoyant;
            }
        }
        if (t.burning >= 3) t.ignite = true;
        return t;
    }
};

pub const Tuning = struct {
    max_health: f32 = 100,
    /// Seconds of breath (docs/03: drown after 5 s submerged).
    max_breath: f32 = 5,
    drown_dps: f32 = 15,
    burning_dps: f32 = 6,
    /// Seconds a fresh ignition burns; oily entities burn this times
    /// `oily_burn_factor`.
    burn_time: f32 = 4,
    oily_burn_factor: f32 = 2.5,
    wet_time: f32 = 3,
    oily_time: f32 = 12,
    bloody_time: f32 = 6,
    shock_damage: f32 = 20,
    /// Wet entities conduct: shock damage factor.
    wet_shock_factor: f32 = 2,
    shock_stun: f32 = 0.6,
    shock_cooldown: f32 = 0.15,
};

/// One struct of timers (seconds left, 0 = off).
pub const Status = struct {
    burning: f32 = 0,
    wet: f32 = 0,
    oily: f32 = 0,
    stunned: f32 = 0,
    bloody: f32 = 0,
    blind: f32 = 0,
    breath: f32 = 5,
    shock_cooldown: f32 = 0,
    /// Ticks until the next flame cells are spawned around a burning entity.
    flame_timer: u32 = 0,
    /// Damage per source this tick (HUD, logs).
    last_damage: f32 = 0,
    shocked: bool = false,

    pub fn isBurning(self: Status) bool {
        return self.burning > 0;
    }

    pub fn ignite(self: *Status, tun: Tuning) void {
        if (self.wet > 0) return;
        const t = if (self.oily > 0) tun.burn_time * tun.oily_burn_factor else tun.burn_time;
        self.burning = @max(self.burning, t);
    }

    pub fn extinguish(self: *Status, tun: Tuning) void {
        self.burning = 0;
        self.wet = tun.wet_time;
    }

    /// Advance timers and apply the contact effects of `t` over `dt`
    /// seconds. Returns the damage taken (hp).
    pub fn apply(self: *Status, t: Touch, dt: f32, tun: Tuning) f32 {
        var dmg: f32 = 0;
        self.shocked = false;
        // Water first: it puts fire out and wets.
        if (t.extinguish) self.extinguish(tun);
        if (t.wet) self.wet = @max(self.wet, tun.wet_time);
        if (t.oily) self.oily = @max(self.oily, tun.oily_time);
        if (t.bloody) self.bloody = @max(self.bloody, tun.bloody_time);
        // Heat dries.
        if (t.burn > 0) self.wet = @max(0, self.wet - dt * 4);
        if (t.ignite) self.ignite(tun);
        dmg += t.burn * dt + t.corrode * dt;
        // Burning: damage over time; oil keeps it going (the timer runs
        // at a fraction while oily).
        if (self.burning > 0) {
            dmg += tun.burning_dps * dt;
            self.burning = @max(0, self.burning - dt * (if (self.oily > 0) 1.0 / tun.oily_burn_factor else 1.0));
            if (self.burning == 0) self.oily = 0; // the oil burnt off
        }
        // Electricity: a charged conductive cell touching the entity.
        self.shock_cooldown = @max(0, self.shock_cooldown - dt);
        if (t.charged > 0 and self.shock_cooldown == 0) {
            dmg += tun.shock_damage * (if (self.wet > 0 or t.liquid_fraction > 0.2) tun.wet_shock_factor else 1.0);
            self.stunned = @max(self.stunned, tun.shock_stun);
            self.shock_cooldown = tun.shock_cooldown;
            self.shocked = true;
        }
        // Breath.
        if (t.head_drown) {
            self.breath = @max(0, self.breath - dt);
            if (self.breath == 0) dmg += tun.drown_dps * dt;
        } else self.breath = @min(tun.max_breath, self.breath + dt * 2);
        if (t.head_blind) self.blind = @max(self.blind, 0.5);
        // Timers.
        if (!t.wet) self.wet = @max(0, self.wet - dt);
        if (!t.oily) self.oily = @max(0, self.oily - dt * 0.25);
        self.stunned = @max(0, self.stunned - dt);
        self.bloody = @max(0, self.bloody - dt);
        self.blind = @max(0, self.blind - dt);
        self.last_damage = dmg;
        return dmg;
    }

    /// Short status names for the HUD, written into `buf`.
    pub fn describe(self: Status, buf: []u8) []const u8 {
        var w: std.Io.Writer = .fixed(buf);
        if (self.burning > 0) w.writeAll(" BURNING") catch {};
        if (self.wet > 0) w.writeAll(" WET") catch {};
        if (self.oily > 0) w.writeAll(" OILY") catch {};
        if (self.stunned > 0) w.writeAll(" STUNNED") catch {};
        if (self.blind > 0) w.writeAll(" BLIND") catch {};
        if (self.bloody > 0) w.writeAll(" BLOODY") catch {};
        return w.buffered();
    }
};

// ---------------------------------------------------------------- tests

fn testTable() ContactTable {
    var t: ContactTable = .{};
    t.contact[1] = .{ .burn = 40, .ignite = true }; // lava
    t.contact[2] = .{ .slow = 0.5, .drown = true, .buoyant = true, .extinguish = true, .wet = true }; // water
    t.contact[3] = .{ .oily = true, .slippery = true }; // oil
    t.contact[4] = .{ .corrode = 15 }; // acid
    return t;
}

fn touchOf(table: *const ContactTable, m: u8, n: u32, info: u8) Touch {
    var b: TouchBuilder = .{};
    for (0..n) |_| b.add(m, info);
    return b.finish(table);
}

test "lava burns, ignites, and the fire keeps burning after leaving it" {
    const table = testTable();
    var s: Status = .{};
    const tun: Tuning = .{};
    const lava = touchOf(&table, 1, 10, 0);
    const d = s.apply(lava, 1.0, tun);
    try std.testing.expect(s.burning > 0);
    try std.testing.expectApproxEqAbs(@as(f32, 40 + 6), d, 0.01);
    // Out of the lava: burning damage only, until the timer runs out.
    var total: f32 = 0;
    var ticks: u32 = 0;
    while (s.burning > 0 and ticks < 1000) : (ticks += 1) total += s.apply(.{}, 1.0 / 60.0, tun);
    try std.testing.expect(ticks >= 3 * 60 and ticks <= 5 * 60);
    try std.testing.expectApproxEqAbs(tun.burning_dps * @as(f32, @floatFromInt(ticks)) / 60.0, total, 0.5);
}

test "water extinguishes and wets; wet blocks ignition by flame" {
    const table = testTable();
    var s: Status = .{ .burning = 3 };
    const tun: Tuning = .{};
    _ = s.apply(touchOf(&table, 2, 10, 0), 1.0 / 60.0, tun);
    try std.testing.expectEqual(@as(f32, 0), s.burning);
    try std.testing.expect(s.wet > 0);
    s.ignite(tun);
    try std.testing.expectEqual(@as(f32, 0), s.burning);
    // Dries out after wet_time.
    for (0..@as(usize, @intFromFloat(tun.wet_time * 60)) + 2) |_| _ = s.apply(.{}, 1.0 / 60.0, tun);
    try std.testing.expectEqual(@as(f32, 0), s.wet);
    s.ignite(tun);
    try std.testing.expect(s.burning > 0);
}

test "oily entities burn longer" {
    const table = testTable();
    const tun: Tuning = .{};
    var dry: Status = .{};
    var oily: Status = .{};
    _ = oily.apply(touchOf(&table, 3, 10, 0), 1.0 / 60.0, tun);
    try std.testing.expect(oily.oily > 0);
    dry.ignite(tun);
    oily.ignite(tun);
    var t_dry: u32 = 0;
    var t_oily: u32 = 0;
    while (dry.burning > 0) : (t_dry += 1) _ = dry.apply(.{}, 1.0 / 60.0, tun);
    while (oily.burning > 0) : (t_oily += 1) _ = oily.apply(.{}, 1.0 / 60.0, tun);
    try std.testing.expect(t_oily > t_dry * 4);
}

test "drowning starts after five seconds under water" {
    const tun: Tuning = .{};
    var s: Status = .{};
    const under: Touch = .{ .head_drown = true };
    var dmg_before: f32 = 0;
    for (0..299) |_| dmg_before += s.apply(under, 1.0 / 60.0, tun);
    try std.testing.expectEqual(@as(f32, 0), dmg_before);
    var dmg_after: f32 = 0;
    for (0..60) |_| dmg_after += s.apply(under, 1.0 / 60.0, tun);
    try std.testing.expect(dmg_after > 10 and dmg_after < 20);
    // Surfacing refills the breath.
    for (0..180) |_| _ = s.apply(.{}, 1.0 / 60.0, tun);
    try std.testing.expectEqual(tun.max_breath, s.breath);
}

test "shocks stun, respect the cooldown, and hurt more when wet" {
    const table = testTable();
    const tun: Tuning = .{};
    var s: Status = .{};
    const zap = touchOf(&table, 5, 3, 0x1);
    const d1 = s.apply(zap, 1.0 / 60.0, tun);
    try std.testing.expectEqual(tun.shock_damage, d1);
    try std.testing.expect(s.stunned > 0);
    // Cooldown: the next tick does not shock again.
    try std.testing.expectEqual(@as(f32, 0), s.apply(zap, 1.0 / 60.0, tun));
    var wet: Status = .{ .wet = 2 };
    try std.testing.expectEqual(tun.shock_damage * tun.wet_shock_factor, wet.apply(zap, 1.0 / 60.0, tun));
    // Stun wears off.
    for (0..60) |_| _ = s.apply(.{}, 1.0 / 60.0, tun);
    try std.testing.expectEqual(@as(f32, 0), s.stunned);
}

test "contact effects scale with the number of cells touched" {
    const table = testTable();
    const one = touchOf(&table, 4, 1, 0);
    const many = touchOf(&table, 4, 20, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 15.0) / @as(f32, full_cells), one.corrode, 0.001);
    try std.testing.expectEqual(@as(f32, 15), many.corrode);
}
