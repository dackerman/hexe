// Interaction class: cellular liquid. Falls by density ordering, always flows
// diagonally down when it can, and spreads sideways into gas or air with a
// chance set by dispersion.
#ifndef HEXE_LIQUID_GLSL
#define HEXE_LIQUID_GLSL
#include "sim/grid/block.glsl"

uint liquid_diagonal_chance(uint move) { return 255u; }

// Sideways move inside one row of the block. Returns true if handled.
bool liquid_lateral(inout Block b, int l, int r, uint rnd8) {
    uint pl = block_phase(b, l);
    uint pr = block_phase(b, r);
    uint mover;
    if (pl == PHASE_LIQUID && pr == PHASE_GAS) mover = b.move[l];
    else if (pr == PHASE_LIQUID && pl == PHASE_GAS) mover = b.move[r];
    else return false;
    if (chance8(rnd8, dispersion_chance(mat_dispersion(mover)))) block_swap(b, l, r);
    return true;
}

#endif
