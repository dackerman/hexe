//! Debug overlay modes (docs/07-tech-demo.md "Tab cycles debug overlays",
//! docs/decisions/103-render-overlays.md). Ids are OVERLAY_* in
//! shaders/common.glsl (mirrored in src/gpu/constants.zig).
//!
//! Three kinds of mode:
//!   * computed by the world pass from the cell snapshot: tiles, bodies,
//!     temperature, particle_cells, light;
//!   * read from the RGBA8 debug overlay image at SLOT_IMG_DEBUG_OVERLAY that
//!     a sim pass writes while `Frame.overlay` is its id: air_pressure,
//!     air_velocity, liquid_particles;
//!   * none.
const std = @import("std");

pub const Mode = enum(u32) {
    none = 0,
    /// Activity tiles active this tick (was F2).
    tiles = 1,
    /// Image: air pressure (air field agent).
    air_pressure = 2,
    /// Image: air velocity (air field agent).
    air_velocity = 3,
    /// Image: liquid particles (liquid solver agent).
    liquid_particles = 4,
    /// Owner ids of body-owned cells, hashed to colors.
    bodies = 5,
    /// Cell temperature as a heat map.
    temperature = 6,
    /// Particle-backed cells highlighted.
    particle_cells = 7,
    /// Irradiance only (lighting debug).
    light = 8,
};

pub const count = @typeInfo(Mode).@"enum".field_names.len;

pub const Blend = enum { alpha, additive };

pub const Info = struct {
    name: []const u8,
    /// Mode samples the debug overlay image.
    image: bool = false,
    blend: Blend = .alpha,
    legend: []const u8,
};

pub fn info(mode: Mode) Info {
    return switch (mode) {
        .none => .{ .name = "none", .legend = "" },
        .tiles => .{ .name = "activity tiles", .legend = "red: tile simulated this tick" },
        .air_pressure => .{ .name = "air pressure", .image = true, .legend = "image from the air field (alpha blend)" },
        .air_velocity => .{ .name = "air velocity", .image = true, .legend = "image from the air field (alpha blend)" },
        .liquid_particles => .{ .name = "liquid particles", .image = true, .blend = .additive, .legend = "image from the liquid solver (additive)" },
        .bodies => .{ .name = "bodies", .legend = "body-owned cells colored by owner id" },
        .temperature => .{ .name = "temperature", .legend = "blue -40C  green 20C  yellow 500C  red 1000C  white 2000C" },
        .particle_cells => .{ .name = "particle cells", .legend = "cyan: particle-backed cells" },
        .light => .{ .name = "light", .legend = "irradiance only (white albedo)" },
    };
}

/// Tab order: every mode, wrapping.
pub fn next(mode: Mode) Mode {
    const i = (@backingInt(mode) + 1) % count;
    return @fromBackingInt(@intCast(i));
}

pub fn prev(mode: Mode) Mode {
    const i = (@backingInt(mode) + count - 1) % count;
    return @fromBackingInt(@intCast(i));
}

test "overlay cycle visits every mode" {
    var m: Mode = .none;
    var seen: [count]bool = @splat(false);
    for (0..count) |_| {
        seen[@backingInt(m)] = true;
        m = next(m);
    }
    try std.testing.expectEqual(Mode.none, m);
    for (seen) |s| try std.testing.expect(s);
    try std.testing.expectEqual(Mode.light, prev(.none));
}
