# Body rasterization: inverse-mapped fixed point, claim image, write then clear

**Context**: M7 step 2 of the frame pipeline: rigid bodies (Box2D on the CPU,
pixel bitmaps) become body-owned cells (flag bit 27, owner image = body id)
every tick, displacing loose material, never overwriting static terrain or
other bodies, with two bodies racing for a pixel resolved deterministically.
The brief suggested clearing last tick's cells by re-rasterizing last tick's
transforms as air.

**Decision** (`src/sim/bodies_gpu.zig`, `shaders/sim/bodies/raster.comp`):
- **Atlas**: one device buffer mirrors `BodyWorld.pixels` byte for byte, so a
  body's bitmap lives at its span offset. A bitmap is uploaded (staging in the
  upload ring + `vkCmdCopyBuffer` in the tick's command buffer) only when the
  body is new or its bitmap changed (per-slot generation + version), never per
  tick. A body whose upload does not fit the tick's staging (512 KiB) is not
  rasterized until it does.
- **Instances** (64 B): world bounding box (origin aligned down to 16 so a
  16x16 workgroup lies in one activity tile), body id = slot + 1, and the
  bitmap coordinate of the first box pixel's center plus (cos, sin), all in
  16.16 fixed point. Each thread **inverse-maps** its world pixel center into
  the bitmap (`bx = l0x + i*cos + j*sin`, `by = l0y - i*sin + j*cos`): no holes
  at any angle, integer math in the grid write. Work items = one per 16x16
  block of a box; one dispatch per mode over all bodies.
- **Pass order** per tick: EXTRACT (loose terrain cells -> air) and RESET
  (claim image under every body) -> CLAIM -> WRITE -> CLEAR -> points ->
  eject fallback, barrier between steps, all inside `timed("bodies")`, after
  commands and before compaction (`Pipeline.recordTick`).
- **Races**: CLAIM does `imageAtomicMin(claim, stamp | id)` with
  `stamp = (tick & 0x7ffff) << 13` on a private world-sized R32_UINT image; the
  lowest id wins. A cell is claimable when it is not body-owned and not static
  (air, gas, liquid, powder), or already owned by the same body. WRITE writes
  where the claim equals this tick's value: a new cell, or for an own cell of
  the same material only the shade (temperature, state, burning survive);
  non-air cells it replaces go to the eject queue with the body's point
  velocity. Static or other-body targets are left alone and counted as
  overlaps, per instance, in the stats buffer (read back one frame later).
- **Clear after write, not before**: CLEAR walks last tick's box of every body
  that moved or died and turns its cells that this tick's claim did not take
  back into air. Same "re-rasterize last tick's footprint" idea as asked, but
  ordered after the write so a body moving by less than a pixel rewrites
  nothing and wakes no tiles, and its cells keep temperature and damage. The
  tick stamp makes "claimed this tick" exact without clearing the claim image.
- **Unchanged bodies are skipped**: identical fixed-point placement, bitmap and
  generation as last tick -> no instance, no clear. Sleeping bodies cost
  nothing and do not keep tiles awake (crate scene: 0 instances per tick once
  asleep).
- **Shade**: variant from `hash_u32(hash_salt(bx, by, atlas_offset))`, a
  stable per-bitmap-pixel shade that moves with the body.
- Body bitmaps hold **static-phase materials only** (`spawnBox`, connectivity
  and beams enforce it): the Margolus pass moves powders and liquids, and it
  does not test the body flag.

**Alternatives**: forward mapping each bitmap pixel to the nearest world pixel
(holes when rotated); a per-body list of covered cells (more memory and an
extra buffer per body); clearing first (rewrites every cell of a resting
body every tick and loses cell state); claiming on the owner image (it holds
particle indices for particle-backed cells, which the claim would destroy).

**Consequences**: measured (`zig build run -Doptimize=ReleaseFast -- --headless
--scene bodies_bench --ticks 600`): 200 bodies, 20-40 px, GPU "bodies" pass
0.067 ms mean / 0.19 ms max while all fall, 0.021 ms mean settled. Eject order
is not deterministic (atomic append); bodies are off in the determinism scene.
Two bodies in contact can overlap by a pixel after rounding; the higher id
loses that cell for the tick (`overlap body` counts). A reaction that changes
a body cell's material is undone when the body next moves: integrating
reactions with bodies (burning wood bodies) needs the bitmap to learn about
it, or the rule to skip body-owned cells.
