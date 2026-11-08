# Air field active tiles

**Context**: 04-fluids.md asks for active-tile masking so still air costs
nothing, with an always-on fallback.

**Decision**:
- Air tiles = grid tiles (16² lattice cells, 32² pixels), one byte wake
  countdown each (`AIR_WAKE_TICKS` = 4), compacted once per tick after
  prep and injection marking into an indirect list used by the LBM steps,
  the effects pass, and next tick's gas advection.
- A tile marks itself and its 8 neighbors when, in any step, a cell has
  |u| > 2e-4 (lattice), a clamp engaged, or a source was applied. Prep marks
  where walls changed and where heat drives buoyancy; injections and
  `air_emit_mass` mark their tiles; damage in the effects pass keeps its
  tile awake. Density offsets alone do not keep a tile awake: a sealed room
  at 1.2 ambient and at rest sleeps (and keeps its pressure).
- A sleeping tile is not stepped, so its two ping-pong buffers keep equal,
  at-rest values that neighbors may pull; a tile only sleeps after 4 quiet
  ticks (16 steps), so both buffers hold the rest state.
- `--air-all-active` (`Config.air_sleep = false`) steps every tile.

**Alternatives**: per-step compaction (waves move at most 4 cells per tick,
neighbor marking covers 16); density-deviation criteria (would keep every
pressurized room awake forever).

**Consequences**: `zig build air-test` gives identical numbers with and
without masking. Tiny residual waves below the threshold freeze in place.
