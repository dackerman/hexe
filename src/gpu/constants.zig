//! CPU mirrors of the constants defined in shaders/common.glsl.
//!
//! common.glsl is the source of truth. Every numeric `#define` in it must be
//! mirrored here or in a file listed in `mirrors` below; the test at the
//! bottom parses common.glsl and fails on any mismatch or unmirrored define.
const std = @import("std");
const cell = @import("../sim/cell.zig");
const materials = @import("../sim/materials.zig");
const commands = @import("../sim/commands.zig");
const air = @import("../sim/air_abi.zig");
const reactions = @import("../sim/reactions.zig");
const Flag = materials.Flag;

// ---- descriptor set 0 (src/gpu/descriptors.zig) ----
pub const binding_storage_images = 0;
pub const binding_storage_buffers = 1;
pub const binding_sampled_images = 2;
pub const binding_samplers = 3;

/// Fixed storage image slots (shared world images).
pub const slot_img_cells = 0;
pub const slot_img_owner = 1;
pub const slot_img_solid_coarse = 8;
pub const slot_img_liquid_coarse = 9;
pub const slot_img_air = 10;
pub const slot_img_air_source = 11;
pub const slot_img_debug_overlay = 12;
pub const slot_img_particle_overlay = 13;
/// First storage image slot handed out by `Descriptors.allocImageSlot`.
pub const slot_img_dynamic_base = 16;

/// Fixed storage buffer slots (shared world buffers).
pub const slot_buf_materials = 0;
pub const slot_buf_tile_marks = 1;
pub const slot_buf_tile_list = 2;
pub const slot_buf_commands = 3;
pub const slot_buf_blast_ejects = 25;
pub const slot_buf_air_events = 26;
pub const slot_buf_air_tile_marks = 27;
pub const slot_buf_air_tile_list = 28;
/// Eject queue: cells displaced by bodies, debris (M7, src/sim/bodies_gpu.zig).
pub const slot_buf_eject = 4;
pub const eject_capacity = 16384;
/// Reaction table, 256 x 256 ReactionEntry (src/sim/reactions.zig).
pub const slot_buf_reactions = 12;
// Particles and events (M4), docs/decisions/50-particle-buffer.md. The
// event queue is the engine's one GPU -> CPU event list (readback.zig).
pub const slot_buf_events = 16;
pub const slot_buf_particle_ctrl = 17;
pub const slot_buf_particle_pos = 18;
pub const slot_buf_particle_vel = 19;
pub const slot_buf_particle_affine = 20;
pub const slot_buf_particle_meta = 21;
pub const slot_buf_particle_binding = 22;
pub const slot_buf_particle_free = 23;
pub const slot_buf_particle_spawn = 24;
/// First storage buffer slot handed out by `Descriptors.allocBufferSlot`.
pub const slot_buf_dynamic_base = 32;

pub const sampler_nearest_clamp = 0;
pub const sampler_linear_clamp = 1;
pub const sampler_nearest_repeat = 2;
pub const sampler_linear_repeat = 3;

pub const push_constant_bytes = 128;

// Capacities of the bindless arrays.
pub const max_storage_images = 64;
pub const max_storage_buffers = 256;
pub const max_sampled_images = 64;
pub const sampler_count = 4;

/// (GLSL name, CPU value) for every numeric define in common.glsl.
pub const mirrors = .{
    .{ "WORLD_SIZE", cell.world_size },
    .{ "WORLD_MASK", cell.world_mask },
    .{ "TILE_SHIFT", cell.tile_shift },
    .{ "TILE_SIZE", cell.tile_size },
    .{ "TILES_PER_SIDE", cell.tiles_per_side },
    .{ "TILE_COUNT", cell.tile_count },
    .{ "SUBSTEPS", cell.substeps },
    .{ "CELL_MATERIAL_SHIFT", cell.material_shift },
    .{ "CELL_MATERIAL_BITS", cell.material_bits },
    .{ "CELL_TEMP_SHIFT", cell.temp_shift },
    .{ "CELL_TEMP_BITS", cell.temp_bits },
    .{ "CELL_STATE_SHIFT", cell.state_shift },
    .{ "CELL_STATE_BITS", cell.state_bits },
    .{ "CELL_FLAG_BURNING", cell.flag_burning },
    .{ "CELL_FLAG_MOVED", cell.flag_moved },
    .{ "CELL_FLAG_PARTICLE", cell.flag_particle },
    .{ "CELL_FLAG_BODY", cell.flag_body },
    .{ "CELL_FLAGS_MASK", cell.flags_mask },
    .{ "CELL_VARIANT_SHIFT", cell.variant_shift },
    .{ "CELL_VARIANT_BITS", cell.variant_bits },
    .{ "BINDING_STORAGE_IMAGES", binding_storage_images },
    .{ "BINDING_STORAGE_BUFFERS", binding_storage_buffers },
    .{ "BINDING_SAMPLED_IMAGES", binding_sampled_images },
    .{ "BINDING_SAMPLERS", binding_samplers },
    .{ "SLOT_IMG_CELLS", slot_img_cells },
    .{ "SLOT_IMG_OWNER", slot_img_owner },
    .{ "SLOT_IMG_PARTICLE_OVERLAY", slot_img_particle_overlay },
    .{ "SLOT_IMG_DYNAMIC_BASE", slot_img_dynamic_base },
    .{ "SLOT_IMG_SOLID_COARSE", slot_img_solid_coarse },
    .{ "SLOT_IMG_LIQUID_COARSE", slot_img_liquid_coarse },
    .{ "SLOT_IMG_AIR", slot_img_air },
    .{ "SLOT_IMG_AIR_SOURCE", slot_img_air_source },
    .{ "SLOT_IMG_DEBUG_OVERLAY", slot_img_debug_overlay },
    .{ "SLOT_BUF_BLAST_EJECTS", slot_buf_blast_ejects },
    .{ "SLOT_BUF_AIR_EVENTS", slot_buf_air_events },
    .{ "SLOT_BUF_AIR_TILE_MARKS", slot_buf_air_tile_marks },
    .{ "SLOT_BUF_AIR_TILE_LIST", slot_buf_air_tile_list },
    .{ "SLOT_BUF_MATERIALS", slot_buf_materials },
    .{ "SLOT_BUF_TILE_MARKS", slot_buf_tile_marks },
    .{ "SLOT_BUF_TILE_LIST", slot_buf_tile_list },
    .{ "SLOT_BUF_COMMANDS", slot_buf_commands },
    .{ "SLOT_BUF_EJECT", slot_buf_eject },
    .{ "EJECT_CAPACITY", eject_capacity },
    .{ "SLOT_BUF_EVENTS", slot_buf_events },
    .{ "SLOT_BUF_PARTICLE_CTRL", slot_buf_particle_ctrl },
    .{ "SLOT_BUF_PARTICLE_POS", slot_buf_particle_pos },
    .{ "SLOT_BUF_PARTICLE_VEL", slot_buf_particle_vel },
    .{ "SLOT_BUF_PARTICLE_AFFINE", slot_buf_particle_affine },
    .{ "SLOT_BUF_PARTICLE_META", slot_buf_particle_meta },
    .{ "SLOT_BUF_PARTICLE_BINDING", slot_buf_particle_binding },
    .{ "SLOT_BUF_PARTICLE_FREE", slot_buf_particle_free },
    .{ "SLOT_BUF_PARTICLE_SPAWN", slot_buf_particle_spawn },
    .{ "SLOT_BUF_DYNAMIC_BASE", slot_buf_dynamic_base },
    .{ "SAMPLER_NEAREST_CLAMP", sampler_nearest_clamp },
    .{ "SAMPLER_LINEAR_CLAMP", sampler_linear_clamp },
    .{ "SAMPLER_NEAREST_REPEAT", sampler_nearest_repeat },
    .{ "SAMPLER_LINEAR_REPEAT", sampler_linear_repeat },
    .{ "PUSH_CONSTANT_BYTES", push_constant_bytes },
    .{ "SLOT_BUF_REACTIONS", slot_buf_reactions },
    .{ "MATERIAL_COUNT", materials.count },
    .{ "MATERIAL_WORDS", @sizeOf(materials.MaterialGpu) / 4 },
    .{ "MATERIAL_AIR", materials.air },
    .{ "MATERIAL_RAMP_WORD", @offsetOf(materials.MaterialGpu, "ramp") / 4 },
    .{ "MATERIAL_RAMP_MAX", materials.ramp_max },
    .{ "PHASE_STATIC", @backingInt(materials.Phase.static) },
    .{ "PHASE_POWDER", @backingInt(materials.Phase.powder) },
    .{ "PHASE_LIQUID", @backingInt(materials.Phase.liquid) },
    .{ "PHASE_GAS", @backingInt(materials.Phase.gas) },
    .{ "MATERIAL_FLAG_CONDUCTIVE", Flag.conductive },
    .{ "MATERIAL_FLAG_TRANSLUCENT", Flag.translucent },
    .{ "MATERIAL_FLAG_EMISSIVE", Flag.emissive },
    .{ "MATERIAL_FLAG_SOLVER_FLIP", Flag.solver_flip },
    .{ "MATERIAL_FLAG_FLAMMABLE", Flag.flammable },
    .{ "MATERIAL_FLAG_HAS_LIFETIME", Flag.has_lifetime },
    .{ "MATERIAL_FLAG_HAS_HEALTH", Flag.has_health },
    .{ "MATERIAL_FLAG_EXTINGUISHER", Flag.extinguisher },
    .{ "MATERIAL_FLAG_BLOCKS_LIGHT", Flag.blocks_light },
    .{ "MATERIAL_FLAG_FEEDS_AIR", Flag.feeds_air },
    .{ "MATERIAL_FLAG_ANCHOR", Flag.anchor },
    .{ "MATERIAL_FLAG_RICOCHET", Flag.ricochet },
    .{ "MATERIAL_FLAG_GLOWS", Flag.glows },
    .{ "MATERIAL_FLAG_MELTS", Flag.melts },
    .{ "MATERIAL_FLAG_FREEZES", Flag.freezes },
    .{ "MATERIAL_FLAG_BOILS", Flag.boils },
    .{ "MATERIAL_FLAG_REACTIVE", Flag.reactive },
    .{ "MATERIAL_FLAG_MISSING", Flag.missing },
    .{ "SORT_KEY_AIR", materials.sort_key_air },
    .{ "SORT_KEY_DENSE_BASE", materials.sort_key_dense_base },
    .{ "SORT_KEY_STATIC", materials.sort_key_static },
    .{ "TILE_ACTIVE_OFFSET", cell.tile_active_offset },
    .{ "TILE_MARK_BYTES", cell.tile_mark_bytes },
    .{ "TILE_WAKE_TICKS", cell.tile_wake_ticks },
    .{ "CMD_FILL_CIRCLE", @backingInt(commands.Kind.fill_circle) },
    .{ "CMD_FILL_RECT", @backingInt(commands.Kind.fill_rect) },
    .{ "CMD_FILL_LINE", @backingInt(commands.Kind.fill_line) },
    .{ "CMD_SPRAY", @backingInt(commands.Kind.spray) },
    .{ "CMD_EJECT", @backingInt(commands.Kind.eject) },
    .{ "CMD_LINE_RADIUS_SHIFT", commands.line_radius_shift },
    .{ "CMD_SHAPE_MASK", commands.shape_mask },
    .{ "CMD_ACTION_SHIFT", commands.action_shift },
    .{ "CMD_ACTION_FILL", @backingInt(commands.Action.fill) },
    .{ "CMD_ACTION_IGNITE", @backingInt(commands.Action.ignite) },
    .{ "CMD_ACTION_HEAT", @backingInt(commands.Action.heat) },
    .{ "CMD_ACTION_CHARGE", @backingInt(commands.Action.charge) },
    .{ "CMD_ONLY_SHIFT", commands.only_shift },
    .{ "CMD_FLAG_ONLY_AIR", commands.flag_only_air },
    .{ "CMD_FLAG_ONLY_MATERIAL", commands.flag_only_material },
    .{ "CMD_FLAG_SET_TEMP", commands.flag_set_temp },
    .{ "CMD_FLAG_SET_STATE", commands.flag_set_state },
    .{ "CMD_COVERAGE_SHIFT", commands.coverage_shift },
    .{ "CMD_TEMP_SHIFT", commands.temp_shift },
    .{ "CMD_STATE_SHIFT", commands.state_shift },
    .{ "CMD_WORDS", @sizeOf(commands.CommandGpu) / 4 },
    .{ "SALT_SPAWN_VARIANT", cell.salt_spawn_variant },
    .{ "CMD_INJECT_PRESSURE", @backingInt(commands.Kind.inject_pressure) },
    .{ "BLAST_FLY", @backingInt(materials.BlastResponse.fly) },
    .{ "BLAST_CHIP", @backingInt(materials.BlastResponse.chip) },
    .{ "BLAST_BREAK", @backingInt(materials.BlastResponse.@"break") },
    .{ "IMPACT_NONE", @backingInt(materials.Impact.none) },
    .{ "IMPACT_SPLASH", @backingInt(materials.Impact.splash) },
    .{ "IMPACT_SPRAY", @backingInt(materials.Impact.spray) },
    .{ "IMPACT_CHIP", @backingInt(materials.Impact.chip) },
    .{ "IMPACT_DENT", @backingInt(materials.Impact.dent) },
    .{ "IMPACT_RICOCHET", @backingInt(materials.Impact.ricochet) },
    .{ "AIR_SIZE", air.size },
    .{ "AIR_MASK", air.size - 1 },
    .{ "AIR_TILE", air.tile },
    .{ "AIR_TILES_PER_SIDE", air.tiles_per_side },
    .{ "AIR_WAKE_TICKS", air.wake_ticks },
    .{ "AIR_TILE_ACTIVE_OFFSET", air.tile_active_offset },
    .{ "AIR_MASS_ONE", air.mass_one },
    .{ "AIR_GAS_CELL_MASS", air.gas_cell_mass },
    .{ "BLAST_EJECT_WORDS", @sizeOf(air.BlastEject) / 4 },
    .{ "BLAST_EJECT_CAPACITY", air.blast_eject_capacity },
    .{ "BLAST_KIND_FLY", @backingInt(air.BlastKind.fly) },
    .{ "BLAST_KIND_CHIP", @backingInt(air.BlastKind.chip) },
    .{ "BLAST_KIND_BREAK", @backingInt(air.BlastKind.@"break") },
    .{ "AIR_EVENT_WORDS", @sizeOf(air.AirEvent) / 4 },
    .{ "AIR_EVENT_CAPACITY", air.event_capacity },
    .{ "AIR_EVENT_PRESSURE", @backingInt(air.EventKind.pressure) },
    .{ "REACTION_FLAG_HAS_CATALYST", materials.ReactionFlag.has_catalyst },
    .{ "REACTION_FLAG_EMITS_EVENT", materials.ReactionFlag.emits_event },
    .{ "CHARGE_SHIFT", cell.charge_shift },
    .{ "CHARGE_HEAD", cell.charge_head },
    .{ "CONDUCTIVE_STATE_MASK", cell.conductive_state_mask },
    .{ "SALT_REACT_CELL", reactions.salt_cell },
    .{ "SALT_REACT_PAIR", reactions.salt_pair },
    .{ "HEAT_SHIFT", reactions.heat_shift },
    .{ "EMIT_GAP_SHIFT", reactions.emit_gap_shift },
    .{ "EMIT_DRAIN_SHIFT", reactions.emit_drain_shift },
    .{ "BURN_TEMP", reactions.burn_temp },
    .{ "BOIL_LATENT", reactions.boil_latent },
    .{ "IGNITE_CONTACT_CHANCE", reactions.ignite_contact_chance },
    .{ "FLAME_CHANCE", reactions.flame_chance },
    .{ "SMOKE_CHANCE", reactions.smoke_chance },
};

pub const Define = struct { name: []const u8, value: u64 };

/// Parse `#define NAME <integer>[u]` lines. Non-numeric defines are skipped.
pub fn parseDefines(src: []const u8, out: []Define) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "#define ")) continue;
        var it = std.mem.tokenizeAny(u8, line["#define ".len..], " \t");
        const name = it.next() orelse continue;
        if (std.mem.indexOfScalar(u8, name, '(') != null) continue; // function-like macro
        var value_text = it.next() orelse continue;
        if (it.next() != null) continue; // expression, not a literal
        if (std.mem.endsWith(u8, value_text, "u")) value_text = value_text[0 .. value_text.len - 1];
        const value = std.fmt.parseInt(u64, value_text, 0) catch continue;
        out[n] = .{ .name = name, .value = value };
        n += 1;
    }
    return n;
}

test "common.glsl mirror" {
    const src = @embedFile("common_glsl");
    var defines: [512]Define = undefined;
    const n = parseDefines(src, &defines);
    try std.testing.expect(n > 40);
    for (defines[0..n]) |d| {
        var found = false;
        inline for (mirrors) |m| {
            if (std.mem.eql(u8, m[0], d.name)) {
                found = true;
                if (@as(u64, m[1]) != d.value) {
                    std.debug.print("mirror mismatch: {s} = {d} in common.glsl, {d} on the CPU\n", .{ d.name, d.value, @as(u64, m[1]) });
                    return error.MirrorMismatch;
                }
            }
        }
        if (!found) {
            std.debug.print("common.glsl define {s} has no CPU mirror (src/gpu/constants.zig)\n", .{d.name});
            return error.MirrorMissing;
        }
    }
    // And every mirror must still exist in the shader source.
    inline for (mirrors) |m| {
        var found = false;
        for (defines[0..n]) |d| found = found or std.mem.eql(u8, m[0], d.name);
        if (!found) {
            std.debug.print("mirror {s} no longer defined in common.glsl\n", .{m[0]});
            return error.MirrorStale;
        }
    }
}
