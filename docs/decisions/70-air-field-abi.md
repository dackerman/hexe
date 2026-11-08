# Air field ABI: slots, images, buffers, commands, material word

**Context**: M5 adds the air field and the shared obstacle coarsening while
six other branches work in parallel; the liquid solver, the particle
spawner, gameplay and the renderer all need to consume what it produces,
and several of those pieces (particle `eject_cell`, the event queue, the
overlay compositor, the material loader's `feeds_air`/`pressure_event`
fields) do not exist on this branch.

**Decision**:
- Fixed slots, taken as a block (images 8-12, buffers 20-23) instead of
  "next free" so parallel branches do not collide on 2, 3, ...:
  | slot | resource |
  |---|---|
  | `SLOT_IMG_SOLID_COARSE` 8 | r8ui 1024², solid pixels (static phase or body-owned) per 2x2 block, 0-4; `Frame.shared.solid_coarse` |
  | `SLOT_IMG_LIQUID_COARSE` 9 | r8ui 1024², liquid pixels per block; `Frame.shared.liquid_coarse` |
  | `SLOT_IMG_AIR` 10 | rgba32f 1024²: x density (ambient 1.0), yz velocity px/tick, w 1 on walls; `Frame.shared.air` |
  | `SLOT_IMG_AIR_SOURCE` 11 | r32ui 1024², int32 fixed-point mass to add next step (`AIR_MASS_ONE` = 65536 = one cell of ambient air) |
  | `SLOT_IMG_DEBUG_OVERLAY` 12 | rgba8 1024², debug view, additive |
  | `SLOT_BUF_BLAST_EJECTS` 20 | header {count, capacity, dropped, tick} + 65536 × {x, y, vx, vy (f32 px/tick), cell, kind} |
  | `SLOT_BUF_AIR_EVENTS` 21 | header + 1024 × {x, y, kind (1 = pressure), value (overpressure ‰)} |
  | `SLOT_BUF_AIR_TILE_MARKS` 22 | air tile wake countdowns + active flags (like TILE_MARKS) |
  | `SLOT_BUF_AIR_TILE_LIST` 23 | indirect args + active air tiles (like TILE_LIST) |
  Air tiles are 16² lattice cells = one 32² pixel grid tile, same coordinates.
- `shaders/sim/air/air_api.glsl` is the GLSL API for other passes:
  `air_field`, `air_velocity` (particle drag), `air_emit_mass`,
  `air_gas_created` / `air_gas_removed` (the reaction pass calls these
  when it creates or consumes a `feeds_air` gas), `air_mark_tile`.
- Blast ejects: the particles branch's `eject_cell` is not here, so the
  effects pass converts a flying pixel to air itself and appends the record;
  the integrator wires the buffer to the particle spawner (one ballistic
  particle per record at (x+0.5, y+0.5), velocity (vx, vy), material from
  `cell`). Kinds: 1 fly (cell became air), 2 chip (cell stays, lost health),
  3 break (cell removed, no rubble material). The buffer is reset each tick.
- Events: no event queue here either; pressure events go to `AIR_EVENTS`,
  copied back per tick and exposed as `Air.events()` (one frame late). At
  most one event per lattice cell per tick; a plate under steady pressure
  reports every tick (the consumer dedupes).
- Material word 24 (`air`): `pressure_event` (16 bits, ‰ overpressure),
  `rubble` (id, `none` = air), `air_flags` (bit 0 `feeds_air`), in
  `MaterialDesc` as `pressure_event`, `rubble`, `feeds_air`. Word 24 rather
  than 11 because 11 is the first reserved word other branches will reach for.
- `CMD_INJECT_PRESSURE` (kind 3) goes through the ordinary command list
  (`CommandList.injectPressure`, `.explosion`); `commands.bounds` returns
  null for it, so the grid and the CPU reference ignore it.
- Sampling: `Air.requestSample(x, y)` (64 per frame), `Air.samples()`;
  `Air.field_readback = true` + `Air.field()` for 256² cells of 8x8 px
  {density, vx, vy, open fraction}; results are collected with the frame
  (the engine calls `Air.collect`), i.e. one frame after submission.
- Coarsening does not yet carry body velocity per block (bodies-gpu work).

**Alternatives**: one RGBA8 coarse image (the liquid branch was told to
expect `solid_coarse` as r8ui); events/ejects through CPU readback only
(the particle spawner is GPU-side).

**Consequences**: integration renumbers nothing unless another branch also
took 8-12 / 20-23. Wiring needed at merge: ejects → particle spawner,
pressure events → the shared event queue, `air_gas_created` calls in the
reaction pass, loader fills word 24.
