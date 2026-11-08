# One material table: the data layer's layout, grown to 192 bytes

**Context**: Two `MaterialGpu` layouts existed: the engine's hand-packed
128-byte struct (src/sim/materials.zig, decisions/30) filled from five
hardcoded materials, and the data layer's 176-byte all-`uint` struct
(src/data/gpu_tables.zig, decisions/03) packed from `materials/*.zon`. The
reactions pass needs nearly every field of the data layout; movement needs
the engine's packed movement word and sort key.

**Decision**:
- The data layer is the single source. The engine uploads
  `gpu_tables.Tables` unchanged: `materialBytes()` to SLOT_BUF_MATERIALS and
  `reactionBytes()` (256 x 256 x 8 B) to SLOT_BUF_REACTIONS (12).
- Data's `MaterialGpu` grows by four words appended before `ramp_len`, as
  decisions/03 prescribes: `move` (phase | dispersion << 8 | slide << 16 |
  vertical_chance << 24, one load for every movement rule), `sort_key`
  (decisions/28), `flame` (gas spawned by burning, also the material whose
  contact ignites it) and `reserved`. Size 192 B, ramp at offset 160.
  `sortKey`, `defaultVerticalChance` and `moveWord` moved into gpu_tables.
- GLSL declares the ramp `uint ramp[8]` (std430 storage buffer: same bytes
  as `uvec4 ramp[2]`), so existing `mt.ramp[i]` code keeps working.
  common.glsl contains `gpu_tables.glsl_material_struct` verbatim; a test in
  src/sim/materials.zig checks it, data's test checks the text against the
  Zig struct. `MATERIAL_FLAG_*` are data's `Flag` bits, mirrored.
  Accessors `mat_phase(move)`, `mat_spawn_temp(m)`, `mat_initial_state(m)`,
  `mat_ramp_len(m)`, `mat_sort_key(m)` remain; `mat_sort_key(uint)` and
  `mat_density` are gone so stale callers fail to compile.
- Deleted: engine `MaterialDesc`, `pack`, `Table`, `MATERIAL_NONE` (no
  transition is the material's own id) and src/sim/materials_builtin.zig.
  src/sim/materials.zig is now `Library` (set + tables, `loadDir`,
  `builtin`), `Ids` (ids scenes and tools use, resolved by name, missing
  ones become air) and `ambientAir`.
- `Library.builtin` is a five-material ZON set (bedrock, sand, smoke,
  stone, water with the shipped ids) for unit tests only. Every executable
  loads `materials/` (or `--materials DIR`) at startup and exits with the
  loader's diagnostics if it fails.
- An empty world is `ambientAir(tables)` (air at its spawn temperature, 24
  C), not zero words: zero is air at -40 C, which would be a heat sink
  keeping every tile next to painted material awake forever. The grid
  clears to it at init; the CPU reference too.
- Schema: `.flammable.flame` (default "flame"; "air" for none). Conductive
  materials keep their charge in state bits 6-7 (decisions/42), so the
  loader rejects health, lifetime counts or burn fuel above 63 for them;
  steel.zon health 255 -> 63 (relative values; damage is not on the GPU
  yet). A boil rule cannot coexist with health or lifetime (boil progress
  uses the state byte, decisions/41).
- Hot reload (src/app.zig): `data.reload.Watcher.poll` every 30 ticks;
  a change rebuilds both tables and uploads them (`Engine.reloadTables`,
  waits idle), re-resolves ids, and the HUD shows "materials reloaded"
  (with a warning when ids moved) or the first loader error for 5 s. A
  broken edit keeps the old tables.

**Alternatives**: mapping data -> the 128-byte engine struct (two encodings
to keep in sync, 13 spare words not enough for burn and lifetime periods);
packing bytes (smaller, but `bitfieldExtract` everywhere and an 8-bit
storage dependency for no measured gain: the table is 48 KB and cached).

**Consequences**: supersedes decisions/30 and the 176-byte size in
decisions/03. A new GPU field is a field in gpu_tables.MaterialGpu, a line
in `glsl_material_struct` and common.glsl (the tests fail until both
match). Other agents' shaders that read `MATERIALS[m].misc*` or
`mat_sort_key(density)` must switch to named fields.
