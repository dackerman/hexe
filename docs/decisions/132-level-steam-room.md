# Proving Grounds: steam room, lava upkeep, glassworks

**Context**: the steam room must pressurize visibly and vent through its
wood wall, not the concrete one; lava must keep lighting its rooms; the
glassworks must make glass from sand.

**Findings**:
- Lava enclosed by cold rock gives its heat away (emission drains the
  emitter) and froze to stone in about 300 ticks.
- Water resting on a hot divider never boiled: awake FLIP water is
  re-rasterized each tick with its material's initial state, which resets
  the boil-latency counter kept in the state byte (temperature is carried,
  the counter is not). The 2 px stone divider of decision 118 therefore
  makes no steam while the liquid solver runs. Reported for the liquid
  layer; not changed here.
- Water poured straight on lava crusts it to stone at the first contact.

**Decision**:
- Lava upkeep ("fed from below"): every 20 ticks each lava body's lava cells
  are repainted as fresh lava (fill only over lava). The glassworks is fed
  at 1256 C, past sand's melting point and short of stone's, so the sand it
  touches melts to molten glass in bulk; the pit stays hot in play, and the
  showcase lets it cool 420 ticks after the gate opens.
- Steam room: 100 x 108 sealed stone room, concrete west wall (upper part),
  2 px wood east wall with state (health) 12, lava floor under a 2 px stone
  divider that stops 4 px short of the east wall, leaving a 16 px strip of
  open lava. Water from the tank (wooden plug in its floor) spreads over the
  divider, runs off into the strip and flashes to steam; the strip's crust
  is remelted with the upkeep, so steam comes at the rate water arrives.
  Measured (pressure overlay, zoom 3): pressure builds from 60 ticks after
  the plug, the wood wall breaks around 110-130 ticks and the room vents
  into the gallery; the concrete wall stands. The wood wall ends 44 px above
  the floor so the lava's heat does not light it in play.
- Glassworks: steel floor gate (wood under lava burns through on its own),
  and a sand silo over the tank whose wooden gate the showcase opens.
- No `materials/*.zon` value was changed.

**Alternatives**: emulated steam (the air-test's injection; would not know
whether the player broke the plug); weep holes in the divider (crusted shut,
or broke the divider into bodies floating on the lava); the strip by the
concrete wall (the steam bursts broke the concrete side first).

**Consequences**: the room is violent once it vents (lava and stone are
thrown into the gallery and the walkway below). Runs are not bit-identical
(ballistic landing order), so the exact vent tick moves by tens of ticks.

**Update** (docs/decisions/142-polish-lava-heat-source.md): lava is now a
heat source that loses no heat to rock, so enclosed lava stays molten and
the generic upkeep (steam room floor, hut seep, arena pit repainted every
20 ticks) is removed. Measured over 3600 ticks of `proving_grounds` without
it: steam room floor 1800 of 1800 lava cells, hut seep 476 of 476. Kept as
level design: the steam strip's crust remelt and the glassworks' 1256 C
feed. With decision 140 the water resting on the divider now boils too.
