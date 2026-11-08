# Phase-change thresholds, rounding and pair temperature

**Context**: 03-materials.md has ice melting "at 0" and water freezing "at
0", lava cooling "below 700", steam condensing on surfaces "below 60". With
an 8 °C temperature byte, inclusive comparisons on both sides would flip a
cell every tick at exactly the threshold. Reactions carry `min_temp` and
`max_temp` but the spec does not say whose temperature.

**Decision**:
- °C → byte rounds to nearest, ties up (`(c + 44) / 8`), clamped to 0–255.
  `toCelsius(t) = 8t − 40` is exact. 100 °C is byte 18 (104 °C).
- Melt, boil and ignition fire when `t > at`; freeze fires when `t < at`.
  A melt and a freeze at the same °C are therefore both stable there.
- If a material has both melt and boil, boil wins when both are active and
  `boil.at` must be above `melt.at`. A material whose freeze threshold is
  more than one byte above a melt/boil threshold is rejected (both would
  fire in between).
- The ping-pong check: for every temperature byte, follow the active
  transition from each material; a cycle (A → B → … → A all enabled at the
  same byte) is rejected with the chain and the temperature. Lifetime decay
  and burning are not part of this check: they take time, so they cannot
  flip at a single temperature.
- Reaction temperature bounds are inclusive and compare against the pair
  temperature `(t_self + t_neighbor) / 2` (integer). It is symmetric, so the
  mirrored table entries keep identical bounds.
- Steam condenses through reactions with cold solids (`max_temp = 60`), not
  through a freeze rule, matching "condenses on cold surfaces"; free steam
  decays to air after its lifetime.

**Alternatives**: Inclusive thresholds with a hysteresis margin added by
the loader (hidden behavior). Bounds on the cell's own temperature (the two
mirrored entries would test different cells).

**Consequences**: Authors write the physical threshold and get stable
behavior at it. A chain that does ping-pong fails at load with a message
naming the files.
