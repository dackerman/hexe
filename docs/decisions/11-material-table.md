# Material table layout and the loader interface

**Context**: M1 hardcodes five materials, but `src/data/` (another agent)
will fill the table from ZON files.

**Decision**: `src/sim/materials.zig` defines `MaterialGpu`, an extern struct
of 32 words (128 bytes, std430), documented word by word next to the GLSL
`struct MaterialGpu` in `shaders/common.glsl` with offsets checked at
comptime and against the GLSL defines. It reserves fields for every
GPU-relevant schema field in docs/03-materials.md (phase, solver, density,
dispersion, slide, health, lifetime, decays_to, spawn temperature,
conductivity, emits_heat, melt/freeze/boil, flammable, impact, blast,
drag, emissive, glow, translucent, conductive, 8-color ramp) and has 13 spare
words. The loader-facing type is `MaterialDesc` in real units (degrees C,
0xRRGGBB colors, resolved material ids) and `pack` derives the GPU encoding:
temperature bytes, RGBA8, `sort_key`, default `vertical_chance`, and
`initial_state` (health, else lifetime clamped to a byte). `Table.add`
assigns ids in order with air first; id 255 is `none` (no transition).
Unused ids are static magenta. `Grid.uploadMaterials(ctx, &table)` replaces
the GPU table (waits for idle; usable for hot reload).

**Alternatives**: the loader writing `MaterialGpu` directly (every loader
would need to know the encoding); a separate buffer per field group.

**Consequences**: CPU-only fields (on_contact, reactions) stay out of this
struct; reactions get their own table in M3. Changing a field's meaning is a
change to common.glsl, materials.zig and the reference together.
