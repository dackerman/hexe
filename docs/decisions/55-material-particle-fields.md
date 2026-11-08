# Material fields for particles: rubble, restitution, ricochet; three builtin materials

**Context**: impact and eject responses need a chip/break product
(`.rubble` in the data schema, decision 06), steel's "dent and ricochet"
(`.ricochet`), and a bounce coefficient. The engine's `MaterialGpu`
(decision 30) had none of them, and the engine still runs on the builtin
table of M1 (air, stone, sand, water, smoke), which has no dirt for the M4
done scene.

**Decision**:
- `MaterialGpu` word 11 (`impact2` in common.glsl): `rubble` (byte 0, id,
  255 = none), `restitution` (byte 1, /255, 0 = engine default), two spare
  bytes; reserved words are now 12-15. `MATERIAL_FLAG_RICOCHET` (0x10) in
  the flags word, set for `.ricochet = true` or `.impact = .ricochet`.
  `MaterialDesc` gained `ricochet`, `rubble`, `restitution`.
- Builtin table: stone's rubble is gravel; appended dirt (5), gravel (6)
  and steel (7, dent + ricochet, restitution 150) with the values of their
  ZON files. Ids 0-4 are unchanged, so existing scenes and the determinism
  check are untouched.

**Alternatives**: a separate particle material table (one more buffer for
three bytes); hard-coding rubble by material id.

**Consequences**: the integrator mapping the data layer's table
(`src/data/gpu_tables.zig`, which already has `rubble` and a ricochet flag)
onto the engine's `MaterialGpu` fills word 11 and the flag. Restitution is
not in the ZON schema yet; 0 means the defaults in decision 51.
