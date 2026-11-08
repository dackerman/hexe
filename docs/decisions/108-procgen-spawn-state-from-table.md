# Procgen spawn state comes from the material table

**Context**: `procgen.SpawnState` defaulted steel's state byte to 255 (its
health in the original spec). Decision 42 capped conductive materials'
state at 63 because bits 6-7 hold the electric charge phase, so every
generated steel cell started as a charge-pulse head. Found by the decision
review (docs/09-decision-review.md, contradiction 1).

**Decision**: `world_mode.spawnState` fills the procgen spawn states from
the loaded table's `state_init` (stone, concrete, steel, wood), so the
generator can never disagree with the material files. The struct defaults
remain for the CPU-only tests and the worldgen preview tool.

**Alternatives**: cap in procgen (would drift again); make the loader
reject the preset (procgen has no loader).

**Consequences**: generated steel starts uncharged with health 63; any
future material whose health the loader clamps is handled automatically.
