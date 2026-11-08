# Blast loads: what a pixel feels

**Context**: 04-fluids.md compares "pressure gradient magnitude" with
`blast_threshold`; at 2 px per lattice cell, loose material, thin walls,
thick rock and liquid pools all needed a definite rule.

**Decision** (`shaders/sim/air/effects.comp`, once per tick over active
air tiles, one thread per lattice cell and its four pixels):
- **Gradient load** for `fly` materials (powders, liquids): central-
  difference density gradient at a fluid cell; in a wall cell (a pool, a
  plug in a coarse wall cell) the largest gradient of its fluid
  4-neighbors. A pool under uniform room pressure feels nothing.
- **Wall load** for `chip`/`break` solids in wall cells: per axis, the
  difference between the nearest fluid cells on either side (search 3
  cells) over their distance; a side with no fluid counts as ambient one
  cell behind the face. Liquid transmits pressure: a liquid cell met on
  the way stands for the gas on top of its column (hydrostatics ignored),
  so the wood beside a pool is loaded by the room above the pool.
- Fly: the pixel becomes air and is appended as a FLY eject with velocity
  = air velocity × 3 − gradient direction × min(excess × 0.05, 8) + jitter,
  capped at 8 px/tick. Chip/break: health (state byte) −= max(1, excess ×
  0.25); at zero the cell becomes its rubble material (powder, it may fly
  next tick) or air plus a BREAK eject; chip materials also emit a CHIP
  eject in one of four damage events.
- Pressure events: overpressure (‰) at the cell, or the highest adjacent
  fluid for walls, above `pressure_event`.
- Particle-backed and body-owned pixels are skipped (liquid and bodies
  branches apply their own impulses).

**Alternatives**: one load for everything (sealed-room overpressure blew
pools apart; the one-sided wall load was wrong for liquids); damaging
solids by gradient alone (a uniformly pressurized room never breaks).

**Consequences**: a breached room vents and stops loading what is left of
the wall; isolated pieces are for the connectivity pass (M7).
