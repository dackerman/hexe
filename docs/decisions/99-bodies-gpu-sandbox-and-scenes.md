# Bodies switch, sandbox keys, scripted scenes

**Context**: bodies must stay off in the determinism scene and be easy to
drive in the app and headless.

**Decision**:
- `pipeline.Config.bodies` (default off). CLI `--bodies` / `--no-bodies`;
  default on in the windowed app and in the `bodies_*` scenes, off otherwise.
  When off, `Bodies.tick` and `Bodies.record` are not called: no pass touches
  cells and verify-determinism is unchanged.
- Engine hook (`engine.zig`, delimited): per tick, after scene and input
  commands and before the command upload, `bodies_scenes.script` then
  `Bodies.tick` (which may add nothing to the list but reads it for
  destruction events); `Bodies.beginFrame` before a frame's ticks.
- Sandbox keys (`src/app.zig`): C concrete crate 40 px at the cursor, X wood
  crate, V stone slab 160x16, B then two left clicks: steel beam 6 px between
  them (ends in rock are welded). Right mouse (erase = fill air) is the eject
  tool: it cuts bodies and triggers connectivity. Number keys now reach the
  appended materials (5 concrete, 6 steel, 7 wood, 8 rubble, 9 gravel), so
  structures can be painted and then undermined. The HUD shows body count,
  CPU, readback and GPU ms.
- Scenes (`src/sim/bodies_scenes.zig`): `bodies_crate`, `bodies_slab`,
  `bodies_beam`, `bodies_water`, `bodies_bench`; a headless run prints a
  bodies report (counts, CPU phases, last GPU stats, poses, cell census).

**Consequences**: windowed key handling was smoke-tested (the app runs at
60 fps with bodies on); the actions behind the keys are the same API calls
the scripted scenes verify headless.
