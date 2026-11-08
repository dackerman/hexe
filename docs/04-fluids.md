# Fluids: Air Field and Liquid Solver

Both solvers run at half pixel resolution, 1024 × 1024 cells over the 2048
window, each cell covering 2 × 2 pixels. Both take their obstacles from a
coarsened solid mask produced every tick from the pixel grid. Both write
their effects back into the pixel grid, which is the only thing gameplay and
rendering ever read.

## Shared: obstacle coarsening

One pass per tick. For each 2 × 2 pixel block: solid fraction (0, ¼, ½, ¾, 1)
from static-solid and body-owned cells, plus the body's velocity if any. The
air field treats fraction ≥ ½ as wall. The liquid solver uses the fraction as
a cut-cell weight in the projection, and the body velocity as the boundary
velocity so bodies push liquid.

## Air field

**Method**: lattice Boltzmann, D2Q9, BGK single relaxation time. Nine f32
distribution values per cell, ping-pong buffers. Streaming and collision
fused into one pass with pull scheme. Bounce-back on walls.

**Why LBM**: entirely local, so it maps to the GPU with no global solve;
arbitrary pixel-shaped boundaries are free; it is compressible, so pressure
waves exist and reflect; and it is stable and cheap at the resolutions we
need.

**Wave speed**: LBM sound speed is 1/√3 lattice cells per step. At 2 px per
cell and 4 steps per tick at 60 Hz, that is roughly 280 px/s, about 14 m/s.
Real sound would cross the screen in a frame. Slowing it is a deliberate
gameplay choice: a blast wave should be something you can see ripple
outward and brace for. Steps per tick is the tuning knob.

**Stability**: BGK is stable up to about Mach 0.3. All injections are
clamped so local velocity stays below that, and relaxation time is kept
above 0.55. Explosions therefore produce a strong, fast pressure pulse, not
a supersonic shock. Visually indistinguishable in play.

**Sources into the field**:
- Explosion command: add density and radial momentum in a disc over a few
  steps. Energy parameter sets peak overpressure and radius.
- Burning and hot cells: add upward momentum proportional to temperature
  above ambient. Fire makes convection; a chimney draws.
- Phase changes creating gas: steam from boiling, smoke from burning,
  gas from reactions each add mass at the cell.
- Gas materials consumed or vented: remove mass.
- Bodies: moving walls via bounce-back with velocity.

**Sinks**: window edges are open boundaries with ambient density. Cells
marked as "vent" by world generation drain toward ambient.

**Effects back onto the world**:
- *Pressure threshold destruction*: each tick, for active air tiles, compare
  pressure gradient magnitude against the material's `blast_threshold`.
  Powders and liquids above threshold become ballistic particles with the
  local air velocity. Breakable solids lose health proportional to excess
  and emit chip particles; at zero health they are removed and the cell
  joins the connectivity check. Steel and bedrock have no threshold.
- *Gas advection*: cells whose material is a gas move with the air velocity
  instead of the random rise rule. Implemented as a semi-Lagrangian step
  on gas cells in the grid pass, reading the air velocity texture. Smoke
  pools under ceilings, drifts down corridors, and gets sucked toward a
  breach.
- *Particle drag*: ballistic particles sample air velocity and accelerate
  toward it by their material's drag. Debris rides the blast.
- *Bodies and entities*: pressure gradient integrated over the body's cells
  gives a blast impulse; dynamic pressure gives drag. Entities get knockback
  and blast damage from the same samples via the readback.
- *Events*: cells whose material has a `pressure_event` threshold append to
  the event queue when exceeded. Pressure plates, fragile glass alarms,
  spell triggers.

**Sealed spaces**: no special code. A room with no path to the edge keeps
its mass. Steam from lava and water in a closed cave raises pressure until
something gives. Flooding a room compresses the air pocket. This is the
single most important emergent behavior and should be the first scenario
test for the air field.

**Cost**: 1M cells × 4 steps × 72 B read+write ≈ 300 MB per tick, about
1.5 ms on the target card. Active-tile masking cuts most of it when the air
is still.

## Liquid solver

**Method**: FLIP/APIC. Particles carry position, velocity and an affine
velocity matrix. Each tick: transfer particle momentum to a staggered MAC
grid, add gravity, enforce solid boundaries, solve a pressure Poisson
equation so the velocity field is divergence-free inside the liquid, transfer
the corrected velocity back to the particles, advect particles, and push
particles out of solids.

**Why FLIP**: it is the standard for free-surface liquids with momentum.
Particles mean the liquid can splash, separate and rejoin without any
surface tracking, and one particle per pixel means the liquid stays
pixel-crisp when rasterized. The pressure projection gives incompressibility,
which is what makes levels equalize, water flow around obstacles, and
pressure build behind a wall.

**Pressure solve**: geometric multigrid on the 1024 grid, V-cycles with
red-black Gauss-Seidel smoothing, cut-cell solid weights from the coarsened
mask. Target 4–6 V-cycles per tick. Residual tolerance can be loose; visual
plausibility matters more than exact incompressibility.

**Particle layout**: structure of arrays.

| field | type | bytes |
|---|---|---|
| position | 2 × f32 | 8 |
| velocity | 2 × f32 | 8 |
| affine matrix | 4 × f32 | 16 |
| material, mode, flags | u32 | 4 |
| cell binding | u32 | 4 |

Mode is ballistic or liquid. Ballistic particles skip the transfers and are
handled by the shared particle pass. A liquid particle that leaves the
liquid body (no neighbors within one cell) switches to ballistic; a
ballistic liquid particle that lands in liquid switches back. Splash is
exactly that transition.

**Deterministic transfer**: particles are binned per grid cell each tick
with a counting sort, and the particle-to-grid step gathers from the bins in
index order. No float atomics. This costs an extra sort pass and keeps the
whole simulation reproducible.

**Rasterization**: after advection, each liquid particle claims the pixel it
occupies and writes a particle-backed liquid cell with its index in the
owner image. Two particles in one pixel: the second is pushed to the nearest
free pixel next tick by a small separation force; if none is free for
several ticks it is merged and deleted. Pixels that were particle-backed
last tick and were not reclaimed are cleared to air.

**Reactions on liquid**: the grid reaction pass runs on rasterized cells like
any other. When a reaction changes a particle-backed cell into something
else, the pass writes the new material and appends the owner index to a
delete list. Water on lava becomes steam and stone, and the particle that
was the water is gone next tick.

**Sleep**: a liquid particle whose speed stays below a threshold for N ticks
and whose eight neighboring pixels are all liquid or solid is a sleep
candidate. Sleep converts it into a plain liquid cell, clearing the
particle-backed flag, and frees the particle. Interior of a still pool
sleeps first, surface last. A pool fully asleep costs the cellular rules
only, and those are nearly free under activity tiling.

**Wake**: a plain liquid cell wakes into a particle when any of these happen
in its tile: a ballistic particle lands in liquid, a solid cell adjacent to
liquid is removed, a body overlaps liquid, air pressure gradient exceeds a
small threshold, or a neighboring liquid cell woke last tick. Waking spawns
the particle with the cell's position and zero velocity and spreads one cell
per tick, so a disturbance ripples outward through a sleeping pool. Wake
spread stops when the budget is reached; the far side of a huge lake stays
asleep and the cellular rules handle it.

**Hybrid pools**: a pool that is part awake and part asleep has a seam. On
the sleeping side the cellular rules still move cells, so the seam is not a
wall, but momentum stops there. Expect this to need tuning: wake radius,
sleep delay, and a soft band where particles are damped before sleeping.

**Multi-liquid**: version one puts only `solver = flip` materials in the
projection, all with the same density. Oil, blood and acid stay cellular.
Variable-density projection is a later milestone and the data schema already
carries density, so nothing in the material files changes.

**Lava**: stays cellular. Slow, viscous, low-dispersion flow is what the
cellular rules already do well, and lava rarely needs momentum. If a
lava-fall ever needs to look better, flipping its `solver` field is the
whole change.

**Budget**: per-cell binning, two transfers, 5 V-cycles and rasterization on
1M particles over a 1M-cell grid is about 4 ms on the target card. The
particle cap is a hard ceiling on active water: spawns beyond it are refused
and the water stays cellular.

## Coupling summary

| from | to | how |
|---|---|---|
| grid | both solvers | coarsened solid mask with body velocity |
| air | grid | gas advection, blast thresholds, events |
| air | particles | drag |
| air | bodies, entities | impulse and drag via readback samples |
| liquid | grid | rasterized particle-backed cells |
| grid | liquid | reactions delete particles; solid removal wakes cells |
| liquid | bodies | buoyancy and drag from particle density around the body |
| bodies | both | moving boundaries |
| air | liquid | explosion impulse applied directly to particles in radius; otherwise none in v1 |
| liquid | air | liquid cells count as walls for the air field |

## Scenario tests to write first

1. Water poured into a U-tube equalizes within 2 seconds.
2. A dam of 1-px wood between two basins is removed; a wave crosses and the
   levels settle.
3. Lava and water meet in a sealed 64 × 64 room; pressure rises; a 1-health
   wood wall on one side fails before the stone on the other.
4. An explosion in a 3-wide corridor destroys sand plugs at twice the
   distance it does in the open.
5. A pool sleeps fully within 5 seconds of being poured, then wakes locally
   when a stone drops in, and the far edge stays asleep.
6. The same seed and input log produce identical cell images after 600 ticks.
