# Liquid solver: own particle arrays and obstacle pass, pending integration

**Context**: M6 runs in parallel with the particles subsystem (owner of the
unified particle buffer) and the air subsystem (owner of the coarsened solid
mask, `SLOT_IMG_SOLID_COARSE`). Neither exists on this branch.

**Decision**:
- `src/sim/liquid.zig` allocates its own particle arrays in the shared
  layout, structure of arrays: position `vec2` (world pixels), velocity
  `vec2` (px/s), affine `vec4` (APIC rows du/dx, du/dy, dv/dx, dv/dy per
  grid cell), info `u32`, binding `u32`. Two sets (A/B) ping-pong through
  the per-tick sort (`Liquid.set` is the current one). Info word: material
  0-7, mode 8-9 (0 dead, 1 liquid, 2 ballistic), overlap ticks 10-13, rest
  ticks 14-19, variant 20-23, temperature 24-31. Binding: owned pixel
  `x | y << 16` or `0xffffffff`; bit 31 is a transient "pending" mark inside
  the raster passes.
- All private buffers sit at consecutive bindless slots; shaders address
  buffer k as `pc.buf + k` (`LQ_BUF_*` in `shaders/sim/liquid/liquid.glsl`,
  mirrored and tested in `liquid.zig`).
- Obstacles are not the coarse solid mask: `classify.comp` reads the
  full-resolution cell image and computes, per 2x2-pixel cell, cut-cell face
  weights (each face is two pixel-wide halves, open when both pixels beside
  it are passable; weight 0, 1 or 2) and the cell type (solid when all four
  pixels are obstacles). Passable = air, gas, or sleeping solver liquid
  (which is in the solve, decision 85). Everything else blocks, including
  powders, other liquids and body cells. A 1-px wall closes the face it
  touches whichever pixel column it is on, which the 2x2 count (count >= 2)
  cannot express.
- Fixed slots added to common.glsl: `SLOT_IMG_LIQUID_WAKE` (14, R32UI, the
  wake hook's target) and `SLOT_IMG_LIQUID_OVERLAY` (15, RGBA8 debug
  overlay). `CMD_WAKE_LIQUID` = 32 (picked high to avoid other agents' new
  command kinds).

**Integration steps**:
1. Particle buffer: point `LQ_POS/VEL/AFF/INFO/BIND` (liquid.glsl) at the
   shared buffer's arrays, keep or merge the mode values (ballistic = the
   particles subsystem's own mode), and replace this subsystem's ballistic
   integration in `g2p.comp` (the `mode == LQ_MODE_BALLISTIC` branch) with
   the shared ballistic pass. The A/B ping-pong needs either a second shared
   set or an in-place permutation; the sort reorders every tick.
2. Obstacles: keep `classify.comp` for face weights (they need pixel
   resolution). Take only body velocities from the shared mask once bodies
   exist: closed faces currently get velocity 0 (`classify.comp`, `u = 0`).
3. Ballistic landing: the particles subsystem calls `liquid_wake_at(pixel,
   hops)` (`shaders/sim/liquid/wake.glsl`) where a particle lands in water
   and hands the particle over in liquid mode.

**Stubbed pending integration**: body boundary velocities (zero), body
overlap wake (hook only), pressure-pulse wake from the air field (hook
only), buoyancy/drag feedback to bodies, explosion impulse on particles.

**Alternatives**: waiting for the shared buffer (blocks M6); using the 2x2
count as binary solids (leaks pressure through 1-px walls at odd columns).

**Consequences**: until integrated, ballistic water lives in this buffer
and other particles do not interact with it.
