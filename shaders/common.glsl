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
// Air field and obstacle coarsening (M5). Slots 8-12 / 20-23 were taken as a
// block rather than "next free" to avoid renumbering at merge
// (docs/decisions/70-air-field-abi.md).
#define SLOT_IMG_SOLID_COARSE 8u
#define SLOT_IMG_LIQUID_COARSE 9u
#define SLOT_IMG_AIR 10u
#define SLOT_IMG_AIR_SOURCE 11u
#define SLOT_IMG_DEBUG_OVERLAY 12u
#define SLOT_IMG_DYNAMIC_BASE 16u

#define SLOT_BUF_MATERIALS 0u
#define SLOT_BUF_TILE_MARKS 1u
#define SLOT_BUF_TILE_LIST 2u
#define SLOT_BUF_COMMANDS 3u
#define SLOT_BUF_BLAST_EJECTS 20u
#define SLOT_BUF_AIR_EVENTS 21u
#define SLOT_BUF_AIR_TILE_MARKS 22u
#define SLOT_BUF_AIR_TILE_LIST 23u
// Eject queue (M7 bodies: cells displaced by bodies, debris), drained into
// particles; layout in shaders/sim/bodies/bodies.glsl.
#define SLOT_BUF_EJECT 4u
#define EJECT_CAPACITY 16384u
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
// Material table (storage buffer at SLOT_BUF_MATERIALS, 256 entries).
// 32 words = 128 bytes per material, std430. Byte layout, little endian, is
// the Zig extern struct `MaterialGpu` in src/sim/materials.zig; keep both in
// sync (tests check the offsets). Temperatures are temperature bytes;
// material references are ids with MATERIAL_NONE = no transition.
//   w0  move     phase | dispersion<<8 | slide<<16 | vertical_chance<<24
//   w1  density  density(16) | sort_key<<16
//   w2  flags    MATERIAL_FLAG_*
//   w3  misc0    solver | health<<8 | conductivity<<16 | emissive<<24
//   w4  misc1    lifetime(16) | decays_to<<16 | initial_state<<24
//   w5  misc2    spawn_temp | emits_heat<<8 | impact<<16 | blast_response<<24
//   w6  misc3    blast_threshold(16) | drag<<16 | ramp_len<<24
//   w7  change0  melt_at | melt_to<<8 | freeze_at<<16 | freeze_to<<24
//   w8  change1  boil_at | boil_to<<8 | ignite_at<<16 | burn_to<<24
//   w9  burn     burn_ticks(16) | smoke_to<<16 | glow_from<<24
//   w10 glow     glow_to | reserved
//   w11-15       reserved
//   w16-23 ramp  RGBA8 colors, R in the low byte; ramp_len of them valid
//   w24 air      pressure_event(16) | rubble<<16 | air_flags<<24 (MATERIAL_AIR_*)
//   w25-31       reserved
// ---------------------------------------------------------------------------
#define MATERIAL_COUNT 256u
#define MATERIAL_WORDS 32u
#define MATERIAL_NONE 255u
#define MATERIAL_AIR 0u
#define MATERIAL_RAMP_WORD 16u
#define MATERIAL_RAMP_MAX 8u

#define PHASE_STATIC 0u
#define PHASE_POWDER 1u
#define PHASE_LIQUID 2u
#define PHASE_GAS 3u

#define MATERIAL_FLAG_CONDUCTIVE 0x1u
#define MATERIAL_FLAG_TRANSLUCENT 0x2u
#define MATERIAL_FLAG_FLAMMABLE 0x4u
#define MATERIAL_FLAG_EMISSIVE 0x8u

// Movement ordering: a cell sinks into a fluid cell below it with a lower key.
#define SORT_KEY_AIR 256u
#define SORT_KEY_DENSE_BASE 512u
#define SORT_KEY_STATIC 65535u

struct MaterialGpu {
    uint move;
    uint density;
    uint flags;
    uint misc0;
    uint misc1;
    uint misc2;
    uint misc3;
    uint change0;
    uint change1;
    uint burn;
    uint glow;
    uint reserved0[5];
    uint ramp[8];
    uint air;
    uint reserved1[7];
};

HEXE_BUFFER(MaterialBlock, readonly, MaterialGpu materials[];, g_material_tables);
#define MATERIALS g_material_tables[SLOT_BUF_MATERIALS].materials

uint mat_phase(uint move) { return move & 0xffu; }
uint mat_dispersion(uint move) { return (move >> 8) & 0xffu; }
uint mat_slide(uint move) { return (move >> 16) & 0xffu; }
uint mat_vertical_chance(uint move) { return move >> 24; }
uint mat_density(uint density) { return density & 0xffffu; }
uint mat_sort_key(uint density) { return density >> 16; }
uint mat_spawn_temp(MaterialGpu m) { return m.misc2 & 0xffu; }
uint mat_initial_state(MaterialGpu m) { return m.misc1 >> 24; }
uint mat_ramp_len(MaterialGpu m) { return m.misc3 >> 24; }
uint mat_health(MaterialGpu m) { return (m.misc0 >> 8) & 0xffu; }
uint mat_blast_response(MaterialGpu m) { return m.misc2 >> 24; }
uint mat_blast_threshold(MaterialGpu m) { return m.misc3 & 0xffffu; }
uint mat_drag(MaterialGpu m) { return (m.misc3 >> 16) & 0xffu; }
uint mat_pressure_event(MaterialGpu m) { return m.air & 0xffffu; }
uint mat_rubble(MaterialGpu m) { return (m.air >> 16) & 0xffu; }
uint mat_air_flags(MaterialGpu m) { return m.air >> 24; }

// MaterialGpu.misc2 blast_response values.
#define BLAST_NONE 0u
#define BLAST_FLY 1u
#define BLAST_CHIP 2u
#define BLAST_BREAK 3u
// air_flags bits (w24 bits 24-31).
#define MATERIAL_AIR_FEEDS_AIR 0x1u

// A freshly spawned cell of `material` (commands, reactions).
uint spawn_cell(uint material, uint variant) {
    MaterialGpu m = MATERIALS[material];
    return cell_make(material, mat_spawn_temp(m), mat_initial_state(m), 0u, variant);
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
//   CMD_FILL_CIRCLE: center (x0, y0), radius x1 (inclusive: d^2 <= r^2)
//   CMD_FILL_RECT:   [x0, x1) x [y0, y1), unwrapped coordinates
// Coordinates are world pixels and wrap on the torus.
// ---------------------------------------------------------------------------
#define CMD_FILL_CIRCLE 1u
#define CMD_FILL_RECT 2u
// Not a grid edit: consumed by the air field (src/sim/air.zig). Center
// (x0, y0), radius x1 (pixels), steps y1; material = density delta as f32
// bits, flags = radial momentum as f32 bits.
#define CMD_INJECT_PRESSURE 3u
#define CMD_FLAG_ONLY_AIR 0x1u
#define CMD_COVERAGE_SHIFT 8u
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
// Air field (M5), docs/04-fluids.md "Air field", src/sim/air.zig. The
// lattice is AIR_SIZE^2 cells of 2x2 pixels; air tiles are AIR_TILE^2
// lattice cells, so an air tile covers exactly one grid activity tile and
// both use the same tile coordinates. Helpers for other passes live in
// shaders/sim/air/air_api.glsl.
//   SLOT_IMG_SOLID_COARSE  r8ui:   static/body-owned pixels per 2x2 block, 0-4
//   SLOT_IMG_LIQUID_COARSE r8ui:   liquid pixels per 2x2 block, 0-4
//   SLOT_IMG_AIR           rgba32f: x density (ambient 1.0), yz velocity in
//                                   pixels per tick, w 1.0 on wall cells
//   SLOT_IMG_AIR_SOURCE    r32ui:  per lattice cell mass to add next step,
//                                   int32 fixed point (AIR_MASS_ONE = 1.0)
//   SLOT_IMG_DEBUG_OVERLAY rgba8:  debug view (air density and velocity)
// ---------------------------------------------------------------------------
#define AIR_SIZE 1024u
#define AIR_MASK 1023u
#define AIR_TILE 16u
#define AIR_TILES_PER_SIDE 64u
#define AIR_WAKE_TICKS 4u
#define AIR_TILE_ACTIVE_OFFSET 4096u
#define AIR_MASS_ONE 65536u
// Mass a feeds_air gas pixel adds when created (removes when consumed).
#define AIR_GAS_CELL_MASS 32768u
// Blast ejects (SLOT_BUF_BLAST_EJECTS) and air events (SLOT_BUF_AIR_EVENTS):
// header {count, capacity, dropped, tick}, then records.
#define BLAST_EJECT_WORDS 6u
#define BLAST_EJECT_CAPACITY 65536u
#define BLAST_KIND_FLY 1u
#define BLAST_KIND_CHIP 2u
#define BLAST_KIND_BREAK 3u
#define AIR_EVENT_WORDS 4u
#define AIR_EVENT_CAPACITY 1024u
#define AIR_EVENT_PRESSURE 1u

#endif
