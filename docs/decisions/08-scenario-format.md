# Scenario file format

**Context**: 08-engineering.md says scenarios are ZON files with a small
world, a tick count and assertions on cell counts. The six scenarios in
04-fluids.md also need pouring, removing a dam, a 1-health wall, an
explosion, pressure, sleep state and a determinism check. The runner is
written by another agent.

**Decision**: See `scenarios/README.md` for the full format. Choices
beyond the brief:
- y grows downward, origin top-left (image convention, matches the PNG
  screenshots). Default world 256 × 256, max 2048.
- Shapes are written as exactly one of `.rect`, `.circle`, `.line` inside
  the fill or region, rather than a nested `.shape` union, for readability.
- Fills take optional `.temperature`, `.state` (for the 1-health wood wall)
  and `.only` (paint only over one material, used for pouring).
- Commands: `fill`, `remove`, `ignite`, `heat`, `explode`, each repeatable
  with `.every`/`.until`.
- Assertions: `count`, `at`, `none` as asked, plus `particles` (awake
  liquid cells, for sleep/wake), `pressure` (air density relative to
  ambient), `deterministic` (rerun and compare cell images), each with an
  optional `.tick` and `.label`.
- `parse` validates structure (shapes, bounds, ticks, ranges);
  `checkMaterials` validates names against a loaded `MaterialSet`, so
  scenarios can be parsed before materials load.
- `pool_sleep` drops a gravel blob instead of "a stone": scenarios have no
  rigid bodies, and static stone does not fall.
- All numeric thresholds in the shipped scenarios are first estimates.

**Alternatives**: A scripting language for commands (overkill); encoding
sleep as a material count (sleep is not a material).

**Consequences**: The runner needs a command per action kind and readback
of material counts, particle-backed flags, air density samples and a
cell-image hash. Bodies in scenarios would be a new command kind.
