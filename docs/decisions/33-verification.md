# Verification: mirror test, GPU accessor test, determinism check

**Context**: the engineering contract wants CPU/GPU constants mirrored with
a check, and a bit-exact CPU reference compared over 300 ticks.

**Decision**:
- `zig build test` (CPU only, Debug) includes "common.glsl mirror": it parses
  every numeric `#define` in `shaders/common.glsl` and requires a matching
  CPU value in `src/gpu/constants.zig` `mirrors`, both ways. It also runs
  cell packing, hash pinning, material packing, PNG round trip, font, command
  bounds and reference behavior tests (sand piles and sleeps, water flattens,
  smoke rises, sand sinks in water, statics hold, torus wrap).
- `zig build verify-determinism` builds a ReleaseSafe binary and runs it
  headless: first `shaders/test/cell_accessors.comp` evaluates every cell
  accessor and the hash on 4096 sample words and compares with
  `cell.accessorTestExpected`; then the seeded `determinism` scene runs 300
  ticks on the GPU and in `src/sim/reference/grid.zig`, once with activity
  tiles and once with every tile active, and every cell of the 2048x2048
  image is compared. GPU readback goes through `Engine.readbackCells` /
  `sim/readback.zig readbackCells`.
- `zig build test -Dgpu-tests` adds the determinism check to the test step.

**Alternatives**: running the GPU comparison inside `zig build test`
(breaks the CPU-only contract on machines without a GPU).

**Consequences**: every grid shader change needs the same change in the
reference, or verify-determinism fails with the first differing cells.
