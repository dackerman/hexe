# Proving Grounds: layout, scenes and hooks

**Context**: docs/07-tech-demo.md asks for one handcrafted level with every
zone, signs, lights, spawn points for the gameplay agent, a scripted
showcase and a burst benchmark. The window is a 2048 torus; the player
jumps about 40 px and has no ladder.

**Decision**:
- `src/game/level.zig` builds the map as commands (a pure function of tick
  and seed, like every scene). Three tiers stacked under an open sky:
  surface at y 400 (powder yard x 24-560, hub 560-780 with the spawn at
  (700, 398), burning village 780-1340, ruin 1360-2010); tier 2 (waterworks
  40-540 x 470-830, shaft S1 600-640, steam room 654-774 x 642-770 over the
  walkway 540-1040 x 812-860, shaft S2 990-1030 from y 586 to 1200, pressure
  corridor and open field 1040-2004 x 586-880); tier 3 under a hallway at
  y 1200-1260 (glassworks 40-496, electric pool 560-980, arena rooms A/B/C
  1060-1730, acid pit 1760-1990 under the hallway floor as the bridge).
  Bedrock below y 1536 and at the x seam.
- Vertical travel: walled shafts with stone ledges every 28 px on
  alternating sides (`B.ledges`); every ledge touches a wall, so none comes
  loose as a body. Rooms under the hallway have their own ledge shafts.
- Anything that would hang free in 2D is tied to the rock: the U-tube's
  inner wall and the glassworks tank's east end hang from steel rods, hut
  shelves touch a wall, the tool rack stands on a plinth.
- Scenes (`src/sim/scenes.zig`, additive): `proving_grounds` (play),
  `proving_grounds_auto` (showcase events on `level.auto_schedule`),
  `proving_grounds_burst` (all events in 5 s). `bodies_scenes.isBodiesScene`
  includes them and `bodies_scenes.script` forwards to `level.script`
  (beams, crate, torch cuts). Headless runs turn the liquid solver on for
  them (`main.zig`, one condition); the windowed app already runs it.
- Public API: `level.spawn_point`, `level.enemy_spawns` ({x, y, kind}),
  `level.anchors` (zone centers), `level.signs`, `drawSigns(engine, cam_x,
  cam_y)` / `drawSignsHud(hud, ...)`, `drawLights(renderer)`, and
  `decorate(renderer, hud)` which `render/demo.zig` calls for the three
  scenes (one dispatch line), so signs and torches show headless and in the
  app without further wiring.
- `materials.Ids` gained `acid`, `moss`, `rubble` (resolved by name like the
  others).
- `--demo-script PREFIX` and `--bench-demo` (`src/game/level_demo.zig`,
  dispatch in `main.zig`).

**Alternatives**: zones side by side on one floor (2048 px is too narrow for
eleven zones); procedural caves around the map (decision 131).

**Consequences**: the band of rock between tier 2 and tier 3 (y 900-1200)
is plain rock with gravel and dirt pockets; room for a later zone. The
gameplay agent wires `spawn_point`/`enemy_spawns`; the app's camera still
starts at the world center for this scene until then.
