// Interaction class: powder. Falls by density ordering (rule_vertical) and
// slides diagonally down with the material's slide chance.
#ifndef HEXE_POWDER_GLSL
#define HEXE_POWDER_GLSL
#include "sim/grid/block.glsl"

uint powder_diagonal_chance(uint move) { return mat_slide(move); }

#endif
