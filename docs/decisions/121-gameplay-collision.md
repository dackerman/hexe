# Gameplay: pixel collision for characters

**Context**: characters (the witch, walkers, flyers) are not cells
(docs/02 "Entity contact"); they need to stand on terrain, bodies and
powder dunes, climb rubble, and survive terrain appearing inside them.

**Decision** (`src/game/physics.zig`):
- A character is an axis-aligned box of whole pixels plus a sub-pixel
  remainder. Each tick it moves along x, then along y, one pixel at a
  time; the first pixel step into a solid cell stops that axis and zeroes
  its velocity. No step is skipped, so nothing tunnels (a 64-step cap per
  axis guards absurd blast speeds).
- Walking climbs steps of up to 3 px (the whole box must fit at the raised
  position) and, when it was on the ground, snaps down up to 3 px after
  the move so slopes are walked, not hopped. A body resting on ground does
  not build up fall speed between pixel steps.
- "Solid" (`world.EntityWorld`) = the mirror's solid mask (static phase or
  body-owned: rock, crates, beams, corpses) plus powder cells from the
  entity's readback region (the mask leaves powders out, but sand dunes
  must be walkable). Liquids and gases are not solid.
- `pushOut` runs first every tick: if the box overlaps solid cells (a sand
  pour, a slab, a body), it moves to the nearest free position within 8-10
  px, up first, then sideways, down, diagonals. If none is free the
  character stays put (no assert); it is marked `stuck`.
- Dropping through thin platforms: S on ground over solid at most 3 px
  thick ignores those rows for 10 ticks.

**Alternatives**: Box2D kinematic bodies for characters (static collision
lags a tick behind and is decomposed into rectangles; character feel is
easier pixel-exact); signed-distance pushes (no pixel exactness).

**Consequences**: the mirror is one or two ticks stale, so a character can
be inside freshly moved cells for a tick; push-out absorbs it. Powders
under a character do not feel its weight. Tests: step-up, slope snap,
landing, push-out, buried, ray casts (`zig build test`).
