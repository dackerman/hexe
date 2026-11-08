//! Projectiles: tiny CPU entities (fire bolts, thrown blast charges, the
//! flyer's spit) integrated ballistically and ray-marched pixel by pixel
//! against the readback mirror (docs/decisions/124-gameplay-projectiles.md).
//! Fixed capacity, no allocation.
const std = @import("std");
const world = @import("world.zig");
const physics = @import("physics.zig");
const explode = @import("explode.zig");
const readback = @import("../sim/readback.zig");
const air_mod = @import("../sim/air.zig");
const status = @import("status.zig");

pub const Kind = enum { fire_bolt, charge, spit };

pub const Projectile = struct {
    kind: Kind,
    x: f32,
    y: f32,
    vx: f32,
    vy: f32,
    age: f32 = 0,
    /// Charges: seconds to detonation.
    fuse: f32 = 0,
    from_player: bool,
    resting: bool = false,
};

pub const capacity = 64;

pub const Tuning = struct {
    fire_bolt_speed: f32 = 430,
    fire_bolt_gravity: f32 = 90,
    fire_bolt_damage: f32 = 18,
    spit_speed: f32 = 230,
    spit_gravity: f32 = 70,
    spit_damage: f32 = 8,
    charge_speed: f32 = 360,
    charge_speed_min: f32 = 90,
    /// Throw speed per pixel of distance to the cursor.
    charge_throw_per_px: f32 = 2.6,
    charge_gravity: f32 = 600,
    charge_fuse: f32 = 1.6,
    charge_radius: i32 = 10,
    charge_strength: f32 = 1.6,
    /// Velocity kept on a bounce.
    bounce: f32 = 0.35,
    max_age: f32 = 4,
};

/// What a projectile can hit besides terrain (filled by the game each tick).
pub const Target = struct {
    box: physics.Body,
    player: bool,
    index: u32,
};

pub const Hit = struct { target: Target, kind: Kind, x: f32, y: f32 };

pub const Projectiles = struct {
    items: [capacity]Projectile = undefined,
    len: u32 = 0,
    tun: Tuning = .{},

    pub fn clear(self: *Projectiles) void {
        self.len = 0;
    }

    pub fn fire(self: *Projectiles, kind: Kind, x: f32, y: f32, dir_x: f32, dir_y: f32, from_player: bool) bool {
        if (self.len >= capacity) return false;
        const l = @sqrt(dir_x * dir_x + dir_y * dir_y);
        const nx = if (l > 0.001) dir_x / l else 1;
        const ny = if (l > 0.001) dir_y / l else 0;
        const speed = switch (kind) {
            .fire_bolt => self.tun.fire_bolt_speed,
            .spit => self.tun.spit_speed,
            // A lob: farther cursor, harder throw.
            .charge => std.math.clamp(l * self.tun.charge_throw_per_px, self.tun.charge_speed_min, self.tun.charge_speed),
        };
        self.items[self.len] = .{ .kind = kind, .x = x, .y = y, .vx = nx * speed, .vy = ny * speed, .from_player = from_player, .fuse = if (kind == .charge) self.tun.charge_fuse else 0 };
        self.len += 1;
        return true;
    }

    /// Readback regions around fire bolts (powders and liquids stop them).
    pub fn requestReadback(self: *const Projectiles, mirror: *readback.Mirror) void {
        for (self.items[0..self.len]) |p| {
            if (p.kind == .charge and p.resting) continue;
            const px: i32 = @intFromFloat(p.x + p.vx * world.dt);
            const py: i32 = @intFromFloat(p.y + p.vy * world.dt);
            mirror.requestRegion(px - 14, py - 14, 28, 28) catch return;
        }
    }

    /// Advance every projectile one tick. Hits on `targets` are written to
    /// `hits` (returns how many); terrain impacts and charge detonations
    /// push their commands and blasts directly.
    pub fn update(self: *Projectiles, ctx: *const world.Ctx, targets: []const Target, hits: []Hit, blasts: *BlastList) u32 {
        var n_hits: u32 = 0;
        var i: u32 = 0;
        while (i < self.len) {
            const p = &self.items[i];
            var remove = false;
            p.age += world.dt;
            switch (p.kind) {
                .charge => {
                    p.fuse -= world.dt;
                    if (p.fuse <= 0) {
                        detonate(ctx, p.x, p.y, self.tun.charge_radius, self.tun.charge_strength, blasts);
                        ctx.log.add("blast charge exploded at {d:.0},{d:.0}", .{ p.x, p.y });
                        remove = true;
                    } else self.moveCharge(ctx, p);
                },
                .fire_bolt, .spit => {
                    if (p.age > self.tun.max_age) remove = true else {
                        const g = if (p.kind == .fire_bolt) self.tun.fire_bolt_gravity else self.tun.spit_gravity;
                        p.vy += g * world.dt;
                        if (self.march(ctx, p, targets, hits, &n_hits)) remove = true;
                    }
                },
            }
            if (remove) {
                self.items[i] = self.items[self.len - 1];
                self.len -= 1;
            } else i += 1;
        }
        return n_hits;
    }

    fn solidFor(ctx: *const world.Ctx, x: i32, y: i32) bool {
        if (ctx.mirror.isSolid(x, y) or ctx.mirror.isLiquid(x, y)) return true;
        if (ctx.mirror.material(x, y)) |m| return ctx.table.phase[m] == status.phase_powder;
        return false;
    }

    /// Step a bolt pixel by pixel along this tick's motion; true when it
    /// hit something (and did its effect).
    fn march(self: *Projectiles, ctx: *const world.Ctx, p: *Projectile, targets: []const Target, hits: []Hit, n_hits: *u32) bool {
        const x0 = p.x;
        const y0 = p.y;
        const x1 = p.x + p.vx * world.dt;
        const y1 = p.y + p.vy * world.dt;
        const steps: u32 = @intFromFloat(@max(1, @ceil(@max(@abs(x1 - x0), @abs(y1 - y0)))));
        var prev = [2]f32{ x0, y0 };
        for (1..steps + 1) |k| {
            const t = @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(steps));
            const x = x0 + (x1 - x0) * t;
            const y = y0 + (y1 - y0) * t;
            const ix: i32 = @intFromFloat(@floor(x));
            const iy: i32 = @intFromFloat(@floor(y));
            for (targets) |tg| {
                if (tg.player == p.from_player) continue;
                if (tg.box.overlaps(ix, iy, 1, 1)) {
                    if (n_hits.* < hits.len) {
                        hits[n_hits.*] = .{ .target = tg, .kind = p.kind, .x = x, .y = y };
                        n_hits.* += 1;
                    }
                    self.impact(ctx, p.kind, prev[0], prev[1], ix, iy);
                    return true;
                }
            }
            if (solidFor(ctx, ix, iy)) {
                self.impact(ctx, p.kind, prev[0], prev[1], ix, iy);
                return true;
            }
            prev = .{ x, y };
        }
        p.x = x1;
        p.y = y1;
        return false;
    }

    fn impact(self: *Projectiles, ctx: *const world.Ctx, kind: Kind, fx: f32, fy: f32, hx: i32, hy: i32) void {
        _ = self;
        const x: i32 = @intFromFloat(@floor(fx));
        const y: i32 = @intFromFloat(@floor(fy));
        const into_liquid = ctx.mirror.isLiquid(hx, hy);
        switch (kind) {
            .fire_bolt => {
                if (into_liquid) {
                    // Fizzles: a puff of steam.
                    ctx.list.fillCircle(x, y, 3, ctx.ids.steam, .{ .only_air = true });
                    return;
                }
                // Ignite and heat what it hit, a burst of flame, and a small
                // scorch that chips loose cells.
                ctx.list.igniteCircle(hx, hy, 6);
                ctx.list.setTemperature(hx, hy, 4, 650);
                ctx.list.fillCircle(x, y, 3, ctx.ids.flame, .{ .only_air = true });
                ctx.list.eject(hx, hy, 3, 260);
            },
            .spit => {
                if (into_liquid) return;
                ctx.list.igniteCircle(hx, hy, 3);
                ctx.list.fillCircle(x, y, 2, ctx.ids.flame, .{ .only_air = true, .coverage = 160 });
            },
            .charge => {},
        }
    }

    fn moveCharge(self: *Projectiles, ctx: *const world.Ctx, p: *Projectile) void {
        if (p.resting) {
            // Falls again if the ground under it went away.
            if (solidFor(ctx, @intFromFloat(@floor(p.x)), @intFromFloat(@floor(p.y + 1)))) return;
            p.resting = false;
        }
        p.vy += self.tun.charge_gravity * world.dt;
        var steps: u32 = @intFromFloat(@max(1, @ceil(@max(@abs(p.vx), @abs(p.vy)) * world.dt)));
        const sx = p.vx * world.dt / @as(f32, @floatFromInt(steps));
        const sy = p.vy * world.dt / @as(f32, @floatFromInt(steps));
        while (steps > 0) : (steps -= 1) {
            const nx = p.x + sx;
            if (solidFor(ctx, @intFromFloat(@floor(nx)), @intFromFloat(@floor(p.y)))) {
                p.vx = -p.vx * self.tun.bounce;
                p.vy *= 0.8;
                break;
            }
            p.x = nx;
            const ny = p.y + sy;
            if (solidFor(ctx, @intFromFloat(@floor(p.x)), @intFromFloat(@floor(ny)))) {
                p.vy = -p.vy * self.tun.bounce;
                p.vx *= 0.6;
                if (@abs(p.vy) < 40) {
                    p.vy = 0;
                    if (@abs(p.vx) < 20) {
                        p.vx = 0;
                        p.resting = true;
                    }
                }
                break;
            }
            p.y = ny;
        }
    }
};

/// Blasts set off this tick (for knockback without the air field and the
/// HUD flash).
pub const BlastList = struct {
    items: [32]world.Blast = undefined,
    len: u32 = 0,

    pub fn add(self: *BlastList, b: world.Blast) void {
        if (self.len >= self.items.len) return;
        self.items[self.len] = b;
        self.len += 1;
    }
    pub fn slice(self: *const BlastList) []const world.Blast {
        return self.items[0..self.len];
    }
};

/// The one explosion call (game/explode.zig) plus the blast record.
pub fn detonate(ctx: *const world.Ctx, x: f32, y: f32, radius: i32, strength: f32, blasts: *BlastList) void {
    explode.explode(ctx.list, @intFromFloat(@floor(x)), @intFromFloat(@floor(y)), radius, strength, ctx.explodeOpts());
    blasts.add(.{ .x = x, .y = y, .radius = @floatFromInt(radius), .strength = strength });
}
