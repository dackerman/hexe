# Polish: destruction events cannot starve connectivity

**Context**: decision 131: the level's tick-0 build carves rooms with air
fills, which the bodies layer reads as destruction events, and those
events kept connectivity busy forever, so a blown pillar never came loose;
the level drops the queued events at tick 1. The cause (`processEvents`):
an event stayed queued while any queued cluster overlapped its whole
footprint. A long carve overlaps the regions of many others; when more
clusters were ready than the 1 ms budget runs in a tick, every event was
kept, the same clusters were rebuilt, the same first ones ran again, and
the rest (real events included) never did.

**Decision** (`src/sim/bodies_sim.zig`):
- An event's connectivity region is computed once (`eventRegion`: the
  256 px square around it grown to its footprint, clamped to 448 per side
  around its center) and used for clustering.
- Each event remembers the cluster it joined (`DestructionEvent.cluster`)
  and is dropped once that cluster has run; it no longer waits for every
  overlapping cluster. A map-wide footprint is analyzed around its center
  only (connectivity is local, decision 93).
- An event still unprocessed `max_event_age` (60) ticks after the readback
  caught up with it is dropped and counted (`Totals.expired`, printed in
  the bodies report): a backlog delays real events by at most a second.
- An erase spanning the whole window in x or y (`build_extent`, 2048) is a
  build, not a destruction: no event.
- The level keeps its explicit drop at tick 1 (harmless; without it the
  build leaves two crumbs of under 4 px that turn into gravel).

**Measured** (ReleaseFast):
- `playtests/bodies_backlog.hexe` (a map-wide carve and a lattice of 26
  long corridors and shafts at tick 0, then a pillar under a slab cut at
  tick 60, far from the lattice): main: 322-473 connectivity runs in 160
  ticks, 21 events still queued at the end, the slab never falls (1000
  stone cells where it was at tick 151). Now: 18 runs, 0 queued, 0 expired,
  the slab falls (0 stone cells there), the lattice's 31 enclosed blocks
  come loose as bodies (main found 21 of them).
- `--scene proving_grounds --ticks 120`: 0 loose components -> bodies,
  0 -> rubble (with the level's drop). Without the drop: 43 events, 21
  connectivity runs, 0 expired, 0 loose components -> bodies, 2 -> rubble.
- `--scene proving_grounds_auto --ticks 700` without the drop: 210 events,
  108 connectivity runs, 0 expired, the ruin's pillar charge brings the
  slab down (2 loose components -> bodies, as with the drop).

**Alternatives**: a worker thread for connectivity (decision 93's
fallback; the backlog would still never drain); merging all events into
one region (connectivity is local and bounded by design).

**Consequences**: an event whose footprint is wider than 448 px is only
analyzed around its center: an island cut free by a long carve far from
its center is found only if another event's region covers it (as before:
connectivity is local). Reopen with the streamed world if a carve over
2048 px wide must count as destruction.
