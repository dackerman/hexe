# Gameplay: movement feel and camera

**Context**: docs/07 asks for run, variable jump, coyote time, terminal
velocity, swimming and a following camera; D9 fixes 1 px = 5 cm and
gravity 196 px/s^2 for bodies.

**Decision** (`player.Tuning`, `app.zig`):
- Box 8 x 27 under a 12 x 30 sprite (2-frame walk, cast pose for 0.25 s
  after any tool use, mirrored to face the cursor).
- Gravity 760 px/s^2 (3.9x real at this scale: real gravity makes jumps
  floaty at character scale), jump speed 270 px/s (a 48 px apex in 0.35 s),
  releasing jump while rising keeps 45% of the speed (variable height),
  coyote time 0.10 s, jump buffer 0.12 s, terminal 540 px/s. Run 120 px/s,
  ground acceleration 1500, friction 1800, air control 900 px/s^2; oily or
  slippery ground cuts acceleration to 20%; a blast knock cuts control to
  15% for 0.4 s.
- Liquid (more than 35% of the box in the liquid mask): gravity x0.25,
  buoyancy 330 px/s^2 times the submerged fraction in buoyant liquids (a
  still witch floats with her head out), strokes 700 px/s^2 (W/Space up,
  S down), drag 4/s, terminal 150 px/s; jump at the surface leaps out.
  Material `slow` scales the top speed. Breath: 5 s with the head point
  in a drowning liquid, then 15 hp/s; refills at 2 s/s.
- Camera: the witch's center, 16 px up, plus 30% of the cursor's offset
  from the window center (clamped to a quarter view), smoothed with rate
  7/s; integer zoom (default 3, = / - change it).
- Death: 1.5 s fade, respawn at the level spawn; R resets the level.

**Alternatives**: real gravity (jumps last a second); a dead-zone camera.

**Consequences**: bodies fall slower than the witch; tune here if that
reads wrong in the demo level.
