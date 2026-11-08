//! What gameplay code sees of the engine during one tick (`Ctx`), the
//! collision view an entity moves against (`EntityWorld`) and the state and
//! per-tick steps every character shares (`Actor`): readback requests,
//! contact scan, status effects, burning, blast knockback.
const std = @import("std");
const cell = @import("../sim/cell.zig");
const commands = @import("../sim/commands.zig");
const readback = @import("../sim/readback.zig");
const air_mod = @import("../sim/air.zig");
const BodySim = @import("../sim/bodies_sim.zig").BodySim;
const physics = @import("physics.zig");
const status = @import("status.zig");
const explode_mod = @import("explode.zig");

pub const dt: f32 = 1.0 / 60.0;

/// Material ids gameplay paints with (air when missing from the set).
pub const Ids = struct {
    air: u8 = 0,
    water: u8 = 0,
    lava: u8 = 0,
    acid: u8 = 0,
    dirt: u8 = 0,
    flame: u8 = 0,
    steam: u8 = 0,
    smoke: u8 = 0,
    flesh: u8 = 0,
    bone: u8 = 0,
    blood: u8 = 0,
    gunpowder: u8 = 0,
    wood: u8 = 0,
    steel: u8 = 0,
    stone: u8 = 0,

    pub fn resolve(lookup: anytype) Ids {
        var r: Ids = .{};
        inline for (@typeInfo(Ids).@"struct".field_names) |f| {
            if (comptime std.mem.eql(u8, f, "air")) continue;
            @field(r, f) = lookup.idOf(f) orelse 0;
        }
        return r;
    }
};

/// A blast gameplay knows about this tick (its own `explode` calls and
/// the gunpowder events), for the direct knockback.
pub const Blast = struct { x: f32, y: f32, radius: f32, strength: f32 };

/// Things that happened, for the HUD and the playtest log.
pub const Log = struct {
    lines: [32][96]u8 = undefined,
    lens: [32]u8 = @splat(0),
    count: u32 = 0,
    /// Print each line to stderr as it is added (playtests).
    echo: bool = false,
    tick: u32 = 0,

    pub fn add(self: *Log, comptime fmt: []const u8, args: anytype) void {
        const i = self.count % self.lines.len;
        const s = std.fmt.bufPrint(&self.lines[i], fmt, args) catch self.lines[i][0..];
        self.lens[i] = @intCast(s.len);
        self.count += 1;
        if (self.echo) std.debug.print("  [tick {d}] {s}\n", .{ self.tick, s });
    }

    /// The newest `n` lines, oldest first.
    pub fn recent(self: *const Log, n: u32, k: u32) ?[]const u8 {
        const have = @min(self.count, @as(u32, self.lines.len));
        const m = @min(n, have);
        if (k >= m) return null;
        const i = (self.count - m + k) % self.lines.len;
        return self.lines[i][0..self.lens[i]];
    }
};

pub const Ctx = struct {
    mirror: *const readback.Mirror,
    table: *const status.ContactTable,
    list: *commands.CommandList,
    bodies: ?*BodySim,
    air: ?*air_mod.Air,
    liquid_on: bool,
    ids: *const Ids,
    rng: std.Random,
    tick: u32,
    log: *Log,
    blasts: []const Blast,

    pub fn explodeOpts(self: *const Ctx) explode_mod.Options {
        return .{ .air = self.air != null, .liquid = self.liquid_on };
    }

    /// Solid for things without a readback region (rays, AI sight).
    pub fn solid(self: *const Ctx, x: i32, y: i32) bool {
        return self.mirror.isSolid(x, y);
    }
};

/// The solid cells an entity collides with: static and body cells from the
/// mirror's mask, plus powders from the entity's readback region (the mask
/// leaves powders out, but a witch stands on a sand dune).
pub const EntityWorld = struct {
    mirror: *const readback.Mirror,
    view: ?readback.RegionView,
    phase: *const [256]u8,
    /// Rows ignored (dropping through a thin platform).
    ignore_y0: i32 = std.math.maxInt(i32),
    ignore_y1: i32 = std.math.minInt(i32),

    pub fn solid(self: *const EntityWorld, x: i32, y: i32) bool {
        if (y >= self.ignore_y0 and y <= self.ignore_y1) return false;
        if (self.mirror.isSolid(x, y)) return true;
        if (self.view) |*v| if (v.material(x, y)) |m| return self.phase[m] == status.phase_powder;
        return false;
    }
};

/// Margin of the readback region requested around an entity's box.
pub const region_margin = 20;

/// State every character has.
pub const Actor = struct {
    body: physics.Body,
    health: f32,
    max_health: f32,
    status: status.Status = .{},
    tuning: status.Tuning = .{},
    touch: status.Touch = .{},
    facing: f32 = 1,
    alive: bool = true,
    /// Fraction of the box in liquid (mask).
    liquid: f32 = 0,
    /// Knockback per unit blast; light entities fly farther.
    blast_factor: f32 = 1,
    /// Air sample points of the last requests (results arrive a frame or
    /// two later, for the point asked then).
    air_points: [4][2]i32 = @splat(.{ std.math.minInt(i32), 0 }),
    air_next: u32 = 0,
    /// Last air sample tick applied.
    air_tick: u32 = 0,
    /// Damage taken in the last tick (flash).
    hurt_flash: f32 = 0,
    /// Embedded and could not be pushed out (buried).
    stuck: bool = false,
    /// Overpressure of the last air sample (blast fronts are rises).
    air_op: f32 = 0,
    /// Seconds of reduced control after a blast knock.
    knock: f32 = 0,

    pub fn cx(self: *const Actor) f32 {
        return self.body.centerX();
    }
    pub fn cy(self: *const Actor) f32 {
        return self.body.centerY();
    }

    pub fn world(self: *const Actor, ctx: *const Ctx) EntityWorld {
        const b = self.body;
        return .{
            .mirror = ctx.mirror,
            .view = ctx.mirror.regionView(b.x - region_margin + 2, b.y - region_margin + 2, @intCast(b.w + 2 * region_margin - 4), @intCast(b.h + 2 * region_margin - 4)) orelse
                ctx.mirror.regionView(b.x - 1, b.y - 1, @intCast(b.w + 2), @intCast(b.h + 2)),
            .phase = &ctx.table.phase,
        };
    }

    /// Ask for the region around the box and the air at its center in the
    /// next recorded frame.
    pub fn requestReadback(self: *Actor, mirror: *readback.Mirror, air: ?*air_mod.Air) void {
        const b = self.body;
        mirror.requestRegion(b.x - region_margin, b.y - region_margin, @intCast(b.w + 2 * region_margin), @intCast(b.h + 2 * region_margin)) catch {};
        if (air) |a| {
            const p = [2]i32{ b.x + @divTrunc(b.w, 2), b.y + @divTrunc(b.h, 2) };
            if (a.requestSample(p[0], p[1]) != null) {
                self.air_points[self.air_next % self.air_points.len] = p;
                self.air_next +%= 1;
            }
        }
    }

    /// Cells of the box plus a 1 px border: contact materials, charge,
    /// burning cells, liquid fraction, head point.
    pub fn scan(self: *Actor, ctx: *const Ctx, w: *const EntityWorld) void {
        const b = self.body;
        var builder: status.TouchBuilder = .{};
        var liquid: u32 = 0;
        var y: i32 = b.y - 1;
        while (y <= b.y + b.h) : (y += 1) {
            var x: i32 = b.x - 1;
            while (x <= b.x + b.w) : (x += 1) {
                const inside = x >= b.x and x < b.x + b.w and y >= b.y and y < b.y + b.h;
                if (inside and ctx.mirror.isLiquid(x, y)) liquid += 1;
                if (w.view) |*v| {
                    const m = v.material(x, y) orelse continue;
                    builder.add(m, v.info(x, y) orelse 0);
                }
            }
        }
        var t = builder.finish(ctx.table);
        t.known = w.view != null;
        t.liquid = liquid;
        t.liquid_fraction = @as(f32, @floatFromInt(liquid)) / @as(f32, @floatFromInt(b.w * b.h));
        // The head: a point a few pixels below the top of the box.
        const hx = b.x + @divTrunc(b.w, 2);
        const hy = b.y + @min(4, @divTrunc(b.h, 3));
        if (w.view) |*v| {
            if (v.material(hx, hy)) |m| {
                const c = ctx.table.contact[m];
                t.head_drown = c.drown and ctx.mirror.isLiquid(hx, hy);
                t.head_blind = c.blind;
            }
        } else t.head_drown = ctx.mirror.isLiquid(hx, hy);
        self.touch = t;
        self.liquid = t.liquid_fraction;
    }

    /// Status effects of this tick's touch; returns the damage taken.
    pub fn applyStatus(self: *Actor, ctx: *const Ctx) f32 {
        const dmg = self.status.apply(self.touch, dt, self.tuning);
        // Burning entities set their surroundings alight.
        if (self.status.burning > 0) {
            if (self.status.flame_timer == 0) {
                self.status.flame_timer = 6 + ctx.rng.uintLessThan(u32, 6);
                const b = self.body;
                const fx = b.x + @as(i32, @intCast(ctx.rng.uintLessThan(u32, @intCast(b.w))));
                const fy = b.y + @as(i32, @intCast(ctx.rng.uintLessThan(u32, @intCast(b.h))));
                ctx.list.spray(.{ .x = fx, .y = fy, .material = ctx.ids.flame, .count = 4, .speed = 40, .spread = 30, .direction = 0.75, .cone = 0.2 });
            } else self.status.flame_timer -= 1;
        }
        self.damage(dmg);
        return dmg;
    }

    pub fn damage(self: *Actor, hp: f32) void {
        if (hp <= 0) return;
        self.health -= hp;
        // Flash on hits, not on the trickle of burning or corrosion.
        if (hp >= 2) self.hurt_flash = @min(0.3, 0.08 + hp * 0.01);
        if (self.health <= 0) {
            self.health = 0;
            self.alive = false;
        }
    }

    /// Blast knockback and damage from the air field sample at the
    /// entity's center (decision 125), and from the blasts gameplay set off
    /// this tick when the air field is off.
    pub fn blast(self: *Actor, ctx: *const Ctx) void {
        if (ctx.air) |a| {
            if (a.sample_tick == self.air_tick) return;
            for (a.samples()) |s| {
                const mine = for (self.air_points) |p| {
                    if (p[0] == s.x and p[1] == s.y) break true;
                } else false;
                if (!mine) continue;
                self.air_tick = a.sample_tick;
                applyAirSample(self, s.sample);
                break;
            }
            return;
        }
        for (ctx.blasts) |bl| self.directBlast(bl, ctx);
    }

    /// Knockback from a known blast center (no air field): the bodies
    /// layer's falloff (docs/decisions/115), blocked by solid cells.
    pub fn directBlast(self: *Actor, bl: Blast, ctx: *const Ctx) void {
        const dx = self.cx() - bl.x;
        const dy = self.cy() - bl.y;
        const d = @sqrt(dx * dx + dy * dy);
        const reach = bl.radius * 4;
        if (d >= reach) return;
        if (physics.rayBlocked(ctx, @intFromFloat(bl.x), @intFromFloat(bl.y), @intFromFloat(self.cx()), @intFromFloat(self.cy()))) return;
        const f = (1 - d / reach) * bl.strength;
        const nx = if (d > 0.5) dx / d else 0;
        const ny = if (d > 0.5) dy / d else -1;
        self.body.vx += nx * blast_direct_speed * f * self.blast_factor;
        self.body.vy += (ny - 0.3) * blast_direct_speed * f * self.blast_factor;
        self.damage(blast_direct_damage * f * f);
    }
};

// Blast tuning (decision 125), from air samples of a strength-1.6 charge
// (radius 10) on open ground: overpressure peaks 0.24 at 40 px, 0.11 at
// 80 px, the wind behind the front ~1 px/tick, the overpressure then decays
// over ~15 ticks.
/// Knockback (px/s) per unit rise of overpressure (the shock front).
pub const blast_shock_speed: f32 = 1500;
/// Lift: the knockback's share added upward.
pub const blast_lift: f32 = 0.45;
/// Wind speed (px/s) above which the air drags an entity along, and the
/// share of the gap closed per sample.
pub const blast_wind_min: f32 = 30;
pub const blast_wind_drag: f32 = 0.08;
/// Overpressure above which the front hurts, and hp per unit of rise above it.
pub const blast_damage_threshold: f32 = 0.08;
pub const blast_damage_per_unit: f32 = 150;
/// Seconds of reduced ground control after a knock.
pub const knock_time: f32 = 0.4;
pub const blast_direct_speed: f32 = 520;
pub const blast_direct_damage: f32 = 40;
pub var debug_air = false;

fn applyAirSample(self: *Actor, s: @import("../sim/air_abi.zig").Sample) void {
    if (s.wall > 0.5) return;
    const op = s.density - 1;
    const prev = self.air_op;
    self.air_op = op;
    defer if (debug_air and (@abs(op) > 0.01)) std.debug.print("air at {d:.0},{d:.0}: op {d:.3} grad {d:.4},{d:.4} v {d:.3},{d:.3} body v {d:.0},{d:.0}\n", .{ self.cx(), self.cy(), op, s.grad_x, s.grad_y, s.vx, s.vy, self.body.vx, self.body.vy });
    const k = self.blast_factor;
    const wx = s.vx * 60;
    const wy = s.vy * 60;
    const wind = @sqrt(wx * wx + wy * wy);
    // The front: overpressure rising. Push along the wind (away from the
    // blast), or down the pressure gradient when the air is still.
    const rise = op - @max(prev, 0);
    if (rise > 0.02) {
        var dx = wx;
        var dy = wy;
        var l = wind;
        if (l < 1) {
            dx = -s.grad_x;
            dy = -s.grad_y;
            l = @sqrt(dx * dx + dy * dy);
        }
        if (l > 1e-6) {
            const dv = rise * blast_shock_speed * k;
            self.body.vx += dx / l * dv;
            self.body.vy += dy / l * dv - dv * blast_lift;
            self.knock = knock_time;
        }
        if (op > blast_damage_threshold) self.damage((op - @max(prev, blast_damage_threshold)) * blast_damage_per_unit);
    }
    // Strong wind drags along.
    if (wind > blast_wind_min) {
        const f = @min(1, blast_wind_drag * k);
        self.body.vx += (wx - self.body.vx) * f;
        self.body.vy += (wy - self.body.vy) * f;
    }
}
