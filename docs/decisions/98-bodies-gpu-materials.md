# Body materials resolved by name; missing ones appended to the M1 table

**Context**: the engine still runs the hardcoded M1 table (air, stone, sand,
water, smoke); bodies need concrete, steel, wood, rubble, gravel, bedrock.
The ZON loader's table has them, with other ids.

**Decision**: `bodies_materials.ensureMaterials(table)` appends those six,
with the values of the ZON files, when the table lacks them (headless with
bodies on, and the windowed app). `bodies_materials.Table.build` resolves
everything by name: Box2D density (decision 15 presets for steel, wood,
concrete; grid density · 1.25e-3 kg/px otherwise), breakup thresholds and
rubble products, anchor materials, liquid densities.

**Consequences**: ids of existing materials do not change, so the
determinism scene and the reference are unaffected (bodies are off there and
the table is unchanged). Switching the engine to the ZON table needs no
change here. Hot reload of materials does not refresh the bodies table yet.
