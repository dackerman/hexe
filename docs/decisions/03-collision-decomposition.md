# Collision shapes from bitmaps and the solid mask

**Context**: bodies are pixel bitmaps; static collision comes from an 8-bit
solid mask read back from the GPU each tick. Both must become Box2D shapes
cheaply and robustly, and static rebuilds must not cost a full rebuild per
tick.

**Decision**:
- **Greedy rectangle decomposition** (`decomposeRects`): scan rows, at each
  uncovered solid cell extend right as far as possible, then down while the
  whole span stays solid. Disjoint rectangles that cover exactly the solid
  cells (tested on random grids). Each rectangle is one `b2MakeOffsetBox`.
- **Pixel bodies**: shapes from the bitmap's rectangles, created with
  `updateBodyMass = false`; mass, center and rotational inertia are summed per
  pixel from material densities (each pixel a unit square, own inertia m/6)
  and set with `b2Body_SetMassData`. Friction and restitution come from the
  dominant material. `splitByConnectivity` (4-connected flood fill with an
  explicit stack) turns a damaged bitmap into tight component bitmaps;
  `splitBody` keeps the first piece in place (same handle, origin and joints)
  and spawns the rest with the original's velocity field.
- **Static collision** (`setStaticCollision(mask, w, h, origin_x, origin_y)`):
  the region is cut into world-aligned 64 × 64 px tiles, each its own static
  body. A tile is rebuilt only when the Wyhash of its mask bytes, its coverage
  rectangle or its mode changes. Tiles whose area comes within 24 px of any
  body's bounding circle are built exactly per pixel; other tiles use 4 × 4
  coarse cells, solid when at least half their pixels are. Tiles map to slots
  by tile coordinate modulo the slot grid, so a scrolling or body-following
  region reuses unchanged tiles; tiles that leave the region are destroyed.
  The mask must not include body-owned cells.

**Alternatives**: chain shapes from marching-squares contours (no internal
seams, but contour extraction and simplification per change, and holes need
care); convex polygon decomposition of bodies (fewer shapes, much more code,
fragile on noisy rubble); rebuilding all static shapes every tick (thousands
of shape creations per tick).

**Consequences**: shape counts grow with surface roughness, not area. Seams
between adjacent rectangles can cause small ghost bumps for bodies sliding
along terrain; reopen with chain shapes if sliding looks wrong. A body that
moves more than the 24 px margin in one tick (over 1440 px/s) can briefly
meet coarse geometry. Measured with `zig build bodies-demo -Doptimize=ReleaseFast
-- --bench` (1024 × 512 mask, 382 rubble bodies, a hole dug every tick):
`setStaticCollision` mean 0.10 ms, max 0.37 ms per tick on the dev machine.
