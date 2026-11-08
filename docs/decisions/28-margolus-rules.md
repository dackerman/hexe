# Margolus movement: offset order, ordering keys, rule order, moved flag

**Context**: the architecture fixes the mechanism (2x2 blocks, four rotating
offsets, 8 substeps, one thread per block, in place) but not the details.

**Decision** (`shaders/sim/grid/{block,powder,liquid,gas}.glsl`,
`movement.comp`, mirrored in `src/sim/reference/grid.zig`):
- **Offset order** (0,0), (1,1), (1,0), (0,1), repeated twice per tick. The
  vertical offset alternates every substep, so falling reaches the
  architecture's 8 px per tick; horizontal alternates every second substep
  (4 px per tick of lateral flow). The order (0,0), (1,0), (0,1), (1,1) would
  halve falling speed to 4 px per tick. One function, `margolus_offset`.
- **Torus**: blocks wrap at the world edge like everything else.
- **Ordering key** per material, derived by `materials.sortKey`: gases use
  their density (< 256), air is 256, powders and liquids are 512 + density,
  statics 65535. An upper cell sinks into a lower *fluid* (liquid, gas, air)
  cell with a strictly lower key. Powders and statics are never displaced.
  So gases rise through air, oil floats on water, sand sinks in water, ash
  floats.
- **Rule order in a block**: vertical (left, right column); diagonal down for
  powders (slide chance) and liquids (always), random order; diagonal up for
  gases, random order; lateral (top row, bottom row) for liquid-gas and
  gas-air pairs with chance `min(dispersion * 32, 255)`. Chance 255 means
  always. Side cells of diagonal moves must be fluid (no squeezing through
  diagonal gaps).
- **Vertical chance**: powders and liquids move every substep they can;
  gases rise with a chance derived from density, `clamp(160 - 12*density,
  24, 200)` (smoke 64/256), overridable per material.
- **Moved flag**: bit 25 means "moved during the last substep this cell's
  block was processed". It prevents a second move inside one block, and a
  lateral swap between two cells that both moved last substep is skipped
  (they most likely just swapped with each other). Without that rule,
  cellular water spreads diffusively; with it a 20x60 column flattens over
  120 px in under 800 ticks (unit test).
- Randomness: `hash(block x, block y, tick, substep)` and one rehash; bytes
  of those are the per-rule rolls.
- Blocks whose four cells share a material skip the rules; cells are
  written only when changed.

**Alternatives**: the listed offset order (slower fall); signed density
instead of keys (gases would sink below air); random lateral direction
state in the cell (needs bits the cell does not have).

**Consequences**: lateral liquid flow is limited to 4 px per tick; fast
water is the FLIP solver's job (M6). Reactions (M3) hook in before each
substep in `Pipeline.recordTick` and may read the moved flag.
