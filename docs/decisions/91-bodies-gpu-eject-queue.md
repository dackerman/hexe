# Eject queue for displaced cells, with a reinsertion fallback

**Context**: a body moving into air, liquid, gas or powder displaces those
cells; the architecture wants them to become ballistic particles. The particle
buffer (and its `eject_cell`) is another agent's work in progress and not on
this branch.

**Decision**:
- A fixed shared buffer at `SLOT_BUF_EJECT` (4) in `common.glsl`, capacity
  `EJECT_CAPACITY` (16384): header `count, dropped, pad, pad`, then entries
  `{ ivec2 p (wrapped), uint cell (flags cleared), uint vel (packHalf2x16, px/s) }`.
  Layout and `bodies_eject_cell(p, cell, v)` in `shaders/sim/bodies/bodies.glsl`
  (named so it cannot collide with the particles agent's `eject_cell`).
- Producers: raster WRITE (displaced cells, velocity = body velocity + w x r),
  points with `POINT_MODE_EJECT` (beam sparks, debris of materials without a
  rubble product). The count is zeroed at the start of the bodies pass.
- Stand-in consumer `eject_fallback.comp` (`BodiesGpu.Config.eject_fallback`,
  on): each non-static entry walks straight up (at most 384 px) through
  liquids, powders, gases and body cells and is put into the first air cell
  with `imageAtomicCompSwap`; walking stops at static terrain. Static entries
  (sparks) are dropped and counted.

**Alternatives**: writing displaced cells beside the body (direction
heuristics, collides with other bodies); deleting them (water would vanish
under every crate); waiting for the particle system (no M7 demo).

**Consequences**: displaced fluid mass is conserved: in `bodies_water` the
pool holds 54000 water cells before and after two 40x40 crates sink into it,
and the level visibly rises. Displaced water lands on top of a floating crate
(it walks up through it), which a particle splash will do better.
Integration with the particles layer: drain this queue into ballistic
particles in the particles pass (or make `bodies_eject_cell` call their
`eject_cell`), then set `eject_fallback = false`. Sparks become visible only
then.
