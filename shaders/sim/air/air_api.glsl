// Air field API for any pass (docs/04-fluids.md "Air field",
// src/sim/air.zig). Include after common.glsl.
//
//   air_field(px)            rgba32f at the lattice cell over pixel px:
//                            x density (ambient 1.0), yz velocity in pixels
//                            per tick, w 1.0 if the cell is a wall
//   air_velocity(px)         the velocity alone, pixels per tick
//   air_emit_mass(px, m)     add m (AIR_MASS_ONE = one lattice cell of
//                            ambient air; negative removes) at pixel px,
//                            applied in the next LBM step; wakes the tile
//   air_gas_created(px, mat) call when a pass turns a cell into `mat`: adds
//                            AIR_GAS_CELL_MASS if mat has feeds_air
//   air_gas_removed(px, mat) the reverse, when such a gas cell disappears
//   air_mark_tile(t)         keep air tile t (= grid tile t) and its
//                            neighbors simulated for AIR_WAKE_TICKS ticks
// Integer atomics only; safe from any number of threads.
#ifndef HEXE_AIR_API_GLSL
#define HEXE_AIR_API_GLSL

layout(set = 0, binding = BINDING_STORAGE_IMAGES, r8ui) uniform uimage2D g_u8_images[];
layout(set = 0, binding = BINDING_STORAGE_IMAGES, rgba32f) uniform image2D g_f4_images[];
layout(set = 0, binding = BINDING_STORAGE_IMAGES, rgba8) uniform image2D g_rgba8_images[];

#define SOLID_COARSE g_u8_images[SLOT_IMG_SOLID_COARSE]
#define LIQUID_COARSE g_u8_images[SLOT_IMG_LIQUID_COARSE]
#define AIR_FIELD g_f4_images[SLOT_IMG_AIR]
#define AIR_SOURCE g_uimages[SLOT_IMG_AIR_SOURCE]
#define DEBUG_OVERLAY g_rgba8_images[SLOT_IMG_DEBUG_OVERLAY]

HEXE_BUFFER(AirTileMarkBlock, , uint8_t marks[];, g_air_tile_marks);
HEXE_BUFFER(AirTileListBlock, , uint dispatch_x; uint dispatch_y; uint dispatch_z; uint count_copy; uint tiles[];, g_air_tile_lists);
#define AIR_TILE_MARKS g_air_tile_marks[SLOT_BUF_AIR_TILE_MARKS].marks
#define AIR_TILE_LIST g_air_tile_lists[SLOT_BUF_AIR_TILE_LIST]

ivec2 air_cell_of(ivec2 px) { return ivec2((uvec2(px) & uvec2(WORLD_MASK)) >> 1u); }
uint air_tile_index(uvec2 t) { return (t.y & (AIR_TILES_PER_SIDE - 1u)) * AIR_TILES_PER_SIDE + (t.x & (AIR_TILES_PER_SIDE - 1u)); }

void air_mark_tile(uvec2 t) {
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            AIR_TILE_MARKS[air_tile_index(uvec2(ivec2(t) + ivec2(dx, dy)))] = uint8_t(AIR_WAKE_TICKS);
        }
    }
}

vec4 air_field(ivec2 px) { return imageLoad(AIR_FIELD, air_cell_of(px)); }
vec2 air_velocity(ivec2 px) { return air_field(px).yz; }

void air_emit_mass(ivec2 px, int amount) {
    ivec2 c = air_cell_of(px);
    imageAtomicAdd(AIR_SOURCE, c, uint(amount));
    air_mark_tile(uvec2(c) / AIR_TILE);
}

void air_gas_created(ivec2 px, uint material) {
    if ((mat_air_flags(MATERIALS[material]) & MATERIAL_AIR_FEEDS_AIR) != 0u) air_emit_mass(px, int(AIR_GAS_CELL_MASS));
}

void air_gas_removed(ivec2 px, uint material) {
    if ((mat_air_flags(MATERIALS[material]) & MATERIAL_AIR_FEEDS_AIR) != 0u) air_emit_mass(px, -int(AIR_GAS_CELL_MASS));
}

#endif
