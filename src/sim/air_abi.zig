//! Air field ABI shared by the CPU and the GPU: lattice geometry, the
//! fixed-point mass format, and the record layouts of the blast eject, air
//! event, sample and field readback buffers. Mirrors the "Air field" section
//! of shaders/common.glsl (checked by the "common.glsl mirror" test in
//! src/gpu/constants.zig). No GPU code here, so tests can import it.
const std = @import("std");
const cell = @import("cell.zig");

/// Lattice cells per side; each covers 2 x 2 pixels.
pub const size = cell.world_size / 2;
/// Lattice cells per air tile side. An air tile covers one grid activity
/// tile (32 x 32 pixels), with the same tile coordinates.
pub const tile = 16;
pub const tiles_per_side = size / tile;
pub const tile_count = tiles_per_side * tiles_per_side;
comptime {
    std.debug.assert(tile * 2 == cell.tile_size and tiles_per_side == cell.tiles_per_side);
}
/// Ticks an air tile stays active after it last saw motion or a source.
pub const wake_ticks = 4;
/// Air tile marks buffer: wake countdowns, then this tick's active flags.
pub const tile_active_offset = tile_count;
pub const tile_mark_bytes = tile_count * 2;
/// Fixed-point unit of SLOT_IMG_AIR_SOURCE: one lattice cell of ambient air.
pub const mass_one: u32 = 65536;
/// Mass one created feeds_air gas pixel adds (0.5 of a lattice cell of
/// ambient air; docs/decisions/74-air-sources.md).
pub const gas_cell_mass: u32 = mass_one / 2;

pub const BlastKind = enum(u32) { fly = 1, chip = 2, @"break" = 3 };

/// One record in SLOT_BUF_BLAST_EJECTS: a pixel the blast threw (fly: the
/// cell was turned into air; break: the cell was removed; chip: the cell
/// stays and lost health). The particle spawner turns these into ballistic
/// particles of `cell`'s material at (x + 0.5, y + 0.5) with velocity
/// (vx, vy) in pixels per tick.
pub const BlastEject = extern struct {
    x: i32,
    y: i32,
    vx: f32,
    vy: f32,
    /// The cell word as it was (material, temperature, variant ...); for
    /// chips and breaks the material is the rubble material.
    cell: u32,
    kind: BlastKind,
};
pub const blast_eject_capacity = 65536;

pub const EventKind = enum(u32) { pressure = 1 };

/// One record in SLOT_BUF_AIR_EVENTS.
pub const AirEvent = extern struct {
    x: i32,
    y: i32,
    kind: EventKind,
    /// Overpressure in 0.001 of ambient density.
    value: u32,
};
pub const event_capacity = 1024;

/// Header of the eject and event buffers.
pub const ListHeader = extern struct {
    count: u32,
    capacity: u32,
    dropped: u32,
    tick: u32,
};

comptime {
    std.debug.assert(@sizeOf(BlastEject) == 24);
    std.debug.assert(@sizeOf(AirEvent) == 16);
    std.debug.assert(@sizeOf(ListHeader) == 16);
}

/// A point sample: air at the lattice cell containing pixel (x, y).
pub const Sample = extern struct {
    /// Density relative to ambient (1.0 = ambient pressure).
    density: f32,
    /// Velocity, pixels per tick.
    vx: f32,
    vy: f32,
    /// Density gradient, per pixel (points from low to high pressure);
    /// the blast force on a body is -gradient integrated over its area.
    grad_x: f32,
    grad_y: f32,
    /// 1 if the cell is a wall for the air field.
    wall: f32,
    _pad: [2]f32 = .{ 0, 0 },
};
pub const max_samples = 64;

/// Downsampled field readback: `field_size`^2 cells of 8 x 8 pixels (4 x 4
/// lattice cells), row major, y down.
pub const field_size = 256;
pub const FieldCell = extern struct {
    /// Mean density over the fluid lattice cells (1.0 where all walls).
    density: f32,
    /// Mean velocity, pixels per tick.
    vx: f32,
    vy: f32,
    /// Fraction of the 16 lattice cells that are fluid.
    open: f32,
};

comptime {
    std.debug.assert(@sizeOf(Sample) == 32);
    std.debug.assert(@sizeOf(FieldCell) == 16);
}
