# Rigid-body units and conventions

**Context**: Box2D is tuned for meters (slop 5 mm, speculative margin, speed
limits). D9 fixes 1 px = 5 cm, gravity 196 px/s², a 60 Hz tick. Bodies,
the grid and the solvers must agree on positions without conversions
scattered through gameplay code.

**Decision**:
- World units are grid pixels. `b2SetLengthUnitsPerMeter(20)` is called in
  `BodyWorld.init`, before the world is created, so Box2D's length-dependent
  constants scale with it (linear slop 0.1 px, max speed 8000 px/s,
  sleep threshold 1 px/s). It is a process-global setting; every
  `BodyWorld` uses the same value.
- y points down like the grid. Gravity is (0, +196) px/s². A positive angle
  turns +x toward +y: clockwise on screen. Body-local (lx, ly) maps to world
  (x + c·lx − s·ly, y + s·lx + c·ly), `Transform.apply`.
- Mass in kg. A pixel is a 5 cm cube, so material density is kg per pixel:
  steel 0.98, concrete 0.30, wood 0.075 (real densities × 1.25e-4 m³).
  Force kg·px/s², impulse kg·px/s, torque kg·px²/s².
- Fixed step `tick_dt = 1/60` s with `Config.substeps = 4`.
- Bitmaps: row-major `u8` material ids, 0 = empty. Each body has an origin
  `(origin_x, origin_y)` in bitmap pixel coordinates (0,0 is the top-left
  corner of pixel (0,0)). Pixel (i, j) has body-local center
  (i + 0.5 − origin_x, j + 0.5 − origin_y). The body transform is the world
  pose of that origin; the GPU rasterizer needs only the transform, origin,
  size and pixels from `rasterIterator`.
- Body world coordinates are unwrapped (not modulo the 2048-px torus).
  Window recentering is the caller's job.

**Alternatives**: 1 unit = 1 m with a ×20 conversion layer at the API edge
(every caller and every event would convert; easy to get wrong);
1 unit = 1 px without changing Box2D's length scale (slop of 0.005 px,
speeds capped at 4 px/s-scaled defaults: jitter and wrong sleeping).

**Consequences**: numbers in body code read directly as pixels. Material
densities are physical, so mass ratios between steel and wood are real.
Reopen if the torus needs bodies to cross the wrap seam (Box2D has no origin
shift in v3.2; we would re-create bodies at the shifted position).
