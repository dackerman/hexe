# Engineering Contract

Rules every contributor, human or agent, follows. The design documents say
what to build; this says how.

## Toolchain

| tool | location | notes |
|---|---|---|
| zig 0.17.1 | `~/.local/bin/zig` | pinned in `.zigversion` and `build.zig.zon` |
| glslc | `/usr/bin/glslc` | GLSL 4.6 → SPIR-V; also `glslangValidator`, `spirv-opt` |
| SDL3 3.4 | system, `pkg-config sdl3` | window, input, Vulkan surface |
| Vulkan loader 1.4 | system `libvulkan.so.1` | NVIDIA ICD present; no `vulkaninfo` installed |
| Vulkan headers + `vk.xml` | `vendor/vulkan-headers/` | for binding generation; no system headers installed |
| Box2D v3.2.0 | Zig package dependency | ships its own `build.zig` |

Dev machine: RTX 4090, Ryzen 7950X, 61 GB RAM, Linux, Wayland desktop.

## Build targets

| command | purpose |
|---|---|
| `zig build run -Doptimize=ReleaseFast` | play the witch (windowed; `-- --sandbox` for the paint sandbox, `-- --world` for the streamed world) |
| `zig build run -- --script playtests/NAME.hexe --view-screenshot PREFIX` | headless scripted play: drives the witch, writes PREFIX-SHOT.png view screenshots with sprites and HUD (docs/decisions/128) |
| `zig build run -- --headless --ticks N --screenshot path.png [--scene NAME]` | drive the sim without a window; dump the world as PNG (`--view-screenshot` renders the lit view with HUD) |
| `zig build test` | unit tests, CPU only, Debug (`-Dgpu-tests` adds verify-determinism and gpu-test) |
| `zig build verify-determinism` | GPU grid vs the CPU reference, bit for bit, cells and event sets (ReleaseSafe) |
| `zig build scenarios` | headless GPU scenario regression suite under `scenarios/` |
| `zig build gpu-test` | GPU tests: particles land and conserve cells, readback mirror, events one tick late |
| `zig build air-test` | air field scenarios (sealed room, corridor blast, flooding a sealed room, no blasts from flowing liquid and bodies) with their own measurements |
| `zig build stream-test` | world streaming GPU round trip: upload, dirty bits, download, save, reload |
| `zig build liquid-test` | liquid solver scenarios (U-tube, dam break, pool sleep, determinism, reactions coupling) |
| `zig build bench` | fixed benchmark scenes headless (ReleaseFast), per-pass GPU ms against budgets |
| `zig build bench-render` | render passes at a 1920x1080 view and sim/render overlap (ReleaseFast) |
| `zig build bodies-demo` | headless beam bend-and-snap demo of the CPU bodies layer (ASCII) |
| `zig build worldgen` | procgen preview image |
| `zig build docs` | regenerate `docs/materials.md` from `materials/` |
| `zig build shaders` | compile all shaders (also implied by `run`) |

Every milestone's done criteria must be checkable with one of these.

## Code conventions

- `zig fmt` clean. No warnings-as-errors tolerance games: the build is quiet.
- No heap allocation inside the per-tick loop. Allocate at init, size from
  config, assert in debug.
- Errors are returned, not panicked, except for programmer errors caught by
  `std.debug.assert`.
- GPU resources are owned by the subsystem that creates them and freed in
  its `deinit`. Use a small arena per subsystem for CPU-side bookkeeping.
- Shared constants between CPU and GPU live once, in `shaders/common.glsl`
  for the GPU and generated into `src/gpu/constants.zig` by the build, or
  mirrored by hand with a test that checks the mirror. Pick one and do not
  drift.
- Sim shaders: integer math only, randomness from `hash(x, y, tick, substep)`.
  Float math is allowed in the air field and liquid solver, but no float
  atomics anywhere. No reads of wall-clock time on the GPU.
- ReleaseFast is the performance truth. Debug is for correctness. Test both
  before claiming a budget number.

## Subsystem and pass interface

Every simulation layer is a struct in `src/sim/` with:

```zig
pub fn init(ctx: *gpu.Context, cfg: Config, alloc: Allocator) !Self
pub fn record(self: *Self, frame: *Frame) void   // records compute work into frame.cmd
pub fn deinit(self: *Self) void
```

`src/sim/pipeline.zig` owns the ordered list of subsystems and calls their
`record` in the order given in the architecture document. Adding a layer is
adding one entry to that list. `Frame` carries the command buffer, tick
number, the shared images (cell, owner, activity, coarsened solid mask),
and the GPU timestamp recorder; call `frame.timed("name", ...)` around work
so it appears in the HUD and in `zig build bench`.

Input and gameplay never call into GPU code directly. They push commands
into `src/sim/commands.zig`, which the pipeline uploads.

## Shaders

- `shaders/common.glsl`: cell format accessors, hash, material table
  layout. Include it; do not copy it.
- One file per interaction class under `shaders/sim/grid/`. One directory per
  solver. `shaders/render/` for graphics.
- Compute local size 16 × 16 unless measured otherwise. Say why if not.
- Compiled by `build.zig` with `glslc -O --target-env=vulkan1.3 -I shaders`,
  output embedded with `@embedFile`. A shader change rebuilds.

## Testing and verification

- Unit tests next to the code, run by `zig build test`. Pure functions
  first: cell packing, hashing, torus math, ZON validation, Box2D wrappers.
- The CPU reference in `src/sim/reference/` is bit-exact against the GPU
  grid. A test runs both on a seeded scenario for 300 ticks and compares.
- Scenarios are ZON files: a small world description, a tick count, and
  assertions on cell counts in regions or at points. The runner is headless.
- Visual checks: `--screenshot` writes a PNG that can be opened and looked
  at. Use it after any rendering or solver change; describe what you saw.
- Performance claims cite `zig build bench` output on this machine.

## Decisions

Anything not specified by the design documents that you had to decide, write
down in `docs/decisions/NN-slug.md` (NN zero-padded, next free number in your
branch; collisions are renumbered at merge):

```
# Title
**Context**: what forced the decision.
**Decision**: what you did.
**Alternatives**: what else was considered.
**Consequences**: what this costs or enables; what would reopen it.
```

Do not edit `docs/00-06` except to fix a factual error, and note the fix in
a decision file. The design documents are the spec; deviations are
decisions, recorded, not silent.

## Git

- Work on your branch in your worktree. Commit early, in small coherent
  commits, message prefixed with the milestone: `m1: margolus movement pass`.
- Every commit message ends with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Never commit to `main`. Never rewrite history on a shared branch.
- Touch only files in your scope. `build.zig` and `src/sim/pipeline.zig`
  may be edited by anyone, minimally, in a clearly delimited section.
- Before reporting done: `zig fmt --check .`, `zig build test`, the build
  targets your milestone adds, and the done criteria from
  `05-milestones.md`, each stated with its actual output.
