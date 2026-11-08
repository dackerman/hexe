# Reactions and heat pass: structure, pairing, rule order, heat model

**Context**: docs/01 asks for a gather pass before each movement substep
(4 neighbors, reaction table with chance, temperature range and catalyst,
conduction, ignition, melting, freezing, lifetime) that stays bit-exact
with the CPU reference. A gather that writes in place races with
neighbors reading it; a pair reaction must change both cells consistently.

**Decision** (shaders/sim/grid/reactions.comp, reactions_commit.comp,
src/sim/reactions.zig; mirror `reactCell` in src/sim/reference/grid.zig):
- **Once per substep**, before movement, over the active tiles. Two
  dispatches: `reactions` reads only CELLS and writes changed cells to a
  private image NEXT plus a 32-word per-tile change mask (one bit per
  cell); `reactions_commit` copies masked cells back. No cell reads an
  updated neighbor, so the result is order independent. Changed tiles are
  marked. Per-tick rules (emission, burn heat, fuel, lifetime, fire
  products, contact ignition, boil count) run in substep 0 only; per-tick
  rates stay per tick.
- **Pairing**: substeps 0-3 use the domino tilings horizontal-even,
  vertical-even, horizontal-odd, vertical-odd, so every cell has exactly
  one partner per pass (at most one reaction per cell) and each adjacent
  pair is offered once per tick, matching data's per-tick `chance`.
  Substeps 4-7 run no pair reactions. Both cells read the same entry pair,
  the pair temperature `(t_a + t_b) / 2`, the roll
  `hash_pass(first cell, tick, substep, SALT_REACT_PAIR)` and the catalyst
  test over the six cells around the domino, so they agree. A partner in an
  inactive tile (not processed) or body-owned cell blocks the reaction on
  both sides. The emits-event entry appends one event.
- **Rule order per cell**, first material change wins: pair reaction
  (result spawns fresh: spawn temperature, `state_init`, same variant);
  heat; burning; phase change; lifetime; fire products; charge. Body-owned
  cells are skipped entirely.
- **Heat** (integer, bytes): conduction every substep,
  `dT = (sum_n min(k, k_n) * (T_n - T) + rnd13) >> 13` with `rnd13` from the
  cell hash (stochastic rounding: exact on average, zero at equilibrium so
  settled tiles sleep); a conductivity k moves k/1024 of a gap per tick.
  Emission once per tick between different materials: the hotter cell's
  `emits_heat` (+ `burn_heat` if burning) moves `min(e, gap >> 3)` into
  the colder one if that is a solid or liquid (gases are heated by
  conduction only); the emitter loses a quarter of what it gave
  (EMIT_DRAIN_SHIFT 2). So lava ignites what touches it and stays liquid
  under a sand pile, yet a pool still freezes from its walls inward over
  ~2500 ticks. Burning cells heat themselves by `burn_heat` per tick up to
  BURN_TEMP (byte 118, 900 C; nothing melts below that except ice).
- **Burning** (flammable materials): ignites when `t > ignite_at`, or once
  per tick with chance 24/256 next to a burning cell or its own `flame`
  material; health-less fuels then get `burn_fuel` as state; `burn_event`
  is appended. Fuel drops by one every `burn_period` ticks; at zero the
  cell becomes `burns_to` keeping its temperature and variant, still
  burning with fresh fuel if the product is flammable (wood -> burning
  charcoal -> ash). An extinguisher neighbor clears burning and caps the
  temperature at `ignite_at`, except for burning liquids (oil floats on
  water and keeps burning, docs/03).
- **Fire products**: once per tick an air cell next to a burning cell
  (first found from a hashed start direction) becomes that cell's `flame`
  with chance 40/256, else its `smoke` with chance 10/256.
- **Phase change** on the new temperature, keeping temperature and
  variant, state = `state_init`: boil (`t > boil_at`) wins over melt, then
  freeze (`t < freeze_at`). Boiling has latent heat as time: the cell is
  held at `boil_at` and counts ticks in its state byte, boiling after
  BOIL_LATENT (40); below `boil_at` the count resets.
- **Lifetime**: once every `lifetime_period` ticks (`tick % period == 0`)
  the count drops; at zero the cell becomes `decays_to`, spawned fresh
  (flame leaves ambient air, not 900 C air).
- **Charge**: decisions/42.
- Randomness: `hash_pass(x, y, tick, substep, salt)` = `hash(x, y, tick,
  substep | salt << 8)`, salts 0x4e1 (cell) and 0x4e2 (pair).

**Measured** (`zig build bench`, ReleaseFast, RTX 4090, 300 ticks, all
4096 tiles active): reactions 0.44 ms/tick (8 substeps, both dispatches) in
the falling-sand and mixing scenes, 0.57 ms with lava, water, oil and
burning wood everywhere; grid total 0.62 / 0.75 ms against the 2.5 ms
budget. The static world stays at 0.011 ms. So per substep it is.

**Alternatives**: checkerboard in-place updates (a pair reaction needs the
partner's decision, which the other phase cannot see); hash-chosen mutual
partners (too few pairs per pass); a per-tick pass (cheaper, but fire and
charge fronts would advance 8x slower than gases move); conduction per
substep with k/128 per tick (lava crusted under sand in a few ticks);
energy-conserving emission (same); free emission (lava never cools).

**Consequences**: tuning lives in common.glsl defines mirrored in
src/sim/reactions.zig. Fire spread, cooling and boiling speeds are first
estimates, checked only by the scenarios. Temperature is not exchanged
across the edge of the active region (inactive cells do not update); the
change wakes the neighbor tile next tick.
