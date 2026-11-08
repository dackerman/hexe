# Liquid pressure solve: aggregation multigrid, tile-local smoothing, p >= 0

**Context**: docs/04-fluids.md asks for geometric multigrid V-cycles with
red-black Gauss-Seidel on the 1024 grid, 4-6 cycles, cut-cell weights.

**Decision**:
- Equation per fluid cell c: `sum_n W_n (p_c - p_n) = b_c`, W the face
  weights (decision 80), p = 0 in air cells (free surface), closed faces
  drop out (solid). b = -(weighted divergence) + density correction
  (decision 83). Velocity update `u -= p_c - p_neighbor` on open faces
  touching fluid.
- Levels 1024, 512, 256, 128, 64, 32 (6). Coarsening is Galerkin for
  piecewise-constant prolongation (unsmoothed aggregation): a coarse face
  weight is the sum of its two fine faces; a coarse cell is air if any child
  is air (McAdams et al. 2010), else fluid if any child is fluid, else
  solid; restriction sums the children's residuals; prolongation adds the
  parent's correction, scaled by `correction` = 1.5 (aggregation
  under-corrects; 1.5 halves the residual after 4 cycles vs 1.0).
- Smoothing: red-black Gauss-Seidel inside 32x32 tiles in shared memory
  (`mg_smooth.comp`), `pre_smooth` = `post_smooth` = 2 iterations per
  visit, halo values from the start of the dispatch; prolongation fused
  into the post-smooth. The coarsest level (32^2) is one workgroup doing 40
  iterations. Per V-cycle: 5 x (2 smooth + 1 restrict) down, 1 coarsest,
  5 x 2 smooth up = 26 dispatches.
- 4 V-cycles per tick, warm-started from last tick's pressure.
- The finest level is projected Gauss-Seidel: p = max(p, 0). Without it,
  liquid hangs from ceilings, lids of sleeping water and wall tops by
  suction (found in the U-tube: a poured blob held up by the plain water
  above it). Liquid can push, not pull.

**Measured** (500K-particle slosh, `--liquid-test residual`, rms of
b - Ap over pressurized cells relative to rms b): 5 cycles x 1.0: 8-11%;
8 x 1.0: 4-6%; 3 x 1.0: 15%; 4 x 1.5: 5-8% (chosen); 5 x 1.5: 4-7%.
Time: about 0.25 ms per V-cycle on the RTX 4090, nearly independent of
smoothing iterations (1+1 vs 2+2 is 1.18 vs 1.28 ms for 5 cycles), so the
cost is dispatches and tile traffic, not arithmetic. Projection: 1.00 ms
per tick at 500K and 1M particles (it covers the whole grid).

**Alternatives**: bilinear prolongation / full weighting (faster
convergence per cycle, harder with cut cells and McAdams typing); PCG with
a multigrid preconditioner (global reductions per iteration); restricting
work to tiles that hold fluid (the next optimization: most of the 1024^2
grid is air in typical scenes).

**Consequences**: the residual is a few percent, enough for plausibility;
small compressions are corrected by the density term. A world with no awake
liquid runs none of this (decision 86).
