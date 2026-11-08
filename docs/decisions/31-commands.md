# Command encoding and application

**Context**: M1 asks for a minimal CPU->GPU command list (fill circle, fill
rect) applied before movement.

**Decision** (`src/sim/commands.zig`, `shaders/sim/grid/commands.comp`):
- 8 words per command: kind, material, x0, y0, x1, y1, flags, seed. Circles
  use x1 as radius (max 1000). Coordinates are unwrapped world pixels and
  wrap on the torus.
- Flags: bit 0 only-air; bits 8-15 coverage (0 = every pixel, else a pixel
  is filled when the low byte of its spawn hash is below it). Coverage is
  how scenes scatter material.
- `CommandList` holds 1024 per tick (extra pushes are counted as dropped).
  Seeds derive from (tick, position in list), so identical pushes give
  identical worlds on the GPU and the CPU reference.
- The engine copies each tick's list into a host-visible ring at
  `SLOT_BUF_COMMANDS` (2 slots x 4 ticks x 1024). `Applier.record` issues one
  dispatch per command over its bounding box (origin aligned down to 16,
  size clamped to one world period) with a barrier between commands, so
  later commands win.
- Spawned cells take the material's spawn temperature and initial state and
  a variant from `hash_salt(x, y, seed, SALT_SPAWN_VARIANT) >> 28`.

**Alternatives**: one dispatch testing every command per pixel (cost grows
with world size), indirect dispatch per command (the CPU already knows the
boxes).

**Consequences**: a new command kind adds a `Kind`, a `bounds` case, shader
handling and a reference mirror. Command kinds that are not per-pixel fills
(spray particles, rasterize body) should get their own pass that reads the
same ring.
