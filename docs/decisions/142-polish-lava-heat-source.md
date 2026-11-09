# Polish: lava is a heat source against rock

**Context**: decision 41 lets an emitter lose a quarter of the heat it
emits (`EMIT_DRAIN_SHIFT`), so lava does not stay hot forever; it also
conducts into its neighbors. Enclosed by rock, which is an unlimited heat
sink, a pool froze to stone in a few hundred ticks, and the level repainted
its lava every 20 ticks (decision 132). Requirements: a pool enclosed by
rock and not touching water stays molten for at least 10 minutes at 60 Hz;
where water touches it, it crusts within seconds; exposed to air it cools
slowly.

**Decision** (`reactions.comp` heat section, mirrored in the CPU
reference): a cell of a non-gas material with `emits_heat > 0` (lava; flame
is a gas and excluded) at or below its spawn temperature is a heat source:
it loses nothing to colder static or powder neighbors, neither by
conduction nor by the emission drain. It still emits into them (rock
around a pool heats up), and it still loses heat by conduction and
emission drain into liquids (water quenches it) and by conduction into
gases (an open surface cools slowly and crusts). Above its spawn
temperature (the glassworks' 1256 C feed, a cell heated by fire) it cools
normally down to it. Lava is "fed from below".

The water side is unchanged: the water + lava pair reaction (chance 255)
crusts lava to stone at the first contact, and the crust is solid, so the
lava under a crust keeps its heat (a lava lake under its skin).

**Measured** (`scenarios/lava_enclosed.zon`, new `.temperature`
assertion: mean °C of a material in a rect):
- 40 x 20 lava sealed in a stone block: main 784 lava cells at tick 300,
  704 at 600, 412 at 1200, 0 at 3600. Now 800 of 800 at every check, mean
  temperature 1104 C (the spawn byte) at 300 and at 3600: it loses no heat,
  so 36000 ticks (10 minutes) extrapolate to 800 of 800. The assertion is
  >= 99% (792) at 3600.
- 40 x 20 pool open to air on top (in a stone pit): main 789 at 300, 0 at
  3600. Now 800 at 3600; mean temperature 1104 -> 1048 C (tick 300) -> 984
  (1200) -> 880 (3600); the surface row is at 816 C at 3600, losing about
  0.08 C per tick, so it crusts (700 C) around tick 5000 (80 s), after
  which the crust shields the lava under it.
- Water: `lava_water.zon` unchanged (steam at tick 120, 116 stone cells of
  crust at 600; the reaction crusts at contact).
- Level (`proving_grounds`, 3600 ticks, no repaint): steam room lava floor
  1800 of 1800 cells, hut seep 476 of 476; the arena pit loses lava only
  where water flows into it (same as before the change).
- verify-determinism: 0 cells differ (lava, water and burning in the
  determinism scene).

**Alternatives**: a smaller drain per material (`emits_heat` loss factor:
conduction into rock alone still froze the pool, decision 41 measured
~2500 ticks); no drain into solids only (same: conduction remains);
an equilibrium rule keyed on the neighbor's temperature (still a slow leak
into an unlimited sink).

**Consequences**: lava sprayed by the player onto rock stays molten until
its air-exposed surface crusts (about a minute and a half for a layer one
cell thick), instead of freezing in a few seconds. Energy is not conserved
around lava: rock near a pool keeps heating toward the lava's temperature
(stone melts only at 1300 C, above lava's 1100 C, so the rock does not
melt). The level's lava repaint is gone (decision 132 update).
