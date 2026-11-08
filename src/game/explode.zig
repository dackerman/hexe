//! Explosions, gameplay side (docs/decisions/115-integrate-explode.md).
//!
//! `explode` is the one call gameplay, tools and scenario commands use. It
//! pushes commands only (docs/01-architecture.md: anything that changes the
//! world goes through the command list), and each layer consumes them:
//!   * the air field: `inject_pressure` (CommandList.explosion), whose blast
//!     effects break and throw cells as ballistic particles;
//!   * bodies: the same `inject_pressure` command, read by the bodies layer
//!     (src/sim/bodies_sim.zig tick): `applyBlast` impulse on nearby bodies
//!     and a destruction event (body cuts, connectivity collapse);
//!   * the liquid solver: `wake_liquid` around the blast;
//!   * without the air field, `eject` stands in for the blast effects so
//!     cells still fly.
//! `Explosions.drain` turns the GPU's EVENT_EXPLODE (gunpowder and any
//! material rule with `.event = .explode`) into `explode` calls, one tick
//! late, through the readback mirror.
const std = @import("std");
const commands = @import("../sim/commands.zig");
const readback = @import("../sim/readback.zig");
const events = @import("../sim/events.zig");

pub const Options = struct {
    /// The air field runs (else the blast is an eject).
    air: bool = true,
    /// The liquid solver runs (wake the water around the blast).
    liquid: bool = false,
};

/// Eject speed (px/s at the center) per unit strength when the air field
/// is off.
pub const eject_speed: f32 = 900;
/// Radius of a material-event explosion (one gunpowder cell), pixels.
pub const event_radius = 6;

pub fn explode(list: *commands.CommandList, x: i32, y: i32, radius: i32, strength: f32, opts: Options) void {
    const r = @max(radius, 1);
    // Air pressure; the bodies layer reads the same command.
    list.explosion(x, y, r, strength);
    // No air field: the cells fly by eject instead of by blast effects.
    if (!opts.air) list.eject(x, y, r * 2, @intFromFloat(std.math.clamp(eject_speed * strength, 0, 65535)));
    if (opts.liquid) list.wakeLiquid(x, y, r * 4, 4);
}

/// Follows the readback mirror's event history and explodes every
/// EVENT_EXPLODE once.
pub const Explosions = struct {
    /// Last tick whose events were handled.
    done: ?u32 = null,
    /// Explosions per drain at most (a burning gunpowder field must not
    /// flood the command list).
    max_per_drain: u32 = 64,

    pub fn drain(self: *Explosions, mirror: *const readback.Mirror, list: *commands.CommandList, opts: Options) u32 {
        if (!mirror.valid) return 0;
        var n: u32 = 0;
        const newest = mirror.tick;
        if (self.done) |d| if (d == newest) return 0;
        var t: u32 = if (self.done) |d| d +% 1 else newest;
        // Ticks that fell out of the mirror's history are skipped.
        if (newest -% t >= readback.event_history) t = newest -% (readback.event_history - 1);
        while (true) : (t +%= 1) {
            if (mirror.eventsAt(t)) |evs| {
                for (evs) |e| {
                    if (e.kind() != .explode or n >= self.max_per_drain) continue;
                    explode(list, e.x, e.y, event_radius, 1.0, opts);
                    n += 1;
                }
            }
            if (t == newest) break;
        }
        self.done = newest;
        return n;
    }
};

test "explode pushes the blast, the eject fallback and the wake" {
    var list: commands.CommandList = .{};
    list.begin(0);
    explode(&list, 100, 200, 8, 1.0, .{ .air = false, .liquid = true });
    try std.testing.expectEqual(@as(u32, 3), list.len);
    try std.testing.expectEqual(@backingInt(commands.Kind.inject_pressure), list.items[0].kind);
    try std.testing.expectEqual(@backingInt(commands.Kind.eject), list.items[1].kind);
    try std.testing.expectEqual(@backingInt(commands.Kind.wake_liquid), list.items[2].kind);
    list.begin(1);
    explode(&list, 100, 200, 8, 1.0, .{});
    try std.testing.expectEqual(@as(u32, 1), list.len);
}

test "drain explodes each event once" {
    var solid: [readback.mask_words]u32 = undefined;
    var liquid: [readback.mask_words]u32 = undefined;
    var data: [4]u32 = undefined;
    var history: [readback.event_history]readback.TickEvents = undefined;
    for (&history) |*h| h.* = .{};
    var m: readback.Mirror = .{ .solid = &solid, .liquid = &liquid, .region_data = &data, .history = &history };
    history[5] = .{ .tick = 5, .valid = true, .len = 2 };
    history[5].items[0] = events.Event.init(10, 20, .explode, 15);
    history[5].items[1] = events.Event.init(11, 20, .eject, 3);
    m.tick = 5;
    m.valid = true;
    var ex: Explosions = .{};
    var list: commands.CommandList = .{};
    list.begin(0);
    try std.testing.expectEqual(@as(u32, 1), ex.drain(&m, &list, .{}));
    try std.testing.expectEqual(@as(i32, 10), list.items[0].x0);
    try std.testing.expectEqual(@as(u32, 0), ex.drain(&m, &list, .{}));
}
