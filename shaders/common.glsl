// hexe shared GPU definitions. Include this; do not copy it.
//
// Everything here that the CPU also needs is mirrored by hand in Zig:
//   world/tile/cell constants, accessors  -> src/sim/cell.zig
//   descriptor slots                      -> src/gpu/constants.zig
//   MaterialGpu layout                    -> src/sim/materials.zig
//   hash                                  -> src/sim/cell.zig
// `zig build test` parses the #defines in this file and checks every mirror
// (src/gpu/constants.zig: "common.glsl mirror"). Integer literals in #defines
// must stay plain decimal or 0x hex with an optional `u` suffix so the
// parser can read them.
#ifndef HEXE_COMMON_GLSL
#define HEXE_COMMON_GLSL

#extension GL_EXT_shader_8bit_storage : require
#extension GL_EXT_shader_explicit_arithmetic_types_int8 : require
#extension GL_EXT_nonuniform_qualifier : require

// ---------------------------------------------------------------------------
// World geometry. The active window is a torus: coordinates wrap modulo
// WORLD_SIZE in both axes.
// ---------------------------------------------------------------------------
#define WORLD_SIZE 2048u
#define WORLD_MASK 2047u
#define TILE_SHIFT 5u
#define TILE_SIZE 32u
#define TILES_PER_SIDE 64u
#define TILE_COUNT 4096u
#define SUBSTEPS 8u

// ---------------------------------------------------------------------------
// Cell format (R32_UINT), docs/01-architecture.md "Pixel grid".
//   bits  0-7  material      id into the material table
//   bits  8-15 temperature   degrees C = 8*t - 40
//   bits 16-23 state         material-defined (lifetime, health, ...)
//   bit  24    burning
//   bit  25    moved         moved during the current substep
//   bit  26    particle-backed (owner image holds the particle index)
//   bit  27    body-owned    (owner image holds the body id)
//   bits 28-31 variant       stable shade index into the color ramp
// ---------------------------------------------------------------------------
#define CELL_MATERIAL_SHIFT 0u
#define CELL_MATERIAL_BITS 8u
#define CELL_TEMP_SHIFT 8u
#define CELL_TEMP_BITS 8u
#define CELL_STATE_SHIFT 16u
#define CELL_STATE_BITS 8u
#define CELL_FLAG_BURNING 0x01000000u
#define CELL_FLAG_MOVED 0x02000000u
#define CELL_FLAG_PARTICLE 0x04000000u
#define CELL_FLAG_BODY 0x08000000u
#define CELL_FLAGS_MASK 0x0f000000u
#define CELL_VARIANT_SHIFT 28u
#define CELL_VARIANT_BITS 4u

uint cell_material(uint c) { return bitfieldExtract(c, int(CELL_MATERIAL_SHIFT), int(CELL_MATERIAL_BITS)); }
uint cell_temperature(uint c) { return bitfieldExtract(c, int(CELL_TEMP_SHIFT), int(CELL_TEMP_BITS)); }
uint cell_state(uint c) { return bitfieldExtract(c, int(CELL_STATE_SHIFT), int(CELL_STATE_BITS)); }
uint cell_flags(uint c) { return c & CELL_FLAGS_MASK; }
uint cell_variant(uint c) { return bitfieldExtract(c, int(CELL_VARIANT_SHIFT), int(CELL_VARIANT_BITS)); }
bool cell_has(uint c, uint flag) { return (c & flag) != 0u; }

uint cell_with_material(uint c, uint m) { return bitfieldInsert(c, m, int(CELL_MATERIAL_SHIFT), int(CELL_MATERIAL_BITS)); }
uint cell_with_temperature(uint c, uint t) { return bitfieldInsert(c, t, int(CELL_TEMP_SHIFT), int(CELL_TEMP_BITS)); }
uint cell_with_state(uint c, uint s) { return bitfieldInsert(c, s, int(CELL_STATE_SHIFT), int(CELL_STATE_BITS)); }
uint cell_with_variant(uint c, uint v) { return bitfieldInsert(c, v, int(CELL_VARIANT_SHIFT), int(CELL_VARIANT_BITS)); }
uint cell_with_flag(uint c, uint flag, bool on) { return on ? (c | flag) : (c & ~flag); }

// `flags` is already positioned (CELL_FLAG_* values); fields are masked.
uint cell_make(uint material, uint temperature, uint state, uint flags, uint variant) {
    return (material & 0xffu) | ((temperature & 0xffu) << CELL_TEMP_SHIFT) | ((state & 0xffu) << CELL_STATE_SHIFT) |
        (flags & CELL_FLAGS_MASK) | ((variant & 0xfu) << CELL_VARIANT_SHIFT);
}

// Temperature byte <-> degrees C. Integer, floor, clamped to the byte.
int temp_to_celsius(uint t) { return int(t) * 8 - 40; }
uint celsius_to_temp(int c) { return uint(clamp((c + 40) >> 3, 0, 255)); }

// ---------------------------------------------------------------------------
// Hashed randomness. Integer only, identical on the CPU (src/sim/cell.zig).
// lowbias32 by Chris Wellons.
// ---------------------------------------------------------------------------
uint hash_u32(uint x) {
    x ^= x >> 16;
    x *= 0x7feb352du;
    x ^= x >> 15;
    x *= 0x846ca68bu;
    x ^= x >> 16;
    return x;
}

// The grid's random source: one 32-bit value per (cell or block, tick, substep).
uint hash(uint x, uint y, uint tick, uint substep) {
    uint xy = ((y & 0xffffu) << 16) | (x & 0xffffu);
    return hash_u32(xy ^ hash_u32(tick ^ hash_u32(substep)));
}

// Same, for passes that need an independent stream (salt distinguishes them).
uint hash_salt(uint x, uint y, uint tick, uint salt) {
    return hash(x, y, tick, salt ^ 0x9e3779b9u);
}

// Per (cell, tick, substep) stream for a pass other than movement; `salt`
// (below 2^24) keeps passes independent.
uint hash_pass(uint x, uint y, uint tick, uint substep, uint salt) {
    return hash(x, y, tick, (substep & 0xffu) | (salt << 8));
}

// ---------------------------------------------------------------------------
// Bindless descriptor set 0, shared by every pipeline (src/gpu/descriptors.zig).
//   binding 0: storage images, any format, indexed by slot
//   binding 1: storage buffers, indexed by slot; declare a typed view with
//              HEXE_BUFFER below (several declarations may alias binding 1)
//   binding 2: sampled images (texture2D)
//   binding 3: samplers (SAMPLER_* indices)
// Push constants: one 128-byte range visible to all stages; each shader
// declares its own block layout.
// Slots below SLOT_*_DYNAMIC_BASE are fixed, shared world resources; above
// that, subsystems allocate slots at init and pass them in push constants.
// ---------------------------------------------------------------------------
#define BINDING_STORAGE_IMAGES 0
#define BINDING_STORAGE_BUFFERS 1
#define BINDING_SAMPLED_IMAGES 2
#define BINDING_SAMPLERS 3

#define SLOT_IMG_CELLS 0u
#define SLOT_IMG_OWNER 1u
#define SLOT_IMG_DYNAMIC_BASE 16u

#define SLOT_BUF_MATERIALS 0u
#define SLOT_BUF_TILE_MARKS 1u
#define SLOT_BUF_TILE_LIST 2u
#define SLOT_BUF_COMMANDS 3u
#define SLOT_BUF_REACTIONS 12u
#define SLOT_BUF_EVENTS 13u
#define SLOT_BUF_DYNAMIC_BASE 32u

#define SAMPLER_NEAREST_CLAMP 0u
#define SAMPLER_LINEAR_CLAMP 1u
#define SAMPLER_NEAREST_REPEAT 2u
#define SAMPLER_LINEAR_REPEAT 3u

#define PUSH_CONSTANT_BYTES 128u

layout(set = 0, binding = BINDING_STORAGE_IMAGES, r32ui) uniform uimage2D g_uimages[];
layout(set = 0, binding = BINDING_SAMPLED_IMAGES) uniform texture2D g_textures[];
layout(set = 0, binding = BINDING_SAMPLERS) uniform sampler g_samplers[];

// HEXE_BUFFER(Block, qualifiers, members, instance): a typed view of binding 1.
//   HEXE_BUFFER(Floats, readonly, float data[];, g_floats)  ->  g_floats[slot].data[i]
#define HEXE_BUFFER(Block, qualifiers, members, instance) \
    layout(set = 0, binding = BINDING_STORAGE_BUFFERS, std430) qualifiers buffer Block { members } instance[]

#define CELLS g_uimages[SLOT_IMG_CELLS]
#define OWNER g_uimages[SLOT_IMG_OWNER]

ivec2 wrap_coord(ivec2 p) { return ivec2(uvec2(p) & uvec2(WORLD_MASK)); }
uint load_cell(ivec2 p) { return imageLoad(CELLS, wrap_coord(p)).x; }
void store_cell(ivec2 p, uint c) { imageStore(CELLS, wrap_coord(p), uvec4(c, 0u, 0u, 0u)); }

// ---------------------------------------------------------------------------
// Material table (storage buffer at SLOT_BUF_MATERIALS, 256 entries), packed
// by the data layer from materials/*.zon. 48 words = 192 bytes per material,
// std430. The struct below is src/data/gpu_tables.zig `glsl_material_struct`
// verbatim (a test checks it); field meanings are documented there and in
// docs/decisions/40-reactions-material-table.md. Temperatures are
// temperature bytes; material references are ids, and "no transition" is
// encoded as the material's own id with a threshold that cannot fire
// (melt/boil/ignite at 255, freeze at 0).
// ---------------------------------------------------------------------------
#define MATERIAL_COUNT 256u
#define MATERIAL_WORDS 48u
#define MATERIAL_AIR 0u
#define MATERIAL_RAMP_WORD 40u
#define MATERIAL_RAMP_MAX 8u

#define PHASE_STATIC 0u
#define PHASE_POWDER 1u
#define PHASE_LIQUID 2u
#define PHASE_GAS 3u

// MaterialGpu.flags (gpu_tables.Flag).
#define MATERIAL_FLAG_CONDUCTIVE 0x1u
#define MATERIAL_FLAG_TRANSLUCENT 0x2u
#define MATERIAL_FLAG_EMISSIVE 0x4u
#define MATERIAL_FLAG_SOLVER_FLIP 0x8u
#define MATERIAL_FLAG_FLAMMABLE 0x10u
#define MATERIAL_FLAG_HAS_LIFETIME 0x20u
#define MATERIAL_FLAG_HAS_HEALTH 0x40u
#define MATERIAL_FLAG_EXTINGUISHER 0x80u
#define MATERIAL_FLAG_BLOCKS_LIGHT 0x100u
#define MATERIAL_FLAG_FEEDS_AIR 0x200u
#define MATERIAL_FLAG_ANCHOR 0x400u
#define MATERIAL_FLAG_RICOCHET 0x800u
#define MATERIAL_FLAG_GLOWS 0x1000u
#define MATERIAL_FLAG_MELTS 0x2000u
#define MATERIAL_FLAG_FREEZES 0x4000u
#define MATERIAL_FLAG_BOILS 0x8000u
#define MATERIAL_FLAG_REACTIVE 0x10000u
#define MATERIAL_FLAG_MISSING 0x80000000u

// Movement ordering: a cell sinks into a fluid cell below it with a lower key.
#define SORT_KEY_AIR 256u
#define SORT_KEY_DENSE_BASE 512u
#define SORT_KEY_STATIC 65535u

struct MaterialGpu {
    uint phase;
    uint density;
    uint dispersion;
    uint slide;
    uint state_init;
    uint health;
    uint lifetime;
    uint lifetime_period;
    uint decays_to;
    uint temperature;
    uint conductivity;
    uint emits_heat;
    uint melt_at;
    uint melt_to;
    uint freeze_at;
    uint freeze_to;
    uint boil_at;
    uint boil_to;
    uint ignite_at;
    uint burn_fuel;
    uint burn_period;
    uint burns_to;
    uint smoke;
    uint burn_heat;
    uint burn_event;
    uint flags;
    uint impact;
    uint blast_threshold;
    uint blast_response;
    uint rubble;
    uint drag;
    uint emissive;
    uint glow_from;
    uint glow_to;
    uint pressure_event;
    uint move;
    uint sort_key;
    uint flame;
    uint reserved;
    uint ramp_len;
    uint ramp[8];
};

HEXE_BUFFER(MaterialBlock, readonly, MaterialGpu materials[];, g_material_tables);
#define MATERIALS g_material_tables[SLOT_BUF_MATERIALS].materials

// MaterialGpu.move: phase | dispersion<<8 | slide<<16 | vertical_chance<<24.
uint mat_phase(uint move) { return move & 0xffu; }
uint mat_dispersion(uint move) { return (move >> 8) & 0xffu; }
uint mat_slide(uint move) { return (move >> 16) & 0xffu; }
uint mat_vertical_chance(uint move) { return move >> 24; }
uint mat_sort_key(MaterialGpu m) { return m.sort_key; }
uint mat_spawn_temp(MaterialGpu m) { return m.temperature; }
uint mat_initial_state(MaterialGpu m) { return m.state_init; }
uint mat_ramp_len(MaterialGpu m) { return m.ramp_len; }

// A freshly spawned cell of `material` (commands, reactions).
uint spawn_cell(uint material, uint variant) {
    return cell_make(material, MATERIALS[material].temperature, MATERIALS[material].state_init, 0u, variant);
}

// Chance test used by every probabilistic rule: 255 means always.
bool chance8(uint rnd8, uint chance) { return chance >= 255u || rnd8 < chance; }

// ---------------------------------------------------------------------------
// Activity tiles (docs/01-architecture.md "Activity tiles").
//   TILE_MARKS: one byte per tile, a wake countdown: a change sets the tile
//               and its 8 neighbors to TILE_WAKE_TICKS; compaction makes
//               every nonzero tile active and decrements it. A tile sleeps
//               after TILE_WAKE_TICKS ticks without change, so a rule that
//               fails a random roll for one tick does not freeze in place.
//   TILE_LIST:  VkDispatchIndirectCommand {count,1,1}, pad, then packed tile
//               coordinates (tx | ty << 16), count of them.
// ---------------------------------------------------------------------------
HEXE_BUFFER(TileMarkBlock, , uint8_t marks[];, g_tile_marks);
HEXE_BUFFER(TileListBlock, , uint dispatch_x; uint dispatch_y; uint dispatch_z; uint count_copy; uint tiles[];, g_tile_lists);
#define TILE_MARKS g_tile_marks[SLOT_BUF_TILE_MARKS].marks
#define TILE_LIST g_tile_lists[SLOT_BUF_TILE_LIST]

uint tile_index(uvec2 t) { return (t.y & (TILES_PER_SIDE - 1u)) * TILES_PER_SIDE + (t.x & (TILES_PER_SIDE - 1u)); }

#define TILE_WAKE_TICKS 8u

// Mark tile `t` and its 8 neighbors (wrapping) active for the next
// TILE_WAKE_TICKS ticks. Racing writers all store the same value.
void mark_tile_and_neighbors(uvec2 t) {
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            TILE_MARKS[tile_index(uvec2(ivec2(t) + ivec2(dx, dy)))] = uint8_t(TILE_WAKE_TICKS);
        }
    }
}

// ---------------------------------------------------------------------------
// Activity tiles: TILE_MARKS also holds, at TILE_ACTIVE_OFFSET + tile, a copy
// of which tiles the compaction put on this tick's list (debug overlay, HUD).
// ---------------------------------------------------------------------------
#define TILE_ACTIVE_OFFSET 4096u
#define TILE_MARK_BYTES 8192u

// ---------------------------------------------------------------------------
// Commands (CPU -> GPU edits), src/sim/commands.zig. 8 words each, in the
// buffer at SLOT_BUF_COMMANDS; the CPU tells each dispatch which one to run.
//   kind, material, x0, y0, x1, y1, flags, seed
//   kind bits 0-7 shape:  CMD_FILL_CIRCLE center (x0, y0), radius x1
//                         (inclusive: d^2 <= r^2); CMD_FILL_RECT [x0, x1) x
//                         [y0, y1), unwrapped coordinates
//   kind bits 8-15 action: CMD_ACTION_FILL paint `material`; IGNITE set the
//                         burning flag on flammable cells; HEAT set the
//                         temperature byte; CHARGE start a charge pulse in
//                         conductive cells
//   material bits 0-7 material, bits 8-15 the only material painted over
//                         (with CMD_FLAG_ONLY_MATERIAL)
//   flags bit 0 only air, bit 1 only material, bit 2 set temperature, bit 3
//                         set state; bits 8-15 coverage (0 = every pixel),
//                         16-23 temperature byte, 24-31 state byte
// Coordinates are world pixels and wrap on the torus.
// ---------------------------------------------------------------------------
#define CMD_FILL_CIRCLE 1u
#define CMD_FILL_RECT 2u
#define CMD_SHAPE_MASK 0xffu
#define CMD_ACTION_SHIFT 8u
#define CMD_ACTION_FILL 0u
#define CMD_ACTION_IGNITE 1u
#define CMD_ACTION_HEAT 2u
#define CMD_ACTION_CHARGE 3u
#define CMD_ONLY_SHIFT 8u
#define CMD_FLAG_ONLY_AIR 0x1u
#define CMD_FLAG_ONLY_MATERIAL 0x2u
#define CMD_FLAG_SET_TEMP 0x4u
#define CMD_FLAG_SET_STATE 0x8u
#define CMD_COVERAGE_SHIFT 8u
#define CMD_TEMP_SHIFT 16u
#define CMD_STATE_SHIFT 24u
#define CMD_WORDS 8u
#define SALT_SPAWN_VARIANT 0x51a7u

struct Command {
    uint kind;
    uint material;
    int x0;
    int y0;
    int x1;
    int y1;
    uint flags;
    uint seed;
};

HEXE_BUFFER(CommandBlock, readonly, Command commands[];, g_command_buffers);
#define COMMANDS g_command_buffers[SLOT_BUF_COMMANDS].commands

// ---------------------------------------------------------------------------
// Reaction table (storage buffer at SLOT_BUF_REACTIONS): 256 x 256
// ReactionEntry, 8 bytes each, read as uvec2, flat index self * 256 + other
// (src/data/gpu_tables.zig ReactionEntry):
//   x: self_result | other_result<<8 | chance<<16 | min_temp<<24
//   y: max_temp | catalyst<<8 | event<<16 | flags<<24
// chance 0 = no reaction. Temperature bounds are inclusive on the pair
// temperature (t_self + t_other) / 2.
// ---------------------------------------------------------------------------
#define REACTION_FLAG_HAS_CATALYST 0x1u
#define REACTION_FLAG_EMITS_EVENT 0x2u

HEXE_BUFFER(ReactionBlock, readonly, uvec2 reactions[];, g_reaction_tables);
#define REACTIONS g_reaction_tables[SLOT_BUF_REACTIONS].reactions

// ---------------------------------------------------------------------------
// Event queue (storage buffer at SLOT_BUF_EVENTS): a ring the GPU appends to
// when a rule needs gameplay to react (docs/01-architecture.md "Readback").
// `count` only grows (wrapping at 2^32); event i lives at
// events[i % EVENT_CAPACITY]. A reader remembers the last count it saw;
// more than EVENT_CAPACITY new events since then means some were
// overwritten. Order within a tick is not deterministic, the set is.
//   event: uvec4(x | y << 16, kind, payload, tick)
// Kinds below 128 are data-defined (materials.Event: 1 explode, 2
// pressure); the engine's own start at 128.
// ---------------------------------------------------------------------------
#define EVENT_CAPACITY 4096u
#define EVENT_EXPLODE 1u
#define EVENT_PRESSURE 2u
#define EVENT_PARTICLE_CELL_CHANGED 128u

HEXE_BUFFER(EventBlock, , uint count; uint capacity; uint dropped; uint pad; uvec4 events[];, g_event_queues);
#define EVENTS g_event_queues[SLOT_BUF_EVENTS]

void emit_event(ivec2 p, uint kind, uint payload, uint tick) {
    uint i = atomicAdd(EVENTS.count, 1u);
    ivec2 w = wrap_coord(p);
    EVENTS.events[i & (EVENT_CAPACITY - 1u)] = uvec4(uint(w.x) | (uint(w.y) << 16), kind, payload, tick);
}

// ---------------------------------------------------------------------------
// State byte (docs/decisions/42-reactions-state-byte.md). Health, lifetime
// count and health-less burn fuel use the whole byte, except in conductive
// materials, which keep their charge phase in bits 6-7 and everything else
// in bits 0-5: CHARGE_HEAD is a fresh pulse, lower values the refractory
// tail; a neutral conductive cell next to a head becomes a head.
// ---------------------------------------------------------------------------
#define CHARGE_SHIFT 6u
#define CHARGE_HEAD 3u
#define CONDUCTIVE_STATE_MASK 0x3fu

bool mat_conductive(uint material) { return (MATERIALS[material].flags & MATERIAL_FLAG_CONDUCTIVE) != 0u; }
uint cell_charge(uint c) { return cell_state(c) >> CHARGE_SHIFT; }

// `c` (of flammable `material`) set alight: the burning flag, and the burn
// fuel as state for materials without health (with health, burning
// consumes the health already in the state byte).
uint cell_ignite(uint c, uint material) {
    uint s = (MATERIALS[material].flags & MATERIAL_FLAG_HAS_HEALTH) != 0u ? cell_state(c) : MATERIALS[material].burn_fuel;
    return cell_with_flag(cell_with_state(c, s), CELL_FLAG_BURNING, true);
}

// ---------------------------------------------------------------------------
// Reactions and heat pass tuning (shaders/sim/grid/reactions.comp,
// docs/decisions/41-reactions-pass.md). Chances are out of 256.
//   HEAT_SHIFT          conduction: dT = sum(min(k_a, k_b) * (T_n - T)) >> 13
//                       per substep (k/1024 per tick), stochastically rounded
//   EMIT_GAP_SHIFT      emission per tick moves at most gap >> 3 bytes, into
//                       solids and liquids only
//   EMIT_DRAIN_SHIFT    the emitter loses a quarter of what it gives
//   BOIL_LATENT         ticks a cell is held at its boil point (counted in
//                       the state byte) before it boils: latent heat
//   BURN_TEMP           burning cells heat themselves up to this byte (900 C)
//   IGNITE_CONTACT_CHANCE  per tick, a flammable cell next to fire ignites
//   FLAME_CHANCE, SMOKE_CHANCE  per tick, air next to a burning cell becomes
//                       its flame / its smoke (cumulative rolls)
// ---------------------------------------------------------------------------
#define SALT_REACT_CELL 0x4e1u
#define SALT_REACT_PAIR 0x4e2u
#define HEAT_SHIFT 13u
#define EMIT_GAP_SHIFT 3u
#define EMIT_DRAIN_SHIFT 2u
#define BURN_TEMP 118u
#define BOIL_LATENT 40u
#define IGNITE_CONTACT_CHANCE 24u
#define FLAME_CHANCE 40u
#define SMOKE_CHANCE 10u

#endif
