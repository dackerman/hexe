# Gameplay: play mode, the fallback scene, level reset

**Context**: `zig build run` must start the playable demo before the demo
level exists; R must reset the level; the level agent adds
`src/game/level.zig` and a `proving_grounds` scene in parallel.

**Decision**:
- `app.run` starts `runPlay` unless `--sandbox` or `--world` is given.
  `app.default_scene` (one line) is `.lighting` until the merge, with
  `defaultSpawn(scene)` (feet at 1060, 1180 on the cave floor) and
  `populate(game, scene)` (a walker by the brazier, a flyer over the lava)
  as the hooks the level replaces: at merge set `default_scene =
  .proving_grounds`, add its spawn to `defaultSpawn` and call the level's
  enemy placement from `populate`. `--scene`, `--spawn X,Y` and
  `--spawn-enemies [N]` override.
- R resets the level by re-creating the engine in place (same window):
  cells, air, liquid particles, bodies, ballistic particles and the tick
  counter all start over, which no subsystem offers individually. Render
  settings and the liquid switch are carried over; the game re-uploads its
  sprites into the new atlas (`Game.rebind`) and calls `reset` and
  `populate`. It takes about 0.2 s. `--reset-at N` triggers it at frame N
  (tested windowed: 400 frames, reset at 200).
- The game is driven per tick inside the app's fixed 60 Hz accumulator;
  key/mouse edges are latched until a tick consumes them, so a click on a
  frame without a tick (high refresh rates) is not lost. Readback regions
  and air samples are requested once per frame that records ticks.
- World mode (`--world`) keeps the sandbox: the witch is not wired to the
  streamed world yet (its coordinates would work: everything wraps through
  the mirror, but spawn and level data are open).

**Alternatives**: a per-subsystem reset (air has one, the rest do not);
a scene-tick offset in the engine (cells, bodies and particles would
still need clearing).

**Consequences**: the engine's init cost (pipelines, images) is paid on
every R. The lighting cave's stalactites come loose at start (its carve
commands are destruction events for the bodies layer), harmless.
