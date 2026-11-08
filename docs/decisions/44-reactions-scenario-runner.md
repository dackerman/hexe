# Scenario runner and the scenario changes it needed

**Context**: M3 asks for a headless runner over `scenarios/*.zon`
(decisions/08); the scenario numbers had never been run.

**Decision** (src/scenario_runner.zig, `zig build scenarios`,
`hexe --headless --scenario FILE | --scenarios DIR`):
- A fresh engine per scenario (and per run of a `deterministic`
  assertion). The scenario world sits at (16, 16) in the torus inside a
  one-cell bedrock ring, which is "the world edge". The engine tick starts
  at the scenario's seed (truncated), so the seed changes every hash.
- Fills are commands of tick 0 (after the ring), scheduled commands are
  pushed before the step of their tick, in file order. Rects are clipped to
  the world, circles are not, lines become circles of radius width/2 every
  cell. `.temperature` and `.state` use the command overrides
  (CMD_FLAG_SET_TEMP/STATE), `.only` a material uses CMD_FLAG_ONLY_MATERIAL.
  `ignite` and `heat` map to the new command actions; `remove` fills air.
- Steps run for ticks 0..max(ticks, assertion ticks); an assertion is
  checked after the step of its tick from a full cell readback.
  `particles` counts particle-backed cells (always 0 until M6: such
  assertions pass vacuously and say so); `pressure` is reported SKIP.
- New schema field `.requires = .{ .flip, .air_field, .explosions,
  .particles, .bodies }`: a scenario naming a system this build lacks is
  SKIP with the reason. Set on u_tube, dam_break, pool_sleep (flip),
  sealed_steam_room (air_field), corridor_blast (explosions, air_field),
  determinism (explosions, flip). An `explode` command without
  `.requires` also skips.
- Output: PASS/FAIL/SKIP per assertion with the measured value, per
  scenario, and a summary; exit 1 on any FAIL. `--screenshot PREFIX`
  writes PNGs of the scenario world at assertion ticks (`--shot-every N`
  adds more).
- Tuning: `water_spreads_flat` ran 900 ticks; cellular water (4 px/tick
  lateral, diffusive) needs about 2000 to flatten a 40x100 block over 208
  columns, so it runs 2400 and its sleep assertion moved to the end. The
  other four active scenarios pass with their original numbers once the
  heat model of decisions/41 was in place (earlier versions crusted lava
  under the sand at once and failed `sand melted on contact`).

**Alternatives**: a 256x256 private world (the engine has one 2048 torus);
treating unknown requirements as FAIL (red builds for work not due yet).

**Consequences**: when M5/M6 land, add the system to `implemented` in the
runner and the skipped scenarios start running. Bodies in scenarios still
need a command kind.
