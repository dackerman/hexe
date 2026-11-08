# Render material table, translucency, emission and glow

**Context**: The sim's GPU material table (128-byte `MaterialGpu`) differs
from the data layer's 176-byte layout of decisions/03 and has no
`blocks_light` flag or visual opacity. Rendering needs light absorption
per material and translucent materials (water, glass, steam, smoke) must
read as transparent although a cell holds exactly one material.

**Decision**:
- `src/render/materials.zig` derives a 48-byte `RenderMaterial` per id
  from the sim table: ramp (cycled to 8), ramp length, phase, flags
  (translucent, emissive, glows, blocks_light, flicker, liquid, gas, air),
  emissive, light absorption, visual alpha, surface texture amplitude,
  glow range and the ramp's brightest ("hot") entry. Defaults come from
  phase and the translucent flag; a short table of per-name art overrides
  (water, glass, ice, steam, smoke, acid gas, flame, lava, oil, acid) sets
  absorption and alpha. When the sim moves to the data layout, only
  `derive` changes; `blocks_light` can then come from the data flag.
- Albedo: `ramp[(variant * ramp_len) >> 4]`, sRGB-decoded; statics and
  powders get a static two-octave value-noise texture (per material
  amplitude). Translucent liquids soften the variant speckle toward the
  ramp mean, darken with depth below their surface and get a lit surface
  line, so water reads as a body rather than noise.
- Translucency: there is no "behind" in a one-material grid, so air and
  translucent cells show a procedural back wall (jittered 10 px cobbles,
  dark seams, lit by the same light at 40%) or, above the terrain surface,
  a sky gradient. Translucent cells blend their lit color over that at
  their alpha. The back wall is what makes caves read as caves.
- Emission (display): `albedo * emissive/255 * gain`, flame flicker by a
  per-cell tick hash, glowing liquids shimmer with drifting value noise,
  burning cells add a flickering orange. Temperature glow (°C = 8t - 40,
  `glow_from..glow_to`) adds the hot ramp entry times g^2 and pulls
  non-emissive albedo toward it. Emitters are not lit by their own
  irradiance (it would double their brightness). The light scene uses the
  same emission times a separate `light_emission_gain`.

**Alternatives**: reading the sim table in render shaders (couples every
render shader to a layout that is about to change); adding render fields
to the sim struct (shared file, not sim data); real layered depth (needs a
second material per cell).

**Consequences**: The overrides are art direction keyed by name; a new
translucent material gets sensible defaults from its phase and flag. The
back wall is purely decorative and costs nothing in the sim.
