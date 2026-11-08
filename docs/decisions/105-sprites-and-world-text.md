# Sprites, debug primitives and world-anchored text

**Context**: gameplay needs entity sprites at world pixel scale lit like
the world, debug shapes in world space, and docs/07 needs floating signs
(HUD text anchored to world positions).

**Decision**:
- `sprites.Atlas`: one 512x512 RGBA8 sampled image, shelf-packed by
  `upload(pixels, w, h) -> AtlasRect` (sRGB colors, R in the low byte;
  init time or between frames, it waits for the GPU). Two placeholder
  bitmaps are compiled from ASCII art: a 12x30 witch and a 16x16 crate
  (`renderer.witch`, `renderer.crate`).
- One batch of 64-byte `QuadGpu` entries per frame (8192 max) drawn into
  the scene image after the world pass with 6 vertices per entry and no
  vertex buffers: sprites (atlas rect, flip, tint, lit by ambient plus
  irradiance), filled rects and 1 px lines (unlit). API on
  `engine.renderer`: `drawSprite(x, y, w, h, rect, flip, tint)`,
  `drawRect(x, y, w, h, color, filled)`, `drawLine(x0, y0, x1, y1,
  color)`, `addLight(x, y, radius, color)`; positions in world pixels,
  wrapped on the torus relative to the camera. Lists are consumed by the
  next rendered frame (`Engine.frame` clears them).
- `engine.hud.printWorld(x, y, fmt, args)` (and `printWorldColor`): up to
  64 strings of 64 characters per frame, centered above the anchor, drawn
  at window resolution in the HUD font with a drop shadow so they stay
  crisp at any zoom; `hud.clear()` drops them with the HUD lines.

**Alternatives**: vertex buffers per batch (more plumbing for the same
result), sprites drawn at window resolution (would not be pixel aligned
with the world), text in world pixels (illegible at zoom 1).

**Consequences**: one atlas page; sprite depth order is submission order.
Animated sprites are several atlas rects. Sprites are not occluders in the
light scene (entities that should cast shadows become bodies).
