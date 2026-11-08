// Rigid-body rasterization (M7): shared declarations for the passes in
// shaders/sim/bodies/. Host side: src/sim/bodies_gpu.zig, which mirrors every
// numeric #define here (test "bodies.glsl mirror") and the struct layouts
// (comptime offset checks). See docs/decisions/90-bodies-gpu-rasterization.md.
#ifndef HEXE_BODIES_GLSL
#define HEXE_BODIES_GLSL

#include "common.glsl"

// Pass modes of raster.comp. Every mode walks the same work items: one 16x16
// workgroup per 16x16 block of a body's world-space bounding box.
// cells matching the bitmap (static, unflagged) -> air
#define BODY_MODE_EXTRACT 0u
// claim image -> ~0 under the bitmap
#define BODY_MODE_RESET 1u
// atomicMin(claim, stamp | id) where the body may write
#define BODY_MODE_CLAIM 2u
// claim winners write body-owned cells, displace, count overlaps
#define BODY_MODE_WRITE 3u
// last tick's cells of this body not rewritten this tick -> air
#define BODY_MODE_CLEAR 4u

// Claim value: (tick & BODY_STAMP_MASK) << BODY_ID_BITS | id. Ids are body
// slot index + 1, so 0 never claims and ~0 is "unclaimed".
#define BODY_ID_BITS 13u
#define BODY_ID_MASK 0x1fffu
#define BODY_STAMP_MASK 0x7ffffu

// Point writes (points.comp). `packed` = material | expect << 8 | mode << 16.
// write where the cell is air or gas, not body-owned
#define POINT_MODE_INTO_AIR 0u
// write where the cell is unflagged `expect`
#define POINT_MODE_REPLACE 1u
// append the cell to the eject queue with `vel`
#define POINT_MODE_EJECT 2u

// Per-region statistics words (stats buffer), then one overlap counter per
// instance from BODY_STAT_INSTANCE_BASE.
#define BODY_STAT_WRITTEN 0u
#define BODY_STAT_OVERLAP_STATIC 1u
#define BODY_STAT_OVERLAP_BODY 2u
#define BODY_STAT_DISPLACED 3u
#define BODY_STAT_CLEARED 4u
#define BODY_STAT_EXTRACTED 5u
#define BODY_STAT_POINTS 6u
#define BODY_STAT_FALLBACK_PLACED 7u
#define BODY_STAT_FALLBACK_DROPPED 8u
#define BODY_STAT_EJECT_OVERFLOW 9u
#define BODY_STAT_INSTANCE_BASE 16u

// Longest walk (px) of the eject fallback looking for air above a displaced cell.
#define EJECT_FALLBACK_WALK 384u

#define SALT_BODY_VARIANT 0xb0d1u
#define SALT_POINT_VARIANT 0x9017u

// One body as uploaded for this tick, 64 bytes (`BodyInstance` in Zig).
// The bounding box origin is aligned to 16 so every workgroup lies in one
// activity tile. Bitmap coordinates of the center of world pixel
// (aabb.x + i, aabb.y + j) are, in 16.16 fixed point,
//   bx = l0.x + i * rot.x + j * rot.y,   by = l0.y - i * rot.y + j * rot.x
// with rot = (cos, sin) * 65536: integer math, no float in the grid write.
struct BodyInstance {
    ivec2 aabb_origin; // unwrapped world px, multiple of 16
    uint aabb_size; // w | h << 16
    uint id; // body id (slot + 1), stored in the owner image
    ivec2 l0;
    ivec2 rot;
    uint bitmap_size; // w | h << 16
    uint atlas_offset; // byte offset of the bitmap in the atlas
    uint flags;
    uint index; // instance index in this tick's upload (per-instance stats)
    vec2 velocity; // px/s, for displaced cells
    float angular_velocity;
    uint pad;
};

struct BodyPoint {
    ivec2 p; // unwrapped world px
    uint packed;
    uint vel; // packHalf2x16(velocity px/s)
};

HEXE_BUFFER(BodyInstanceBlock, readonly, BodyInstance instances[];, g_body_instances);
HEXE_BUFFER(BodyItemBlock, readonly, uvec2 items[];, g_body_items);
HEXE_BUFFER(BodyPointBlock, readonly, BodyPoint points[];, g_body_points);
HEXE_BUFFER(BodyAtlasBlock, readonly, uint8_t px[];, g_body_atlas);
HEXE_BUFFER(BodyStatsBlock, , uint words[];, g_body_stats);

// ---------------------------------------------------------------------------
// Eject queue at SLOT_BUF_EJECT (common.glsl): cells pushed out of the grid
// by bodies (displaced liquid, powder, gas) and debris requested by the CPU
// (sparks). The particles layer is meant to drain it into ballistic
// particles; until it does, eject_fallback.comp reinserts each cell at the
// first air cell above it (docs/decisions/91-bodies-gpu-eject-queue.md).
// ---------------------------------------------------------------------------
struct EjectEntry {
    ivec2 p; // world px (wrapped)
    uint cell; // full cell word, flags cleared
    uint vel; // packHalf2x16(velocity px/s)
};

HEXE_BUFFER(EjectBlock, , uint count; uint dropped; uint pad0; uint pad1; EjectEntry items[];, g_eject_queue);
#define EJECT g_eject_queue[SLOT_BUF_EJECT]

void bodies_eject_cell(ivec2 p, uint c, vec2 velocity) {
    uint i = atomicAdd(EJECT.count, 1u);
    if (i < EJECT_CAPACITY) {
        EJECT.items[i].p = wrap_coord(p);
        EJECT.items[i].cell = c & ~(CELL_FLAG_BODY | CELL_FLAG_PARTICLE | CELL_FLAG_MOVED);
        EJECT.items[i].vel = packHalf2x16(velocity);
    } else {
        atomicAdd(EJECT.dropped, 1u);
    }
}

uint body_cell_phase(uint c) { return mat_phase(MATERIALS[cell_material(c)].move); }

// A cell a body may take over: not body-owned and not a static solid
// (air, gas, liquid, powder; particle-backed liquid included).
bool body_claimable(uint c) {
    return !cell_has(c, CELL_FLAG_BODY) && body_cell_phase(c) != PHASE_STATIC;
}

#endif
