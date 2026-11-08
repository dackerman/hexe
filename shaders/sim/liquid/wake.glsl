// Wake hook for every pass that disturbs liquid (docs/04-fluids.md "Wake"):
// a ballistic particle landing in liquid, a body overlapping it, a pressure
// pulse. Include this file and call
//
//     liquid_wake_at(pixel, hops);
//
// The sleeping solver-liquid cell at `pixel` (if it is one) becomes a
// particle in the next liquid wake pass, and the wake spreads `hops - 1`
// more pixels, one per tick, until the per-tick wake budget runs out.
// Safe to call from any compute pass, any number of times (atomic OR on a
// thermometer code, so the result does not depend on call order). Marks the
// pixel's activity tile so the wake pass visits it. Pixels that are not
// sleeping solver liquid are ignored by the wake pass.
#ifndef HEXE_LIQUID_WAKE_GLSL
#define HEXE_LIQUID_WAKE_GLSL
#include "common.glsl"

#define LIQUID_WAKE g_uimages[SLOT_IMG_LIQUID_WAKE]

uint liquid_wake_code(uint hops) { return (1u << clamp(hops, 1u, 8u)) - 1u; }

void liquid_wake_at(ivec2 pixel, uint hops) {
    ivec2 p = wrap_coord(pixel);
    imageAtomicOr(LIQUID_WAKE, p, liquid_wake_code(hops));
    mark_tile_and_neighbors(uvec2(p) >> TILE_SHIFT);
}

#endif
