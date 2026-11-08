# Connectivity after destruction: bounded regions, one anchored flood, time budget

**Context**: after material is removed, static islands no longer connected to
the region boundary or to bedrock must become falling bodies (architecture
"Bodies"). No event queue exists yet.

**Decision** (`BodySim.connectivity`, `processEvents`):
- **Events**: `DestructionEvent{x, y, radius}` (plus the exact rect for
  fill-rect commands). Sources: every fill-circle / fill-rect command with
  material air in the tick's list (the eject tool, scripted ejects), and
  `notifyDestruction(x, y, r)` for the reactions/particles/explosion code.
  Bodies overlapping an event lose those pixels immediately (CPU bitmaps);
  connectivity waits until `readTick` shows the event's tick.
- **Region**: 256x256 centered on the event (grown to cover the event),
  overlapping regions merged up to 448x448; past that, separate runs.
- **Algorithm**: static-material ids (body-owned excluded, pending
  extractions masked) -> one 4-connected flood fill seeded from every border
  pixel and every anchor-material pixel (`bedrock`, `anchor = true` in the
  ZON) zeroes all anchored solid -> `splitByConnectivity` only over the
  bounding box of what is left. Each remaining component: < 4 px -> its
  cells become its rubble material in place (`POINT_MODE_REPLACE`, or air +
  eject when it has none); otherwise `createPixelBody` at its exact position
  (angle 0, origin 0) and an EXTRACT instance that turns exactly those cells
  (matching material, unflagged) into air in the same tick, before the raster
  writes them back as body-owned. Components over 256x256 stay terrain.
- **Main thread**, with a budget: measured ReleaseFast on the dev machine,
  256^2 regions 0.19-0.36 ms; 512^2 regions 0.57-1.05 ms (hence the 448 cap,
  about 0.8 ms). A tick stops starting clusters after 1 ms of connectivity
  (`connectivity_budget_ms`); their events stay queued for the next tick.

**Alternatives**: a worker thread (the brief's fallback above 1 ms: adds a
tick of latency and a job queue for a pass that fits the budget); GPU label
propagation (the architecture's wording; the CPU version was cheap and the
bitmaps are needed on the CPU for Box2D anyway); labelling every component as
`splitByConnectivity` alone does (1.6x slower on the slab region, 0.57 vs
0.36 ms: the anchored terrain's bitmap is copied).

**Consequences**: a structure larger than the region that is only held up
outside it is treated as anchored (connectivity is local). Reopen with a
worker thread if regions must grow beyond ~450 px.
