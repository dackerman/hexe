// D2Q9 lattice Boltzmann definitions for the air field passes.
// Directions (pixel space, +y down):
//   6 2 5        0 rest, 1 +x, 2 +y, 3 -x, 4 -y,
//   3 0 1        5 (+1,+1), 6 (-1,+1), 7 (-1,-1), 8 (+1,-1)
//   7 4 8
// Distributions are 9 planes of AIR_SIZE^2 f32 (structure of arrays,
// x fastest), so neighboring threads read neighboring words.
#ifndef HEXE_LBM_GLSL
#define HEXE_LBM_GLSL

const ivec2 LBM_E[9] = ivec2[9](ivec2(0, 0), ivec2(1, 0), ivec2(0, 1), ivec2(-1, 0), ivec2(0, -1),
    ivec2(1, 1), ivec2(-1, 1), ivec2(-1, -1), ivec2(1, -1));
const float LBM_W[9] = float[9](4.0 / 9.0, 1.0 / 9.0, 1.0 / 9.0, 1.0 / 9.0, 1.0 / 9.0,
    1.0 / 36.0, 1.0 / 36.0, 1.0 / 36.0, 1.0 / 36.0);
const int LBM_OPP[9] = int[9](0, 3, 4, 1, 2, 7, 8, 5, 6);

// Node word (private r32ui image, written by prep.comp once per tick):
//   bits 0-8   bit i set: the pull source c - e_i is a wall (bounce back)
//   bit 9      this cell is a wall
//   bit 10     pixels of this wall cell were removed by the blast this tick:
//              if it becomes fluid, it does not draw its air from its
//              neighbors (no vacuum where debris was thrown out)
//   bits 16-31 vertical body force (f16, lattice units, +y down)
#define NODE_WALL 0x200u
#define NODE_BLASTED 0x400u

HEXE_BUFFER(AirDistBlock, , float f[];, g_air_dist);

// Diagonal direction index of (ex, ey), both +-1.
int lbm_diag(int ex, int ey) { return ey > 0 ? (ex > 0 ? 5 : 6) : (ex > 0 ? 8 : 7); }

uint lbm_index(int i, ivec2 c) { return uint(i) * (AIR_SIZE * AIR_SIZE) + uint(c.y) * AIR_SIZE + uint(c.x); }

float lbm_feq(int i, float rho, vec2 u) {
    float eu = dot(vec2(LBM_E[i]), u);
    return LBM_W[i] * rho * (1.0 + 3.0 * eu + 4.5 * eu * eu - 1.5 * dot(u, u));
}

ivec2 air_wrap(ivec2 c) { return ivec2(uvec2(c) & uvec2(AIR_MASK)); }

// Window-local lattice coordinate: the open edge of the air field is at the
// window seam (docs/decisions/71-air-boundaries.md), not at the torus edge.
ivec2 air_local(ivec2 c, ivec2 seam) { return ivec2(uvec2(c - seam) & uvec2(AIR_MASK)); }
bool air_inside(ivec2 local) { return all(greaterThanEqual(local, ivec2(0))) && all(lessThan(local, ivec2(AIR_SIZE))); }

#endif
