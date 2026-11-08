# Gameplay: contact and status effects

**Context**: docs/03 "Entity contact effects" lists per-material effects;
the materials carry them as `on_contact` (CPU only). Characters need one
shared, data-light implementation.

**Decision** (`src/game/status.zig`, `world.Actor`):
- Each tick a character scans its box plus a 1 px border in its readback
  region: per material count, charged and burning cells, the liquid
  fraction (mask), and the head point (4 px below the top) for drowning
  and smoke.
- A material's damage (burn, corrode) scales with the cells touched, full
  at 6; flags (ignite, extinguish, wet, oily, slippery, bloody, buoyant)
  need 2 cells. Three burning cells also ignite.
- One `Status` struct of timers (seconds): burning (6 hp/s, 4 s; while
  oily the timer runs at 1/2.5 speed, and the oil burns off with it), wet
  (3 s after leaving water; blocks ignition, doubles shock damage), oily
  (12 s, decays at 1/4 speed out of oil), stunned (no input/AI), bloody
  (cosmetic), blind (0.5 s after the head leaves smoke: darkened edges and
  a stronger vignette), breath.
- Electricity: touching any charged conductive cell is a shock: 20 hp (40
  wet or standing in liquid), 0.6 s stun, 0.15 s cooldown. Charge is a
  pulse (decision 42), so a lightning bolt pulses its hit point for 10
  ticks to be caught by the end-of-tick readback.
- A burning character sprays a few flame particles from its box every
  6-11 ticks, so it sets dry surroundings alight.
- Water extinguishes and wets; heat dries.

**Alternatives**: per-effect components (more code for six timers);
damage from the touched fraction only (one lava cell at the feet would do
nothing).

**Consequences**: steam's 5 hp/s, lava's 40, acid's 15 come straight from
the material files: tuning is data. Tests cover timers, oil, drowning,
shocks and scaling.
