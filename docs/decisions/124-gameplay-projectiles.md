# Gameplay: projectiles

**Context**: the fire bolt, the thrown blast charge and the flyer's spit
are small moving things that must hit terrain and characters precisely
and light the scene.

**Decision** (`src/game/projectiles.zig`): a fixed array of 64 CPU
projectiles integrated ballistically every tick and ray-marched pixel by
pixel along the tick's motion against the mirror: solid mask, liquid mask,
and powders from a 28 x 28 readback region requested around each moving
projectile; then against character boxes (the shooter's side is
ignored). Drawn with `drawRect` and an `addLight` each.
- Fire bolt: 430 px/s, gravity 90; on impact `igniteCircle` r6,
  `setTemperature` r4 to 650 C, flame cells r3 into the air, a small
  `eject` (r3, 260 px/s); into liquid it fizzles to steam. Hitting a
  character: 18 hp and ignites it. Secondary of tool 1 is a flame `spray`.
- Spit: 230 px/s, gravity 70, 8 hp + ignite, a little flame on impact.
- Blast charge: thrown at 2.6 px/s per px of cursor distance (90-360
  px/s) with a little loft, gravity 600, bounces (35% kept), rests, falls
  again if its support goes; after 1.6 s `explode` (radius 10, strength
  1.6) from game/explode.zig. The red blink speeds up in the last 0.5 s.

**Alternatives**: GPU ballistic particles (no callback on impact, no
character hits); Box2D bullets for charges (overkill for a dot).

**Consequences**: projectiles see the world one tick late, like
everything on the CPU; at 430 px/s that is 7 px.
