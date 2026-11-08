# Render pipeline: world-resolution scene image, composite upscale, pass order

**Context**: M8 asks for palette shading, radiance-cascade lighting, a
sprite pass at world pixel scale, overlays, bloom and vignette, all inside
the 3 ms "readback, render, lighting" budget of the architecture. The M0
world pass shaded every window fragment directly, and no materials beyond
the M1 builtin five (air, stone, sand, water, smoke) exist in the sim yet.

**Decision**:
- `src/render/renderer.zig` owns every render resource and records the
  whole frame on the graphics queue: `light_build` (skyline.comp,
  light_scene.comp, light_mip.comp), `cascades` (rc_cascade.comp),
  `merge` (light_resolve.comp, light_dilate.comp), `world` (world.frag),
  `sprites` (quads.*), `post` (bloom.comp, composite.frag), `hud`. Each is
  a named GPU timestamp (HUD, `--profile`, `--bench-render`).
- The world and sprites render into an RGBA16F scene image with one texel
  per world pixel of the view (`ceil(window / zoom)`, capacity 2048x2048).
  `composite.frag` integer-upscales it with `texelFetch` (crisp pixels at
  any zoom), adds bloom, applies exposure, a hue-preserving ACES curve on
  luminance (per-channel ACES turned lava yellow), vignette, sRGB encode
  and a 1-LSB triangular dither against banding. HUD and world-anchored
  text draw after it at window resolution.
- Per-frame parameters live in a host-visible `RenderFrame` buffer per
  frame slot (bindless slots, region, tuning); push constants carry only
  that buffer's slot plus per-dispatch values.
- Render shaders never read the sim material layout; they read a
  `RenderMaterial` table built on the CPU (decisions/101).
- Headless `Engine.frame(.., view)` now renders into the capture image
  exactly like the window path (minus present); `captureView` renders from
  the live images after `finish`, so `--screenshot` and `--view-screenshot`
  keep working and show the lit result.
- `src/sim/materials_extra.zig` appends lava, glass, flame, steam, wood and
  molten glass (values from `materials/*.zon`) after the builtin five, ids
  5-10, so the rendering classes can be exercised before the sim loads
  `materials/`. Builtin ids are unchanged; verify-determinism still uses
  the builtin table only. Delete it when the sim adopts the data layer.
- `--scene lighting` (src/sim/scenes.zig) plus `src/render/demo.zig`
  (lights, sprites, signs per scene) is the visual test.

**Alternatives**: shading at window resolution (sprites would not be pixel
aligned, bloom would run at 9x the pixels at zoom 3); a compute world pass
(the sprite batch needs rasterization anyway); wiring the data-layer table
into the sim here (owned by the reactions work, conflicts certain).

**Consequences**: Render memory is about 270 MiB (cell, owner and overlay
snapshot rings 72, scene image 32, light-scene mips 43, two RGB9E5 cascade
images 72, irradiance 36, bloom 16): well above the architecture's
resource table, which predates lighting; shrink the capacities (scene
size, max probes) for the minimum-spec profile. The renderer uses 20 of
the 48 dynamic storage-image slots and 5 sampled-image slots.
