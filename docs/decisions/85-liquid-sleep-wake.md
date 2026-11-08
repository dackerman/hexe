# Liquid sleep and wake rules

**Context**: docs/04-fluids.md gives the intent (sleep when slow and
surrounded, wake on disturbance, spread one cell per tick, budget) and
warns that the seams will need tuning. They did; these are the rules that
pass scenarios 2 and 5 together.

**Decision**:
- Movement treats particle-backed cells as static (block.glsl, mirrored in
  the CPU reference): the cellular rules never move awake water. Powders
  therefore rest on awake water until it sleeps, then sink cellularly
  (waking it again around them).
- Sleep (`settle.comp`): rest counter >= 16 ticks below 8 px/s (a faster
  tick halves the counter rather than resetting it), and supported by things
  that do not move: the pixel below is sleeping liquid or an obstacle and
  neither diagonal below is an awake particle. Bodies fall asleep from the
  bottom up, like sediment. Letting particles sleep on top of awake ones
  froze chunks inside moving water and jammed it (the dam settled into a
  slope like a sand pile). Air beside or diagonally below is allowed, so a
  surface step sleeps and the cellular rules level it.
- Sleeping liquid is in the pressure solve as liquid at rest (zero face
  velocity before forces, gravity applied). That gives two wake signals
  from last tick's projection: a face that awake particles touched moving
  faster than 20 px/s (pushed or pulled by awake water), and, in the
  interior of a body (fluid cells 2 cells away on all sides), a face no
  particle touched moving faster than 80 px/s^2 x dt (out of hydrostatic
  balance, e.g. a pour piling up in one arm of a U-tube). Lower thresholds
  churned (surface bumps being leveled are locally out of balance).
- Other triggers: any command's box grown by 16 px wakes plain solver
  liquid inside (removing a dam, painting into water), except commands that
  place solver liquid itself; `CMD_WAKE_LIQUID` (circle, hop count);
  `liquid_wake_at` from any pass; a moved powder neighbor (4 hops); a cell
  the cellular rules moved onto something at rest with >= 6 liquid
  neighbors (a pour landing in a body); fast (> 40 px/s) or pushing (> 4
  px/s) liquid particles and landing ballistic ones hitting sleeping water.
- Poured or painted solver liquid starts asleep and falls with the cellular
  rules (8 px per tick): woken water starts from the local flow, and water
  woken at rest throttles a pour to free-fall speed (196 px/s^2 from rest
  clears a 4 px nozzle in about 12 ticks). The sandbox pour key adds a wake
  command so its water starts awake.
- A new particle inherits last tick's grid velocity at its pixel; a cell
  that was falling cellularly with no grid velocity starts at 240 px/s down.
- Budget: `wake_budget` 65536 per tick; candidates past it keep their
  request for the next tick (and stop spreading); past `capacity` (1M) the
  request is dropped and the water stays cellular.

**Measured**: pool scenario fully asleep 250 ticks after the pour ends
(tick 310 of the 360 allowed); the gravel blob at tick 400 wakes 200-300
pixels near it, none at the far edge.

**Consequences**: water that sleeps out of balance by less than about 80
px/s^2 (a few pixels of level difference over a basin) stays so; the U-tube
ends 3 px apart (decision 87). The parameters are all in `liquid.Params`.
