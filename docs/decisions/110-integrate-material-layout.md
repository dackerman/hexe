# Integration: one material layout

**Context**: three material layouts met at the integration: main's
engine-side 128-byte `MaterialGpu` (packed words, `MATERIAL_NONE` = 255
for "no transition"), built from hardcoded `MaterialDesc` tables
(`materials_builtin.zig`, `bodies_materials.ensureMaterials`,
`materials_extra.zig`), the data layer's 192-byte `MaterialGpu` that the
reactions branch made the engine's (decision 40), and the renderer's own
48-byte table derived from the sim table (decision 101).

**Decision**:
- The data layer's packing (`src/data/gpu_tables.zig`, embedded verbatim in
  `shaders/common.glsl` by `glsl_material_struct`) is the one sim layout.
  `materials_builtin.zig`, `materials_extra.zig`, `MaterialDesc`, `Table`
  and `ensureMaterials` are deleted. Every executable loads `materials/`
  (`--materials DIR`) into a `materials.Library`; scenes, tools, bodies and
  harnesses look ids up by name (`materials.Ids`, extended with glass,
  molten glass, steam, concrete, gravel).
- Main's fields map onto it: air's `pressure_event` and `feeds_air`
  (now `MATERIAL_FLAG_FEEDS_AIR`), particles' `rubble` and
  `MATERIAL_FLAG_RICOCHET`. The spare word at offset 152 becomes
  `restitution` (velocity a bouncing particle keeps, /255; 0 = engine
  default) with a new schema field `restitution: i32 = 0` (0-255), set to
  150 on steel as main's builtin table had it. The design doc schema
  (docs/03-materials.md) is not edited; this file records the addition.
- `rubble` is the material's own id when it has none (the data layer's
  "null = itself"): chips and blast breakage fly as the material itself,
  and health damage to zero leaves a hole (ballistic `damage_cell`).
- `BLAST_*` follow the data enum (fly 0, chip 1, break 2); immunity is
  `blast_threshold == 0` (main's `BLAST_NONE` is gone). `IMPACT_*` moved
  into common.glsl. `mat_*` accessors for the old packed words are gone;
  shaders read fields.
- The renderer's table stays (decision 101): `render/materials.zig`
  derives it from the 192-byte entries and the library's names, and also
  honours `MATERIAL_FLAG_BLOCKS_LIGHT`. `Engine.reloadTables(lib)` re-uploads
  sim, reaction, bodies and render tables on hot reload.
- The bodies layer resolves roles and per-name presets (steel, wood,
  concrete, stone, glass) from the library; rubble comes from the material
  file; `anchor` from the flag. Its "none" (255) is CPU-only.

**Alternatives**: keep the 128-byte packed layout and pack the data layer
into it (smaller, but every new field needs bit surgery and the data layer
already tests its layout against the GLSL text).

**Consequences**: 64 bytes more per material (12 KiB total). A material
with id 255 would collide with the bodies layer's `body_owned` marker;
the shipped set ends at 30.
