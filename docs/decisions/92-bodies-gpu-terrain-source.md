# TerrainSource: what bodies read from the grid, synchronous tile readback for now

**Context**: Box2D needs the static solid mask around bodies; connectivity
needs material ids around destruction events; buoyancy needs liquid next to
bodies. The planned async `Mirror` (1-bit solid mask of the window + material
regions, one tick late) is being written in parallel.

**Decision** (`src/sim/terrain_source.zig`):
- `TerrainSource` vtable: `request(region)`, `prepare()`, `solidMask(region,
  out)`, `materials(region, out)`, `readTick()`. Regions are unwrapped world
  rectangles read with torus wrapping.
  - solid = static or powder phase, not body-owned, not particle-backed
    (bodies rest on sand piles instead of plowing through them; liquids and
    gases are displaced instead).
  - materials = material id, `255` (`materials.none`) for body-owned cells.
  - `readTick` = first tick whose results are not visible yet.
- `SyncReadback` implements it today: requested regions are rounded to 64x64
  world tiles; `prepare` copies them in one `vkCmdCopyImageToBuffer` with many
  regions via `ctx.runOnce` on the compute queue. That submission comes after
  every submitted frame on the same queue and starts with an all-commands
  barrier, so it sees all ticks before the frame being recorded without an
  explicit timeline wait (`Bodies.beginFrame(completed_tick)`). Tiles go into
  a world-sized CPU cache plus a solid-mask cache; a tile already copied for
  the current completed tick is not copied again (multi-tick frames).
- Requests per tick: each body's bounding circle + 32 px + 2 ticks of motion
  (every 4th tick for sleeping bodies, staggered), ready event clusters, beam
  placements, 5x5 probes at beam anchors.
- Loose terrain just turned into a body still reads as static until the
  readback catches up: a **pending overlay** (its bitmap, until `readTick`
  passes the extraction tick) is masked out of collision and connectivity.

**Alternatives**: full-window readback each tick (16 MB); waiting for the
Mirror (no M7 demo); reading cells back at the end of the tick into a ring
(that is the Mirror).

**Consequences**: cost is CPU-side copy plus waiting for the previous frame:
0.1-0.6 ms per tick in the scenes (200-body bench: 0.53 ms mean), and it
serializes CPU recording with the GPU when bodies exist. Switching to the
Mirror: implement the five functions on it (`request` registers material
regions for next tick, `prepare` no-op, `solidMask` from its 1-bit mask with
the definition above, `readTick` = its tick), pass `mirror.source()` to
`BodySim.create` in `Bodies.init`, drop `SyncReadback`. Nothing else changes.
