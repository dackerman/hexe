# Milestones

Each milestone ends in something that runs and is fun to poke at. Each later
layer is designed in from the start but built only when its milestone comes.
"Done" criteria are checkable, not aspirational.

## M0 — Bootstrap

- Zig pinned in `.zigversion`; `zig build run` opens an SDL3 window with a
  Vulkan device, swapchain, compute pipeline writing to a storage image, and
  a blit to screen.
- GPU timestamp queries drawn as an on-screen frame-time HUD.
- GLSL compiled to SPIR-V in `build.zig`; a shader change rebuilds.
- Done: 60 Hz animated noise at 2048 × 2048 internal resolution with the HUD
  showing compute and present time.

## M1 — Cellular grid

- Cell and owner images with the format in the architecture doc.
- Margolus movement with four rotating offsets, 8 substeps per tick.
- Materials hardcoded: air, stone, sand, water (cellular for now), smoke.
- Mouse painting and erasing with a brush. Camera pan and zoom.
- CPU reference implementation in `src/sim/reference/` and a test that
  compares it bit-for-bit against the GPU after 300 ticks on a seeded
  scenario.
- Done: sand piles, water pools and spreads, smoke rises; the determinism
  test passes.

## M2 — Sleep and profiling

- 32 × 32 activity tiles, compaction, indirect dispatch for all grid passes.
- Per-pass GPU timings in the HUD. A profile dump to a file.
- Done: a static 2048 world costs under 0.2 ms of grid time; a fully active
  one under 2.5 ms.

## M3 — Materials as data

- ZON loader with validation, hot reload on file change, GPU material and
  reaction tables.
- Reaction and heat gather pass with probability, temperature range,
  catalyst and event fields.
- Burning flag, flame gas, lifetime decay, melt, freeze, boil.
- `zig build docs` generates `docs/materials.md`.
- Scenario runner: headless sim of a ZON scenario, asserts on cell counts
  and positions after N ticks.
- Done: the full version one set loads; wood burns to ash, water on lava
  makes stone and steam, sand on lava makes glass; scenarios pass.

## M4 — Commands, particles, player

- Command list: fill, line, spray, ignite, set temperature, explode
  (impulse heuristic until M5).
- Unified particle buffer, ballistic mode: spawn, integrate, raymarch,
  land by atomic claim. Impact responses: splash, spray, chip, dent.
- Readback: solid mask, entity strips, event queue. Gunpowder emits
  `explode`; CPU handles it.
- Player entity with pixel collision against the mirror, run, jump, a dig
  tool and a blast tool. Camera follows.
- Toroidal window, 256-pixel chunk streaming, procgen stub, save and load
  of modified chunks.
- Done: walk through an endless procedural cave, dig, blow things up,
  debris flies and lands; one-tick latency is not perceptible.

## M5 — Air field

- D2Q9 LBM at 1024 × 1024, obstacle coarsening, bounce-back, open edges.
- Explosion injection replaces the impulse heuristic. Buoyancy from heat.
  Mass from gas creation.
- Blast thresholds on the grid, gas advection, particle drag, pressure
  events.
- Debug overlay for density and velocity.
- Done: scenarios 3 and 4 from the fluids doc pass; smoke follows drafts;
  a grenade in a corridor is visibly deadlier than in the open.

## M6 — Liquid solver

- FLIP/APIC particles, deterministic binning, staggered grid, multigrid
  projection with cut cells, rasterization, reaction-driven deletes.
- Sleep and wake with budgets. Water switches to `solver = flip`.
- Done: scenarios 1, 2, 5 and 6 pass; a dam break looks like a wave; a
  still lake costs nothing.

## M7 — Bodies

- Box2D v3 linked. Body bitmaps, rasterization as body-owned cells,
  transforms uploaded per tick.
- Connectivity pass after destruction; islands become bodies; landing
  breaks them by threshold.
- Steel beams as segment chains with plastic, breakable weld joints.
- Fluid forces on bodies from readback samples.
- Done: cut a steel beam, it sags then snaps; blow out a concrete pillar,
  the slab above falls and shatters; a crate floats and gets blasted.

## M8 — Rendering

- Palette ramps, variant shades, temperature glow, emissives, translucency.
- Radiance cascades lighting from emissive cells and point lights, smoke
  occlusion.
- Sprite pass for entities, integer upscale, basic post.
- Done: lava lights a cave, fire flickers, glass and water read as such.

## M9 — Gameplay foundation

- Entity system, enemies with simple AI on the readback mirror.
- Weapon framework: projectiles, sprays, placed charges, beams, each
  expressed as command emitters with material payloads.
- Entity contact effects, status effects, death into bodies and blood.
- Electricity propagation.
- Done: a short vertical slice where enemies can be killed by every class
  of interaction in the checklist.

## Later

- Variable-density projection for oil on water.
- Load-bearing heuristics for structures.
- Two-way air–liquid interface.
- Magical material class once the spell design settles.
- Minimum-spec profile tuning and a benchmark scene.
