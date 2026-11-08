# Materials

This document specifies the material schema and the version one material
set. Once the loader exists, the per-material tables below are replaced by a
generated `materials.md` produced from the ZON files by `zig build docs`, so
the data and the documentation cannot drift. The schema section stays
hand-written.

## Schema

One ZON file per material in `materials/`. Every field has a default that
means "not in this class", so a file lists only what matters. Names
reference other materials by file name; the loader resolves them to ids and
rejects unknown names, cycles in phase-change chains, and missing ramps.

```zig
.{
    .name = "water",
    .id = 29,                    // optional explicit id 1–255; see decisions/01
    .phase = .liquid,            // .static, .powder, .liquid, .gas
    .solver = .flip,             // .cellular (default) or .flip; liquids only
    .density = 100,              // integer ordering; heavier displaces lighter
    .dispersion = 5,             // liquid/gas sideways spread per substep, 0–8
    .slide = 0,                  // powder diagonal-slide chance, 0–255
    .health = 0,                 // 0 = indestructible by damage; else initial state byte
    .lifetime = 0,               // ticks until decay, 0 = never; uses state byte (count × period, decisions/05)
    .decays_to = null,           // material on lifetime expiry
    .temperature = 20,           // spawn temperature, °C
    .conductivity = 40,          // heat diffusion rate, 0–255
    .emits_heat = 0,             // °C added to neighbors per tick
    .melt = null,                // .{ .at = 1200, .to = "molten_glass" }
    .freeze = null,              // .{ .at = 0, .to = "ice" }
    .boil = .{ .at = 100, .to = "steam" },
    .flammable = null,           // .{ .ignite_at = 300, .burn_ticks = 600, .to = "charcoal", .smoke = "smoke", .heat = 24, .event = .none, .flame = "flame" }
    .conductive = true,          // carries electricity
    .impact = .splash,           // .none, .splash, .spray, .chip, .dent, .ricochet
    .ricochet = false,           // also ricochets, for .dent materials (steel)
    .blast_threshold = 10,       // pressure gradient that moves/breaks it; 0 = immune
    .blast_response = .fly,      // .fly, .chip, .@"break" (break is a Zig keyword)
    .rubble = null,              // material chips and breakage land as; null = itself
    .drag = 200,                 // how strongly ballistic particles of it follow air, 0–255
    .pressure_event = 0,         // pressure that appends a pressure event; 0 = never (04-fluids)
    .on_contact = .{ .slow = 0.5, .drown = true },
    .emissive = 0,               // 0–255 light emission
    .glow = null,                // .{ .from = 500, .to = 1200 } temperature glow range
    .translucent = true,
    .blocks_light = false,       // non-solid that blocks light (smoke)
    .extinguishes = true,        // puts out burning neighbors
    .feeds_air = false,          // creation injects mass into the air field (steam)
    .anchor = false,             // connectivity anchor (bedrock)
    .ramp = .{ 0x1a3a6b, 0x215091, 0x2a66b5, 0x3a7ad0 },
    .reactions = .{
        .{ .with = "lava", .self = "steam", .other = "stone", .chance = 255 },
        .{ .with = "dirt", .self = "mud", .other = "mud", .chance = 20 },
    },
}
```

**Air** is material 0, defined by the engine rather than a file: a gas with
no lifetime, no mass contribution, density 0. Every empty cell is air.

**Reactions** are symmetric at load time: an entry on either side produces
one table entry. Each entry may carry `.min_temp`, `.max_temp`, `.catalyst`
(a third material that must also be adjacent), and `.event` (an event id to
append when it fires). `.self` and `.other` may be `null` to mean unchanged
or `"air"` to mean consumed.

**Phase changes** are reactions with the cell's own temperature as the
condition and are listed separately only for readability. Melt and boil
fire strictly above `.at`, freeze strictly below it, so a melt and a
freeze at the same temperature are stable there (decisions/04).

**Color ramp**: four to eight colors. The variant bits pick one at spawn
and keep it as the pixel moves. Temperature glow blends toward the hot end
of the ramp and adds emission.

## Version one set

Values are starting points to tune in play, not physics.

### Solids

| material | phase | density | health | impact | blast | heat behavior | notes |
|---|---|---|---|---|---|---|---|
| bedrock | static | 1000 | 0 | ricochet | immune | inert | world floor, connectivity anchor, unbreakable |
| stone | static | 300 | 200 | chip | 200, break | melts to lava at 1300 | default cave rock |
| concrete | static | 280 | 180 | chip | 150, break | inert | shatters: chip debris, crack pattern, chunks fall as bodies, breaks into rubble |
| steel | static | 800 | 255 | dent, ricochet | immune | conducts heat fast, melts to molten steel at 1500 | conductive; as a body it bends and snaps |
| wood | static | 60 | 120 | chip | 80, break | ignites at 300, burns 600 ticks to charcoal, emits smoke | floats as rubble, falls as bodies |
| charcoal | static | 50 | 60 | chip | 60, break | ignites at 400, burns 900 ticks to ash | hotter, longer fire |
| glass | static | 250 | 40 | chip | 30, break | melts to molten glass at 1200 | translucent; shatters easily; pressure event when broken |
| ice | static | 90 | 80 | chip | 60, break | melts to water at 0 | slippery on_contact |

### Powders

| material | density | slide | impact | blast | notes |
|---|---|---|---|---|---|
| sand | 150 | 200 | spray | 20, fly | melts to molten glass at 1200; sand + water → wet sand (later) |
| dirt | 140 | 60 | spray | 25, fly | dirt + water → mud (cellular liquid, slow) |
| gravel | 160 | 120 | spray | 40, fly | byproduct of stone |
| rubble | 170 | 100 | spray | 40, fly | byproduct of concrete |
| ash | 30 | 220 | spray | 5, fly | byproduct of burning; drifts in air |
| gunpowder | 120 | 150 | spray | 15, fly | ignites at 200; on ignition appends `explode` event and becomes smoke |

### Liquids

| material | solver | density | dispersion | temp | notes |
|---|---|---|---|---|---|
| water | flip | 100 | 5 | 20 | boils to steam at 100, freezes to ice at 0; conductive; drowns, slows; extinguishes burning cells |
| lava | cellular | 270 | 1 | 1100 | emits heat; ignites; water contact → stone + steam; cools to stone below 700; emissive, glow |
| oil | cellular | 80 | 4 | 20 | floats on water; ignites at 250, burns 400 ticks to smoke; stains entities; fire spreads across its surface |
| acid | cellular | 110 | 4 | 20 | dissolves stone, concrete, steel, wood, flesh with chance; self → acid gas on reaction; corrodes entities |
| mud | cellular | 130 | 1 | 20 | dirt + water; slows entities; dries to dirt over time |
| molten_glass | cellular | 240 | 1 | 1200 | cools to glass below 800; emissive |
| molten_steel | cellular | 780 | 1 | 1500 | cools to steel below 1300; emissive; conducts |
| blood | cellular | 105 | 4 | 37 | byproduct of entities; stains; dries to a dark static crust over time |

### Gases

| material | density | lifetime | notes |
|---|---|---|---|
| steam | 5 | 600 | from boiling water; condenses to water on cold surfaces (temp < 60) with chance; adds mass to air field |
| smoke | 8 | 1200 | from burning; blocks light; follows air field |
| acid_gas | 9 | 300 | from acid reactions; corrodes entities |
| flame | 3 | 20 | spawned above burning cells; emits heat 60 and light; ignites; decays to air |

### Growth

| material | notes |
|---|---|
| moss | static; grows onto stone adjacent to water with low chance; burns fast to ash; purely to exercise the class |

### Entity materials

Produced when characters die or bleed. Corpses are bodies made of these
cells and obey every rule above.

| material | phase | density | health | notes |
|---|---|---|---|---|
| flesh | static | 110 | 60 | burns at 350 to ash with smoke; dissolved by acid; floats in water as rubble-sized chunks |
| bone | static | 180 | 150 | chips; immune to fire; dissolved slowly by acid |
| blood_crust | static | 100 | 20 | dried blood; chips to dust-like ash |

Chips, shards and splinters are not separate materials: they are ballistic
particles of the parent material (glass, wood, stone) that land as the
parent material or as its listed rubble.

## Interaction matrix highlights

| A | B | result |
|---|---|---|
| water | lava | steam + stone; pressure rises in sealed spaces |
| water | burning cell | extinguish; steam |
| water | steel or water | conducts electricity |
| lava | sand | molten glass |
| lava | wood, oil, gunpowder | ignition by heat |
| lava | steel | heats it; steel conducts heat onward |
| acid | stone, concrete, steel, wood | dissolve with chance; acid gas |
| oil | water | floats; burning oil on water keeps burning |
| dirt | water | mud |
| gunpowder | flame or heat | explode event |
| steam | cold stone | condense to water |
| blast | sand, dirt, ash | fly as particles |
| blast | glass, wood, concrete | chip, then break, then connectivity |

## Entity contact effects

| material | effect |
|---|---|
| water | buoyancy, slow 50%, drown after 5 s submerged, extinguish burning status, wet status (conducts) |
| lava | burn 40 hp/s, ignite |
| acid, acid_gas | corrode 15 hp/s, strip armor status |
| oil | oily status: flammable, slippery |
| mud | slow 70% |
| ice | slippery |
| flame | ignite |
| smoke | blind if submerged |
| steam | burn 5 hp/s |
| blood | bloody status (cosmetic, enemy scent later) |

## Byproduct graph

```
wood ─burn→ charcoal ─burn→ ash
wood ─blast→ wood chips (particles) + wood
stone ─blast→ gravel ; ─melt→ lava ─cool→ stone
concrete ─blast→ rubble ; ─loose→ body ─land→ rubble
sand ─melt→ molten_glass ─cool→ glass ─blast→ glass shards (particles)
steel ─melt→ molten_steel ─cool→ steel
water ─boil→ steam ─condense→ water ; ─freeze→ ice ─melt→ water
dirt + water → mud ─dry→ dirt
oil ─burn→ smoke
gunpowder ─ignite→ explode event + smoke
acid + solid → acid_gas
entity ─die→ body(flesh, bone) + blood ─dry→ blood_crust
```

Every arrow is data. If a byproduct does not exist yet, the loader fails at
startup and names the missing material.
