# Material values not given by the spec

**Context**: The 03-materials.md tables give density, health, impact,
blast, phase thresholds and a few temperatures and lifetimes. Every
material also needs conductivity, drag, a ramp and more.

**Decision**: Starting values chosen for plausibility, to be tuned in play
(all visible in `docs/materials.md`):
- Conductivity: steel 220, molten steel 200, flame 80, water/lava/ice 60,
  molten glass 50, stone/acid/blood 40, bedrock/concrete/glass/gravel/mud
  30, sand/rubble 25, dirt/oil/gunpowder/steam/flesh/bone 20, charcoal/
  moss/blood crust 15, wood/ash/smoke/acid gas 10, air 8.
- Drag: gases 255, ash 240, water 200, acid 180, oil/blood/moss/blood crust
  150, light chips 80–90, dense solids 0–40.
- Gas dispersion: steam 6, acid gas 5, smoke 4, flame 2.
- Heat: lava emits 40 °C/tick, flame 60 (given). Burn heat: charcoal 40,
  wood and oil 24, moss and flesh 16.
- Temperatures: flame spawns at 900 °C, steam at 110 °C, ice at −10 °C,
  flesh, bone and blood at 37 °C.
- Lifetimes: mud dries to dirt after 3600 ticks, blood dries to blood crust
  after 1800; steam, smoke, acid gas and flame decay to air.
- Liquids have blast thresholds (water/oil/acid/blood 10, mud 30, lava and
  molten glass 40, molten steel 60, all `fly`); gases are 0 (moved by the
  air field instead). Moss health 10; blood crust breaks into ash.
- Reaction chances: water + lava 255 (spec), water + dirt 20 (spec), water +
  flame → steam + air 60, sand + lava → molten glass 16, acid on stone 20,
  concrete 24, steel 8, wood 30, flesh 40, bone 4, steam condensing on
  stone, bedrock, concrete, steel, glass and ice 6 at ≤ 60 °C, moss growth
  1 with water catalyst.
- Gravel melts to lava at 1300 °C like stone; rubble stays inert like
  concrete. Molten glass and molten steel burn entities (30 and 50 hp/s)
  and ignite them, like lava.
- Ramps: 4–6 colors per material in hand-picked pixel-art palettes.

**Alternatives**: Leave unset fields at 0 (no conduction, no drag), which
would make most interaction classes inert.

**Consequences**: These numbers are the first thing to tune once the
reaction pass runs; change the ZON files and regenerate the docs.
