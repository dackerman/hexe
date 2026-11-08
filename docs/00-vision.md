# Hexe: Vision

Hexe is a 2D action game set in a world where every pixel is a physically
simulated piece of material. The player is a witch who fights through caves
and ruins with weapons and spells whose effects are not scripted outcomes but
real consequences in the simulation. Fire spreads because wood is hot. Water
floods a room because a wall is gone. An explosion kills because its pressure
wave reaches you.

The lineage is Noita. The departure is that Hexe simulates pressure: both
water with momentum and air with shockwaves. That one change turns the world
from a pile of reactive pixels into a system the player can reason about and
exploit.

## Pillars

1. **Everything is material.** Terrain, debris, fluids, smoke, corpses. There
   are no decorative pixels. If it is visible, it has a material id and obeys
   that material's rules.
2. **Pressure is real.** Gas has pressure that propagates as waves and builds
   in sealed spaces. Liquids have momentum, level out, flow around obstacles,
   and burst through weak walls. Approximate, but consistent enough that a
   player can plan around it.
3. **Creative lethality.** Enemies die to the same rules as everything else.
   Burn, drown, crush, corrode, electrocute, bury, blast, launch. Weapons are
   tools for moving energy and material around; the kill is emergent.
4. **Data over code.** Adding a material or an interaction is a data change.
   The engine provides a fixed set of interaction classes, each exercised by
   at least one material from day one, so that new ideas slot in without
   rearchitecting.
5. **Performance is a feature.** The simulation runs on the GPU in Zig and
   Vulkan. A smaller active world on stronger hardware is an acceptable trade
   for richer simulation. A 4090-class card is the design target, a 3060-class
   card the minimum.

## What the world can do

- Dirt sprays and piles. Sand flows. Concrete chips, cracks and shatters, and
  disconnected chunks fall as rigid bodies. Steel dents, ricochets bullets,
  bends under load and finally snaps.
- Water splashes, sloshes, equalizes between connected basins, siphons,
  floods through a breach as a wave, and compresses air pockets.
- Lava flows slowly, ignites what it touches, melts sand into glass, and
  turns to stone when water hits it, releasing steam that raises pressure.
- Fire spreads through heat as well as contact, consumes fuel to charcoal
  and ash, fills rooms with smoke that follows real air currents, and vents
  pressure through the nearest opening.
- Explosions emit a pressure pulse that reflects off walls, channels down
  corridors, blows powders and weak solids apart by pressure gradient alone,
  and is deadlier in confined spaces.
- Electricity propagates through water and steel.

## What the world does not do

See the limits section of the architecture document. In short: no true
supersonic shocks, no sub-two-pixel fluid flow, no load-bearing stress
analysis, no sub-pixel mixtures, and no same-frame CPU reaction to a pixel
change.

## Scale

| quantity | value |
|---|---|
| one world pixel | 5 cm |
| player height | about 34 px, roughly 1.7 m |
| gravity | 9.8 m/s² = 196 px/s² |
| active simulation window | 2048 × 2048 px, about 100 m square |
| visible area at 1080p, 3× integer scale | 640 × 360 px, 32 × 18 m |
| simulation tick | fixed 60 Hz |

Every solver shares these units so that a blast radius, a falling body, and a
water column all feel like the same world.
