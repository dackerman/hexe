# Lifetimes and burn times longer than the state byte

**Context**: 03-materials.md says lifetime "uses state byte", but smoke
lives 1200 ticks, steam 600, mud would dry over minutes, and charcoal burns
900 ticks; the state byte holds 0–255. Burning "consumes health", and
wood's 600 burn ticks are more than its 120 health.

**Decision**: Durations stay in ticks in the ZON files. The packer splits
each into a state count ≤ 255 and a period: the GPU decrements the state
byte once every `period` ticks (`tick % period == 0`, or a hash chance of
1/period). `packTicks` picks `period = ceil(ticks / 255)` and
`count = ceil(ticks / period)`, exact for the shipped values (smoke 240 ×
5, steam 200 × 3, mud 240 × 15). For burning:
- with health (wood, charcoal, moss, flesh) the state byte is health,
  `burn_fuel = health` and `burn_period = round(burn_ticks / health)`
  (wood 120 × 5 = 600);
- without health (oil, gunpowder) ignition sets the state to `burn_fuel`
  from `packTicks(burn_ticks)`.
`state_init` in `MaterialGpu` is the byte a cell gets when it becomes the
material (health, else lifetime count, else 0). Because health, lifetime
and health-less burning share the byte, the loader rejects lifetime
together with health, and lifetime together with health-less burning.

**Alternatives**: A wider state field (costs a cell bit layout change);
stochastic decay with chance only (no hard upper bound on lifetime).

**Consequences**: Long lifetimes have a granularity of `period` ticks. A
material needing both health and lifetime needs a cell-format change.
