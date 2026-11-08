# Lighting: 2D radiance cascades over the view, sky, ambient, wall light

**Context**: M8 asks for radiance cascades over the visible region plus
margin, emissive cells and point lights as sources, solids and smoke as
occluders, a sky light and ambient, a quality knob, a simple-lights
fallback, and at most 1.5 ms at a 1080p view.

**Decision**:
- **Region**: the view plus 64 px, snapped to a world-aligned grid of the
  top cascade's probe spacing (`spacing << 5`), so probes do not swim when
  the camera moves (src/render/lighting.zig, unit-tested). Capacity 2048
  world px and 1536 cascade-0 probes per axis; the spacing doubles until
  the region fits.
- **Light scene**: one RGBA16F texel per world pixel: premultiplied
  emission, opacity per pixel (material absorption; body cells >= 0.9;
  emitters >= 0.35). Point lights (`Renderer.addLight`) are drawn as
  emitting discs of radius `clamp(r/12, 2, 6)` with radiance chosen so the
  irradiance is about 1/4 of the color at the nominal radius. Mips 1-6:
  a texel with any solid child is solid (thin walls never leak), otherwise
  mean opacity over the doubled path; emission is the coverage-weighted
  mean radiance times the mean coverage, so a light keeps its brightness
  across mips (plain averaging made a visible ring where cascades switch
  mips).
- **Cascades**: cascade-0 spacing 2 world px by default (`--spacing`,
  F6: 1, 2, 4), 4 * 4^i directions, intervals `t_i = 2*spacing*(4^i-1)/3`,
  as many cascades (<= 6) as reach the region diagonal. Each interval is
  marched one scene-mip texel per step at the coarsest mip that keeps
  about 16 steps (`--samples`). Merge uses Sannikov's "bilinear fix" (one
  ray per neighbouring upper probe, to that probe's interval start);
  the plain merge rang visibly around small lights. Cascade texels are
  RGB9E5 in r32ui images (half the memory and bandwidth of RGBA16F).
- **Sky**: a skyline pass finds per region column the first light-blocking
  row from y = 0. A ray that leaves the region, or ends in the top cascade,
  pointing up and above the skyline receives the sky radiance; the sky
  therefore pours into shafts and cave mouths with soft shadows. The sky
  background is drawn only above the terrain surface (skyline here and
  24 px to each side), so narrow shafts show the back wall.
- **Ambient**: surface ambient fading to cave ambient over 260 px below
  that surface (tunable; scenes without lights get brighter defaults in
  demo.zig).
- **Walls**: a probe whose footprint holds a solid has its rays blocked at
  once, so `light_dilate.comp` gives it the weighted mean of open probes
  within 10 px, faded by how few are near: rock is lit a few pixels deep
  at its surface and dark inside.
- **Modes**: cascades; simple (each point light raymarched through mip 1
  for a hard-ish shadow, `(1-d/r)^2` falloff, emissive cells do not light);
  off (white). F5 cycles, `--light`.

**Alternatives**: half-resolution scene (thin walls leak), the plain
bilinear merge (ringing), per-channel transmittance (needs a second
scene texture; smoke and water are grey occluders for now), a separate
sun light (no design need yet).

**Consequences** (RTX 4090, `--bench-render`, 1920x1080, lighting scene;
lighting = light_build + cascades + merge): zoom 2 (default) 0.31 ms of a
0.36 ms render; spacing 1 at zoom 2 0.92 ms of 0.96 ms; spacing 4 0.16 ms;
zoom 1 (2048x1280 region, 6 cascades) 1.12 ms of 1.19 ms; simple lights
0.05 ms. The far cascades sample 16-64 px mips, so very distant
shadows are blocky and can be over-dark behind thin translucent walls.
