# Beams in the world: placement, cuts, anchors, sparks

**Context**: steel and wood beams placed between two points, anchored where
they enter rock, weakened by cells removed from them, snapping with sparks.

**Decision**:
- `placeBeam(x0, y0, x1, y1, material, thickness)` queues a request handled
  at the next tick once the terrain along the line is read. Each end inside
  static solid is walked toward the other in 1 px steps until it leaves the
  solid: the beam spans the gap and its ends are welded (`anchor_start/end`)
  at the rock faces, not embedded in rock (embedded ends would fight the
  static collision). Segments of about 10 px (`clamp(round(span / 10), 2, 64)`).
- **Cuts**: a destruction event over a beam segment removes those bitmap
  pixels (`splitBody`, the first piece keeps the joints) and calls
  `weakenBeamAt` at both joint positions of that segment with the fraction of
  thickness left in its most damaged column (moment capacity goes with its
  square); a severed segment breaks both joints and falls free.
- **Anchors**: each tick the cell 2 px beyond each welded end, inside the
  rock, is checked; when no static solid is left there the anchor is
  released (`releaseBeamAnchor`).
- **Sparks**: each `jointBreaks()` entry emits 12 points of the beam's
  material into the eject queue at 80-300 px/s in random directions.

**Consequences**: `bodies_beam` (240 px, 4 px steel beam welded to two
cliffs, 50x50 concrete crate on it, torch from below following the beam):
first cut (3/4 left) holds at 2.9 px sag; second cut (2/4) yields
plastically, sag 2.9 -> 9.7 px over 4 s; third cut (1/4) snaps it (2 joint
breaks, 24 sparks); ejecting the rock behind the right weld releases that
anchor and the right half falls. Sparks are dropped by the eject fallback
until particles land. An 8 px steel beam carried the same crate even with the
middle segment cut out: thickness matters as t^2.
