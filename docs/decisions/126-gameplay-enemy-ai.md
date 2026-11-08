# Gameplay: enemies

**Context**: docs/07 asks for a walker and a flyer that share the
witch's contact rules and die into pixel bodies.

**Decision** (`src/game/enemies.zig`), 32 enemies at most:
- Walker (box 14 x 26, 60 hp): patrols at 40 px/s, turning at walls and
  at ledges (no ground within 10 px below 2 px ahead); chases at 82 px/s
  when the witch is within 200 px (300 once chasing) and a ray from its
  eye to her through the solid mask is clear; jumps (250 px/s) when a wall
  stops it mid-chase; melee 12 hp with knockback, 0.8 s cooldown. In
  liquid it is heavy: sinks, walks the bottom, drowns after 5 s.
- Flyer (box 12 x 12, 25 hp): a spring-damper toward a point 110 px to its
  side of the witch and 70 px above, plus a sine bob; home position when
  it does not see her (280 px); spits every 2 s when it does; stunned, in
  liquid or knocked by a blast it stops steering and falls.
- Enemies farther than 700 px from the witch are frozen and request no
  readback (region and sample budgets: 64 each per frame).
- Death: the sprite's opaque pixels become flesh, a skeleton of bone
  (skull, spine, arms, shins), mirrored to the facing, spawned with
  `BodySim.spawnBody` at the enemy's velocity with a little spin; blood
  is sprayed (60 particles) and pooled (r3). The corpse then burns, floats,
  gets cut and crushed like any body.
- `Enemies.spawn(kind, x, y)` with (x, y) the feet / bottom center is the
  level's API; `--spawn-enemies [N]` drops walkers beside the witch and a
  flyer above once the world is read back.

**Alternatives**: navmesh or flow-field pathing (the terrain changes every
tick; local rules are enough for a demo); corpses as cells without a body
(they would not tumble).

**Consequences**: walkers do not path around pits; they fall in (and burn
in lava: seen in the `lighting_cave` playtest).
