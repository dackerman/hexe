# Tech Demo: The Proving Grounds

The first playable build is a single handcrafted level that shows every
interaction class and lets the player trigger each one. It is a tech demo,
not a game: no progression, no win state. It must be fun to poke at for ten
minutes and make the simulation legible.

## Level

A 2048 × 1536 pixel handcrafted map, loaded into the window with the rest
filled by procedural caves so the edges are not walls. The player spawns at
the hub. Each zone is a few screens and is labeled with a floating sign
(HUD text anchored to world position) that says what to try.

| zone | what is there | what it shows |
|---|---|---|
| hub | flat stone floor, a tool rack sign listing keys | controls |
| powder yard | sand dunes, dirt hills, gravel pile, a wooden fence | spray and pile, slide differences, blast on powders |
| waterworks | a U-tube of glass, a reservoir above a wooden dam, a drained basin below, a long pipe | equalization, dam-break wave, flow around obstacles |
| steam room | sealed stone room, lava floor, water tank above with a wooden plug, one wall of wood, one of concrete | sealed-space pressure, steam bomb, weakest wall fails |
| pressure corridor | a 3 px wide corridor with sand plugs every 64 px next to an open field with the same plugs | confinement amplifies blasts |
| burning village | wooden huts, oil barrels (oil pools in wood boxes), a hay-like moss patch, a lava trickle nearby | ignition by heat, fire spread over oil, smoke following drafts, charcoal and ash |
| glassworks | sand pit with a lava channel above it, a gate the player can open | sand to molten glass to glass; glass shatters |
| ruin | concrete building with steel beams, pillars, glass windows, a second floor | chip, crack, shatter, connectivity collapse, steel beams sag and snap, ricochet |
| electric pool | water pool with steel rails and a steel grate, an enemy standing in it | electricity through water and steel |
| arena | three rooms with enemies: one over a lava pit, one in a flooded room, one behind a glass wall near gunpowder barrels | every kill class |
| acid pit | an acid pool under a stone bridge | corrosion, acid gas |

## Tools

Number keys select, left mouse uses, right mouse is the secondary.

| key | tool | primary | secondary |
|---|---|---|---|
| 1 | fire bolt | projectile that ignites and emits heat on impact | small flame spray |
| 2 | blast charge | thrown charge, explodes on timer, strong pressure pulse | instant blast at cursor |
| 3 | water spray | spray water particles | place a water column |
| 4 | lava spray | spray lava | place a lava blob |
| 5 | acid spray | spray acid | place acid blob |
| 6 | dig | carve a circle at the cursor | fill with dirt |
| 7 | lightning | charge the cell under the cursor; propagates through conductors | continuous arc |
| 8 | cutter | removes cells along a line, severs beams | place a steel beam between two clicks |
| 9 | gunpowder | place a gunpowder pile | place a wooden box |
| 0 | painter | paint the selected material; scroll cycles materials | erase |

## Controls

| key | action |
|---|---|
| A, D (or arrows) | move; Space (or W, Up) jump, higher while held; in water W/Space swim up, S dive |
| S (or Down) | drop through a thin (at most 3 px) platform |
| mouse | aim (world space); LMB primary, RMB secondary; wheel brush size, or material for the painter |
| 1-9, 0 | select a tool (table above) |
| Tab, Shift+Tab | cycle debug overlays: none, activity tiles, air pressure, air velocity, liquid particles, bodies, temperature, particle cells, light |
| F1 | help overlay with the tool table and these keys |
| F3 | HUD timings on and off |
| R | reset level; P pause; period single step while paused |
| = / - | zoom in / out (integer) |
| E, X | explosion / eject at the cursor (sandbox keys kept) |
| C, Z, V | concrete crate / wood crate / stone slab at the cursor (sandbox keys kept) |
| L | liquid solver on and off |
| F2, F4, F6, F7, F8, F12 | tiles overlay, light mode, light quality, bloom, vignette, screenshot |
| Escape | quit |

The sandbox (paint, pan, palette on 1-9) is `--sandbox`, and the streamed
world `--world`; their keys are in docs/decisions/114-integrate-keys.md.
The final key map and why: docs/decisions/127-gameplay-key-map.md.

## Enemies

Two kinds are enough for the demo.

- **Walker**: ground enemy, patrols, chases the player when seen, melee.
  Body of flesh over bone; bleeds; burns; drowns; conducts electricity.
- **Flyer**: hovers, dodges, spits small fire bolts. Lighter, blown far by
  blasts, falls when stunned.

Death converts the sprite into a pixel body of flesh and bone that bleeds
blood into the world and obeys all rules from then on.

## Must be visible in the demo

Every row of the class table in `02-interaction-classes.md`, and specifically:
the dam-break wave, the steam room venting, the corridor versus open field
difference, smoke drifting down a corridor toward a breach, a beam sagging
then snapping, a pillar blown out and the slab above collapsing into
rubble, lava lighting its surroundings, glass made from sand, an enemy
electrocuted in water, an enemy dying into a body that bleeds.

## Performance

60 Hz at 1080p with the full level active during a burst of simultaneous
events (dam break plus explosion plus fire). HUD shows per-pass ms. The
demo ships with a `--bench-demo` flag that scripts those events headless
and prints timings.
