# Readback mirror: full masks every tick, per-slot buffers, poll without waiting

**Context**: the architecture lists a 1-bit solid mask, material strips
around entities, the event queue and coarse samples as the GPU -> CPU path,
one tick late, never stalling. Bodies need the solid mask for collision,
gameplay needs strips and events, the scenario runner needs a particle
count.

**Decision** (`src/sim/readback.zig`, `shaders/sim/readback/`):

- **What**, every tick, at the end (architecture step 7):
  - solid mask: bit `x % 32` of word `y * 64 + x / 32`, set for static
    phase or body-owned cells; 512 KiB;
  - liquid mask, same layout: liquid phase (cellular or particle-backed),
    not body-owned. Powders are neither: they are not "static" in the
    sense the bodies need, and gameplay can ask for strips;
  - material bytes of up to 64 requested rectangles (`region_bytes` = 1 MiB
    total, rows padded to 4 bytes);
  - the event queue (decision 53) and the particle counters (first 32 words
    of `PCTRL`: live, spawned, landed, refused, lost, impacts, high water).
- **How**: `mask.comp` (one workgroup per 256 cells of a row, shared-memory
  `atomicOr`) and `region.comp` write a device-local scratch buffer, one
  `vkCmdCopyBuffer` moves it into the frame slot's host-visible buffer;
  events and counters are copied per tick into the slot's `ticks` buffer
  (one region per tick of the frame). Writing host memory straight from
  the shader cost 0.14 ms; scratch + copy costs 0.064 ms (0.019 compute,
  0.045 the 1 MiB copy over PCIe).
- **When the CPU sees it**: `Engine.poll()` folds every finished frame slot
  into the mirror, oldest first, without waiting (`vkGetSemaphoreCounterValue`);
  `Engine.frame` polls before waiting for its own slot, and the windowed
  loop polls at the top of each iteration, before building commands. So
  commands for tick T+1 are built against the end of tick T whenever the
  GPU has finished it (the usual case: sim takes well under a frame), and
  against T-1 at worst. Nothing waits for readback.
- **API** (`engine.mirror()` returns `*Mirror`):
  - `tick`, `valid`: the tick whose end state this is;
  - `isSolid(x, y)`, `isLiquid(x, y)`: wrap on the torus;
  - `requestRegion(x, y, w, h) !void`: for the next recorded frame; ask
    again every frame (entity strips follow entities);
  - `material(x, y) ?u8`: inside a region read back at `tick`, else null;
  - `events()`: events of `tick`; `eventsAt(t)`: any of the last 8 ticks,
    null if not arrived or gone (a consumer remembers the last tick it
    handled and walks forward);
  - `particles` (`particles.Stats`), `liveParticles()`.
  Synchronous helpers (`readbackCells`, `readbackOwner`, `readbackImage`)
  stay for tools, tests and verification; `computeMasks` is the CPU
  definition of the masks the GPU test compares against.
- **Scenario runner**: the `particles` assertion counts live particles with
  `engine.mirror().liveParticles()` after `engine.finish()` (or after a
  `poll` once the tick is done). Region-limited counts are not read back;
  for the awake-liquid meaning in scenario.zig the liquid solver will need
  to count particle-backed cells (the solid/liquid masks do not separate
  them).

**Alternatives**: masks only for tiles on the active list (0.005 ms on a
still world, but every writer of cells must mark tiles and a material
reload would leave stale bits; worth it if readback shows up in a budget);
a persistent mapped mask that the CPU reads in place (torn reads while the
GPU writes the next tick); waiting for the fence (stalls).

**Consequences**: 0.064 ms per tick regardless of activity, 2 x 2.5 MiB of
host-visible memory. Up to 4 ticks recorded in one frame share one region
request list and only the last tick's masks are kept.
