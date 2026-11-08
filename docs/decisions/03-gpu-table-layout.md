# GPU material and reaction table layout

**Context**: The material table and the 256 × 256 reaction table are
uploaded to the GPU; another agent writes the shaders in parallel. The
layout must be unambiguous in both Zig and GLSL.

**Decision**:
- `MaterialGpu` is an `extern struct` of 36 `u32` fields followed by
  `ramp: [8]u32` at offset 144 (GLSL `uvec4 ramp[2]`); 176 bytes. Only
  `uint` scalars and a 16-aligned `uvec4` array means std140 and std430
  produce the same offsets and a 176-byte array stride. The GLSL text is
  `gpu_tables.glsl_material_struct`, checked against the Zig struct by a
  test; the offset table is also in `docs/materials.md`.
- Every scalar is a full `u32` rather than packed bytes: 45 KB total, and
  the shader reads fields directly without `bitfieldExtract`.
- Temperatures are temperature bytes; rates (`emits_heat`, `burn_heat`) are
  temperature-byte steps per tick.
- "No rule" is encoded so the rule can never fire, keeping shaders
  branch-free: melt/boil/ignite at 255 (they fire on `t > at`), freeze at 0
  (`t < at`), targets equal to the material's own id. Flags `melts`,
  `freezes`, `boils`, `flammable` exist for early-outs.
- Ramp colors are RGBA8 with red in the low byte (`unpackUnorm4x8`). The
  4–8 authored colors repeat cyclically to fill 8 slots, so both
  `ramp[variant & 7]` and `ramp[variant % ramp_len]` work. Alpha is 255,
  160 for translucent materials, 0 for air.
- `ReactionEntry` is 8 bytes: self_result, other_result, chance, min_temp,
  max_temp, catalyst, event, flags. The table is indexed
  `[self * 256 + neighbor]` and read as `uvec2` from a std430 buffer
  (std140 would pad to 16 bytes). Unchanged is the cell's own id, consumed
  is 0, `chance = 0` means no reaction. `flags` bit 0 = has catalyst (so air
  can be a catalyst), bit 1 = emits event, set on exactly one direction of
  a pair (`self ≤ neighbor`) so one firing appends one event.
- Symmetry: a reaction declared on either side writes `[a][b]` and `[b][a]`
  with self/other swapped and all other fields equal. The gather pass must
  derive its random number from the unordered pair so both cells agree.
- Unused ids hold an inert, static, magenta/black placeholder with flag
  bit 31 `missing`.

**Alternatives**: Packed `u8` fields with `GL_EXT_shader_8bit_storage`
(smaller, needs an extension and careful alignment); a texture for the
material table.

**Consequences**: The GPU side's provisional struct can be replaced by the
GLSL text verbatim. Adding a field means appending before `ramp_len` and
keeping the ramp 16-aligned (pad with `_pad` fields if needed); the layout
test fails until the GLSL text matches.
