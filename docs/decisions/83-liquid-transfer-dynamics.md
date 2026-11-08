# Liquid transfers and dynamics: FLIP 0.95, drags, density correction, advection

**Context**: the spec fixes FLIP/APIC, the 0.95/0.05 blend, RK2 advection,
gravity 196 px/s^2 and pushout from solids; everything else had to be
chosen, mostly by running the scenarios.

**Decision**:
- Units: positions in pixels, velocities px/s, grid in cells of 2 px,
  dt = 1/60 s. Bilinear (tent) kernels for P2G and G2P; APIC affine C is
  the gradient of the interpolated grid velocity (multilinear APIC).
- Blend: v = 0.95 (v_p + u_new - u_old) + 0.05 u_new at the particle. Pure
  PIC (0.0) was tried: the resting-pool noise was the same, so the blend is
  not the noise source.
- Advection: RK2 through the grid velocity, the midpoint sampled from faces
  that carry liquid weight (else the particle's own velocity), then marched
  through the pixel grid one pixel per step, x then y, zeroing a blocked
  component: particles slide along walls and never cross a 1-px wall. Speed
  capped at 480 px/s (8 px per tick, the grid's own limit). A particle found
  inside an obstacle moves to the nearest free pixel within 2 that is not
  behind a wall, else dies.
- Settling drag: `settle_rate` (4/s) at rest, fading linearly to zero at
  `settle_speed` (64 px/s), times `band_factor` (3) for liquid resting on
  sleeping liquid or a solid (the "soft band" of docs/04-fluids.md "Hybrid
  pools"). Without it a shallow pool keeps sloshing (a 216 px basin 16 px
  deep has a slosh period near 8 s) and never sleeps; with linear drag
  strong enough to settle it, pressure-driven flows crawl (tested: the U-tube
  barely drained at 2/s). Fast flows (waves, pours) are untouched.
- Density correction: a cell holding n > 4 liquid particles gets a
  divergence target of 32 (n - 4) / 4 (divergence.comp), so the projection
  pushes particles out of over-full cells. Under-full cells cannot be
  corrected (p >= 0): splashing water stays somewhat foamy until it settles.
- Mode switches: a liquid particle with no other liquid particle in the 3x3
  cells around it becomes ballistic (gravity only, no transfers); a
  ballistic one becomes liquid near liquid particles or when it hits
  sleeping water (and wakes it).

**Alternatives**: acceleration-gated drag (drag only where the grid
acceleration is small): per-particle acceleration noise at rest is about
100 px/s^2, larger than the 30 px/s^2 of a slow equalizing flow; an 8x8
block average did not separate them either (surface ripples have large
real accelerations). Dropped.

**Consequences**: water at rest loses a little energy per tick by design;
sloshing dies within a few seconds. Tunables are in `liquid.Params` and
settable with `--liquid-param name=value`.
