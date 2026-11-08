# Gameplay: blast knockback from the air field

**Context**: explosions are air-field pressure pulses (decisions 75, 77,
115); characters should be thrown by them, more in confined spaces, and
hurt by strong ones.

**Decision** (`world.Actor.blast`): each character asks for an air sample
at its center every frame (`Air.requestSample`); results come back one or
two frames later and are matched against the last four requested points.
Measured on open ground for a strength 1.6, radius 10 charge: the front
arrives about 8 ticks after the blast 40 px away, overpressure peaks at
0.24 there (0.11 at 80 px), the wind behind the front is about 1 px/tick
and the overpressure decays over ~15 ticks. So:
- the front is a rise of overpressure (> 0.02 since the last sample):
  impulse = rise x 1500 px/s along the wind (or down the pressure gradient
  in still air), plus 45% of it upward; 0.4 s of reduced control;
- wind above 30 px/s drags the character 8% of the gap per sample;
- damage = the rise above 0.08 overpressure x 150 hp (24 hp at 40 px from
  a charge, nothing at 80 px).
`blast_factor` scales the push: walker 0.8, witch 1, flyer 3. With the air
field off, blasts gameplay set off push directly with the bodies layer's
falloff (4x the radius, blocked by solid cells).

**Alternatives**: direct radial impulses from known explosion centers
only (ignores walls, corridors and gunpowder chains); integrating the
pressure gradient (the LBM gradient is small and noisy, the overpressure
rise is the robust signal).

**Consequences**: a witch 40 px from a charge flies ~70 px back, ~20 px up,
and loses ~24 hp (playtest `blast`); a flyer next to a blast leaves at
~700 px/s (`flyer_blast`). Confinement raises overpressure and so the
push, as the air field intends.
