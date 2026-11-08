//! The GPU -> CPU event ABI, CPU mirror of shaders/sim/events.glsl
//! (docs/decisions/53-event-queue.md, 111-integrate-event-queue.md).
//!
//! One queue for the whole engine at SLOT_BUF_EVENTS, reset at the start of
//! every tick and copied into the readback mirror (src/sim/readback.zig),
//! which keeps the last `readback.event_history` ticks. Appenders: material
//! rules in the reactions pass (explode, pressure, particle_cell_changed),
//! commands (eject). Order within a tick is not deterministic, the set is.
const std = @import("std");

pub const capacity = 4096;
pub const header_words = 4;
pub const payload_shift = 8;

pub const Kind = enum(u8) {
    none = 0,
    /// A material rule with `.event = .explode` fired (gunpowder ignited);
    /// payload = material id. Gameplay answers with an explosion
    /// (src/game/explode.zig).
    explode = 1,
    /// A cell's `pressure_event` threshold was exceeded; payload = material.
    pressure = 2,
    /// CMD_EJECT ran; payload = radius. The M4 test event.
    eject = 3,
    /// A reaction changed the material of a particle-backed cell; payload =
    /// its owner image value (the particle index), for the liquid solver.
    particle_cell_changed = 128,
    _,
};

/// One queue entry (8 bytes, `uvec2`).
pub const Event = extern struct {
    x: u16,
    y: u16,
    /// kind | payload << payload_shift.
    word: u32,

    pub fn init(x: u32, y: u32, k: Kind, p: u32) Event {
        return .{ .x = @intCast(x), .y = @intCast(y), .word = @as(u32, @backingInt(k)) | (p << payload_shift) };
    }
    pub fn kind(e: Event) Kind {
        return @fromBackingInt(@intCast(@as(u8, @truncate(e.word))));
    }
    pub fn payload(e: Event) u32 {
        return e.word >> payload_shift;
    }
};

comptime {
    std.debug.assert(@sizeOf(Event) == 8);
}

/// An event with the tick it was appended in (comparisons across ticks:
/// verify-determinism, scenario runner).
pub const Ticked = struct {
    tick: u32,
    event: Event,

    pub fn lessThan(_: void, a: Ticked, b: Ticked) bool {
        if (a.tick != b.tick) return a.tick < b.tick;
        if (a.event.y != b.event.y) return a.event.y < b.event.y;
        if (a.event.x != b.event.x) return a.event.x < b.event.x;
        return a.event.word < b.event.word;
    }

    pub fn eql(a: Ticked, b: Ticked) bool {
        return a.tick == b.tick and a.event.x == b.event.x and a.event.y == b.event.y and a.event.word == b.event.word;
    }
};

test "events.glsl mirror" {
    const src = @embedFile("events_glsl");
    const constants = @import("../gpu/constants.zig");
    var defines: [32]constants.Define = undefined;
    const n = constants.parseDefines(src, &defines);
    try @import("particles.zig").checkMirror(defines[0..n], .{
        .{ "EVENT_CAPACITY", capacity },
        .{ "EVENT_HEADER_WORDS", header_words },
        .{ "EVENT_PAYLOAD_SHIFT", payload_shift },
        .{ "EVENT_NONE", @backingInt(Kind.none) },
        .{ "EVENT_EXPLODE", @backingInt(Kind.explode) },
        .{ "EVENT_PRESSURE", @backingInt(Kind.pressure) },
        .{ "EVENT_EJECT", @backingInt(Kind.eject) },
        .{ "EVENT_PARTICLE_CELL_CHANGED", @backingInt(Kind.particle_cell_changed) },
    });
}

test "event packing" {
    const e = Event.init(5, 2047, .particle_cell_changed, 1_000_000);
    try std.testing.expectEqual(Kind.particle_cell_changed, e.kind());
    try std.testing.expectEqual(@as(u32, 1_000_000), e.payload());
    try std.testing.expectEqual(@as(u16, 2047), e.y);
}
