// Margolus block core shared by the movement rules: a 2x2 block of cells,
//   0 1      0 = (x, y)      1 = (x+1, y)
//   2 3      2 = (x, y+1)    3 = (x+1, y+1)       (+y is down, gravity)
// with each cell's material movement word and sort key cached, and a local
// moved flag so no cell moves twice in one substep. Mirrored exactly by
// src/sim/reference/grid.zig.
#ifndef HEXE_BLOCK_GLSL
#define HEXE_BLOCK_GLSL

struct Block {
    uint cell[4];
    uint move[4];
    uint key[4];
    bool moved[4];
};

// Offset sequence, indexed by substep & 3. Vertical offset alternates every
// substep so falling reaches one pixel per substep
// (docs/decisions/09-margolus-rules.md).
uvec2 margolus_offset(uint substep) {
    uint s = substep & 3u;
    return uvec2(s == 1u || s == 2u ? 1u : 0u, s & 1u);
}

void block_cache(inout Block b, int i) {
    uint m = cell_material(b.cell[i]);
    b.move[i] = MATERIALS[m].move;
    b.key[i] = MATERIALS[m].sort_key;
    // Particle-backed cells belong to the liquid solver: static here.
    if (cell_has(b.cell[i], CELL_FLAG_PARTICLE)) {
        b.move[i] = PHASE_STATIC;
        b.key[i] = SORT_KEY_STATIC;
    }
    b.moved[i] = false;
}

uint block_phase(Block b, int i) { return mat_phase(b.move[i]); }
bool block_is_air(Block b, int i) { return cell_material(b.cell[i]) == MATERIAL_AIR; }
bool block_is_fluid(Block b, int i) {
    uint p = block_phase(b, i);
    return p == PHASE_LIQUID || p == PHASE_GAS;
}

void block_swap(inout Block b, int i, int j) {
    uint c = b.cell[i]; b.cell[i] = b.cell[j]; b.cell[j] = c;
    uint m = b.move[i]; b.move[i] = b.move[j]; b.move[j] = m;
    uint k = b.key[i]; b.key[i] = b.key[j]; b.key[j] = k;
    b.moved[i] = true;
    b.moved[j] = true;
}

// `upper` may trade places with `lower` (below it, straight or diagonal):
// neither moved yet, upper is not static, lower is a fluid (liquid, gas or
// air) and upper is heavier in sort-key order. Powders and statics are never
// displaced; gases rise because air outranks every gas.
bool block_can_sink(Block b, int upper, int lower) {
    return !b.moved[upper] && !b.moved[lower] && block_phase(b, upper) != PHASE_STATIC &&
        block_is_fluid(b, lower) && b.key[upper] > b.key[lower];
}

// Density ordering along a column: heavier falls, lighter rises. The mover
// is the cell whose motion this is (a rising gas is the lower cell).
void rule_vertical(inout Block b, int upper, int lower, uint rnd8) {
    if (!block_can_sink(b, upper, lower)) return;
    uint mover = block_phase(b, upper) == PHASE_GAS ? b.move[lower] : b.move[upper];
    if (chance8(rnd8, mat_vertical_chance(mover))) block_swap(b, upper, lower);
}

uint dispersion_chance(uint dispersion) { return min(dispersion * 32u, 255u); }

#endif
