// Pressure Poisson operator shared by the multigrid passes. At level l, for a
// fluid cell c with face weights W to its 4 neighbors (0 = closed):
//     sum_n W_n (p_c - p_n) = b_c,   p_n = 0 for air (free surface, Dirichlet)
// Closed faces (solids) drop out (Neumann). Level 0's b is minus the
// weighted velocity divergence; projecting u -= grad p then leaves the
// weighted divergence zero.
#ifndef HEXE_LIQUID_MG_GLSL
#define HEXE_LIQUID_MG_GLSL
#include "sim/liquid/liquid.glsl"

#define MG_TYPE(i) LQ_U32(LQ_BUF_MG_TYPE)[i]
#define MG_P(i) LQ_F32(LQ_BUF_MG_P)[i]
#define MG_B(i) LQ_F32(LQ_BUF_MG_B)[i]

// diag = sum of open face weights; off = sum W_n p_n over fluid neighbors.
void mg_neighbors(uint l, ivec2 c, uint w, out float diag, out float off) {
    uint wr = mg_wl(MG_TYPE(lidx(l, c + ivec2(1, 0))));
    uint wb = mg_wt(MG_TYPE(lidx(l, c + ivec2(0, 1))));
    uint wl = mg_wl(w);
    uint wt = mg_wt(w);
    diag = float(wl + wr + wt + wb);
    off = 0.0;
    if (wl != 0u) { uint i = lidx(l, c + ivec2(-1, 0)); if (mg_type(MG_TYPE(i)) == LQ_FLUID) off += float(wl) * MG_P(i); }
    if (wr != 0u) { uint i = lidx(l, c + ivec2(1, 0)); if (mg_type(MG_TYPE(i)) == LQ_FLUID) off += float(wr) * MG_P(i); }
    if (wt != 0u) { uint i = lidx(l, c + ivec2(0, -1)); if (mg_type(MG_TYPE(i)) == LQ_FLUID) off += float(wt) * MG_P(i); }
    if (wb != 0u) { uint i = lidx(l, c + ivec2(0, 1)); if (mg_type(MG_TYPE(i)) == LQ_FLUID) off += float(wb) * MG_P(i); }
}

// b - A p at a fluid cell.
float mg_residual(uint l, ivec2 c) {
    uint i = lidx(l, c);
    uint w = MG_TYPE(i);
    if (mg_type(w) != LQ_FLUID) return 0.0;
    float diag, off;
    mg_neighbors(l, c, w, diag, off);
    return MG_B(i) - (diag * MG_P(i) - off);
}

#endif
