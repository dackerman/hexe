# Architecture

## Summary

The world is a grid of material cells that lives on the GPU and is
authoritative there. Two fluid solvers run beside the grid at half its
resolution: a lattice Boltzmann air field for compressible gas and a FLIP
particle solver for liquids. A rigid body layer on the CPU handles authored
objects, beams and falling chunks. The grid is the common medium: every layer
reads its boundaries from the grid and writes its results back into it.

The CPU runs gameplay. It never touches pixels directly. It sends a command
list to the GPU and receives a one-frame-stale mirror of what it needs.

```
            CPU                                  GPU
  ┌──────────────────────┐          ┌───────────────────────────────┐
  │ input, gameplay, AI  │ commands │ apply edits                   │
  │ entities, weapons    │ ───────► │ N× { reactions, movement }    │
  │ Box2D bodies         │          │ air field (LBM)               │
  │ chunk streaming      │          │ liquid solver (FLIP)          │
  │ procgen              │ ◄─────── │ particles, rasterize          │
  │                      │ readback │ activity compaction           │
  │                      │          │ render + lighting             │
  └──────────────────────┘          └───────────────────────────────┘
```

## Stack

| concern | choice | notes |
|---|---|---|
| language | Zig, pinned version in `.zigversion` | all CPU code, build system, tooling |
| GPU API | Vulkan 1.3 via vulkan-zig bindings | compute and graphics, async compute queue, timeline semaphores, indirect dispatch |
| window, input, audio | SDL3 | creates the Vulkan surface; already on the dev machine |
| shaders | GLSL 4.6 compiled to SPIR-V with glslc in `build.zig` | embedded with `@embedFile`; Zig's SPIR-V backend revisited later |
| rigid bodies | Box2D v3, C API linked from Zig | beams as segment chains with breakable, plastic joints |
| data | ZON files, hot reloaded | materials, reactions, scenarios |
| fallback GPU API | SDL3 GPU | only if Vulkan boilerplate stalls the project; architecture unchanged |

## Layers

### Pixel grid

Resolution: the active window, 2048 × 2048 cells. Two images:

**Cell image**, `R32_UINT`:

| bits | field | meaning |
|---|---|---|
| 0–7 | material | id into the material table, 256 entries, widen to 10 bits later if needed |
| 8–15 | temperature | °C = 8·t − 40, range −40 to 2000 |
| 16–23 | state | material-defined: lifetime for flame and gas, health for wood and steel, wetness, fill |
| 24 | burning | cell is on fire; consumes health, emits flame and heat |
| 25 | moved | moved this substep; prevents double moves across block boundaries |
| 26 | particle-backed | rasterized from a liquid particle; the particle owns it |
| 27 | body-owned | rasterized from a rigid body; the body owns it |
| 28–31 | variant | stable per-pixel shade index into the material's color ramp |

**Owner image**, `R32_UINT`: body id when body-owned, particle index when
particle-backed, zero otherwise. Only read when the matching flag is set.

Movement uses a Margolus block cellular automaton. The grid is tiled into
2 × 2 blocks, one GPU thread per block, and the tiling offset cycles through
four positions each substep. A thread writes only its own block, so there are
no races, no atomics, no double buffering, and the result is deterministic.
Within a block: powders swap with lighter cells below or diagonally below,
liquids additionally spread sideways, gases do the same inverted, static
solids never move. Density is an integer ordering. A cell moves one block
position per substep; eight substeps per tick give a grid speed limit of
8 px per tick, 480 px/s. Anything faster becomes a particle.

Reactions and heat run as a gather pass before each movement pass. Each cell
reads its four neighbors, looks up material pairs in the reaction table,
diffuses temperature by conductivity, applies ignition, melting, freezing and
lifetime decay. Reaction entries carry a probability, a temperature range and
an optional catalyst material that must also be adjacent. Pairwise
reactions, growth, freezing and spell rules all fit that one shape.

Randomness is a hash of cell coordinate, tick and substep. No floats in the
grid shaders. This makes the grid bit-for-bit reproducible, which the CPU
reference implementation and the scenario tests depend on.

### Activity tiles

The grid is divided into 32 × 32 tiles with a one-byte flag each. A tile that
changes marks itself and its eight neighbors active for the next tick. A
compaction pass builds a list of active tiles and all grid passes dispatch
indirectly over that list. A static world costs almost nothing. The fluid
solvers have their own activity masks derived the same way.

### Air field

Lattice Boltzmann, D2Q9, single relaxation time, at 1024 × 1024 cells, each
covering 2 × 2 pixels. Compressible, so pressure waves exist and travel at a
tunable finite speed. Obstacles come from a coarsened solid mask each tick
with bounce-back boundaries. Sources: explosions inject density and momentum,
burning and hot cells inject buoyancy, steam and gas creation inject mass.
Sinks: open world edges, vents to the unsimulated region. Outputs: pressure
gradient and velocity sampled by the grid (destruction thresholds, gas
advection, particle drag), by bodies (blast impulse, drag) and by entities
(knockback, blast damage). Details in `04-fluids.md`.

### Liquid solver

FLIP/APIC particles, one per liquid pixel, with an incompressible pressure
projection on a 1024 × 1024 staggered grid solved by geometric multigrid.
Solid boundaries from the coarsened mask, free surface from particle
markers. Each tick the particles are rasterized into the grid as
particle-backed liquid cells so rendering, reactions and entity queries see
ordinary water. A reaction that consumes a particle-backed cell emits a
delete for the owning particle.

Liquid at rest is not particles. A particle that has been still for a while,
surrounded by liquid or solid, rasterizes permanently into a plain cell
governed by the cellular rules. A plain liquid cell wakes into a particle
when disturbed: a particle or flying pixel hits it, an adjacent solid
disappears, a pressure pulse passes, a body enters. The particle cap limits
active water, not total water. Details in `04-fluids.md`.

### Particle buffer

One GPU buffer serves both flying pixels and liquid particles. A particle
outside a liquid body is ballistic: integrate, raymarch the grid, land and
reinsert by atomic claim. A particle inside a liquid body is governed by the
projection. A splash is particles crossing that line. Capacity 1M on the
target card, with per-material spawn budgets so one explosion cannot starve
the rest.

### Bodies

Box2D on the CPU. Each body carries a pixel bitmap of materials. Each tick
the CPU uploads body transforms and the GPU rasterizes bitmaps into the grid
as body-owned cells, clearing last tick's cells first. Bodies collide with
the solid mask from the readback mirror. Beams are chains of segments with
weld joints: joints flex under load, shift their rest angle past a yield
threshold so the bend is permanent, and break past a fracture threshold.
Forces from the air and liquid fields are sampled per body from the readback.

After destruction events, a connectivity pass runs over a bounded region
around the event: iterative label propagation on the static-solid mask.
Islands not connected to the region boundary or to bedrock are extracted as
bodies and fall. Landing impacts above a material's threshold break them
into rubble cells and particles.

## The CPU–GPU boundary

**Commands** (CPU → GPU, per tick): fill circle, fill line, spray particles,
set temperature, ignite, inject pressure, rasterize body, delete body,
load chunk, save chunk. Anything that changes the world goes through this
list. Weapons, spells, enemies and scripts are all command emitters.

**Readback** (GPU → CPU, one tick late): a 1-bit solid mask of the window
(512 KB), material and temperature strips around each entity, body-region
material bitmaps for connectivity extraction, coarse pressure and velocity
samples at entity positions, and the **event queue**: a list the GPU appends
to when a rule needs gameplay to react. Gunpowder ignited here, entity cell
touched lava, pressure at a cell exceeded a trigger threshold. The CPU
drains it next tick and emits commands in response.

Gameplay code must tolerate one tick of lag. Collision pushes entities out
of solids rather than asserting they are not inside one.

## World streaming

The active window is a torus: coordinates wrap modulo 2048. Scrolling the
camera loads one new 256-pixel row or column of chunks into the slot the far
edge vacated. Chunks outside the window live compressed in CPU memory and on
disk, generated on demand by procedural generation that runs on the GPU
(noise, cave carving) and is seeded per chunk. The fluid solvers and
particle buffer wrap the same way, and liquid leaving the window is frozen
into cells before its chunk is evicted.

## Rendering

The grid is already on the GPU. One fullscreen pass maps material id and
variant to a palette ramp, adds temperature glow and emissive materials, and
samples lighting. Lighting starts as a handful of raymarched point lights
through the solid mask and becomes radiance cascades, which fit a 2D pixel
world well and let lava and fire light caves for free. Entities draw as
sprites at world pixel scale in a second pass. The world framebuffer is
integer upscaled to the window. Smoke and steam are rendered from the grid
like any other material; the air field itself is debug-only.

## Frame pipeline

1. CPU: drain event queue, input, gameplay, AI, weapons, Box2D step, chunk
   streaming. Produce command list.
2. GPU: apply commands. Rasterize bodies.
3. GPU: 8 × { reactions and heat gather; Margolus movement with rotating
   offset }, over active tiles only.
4. GPU: coarsen solid mask for the solvers.
5. GPU: air field, 4 steps. Apply pressure thresholds to grid, advect gases.
6. GPU: liquid solver: wake and sleep transitions, particle to grid,
   projection, grid to particle, advect, ballistic particles, rasterize.
7. GPU: activity compaction. Write readback buffers and event queue.
8. GPU: render world, lighting, sprites, upscale, present.
9. CPU: copy last tick's readback into the mirror.

Steps 3 through 7 run on the compute queue and overlap the render of the
previous tick on the graphics queue.

## Performance budget

Estimates for the target card at the standard window. Measured numbers
replace these as milestones land.

| stage | ms |
|---|---|
| grid passes, 8 substeps, active tiles | 2 |
| air field, 4 steps | 1.5 |
| liquid solver, 1M active particles | 4 |
| bodies, CPU, overlapped | under 1 |
| readback, render, lighting | 3 |
| total | ~11 at 60 Hz |

| resource | size |
|---|---|
| cell and owner images | 32 MB |
| air field, two D2Q9 buffers in f32 | 72 MB |
| liquid grid with multigrid levels | 32 MB |
| particles, 1M × 40 B | 40 MB |
| total GPU | ~180 MB |

Minimum spec profile: 1024 window, 512 fluid grids, 300K particles,
4 substeps. Same game, less of the world alive at once.

## Determinism

The grid and the air field are deterministic by construction. The liquid
solver's particle-to-grid transfer uses sorted per-cell binning with a
fixed gather order rather than float atomics, so it is deterministic too, at
some cost. The whole simulation is therefore reproducible from a seed and an
input log. This is what makes scenario tests exact and bug reports
replayable. Keep it that way: no float atomics, no wall-clock time, no
hardware-dependent math in any sim shader.

## Limits

- **Continuous solids**: the grid cannot bend or carry stress. Only bodies
  bend and break. Body count is hundreds to low thousands.
- **Fluids**: no true shocks, the air field is weakly compressible and
  injections are clamped. No flow narrower than two pixels is seen by the
  solvers. Air–water coupling is one-way plus explicit impulses. One liquid
  phase in the projection until multi-density lands.
- **Structures**: connectivity decides whether a chunk falls, not whether a
  pillar can hold it. Load-bearing heuristics are a later addition.
- **Mixtures**: one material per cell. Mud and wet sand are materials made by
  reactions.
- **Thermal**: 8-bit temperature, neighbor diffusion. Looks right, not
  physically timed.
- **Latency**: gameplay sees the world one tick late and changes it one tick
  later. Pixel-exact reactivity must be a GPU rule.
- **Sleep seams**: the boundary between sleeping and active liquid is where
  artifacts will appear and need iteration.

## Repository layout

```
build.zig, build.zig.zon     Zig build, shader compilation, codegen steps
.zigversion                  pinned toolchain
src/
  main.zig                   loop, timing, queues
  gpu/                       Vulkan device, memory, pipelines, timestamps
  sim/
    grid.zig                 cell format, images, dispatch
    air.zig                  LBM solver host code
    liquid.zig               FLIP solver host code
    particles.zig            shared particle buffer
    bodies.zig               Box2D integration, rasterization, connectivity
    commands.zig             command list encoding
    readback.zig             mirror, event queue
    reference/               CPU implementation of grid rules, bit-exact
  world/                     chunks, streaming, procgen, save
  game/                      entities, player, weapons, enemies, AI
  render/                    world pass, lighting, sprites, upscale
  data/                      ZON loaders, validation, table generation
shaders/
  sim/grid/                  one rule file per interaction class
  sim/air/, sim/liquid/, sim/particles/, sim/bodies/
  render/
materials/                   one ZON file per material
scenarios/                   declarative regression worlds
docs/                        these documents; materials.md is generated
tools/                       material doc generator, scenario runner, profiler
```

Adding a material: one file in `materials/`. Adding an interaction class:
one rule file under `shaders/sim/grid/`, one hook in the owning pass, one
row in `02-interaction-classes.md`, one representative material.
