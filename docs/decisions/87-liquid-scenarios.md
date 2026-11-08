# Liquid scenarios: harness, stand-ins, and the U-tube result

**Context**: `zig build scenarios` is not on this branch; the data branch
wrote scenarios/{u_tube,dam_break,pool_sleep}.zon with assertions.

**Decision**:
- `hexe --headless --liquid-test [utube|dam|pool|reaction|determinism|all]`
  (`src/liquid_test.zig`) builds those geometries at (896, 896) inside a
  stone frame (the scenario world is not a torus) through
  `src/sim/liquid_scenes.zig` and checks the same assertions. Material
  stand-ins until the ZON table drives the sim: bedrock -> stone, gravel ->
  sand; wood was added to the builtin table (id 5, static).
- Pours start at tick 1, not 0: the tick-0 setup fills overlap the nozzle,
  and command boxes wake liquid, so the first pour would wake at rest.
- Water switched to `solver = flip` in the builtin table. With the solver
  off (`Config.liquid = false`, the default) it is plain cellular water and
  the determinism check is unchanged.

**U-tube (scenario 1) does not pass**: 160-px arms at 196 px/s^2 form an
oscillator with a period of about 4 s (L ~ 170 px of liquid column,
T = 2 pi sqrt(L / 2g)), so "equal levels within 2 s of the pour" would need
damping that also kills dam-break waves and pours (tried: linear drag 2-3/s
stops the drain). Measured: the poured water drains into the right arm and
overshoots (left empty at tick 180), sloshes back, and is asleep about 3 px
apart by tick 700. Total water 3250 of the 4880 the scenario expects,
because the left arm fills faster than water can flow through the 20-px
channel at physical speed. Reopen if the doc's 2-s target is to hold: it
needs either stronger gravity for liquid or tube-wall friction.

**Consequences**: the integrator's scenario runner should translate the
same way (or run with the real material table); the harness stays as a
quick check (`--liquid-test all` takes about a minute).
