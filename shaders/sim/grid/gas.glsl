// Interaction class: gas. The inverse of a liquid: rises through air (and
// through heavier gases) by density ordering with the material's vertical
// chance, drifts diagonally up, and spreads sideways into air by dispersion.
// Air (material 0) is a gas that never moves on its own.
#ifndef HEXE_GAS_GLSL
#define HEXE_GAS_GLSL
#include "sim/grid/block.glsl"

// `from` is a bottom cell, `to` the opposite top cell, `side` the cell beside
// `from` in its row.
void gas_diagonal_up(inout Block b, int from, int to, int side, uint rnd8) {
    if (block_phase(b, from) != PHASE_GAS || block_is_air(b, from)) return;
    if (block_phase(b, to) != PHASE_GAS || !block_is_fluid(b, side)) return;
    if (!block_can_sink(b, to, from)) return;
    if (chance8(rnd8, mat_vertical_chance(b.move[from]))) block_swap(b, from, to);
}

void gas_lateral(inout Block b, int l, int r, uint rnd8) {
    if (block_phase(b, l) != PHASE_GAS || block_phase(b, r) != PHASE_GAS) return;
    bool al = block_is_air(b, l);
    bool ar = block_is_air(b, r);
    if (al == ar) return;
    uint mover = al ? b.move[r] : b.move[l];
    if (chance8(rnd8, dispersion_chance(mat_dispersion(mover)))) block_swap(b, l, r);
}

#endif
