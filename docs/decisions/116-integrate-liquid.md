# Integration: liquid solver and the shared particle buffer

**Context**: the liquid solver (M6) keeps its own particle arrays in the
shared SoA layout as two sets A/B that its per-tick counting sort
ping-pongs (also its compaction), and integrates ballistic particles
itself. The shared buffer (M4) has slots 17-24, a free list and a spawn
queue, and its own ballistic pass. Decision 87 recorded that the U-tube
cannot equalize in 2 s without damping that kills dam-break waves.

**Decision**:
- Two buffers, explicit hand-off (the fallback the coordinator allowed):
  the solver keeps its private sorted sets for liquid-mode particles; a
  particle that leaves the liquid (no liquid within its 3x3 cells) spawns
  a shared ballistic particle (`spawn_particle`, same material,
  temperature, variant, velocity) and dies in the solver (`LQ_PC_HANDOFF`,
  `Config.liquid_handoff`, default on). A refused spawn keeps flying in the
  solver's own ballistic mode.
- Solver liquid landing from the shared pass (`ballistic.comp land`) and
  solver liquid displaced by a body call `liquid_wake_at`, so water rejoins
  the solver. Explosions wake the liquid around them (decision 115).
- Solver liquids are found by `MATERIAL_FLAG_SOLVER_FLIP` (data layer)
  instead of main's `misc0` byte. Particle-backed cells stay static to the
  Margolus pass (block.glsl and the CPU reference).
- The liquid overlay is the renderer's mode 4 (decision 112).
- U-tube: no damping is added; `scenarios/u_tube.zon` and the harness
  assert both arms within 4 px (and 4 rows of cells) by tick 780, 12 s
  after the pour. Measured: within 4 px for good from tick 710.
- `liquid-test` disables the air field; its determinism check runs with
  the hand-off off: the solver alone is bit-reproducible, the shared
  ballistic pass is not (landing claims race on atomics).

**Alternatives**: repoint the solver's LQ_* macros at slots 17-24 and keep
its sorted copy as private scratch written back by index (full
unification; touches every liquid kernel and the shared free list, left
for the liquid owner).

**Consequences**: ballistic water from either source looks and lands the
same. Not wired (named TODOs in decision 119): body boundary velocities
in `classify.comp`, buoyancy/drag feedback to bodies, explosion impulses
on liquid particles.
