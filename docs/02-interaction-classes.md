# Interaction Classes

An interaction class is a mechanism the engine provides. Every material is a
combination of class memberships configured by data. The rule for this
project: every class has at least one representative material in the version
one set, so the mechanism is built and tested before anyone needs it for a
material we have not thought of yet.

Adding a material in an existing class is one file in `materials/`. Adding a
class is engine work: a rule file under `shaders/sim/grid/`, a hook in the
pass that owns it, a row here, and a representative material.

## The classes

| class | engine mechanism | owning pass | representatives |
|---|---|---|---|
| static solid | cell never moves; optional health byte | movement | concrete, stone, bedrock |
| powder | Margolus fall and slide, slide probability | movement | sand, dirt, gravel, rubble, ash |
| cellular liquid | fall, spread, dispersion, density ordering | movement | lava, oil, acid, blood |
| solver liquid | FLIP particles with pressure projection; sleeps to cellular | liquid solver | water |
| gas | inverted gravity, lifetime decay, advected by the air field | movement, air | steam, smoke |
| transient energetic | lifetime, emits heat and light, ignites neighbors | reactions | flame |
| temperature phase change | temperature byte, conductivity, melt and freeze rules | reactions | water↔steam, water↔ice, lava→stone, sand→molten glass→glass, steel→molten steel |
| contact reaction | pairwise table entry with probability, temperature range, optional catalyst | reactions | acid on stone and steel, water on lava, dirt and water → mud |
| burning | burning flag, fuel health, burn product, smoke emission | reactions | wood, oil, charcoal, gunpowder |
| event emitter | GPU appends to the event queue; CPU reacts next tick | reactions, air | gunpowder ignition, pressure trigger, entity-in-lava |
| impact response | per-material response to particle or body impact: splash, spray, chip, dent, ricochet | particles, bodies | water, dirt, concrete, steel |
| blast response | pressure-gradient threshold; fly, chip, break | air | sand, glass, wood, concrete |
| field propagation | charge flag spreads through conductive cells with lifetime | reactions | electricity through water and steel |
| growth | slow reaction conditioned on a catalyst neighbor | reactions | moss on wet stone |
| body-backed cells | owner id per cell; rasterized from a body each tick | bodies | steel beams, concrete chunks, corpses |
| structural support | connectivity after destruction; islands become bodies | bodies | concrete, wood, stone |
| entity contact | per-material effect on characters touching it | gameplay via readback | lava burns, water drowns and slows, acid corrodes, oil stains |
| rendering | palette ramp, variant shades, emissive, temperature glow, translucency | render | lava, flame, glass, water |

## Class notes

**Static solid vs body-backed.** A steel wall drawn into the terrain is a
static solid: it dents, ricochets and finally breaks, but it does not bend.
A steel beam authored as a body bends and snaps. The material file is the
same; the difference is whether world generation placed it as cells or as a
body. Connectivity converts static solids into bodies when they come loose.

**Cellular liquid vs solver liquid.** Both are liquids in the material
schema. The `solver` field picks the path. Cellular liquids never leave the
grid. Solver liquids sleep as cellular liquids and wake as particles. Any
cellular liquid can be promoted to solver later by flipping the field once
variable density lands.

**Burning vs flame.** Burning is a flag on a fuel cell. Flame is a gas
material spawned above burning cells. Fuel loses health while burning and
becomes its burn product at zero. Flame carries heat and light and ignites
by raising neighbor temperature past their ignition point. Fire therefore
spreads through hot steel plates and across oil surfaces without a
dedicated rule.

**Impact vs blast.** Impact is a particle or body hitting a cell: the cell's
material decides whether the hitter splashes, the target sprays, chips or
dents. Blast is the air field pressing on a region: the cell's threshold
decides whether it flies, loses health or ignores it. Both produce particles
and both feed connectivity.

**Event emitter.** The only path from a GPU rule back to gameplay. An event
is a cell position, an event id and a small payload. Gunpowder appends an
event when ignited; the CPU reads it next tick and issues an explosion
command, which is what actually destroys things and shakes the air field.
Spells that trigger on world conditions work the same way.

**Entity contact.** Entities are not cells. Each tick the readback delivers
the materials under and around every entity, and gameplay applies the
material's `on_contact` effects: damage per second, movement multiplier,
status effect, buoyancy. A corpse is converted into a body-backed set of
flesh and bone cells and then obeys everything above.

## Checklist for a new material

1. Which classes does it belong to? Fill only those fields.
2. Does every reaction it names reference an existing material? The loader
   rejects unknown names.
3. Does it have a color ramp and, if emissive, a glow curve?
4. If it is a byproduct, does the producing material name it?
5. Add a scenario if it has a behavior worth protecting.

## Checklist for a new class

1. Write the mechanism in one rule file; it must be deterministic and
   integer-only in grid passes.
2. Hook it into the owning pass behind a material flag so materials outside
   the class pay nothing.
3. Add the schema fields with defaults that mean "not in this class".
4. Add a representative material and a scenario.
5. Add a row to the table above and a note if the class interacts with
   another in a non-obvious way.
