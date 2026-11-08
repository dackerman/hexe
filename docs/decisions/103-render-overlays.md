# Debug overlays: modes, the SLOT_IMG_DEBUG_OVERLAY image, keys

**Context**: docs/07 wants Tab to cycle overlays (none, activity tiles,
air pressure, air velocity, liquid particles, bodies, temperature). Air
and liquid are written by other agents in parallel and need a contract.

**Decision**:
- Modes are `OVERLAY_*` in shaders/common.glsl (mirrored in
  src/gpu/constants.zig) and `overlay.Mode` in src/render/overlay.zig:
  none 0, tiles 1, air_pressure 2, air_velocity 3, liquid_particles 4,
  bodies 5, temperature 6, particle_cells 7, light 8. The world pass
  composites them after shading; the HUD prints the mode and a legend.
- Image ABI: the renderer owns an RGBA8 1024x1024 image at the fixed slot
  `SLOT_IMG_DEBUG_OVERLAY` (2), GENERAL layout. Texel (x, y) covers world
  pixels (2x, 2y)..(2x+1, 2y+1). `Frame.overlay` (src/sim/pipeline.zig)
  carries the current mode into every sim pass; a pass writes the image
  only while `frame.overlay` equals its id, overwriting every texel it
  does not want to keep (clear first when scattering). Declare it with
  `#define HEXE_WANT_DEBUG_OVERLAY` before including common.glsl and
  `imageStore(DEBUG_OVERLAY, texel, rgba)`. air_pressure and air_velocity
  are alpha blended with the texel's alpha; liquid_particles is additive
  (`overlay.info`). The renderer snapshots the image with the cells when
  an image mode is active, so the next tick may rewrite it.
- Computed modes need no writer: tiles (this tick's active list, the old
  F2 tint), bodies (owner id hashed to a color on body-owned cells),
  temperature (heat map), particle cells, light (irradiance only).
- Keys (windowed app): Tab / Shift+Tab cycle, F2 toggles tiles, F5
  lighting mode, F6 probe spacing, F7 bloom, F8 vignette, T cursor torch
  (a 70 px point light following the mouse). CLI: `--overlay NAME`.

**Alternatives**: one image per overlay (more slots and memory), overlays
drawn by each owning agent (every agent would need graphics pipelines).

**Consequences**: one RGBA8 image is shared by all image overlays, so only
one is visible at a time, which is what Tab cycling shows anyway. Overlay
colors go through exposure and tone mapping, so they are slightly muted.
