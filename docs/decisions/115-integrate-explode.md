# Integration: explosions and the eject queue

**Context**: explosions existed three ways: air's `inject_pressure`
(`CommandList.explosion`), particles' interim `eject`, and the bodies
layer, which ignored both (`else => {}`) and wanted `applyBlast` +
`notifyDestruction`. Gunpowder appended EVENT_EXPLODE with no consumer.
Cells displaced by bodies went to an eject queue drained by a stand-in
that reinserted them above.

**Decision**:
- `src/game/explode.zig` `explode(list, x, y, r, strength, opts)` is the
  one gameplay call (keys, scenario `explode` commands, events). It only
  pushes commands: the explosion (`inject_pressure`), an `eject` when the
  air field is off, and a `wake_liquid` when the liquid solver runs.
- The bodies layer consumes the same `inject_pressure` command from the
  tick's list: `applyBlast` at 4x the charge radius with impulse 40 per
  unit overpressure per body pixel, and a destruction event at the charge
  (cuts, connectivity). It also treats `eject` as a destruction event. So
  scene explosions (air_demo, bench_air) push bodies too.
- `Explosions.drain` follows the readback mirror and calls `explode` once
  per EVENT_EXPLODE (radius 6, strength 1), one tick late; the windowed
  app and headless runs drain every frame (verify-determinism does not).
- `bodies_eject_cell` spawns a shared ballistic particle (velocity from
  the body) and wakes solver liquid it displaces; only spawns the particle
  budget refuses reach the eject queue, whose fallback stays on so
  displaced fluid is never lost.
- The ballistic pass relaxes velocity toward the air's at
  `drag/255 * 2/s` when the air field runs (particles.air_drag).

**Alternatives**: `explode` calling `bodies.applyBlast` directly (a second
path besides the command list, and scene explosions would skip it).

**Consequences**: one EVENT_EXPLODE per burning gunpowder cell, capped at
64 explosions per drain.
