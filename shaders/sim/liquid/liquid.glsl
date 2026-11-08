// Liquid solver (docs/04-fluids.md "Liquid solver"): shared definitions for
// every pass under shaders/sim/liquid/. Host side: src/sim/liquid.zig, which
// mirrors every #define below (test "liquid.glsl mirror").
//
// Resources are private buffers allocated at consecutive bindless slots
// starting at pc.buf; LQ_BUF_* are offsets from that base. Particle arrays
// are structure of arrays in two sets (A/B) ping-ponged by the per-tick
// reorder: `pc.src` is the set holding last tick's particles, `pc.dst` the
// set written by this tick's sort and used by every later pass.
//
// Particle layout (the shared particle buffer's SoA, docs/04-fluids.md):
//   position  vec2  world pixels, [0, WORLD_SIZE)
//   velocity  vec2  pixels per second
//   affine    vec4  APIC matrix rows: (du/dx, du/dy, dv/dx, dv/dy), in
//                   (px/s) per grid cell
//   info      uint  material 0-7 | mode 8-9 | overlap 10-13 | rest 14-19 |
//                   variant 20-23 | temperature 24-31
//   binding   uint  pixel this particle owns in the cell image
//                   (x | y << 16), or LQ_NONE
#ifndef HEXE_LIQUID_SOLVER_GLSL
#define HEXE_LIQUID_SOLVER_GLSL
#include "common.glsl"

// ---- grid ----
#define LQ_GRID 1024u
#define LQ_GRID_MASK 1023u
#define LQ_GRID_SHIFT 10u
#define LQ_LEVELS 6u
#define LQ_NONE 0xffffffffu
#define LQ_BIND_PENDING 0x80000000u

// ---- private buffers, offsets from pc.buf ----
#define LQ_BUF_STATE 0u
#define LQ_BUF_POS 1u
#define LQ_BUF_VEL 3u
#define LQ_BUF_AFF 5u
#define LQ_BUF_INFO 7u
#define LQ_BUF_BIND 9u
#define LQ_BUF_BIN_OF 11u
#define LQ_BUF_BIN_COUNT 12u
#define LQ_BUF_BIN_SCAN 13u
#define LQ_BUF_BIN_SUMS 14u
#define LQ_BUF_SORTED 15u
#define LQ_BUF_U 16u
#define LQ_BUF_V 17u
#define LQ_BUF_U_OLD 18u
#define LQ_BUF_V_OLD 19u
#define LQ_BUF_UW 20u
#define LQ_BUF_VW 21u
#define LQ_BUF_MG_TYPE 22u
#define LQ_BUF_MG_P 23u
#define LQ_BUF_MG_B 24u
#define LQ_BUF_TILE_COUNT 25u
#define LQ_BUF_TILE_SCAN 26u
#define LQ_BUF_TILE_SUMS 27u
#define LQ_BUF_COUNT 28u

// ---- STATE words ----
// 0 particle count, 1-3 particle dispatch, 4-6 gated 1024^2 cell dispatch
// (16x16 groups), 7-9 gated bin scan dispatch, then per multigrid level l
// two gated dispatches: one 16x16 group per 16x16 cells (LQ_ST_ARGS_MG + 6l)
// and one group per 32x32 tile of one checkerboard color (+3).
#define LQ_ST_COUNT 0u
#define LQ_ST_ARGS_PARTICLES 1u
#define LQ_ST_ARGS_CELLS 4u
#define LQ_ST_ARGS_SCAN 7u
#define LQ_ST_ARGS_MG 10u
#define LQ_ST_SPAWNED 52u
#define LQ_ST_REFUSED 53u
#define LQ_ST_KILLED 54u
#define LQ_ST_SLEPT 55u
#define LQ_ST_MERGED 56u
#define LQ_ST_BALLISTIC 57u
#define LQ_ST_ALIVE 58u
#define LQ_ST_CANDIDATES 59u
#define LQ_ST_GRID_VALID 60u
// Totals since start (never reset): merged, killed (lift + stuck), slept.
#define LQ_ST_TOTAL_MERGED 61u
#define LQ_ST_TOTAL_KILLED 62u
#define LQ_ST_TOTAL_SLEPT 63u
// Moving cellular solver-liquid cells in bodies this tick (wake mode 0).
#define LQ_ST_MOVED 46u
// Wake decisions by trigger this tick (debug): request, powder, landing,
// flow (momentum), flow (imbalance).
#define LQ_ST_TRIGGERS 47u
// Ticks left of solving after the last activity (finalize).
#define LQ_ST_GRACE 64u
#define LQ_ST_WORDS 80u

// ---- particle info word ----
#define LQ_MODE_DEAD 0u
#define LQ_MODE_LIQUID 1u
#define LQ_MODE_BALLISTIC 2u
#define LQ_MATERIAL_SOLVER_FLIP 1u
// Ticks without a pixel before an extra particle is merged (deleted).
#define LQ_MERGE_TICKS 15u

// ---- multigrid cell word: type 0-1 | W_left 8-15 | W_top 16-23 | liquid particles 24-31 ----
// Face weights count open half-faces: at the finest level a face between two
// cells spans two pixel rows (columns), each open when both pixels next to it
// are free; coarse faces sum their two fine faces (Galerkin aggregation).
#define LQ_AIR 0u
#define LQ_FLUID 1u
#define LQ_SOLID 2u

// ---- wake mask (SLOT_IMG_LIQUID_WAKE): thermometer-coded hop counts ----
// byte 0: requests from other passes (liquid_wake_at), consumed next wake pass
// bytes 1, 2: spread from cells woken last tick, ping-pong by tick parity
#define LQ_WAKE_HOPS_COMMAND 3u
#define LQ_WAKE_HOPS_POWDER 4u
#define LQ_WAKE_HOPS_PARTICLE 2u
#define LQ_WAKE_HOPS_FLOW 1u

layout(push_constant) uniform PC {
    uint buf; // first private buffer slot
    uint overlay; // RGBA8 overlay image slot (debug), or LQ_NONE
    uint tick;
    uint src; // particle set holding last tick's particles
    uint dst; // particle set written by the sort
    uint level; // multigrid level / scan block count / command index
    uint mode; // pass variant
    uint n; // element count (scan), or wake budget
    uint cap; // particle capacity
    uint flags; // LQ_PC_*
    ivec2 box_origin; // wake_commands: box origin (multiple of 16)
    uvec2 box_size;
    float dt;
    float gravity; // px/s^2, +y down
    float flip; // FLIP fraction of the FLIP/PIC blend
    float sleep_speed; // px/s
    uint sleep_ticks;
    float wake_speed; // px/s
    float max_speed; // px/s
    float correction; // multigrid coarse-correction scale
    float damping; // 1/s, linear drag on liquid-mode particles
    float density_gain; // divergence target per excess particle (divergence.comp)
    float settle_rate; // 1/s drag at zero speed, fading to 0 at settle_speed
    float settle_speed; // px/s
    float imbalance_accel; // px/s^2: sleeping liquid accelerated faster than this wakes
    float push_speed; // px/s: a liquid particle pushed into sleeping liquid this fast wakes it
    float band_factor; // settling drag multiplier on top of sleeping liquid or solids
} pc;

#define LQ_PC_MARK_TILES 1u
#define LQ_PC_OVERLAY 2u
// Wake decides but does not spawn: requests are kept for a later tick
// (drain and idle modes, src/sim/liquid.zig Mode).
#define LQ_PC_NO_SPAWN 4u

HEXE_BUFFER(LqU32Block, , uint d[];, lq_u32);
HEXE_BUFFER(LqF32Block, , float d[];, lq_f32);
HEXE_BUFFER(LqVec2Block, , vec2 d[];, lq_vec2);
HEXE_BUFFER(LqVec4Block, , vec4 d[];, lq_vec4);

#define LQ_STATE lq_u32[pc.buf + LQ_BUF_STATE].d
#define LQ_POS(s) lq_vec2[pc.buf + LQ_BUF_POS + (s)].d
#define LQ_VEL(s) lq_vec2[pc.buf + LQ_BUF_VEL + (s)].d
#define LQ_AFF(s) lq_vec4[pc.buf + LQ_BUF_AFF + (s)].d
#define LQ_INFO(s) lq_u32[pc.buf + LQ_BUF_INFO + (s)].d
#define LQ_BIND(s) lq_u32[pc.buf + LQ_BUF_BIND + (s)].d
#define LQ_U32(k) lq_u32[pc.buf + (k)].d
#define LQ_F32(k) lq_f32[pc.buf + (k)].d

layout(set = 0, binding = BINDING_STORAGE_IMAGES, rgba8) uniform writeonly image2D lq_rgba8_images[];

// ---- info accessors ----
uint info_material(uint f) { return f & 0xffu; }
uint info_mode(uint f) { return (f >> 8) & 3u; }
uint info_overlap(uint f) { return (f >> 10) & 15u; }
uint info_rest(uint f) { return (f >> 14) & 63u; }
uint info_variant(uint f) { return (f >> 20) & 15u; }
uint info_temp(uint f) { return f >> 24; }
uint info_with_mode(uint f, uint m) { return bitfieldInsert(f, m, 8, 2); }
uint info_with_overlap(uint f, uint o) { return bitfieldInsert(f, min(o, 15u), 10, 4); }
uint info_with_rest(uint f, uint r) { return bitfieldInsert(f, min(r, 63u), 14, 6); }
uint info_with_temp(uint f, uint t) { return bitfieldInsert(f, t, 24, 8); }
uint info_make(uint material, uint mode, uint variant, uint temp) {
    return (material & 0xffu) | ((mode & 3u) << 8) | ((variant & 15u) << 20) | ((temp & 0xffu) << 24);
}

// ---- cells ----
uint mat_phase_of(uint m) { return mat_phase(MATERIALS[m].move); }
// A pixel a particle may occupy: air or gas, not owned by a body or particle.
bool cell_free(uint c) {
    return (c & (CELL_FLAG_PARTICLE | CELL_FLAG_BODY)) == 0u && mat_phase_of(cell_material(c)) == PHASE_GAS;
}
bool mat_is_flip(uint m) {
    return mat_phase_of(m) == PHASE_LIQUID && (MATERIALS[m].misc0 & 0xffu) == LQ_MATERIAL_SOLVER_FLIP;
}
// A sleeping solver liquid cell: wakes into a particle when disturbed.
bool cell_flip_plain(uint c) {
    return (c & (CELL_FLAG_PARTICLE | CELL_FLAG_BODY)) == 0u && mat_is_flip(cell_material(c));
}

// Open to liquid flow in the pressure solve: free pixels and sleeping solver
// liquid (which the solve treats as liquid at rest; see classify.comp).
bool cell_passable(uint c) { return cell_free(c) || cell_flip_plain(c); }

// A jump from p by o (|o| <= 2) does not pass through a wall: the pixel
// halfway is not an obstacle (free, liquid, awake liquid).
bool clear_path(ivec2 p, ivec2 o) {
    if (max(abs(o.x), abs(o.y)) < 2) return true;
    uint c = load_cell(p + o / 2);
    return cell_passable(c) || cell_has(c, CELL_FLAG_PARTICLE);
}

uint pack_pixel(ivec2 p) { return uint(p.x) | (uint(p.y) << 16); }
ivec2 unpack_pixel(uint b) { return ivec2(int(b & 0xffffu), int((b >> 16) & 0x7fffu)); }
ivec2 pixel_of(vec2 pos) { return wrap_coord(ivec2(floor(pos))); }
vec2 wrap_pos(vec2 p) { return mod(p, vec2(float(WORLD_SIZE))); }

// ---- grid ----
uint gidx(ivec2 c) { return (uint(c.y) & LQ_GRID_MASK) * LQ_GRID + (uint(c.x) & LQ_GRID_MASK); }
// Torus difference a - b on the 1024 grid, in (-512, 512].
vec2 gdiff(vec2 a, vec2 b) {
    vec2 d = a - b;
    return d - float(LQ_GRID) * round(d / float(LQ_GRID));
}
uint level_size(uint l) { return LQ_GRID >> l; }
// Offset of level l in the concatenated multigrid buffers.
uint level_offset(uint l) {
    uint off = 0u;
    for (uint k = 0u; k < l; k++) off += level_size(k) * level_size(k);
    return off;
}
uint lidx(uint l, ivec2 c) {
    uint n = level_size(l);
    return level_offset(l) + (uint(c.y) & (n - 1u)) * n + (uint(c.x) & (n - 1u));
}
uint mg_type(uint w) { return w & 3u; }
uint mg_wl(uint w) { return (w >> 8) & 0xffu; }
uint mg_wt(uint w) { return (w >> 16) & 0xffu; }
uint mg_liquid(uint w) { return w >> 24; }

// Exclusive prefix of element i from scan_local + scan_sums (1024 per block).
uint scan_prefix(uint scan_buf, uint sums_buf, uint i) {
    return LQ_U32(scan_buf)[i] + LQ_U32(sums_buf)[i >> 10];
}

// Mark the tile holding pixel p, and neighbors when p is on a tile edge.
void mark_pixel_tile(ivec2 p) {
    uvec2 t = uvec2(p) >> TILE_SHIFT;
    uvec2 r = uvec2(p) & (TILE_SIZE - 1u);
    if (r.x == 0u || r.y == 0u || r.x == TILE_SIZE - 1u || r.y == TILE_SIZE - 1u) {
        mark_tile_and_neighbors(t);
    } else {
        TILE_MARKS[tile_index(t)] = uint8_t(TILE_WAKE_TICKS);
    }
}

#endif
