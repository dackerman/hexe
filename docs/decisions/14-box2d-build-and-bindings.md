# Box2D build flags and Zig bindings

**Context**: D7 links Box2D v3's C API; the engineering contract pins v3.2.0
as a Zig package dependency. Box2D needs SIMD flags or
`BOX2D_DISABLE_SIMD`, and Zig needs bindings for its headers.

**Decision**:
- `zig fetch --save=box2d https://github.com/erincatto/box2d/archive/refs/tags/v3.2.0.tar.gz`.
  The package's own `build.zig` (requires Zig ≥ 0.15.1) builds under 0.17.1
  unchanged, so `build.zig` uses it: `b.dependency("box2d", .{ target,
  optimize }).module("box2d")`. That module is the package's `addTranslateC`
  of `include/box2d/box2d.h`, already linked to the static `box2d` library.
- Bindings are therefore translate-c output generated at build time; nothing
  is committed and no `@cImport` is used. Calls look like
  `b2.b2World_Step(...)`. Only `src/sim/bodies.zig` imports `box2d`; the rest
  of the game uses the Zig API there.
- Flags are the package's: `-std=gnu17 -D_GNU_SOURCE -ffp-contract=off`,
  static linkage, SIMD **enabled** (`disable_simd = false`). On x86-64 v3.2
  compiles an SSE2 baseline plus an 8-wide AVX2 contact solver behind a
  target attribute and picks between them at runtime with `cpuid`, so no
  `-mavx2` is needed and the binary still runs on CPUs without AVX2.
- Box2D runs single-threaded (no task callbacks given to the world).
  Same binary, same inputs, same results.

**Alternatives**: compiling the C sources ourselves with `addCSourceFiles`
(only needed if the package's build.zig broke on 0.17.1); `@cImport`
(deprecated direction in Zig, slower builds); hand-written externs for the
subset used (fragile across Box2D versions); `BOX2D_DISABLE_SIMD` (slower,
only useful for cross-ISA determinism).

**Consequences**: upgrading Box2D is a `zig fetch` and a recompile; API
changes surface as compile errors in `bodies.zig` only. Debug and
ReleaseFast builds produce slightly different contact results (seen in the
demo's impact impulses), so replay determinism holds per build mode, not
across them. Revisit if lockstep multiplayer needs cross-machine bit
equality: then disable SIMD or force one width, and add Box2D's task
system only with a deterministic scheduler.
