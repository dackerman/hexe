# Particle buffer: SoA at fixed slots, atomic free stack plus spawn queue

**Context**: docs/01-architecture.md wants one GPU particle buffer shared by
flying pixels and FLIP liquid particles, 1M capacity on the target card,
with per-material spawn budgets. docs/04-fluids.md fixes the per-particle
fields but not the allocation scheme, the slots, or how several passes
(commands, impacts, blast thresholds, FLIP wake) create and free particles
in one tick.

**Decision** (`src/sim/particles.zig`, `shaders/sim/particles/particles.glsl`):

- **Layout**, structure of arrays, `capacity` entries each (default
  `Config.particle_capacity = 1 << 20`), every array at a fixed bindless
  slot so other branches reach it without plumbing:

  | slot | GLSL | type | content |
  |---|---|---|---|
  | `SLOT_BUF_PARTICLE_POS` 18 | `P_POS[i]` | vec2 | world px, wrapped to [0, 2048) |
  | `SLOT_BUF_PARTICLE_VEL` 19 | `P_VEL[i]` | vec2 | px/s, +y down |
  | `SLOT_BUF_PARTICLE_AFFINE` 20 | `P_AFFINE[i]` | vec4 | APIC c00 c01 c10 c11; FLIP only; zeroed at spawn |
  | `SLOT_BUF_PARTICLE_META` 21 | `P_META[i]` | uint | see below |
  | `SLOT_BUF_PARTICLE_BINDING` 22 | `P_BINDING[i]` | uint | FLIP's cell binding; `PARTICLE_UNBOUND` (0xffffffff) for ballistic |
  | `SLOT_BUF_PARTICLE_CTRL` 17 | `PCTRL[w]` | uint[544] | header, per-material live counts, budgets |
  | `SLOT_BUF_PARTICLE_FREE` 23 | `P_FREE[k]` | uint | free stack of indices |
  | `SLOT_BUF_PARTICLE_SPAWN` 24 | `P_SPAWN[k]` | SpawnRequest (32 B) | this tick's spawn queue |
  | `SLOT_IMG_PARTICLE_OVERLAY` 8 | `P_OVERLAY` | r32ui image | ballistic particles drawn for the world pass |

  40 B per particle as in the fluids doc, plus 4 B of free stack: 44 MB at
  1M, plus 8 MB of spawn queue (`Config.particle_queue = 1 << 18` requests
  per tick) and the 16 MB overlay. Slots 16-24 were taken as a block so
  branches numbering upward from 4 do not collide.
- **`P_META`**: bits 0-7 material, 8-9 mode (`PARTICLE_MODE_FREE` 0,
  `BALLISTIC` 1, `LIQUID` 2), 10-13 stuck counter (ballistic), 16-23
  temperature byte, 24-27 variant, 14-15 and 28-31 free for FLIP. A
  particle carries the temperature and shade of the cell it came from and
  lands as that cell (`particle_cell`).
- **Allocation protocol** (the important part for the liquid solver):
  - *Request* (any pass, any time in the tick): `spawn_particle(pos, vel,
    meta, binding)` or `eject_cell(p, vel)` / `eject_cell_as(...)`.
    `particle_reserve` takes one per-material budget unit
    (`PCTRL_MAT_LIVE[m] < PCTRL_BUDGET[m]`) and one queue entry
    (`atomicAdd(PCTRL_SPAWN_COUNT) < PCTRL_SPAWN_LIMIT`), undoing both on
    refusal (`PCTRL_REFUSED`). `PCTRL_SPAWN_LIMIT` is a snapshot of
    `min(free count, queue capacity)` taken at the end of the previous
    tick, so every accepted request is guaranteed an index.
  - *Release* (any pass that owns the particle): `release_particle(i)`
    clears `P_META[i]`, decrements the material's live count and pushes `i`
    with `atomicAdd(PCTRL_FREE_COUNT)`.
  - *Materialize*: only `spawn.comp` pops, once per tick after every other
    particle pass (end of architecture step 6): request k takes
    `P_FREE[free_count - 1 - k]`. `control.comp` then lowers the free count,
    resets the queue, snapshots the next limit, recomputes `PCTRL_LIVE` and
    the indirect args (`PCTRL_DISPATCH`: groups of 256 over
    `PCTRL_HIGH_WATER`). Pushes and pops never share a pass, so the stack
    needs no locking; a particle requested in tick T first moves in T+1.
  - When nothing is live, `rebuild.comp` rewrites the stack as
    capacity-1..0 and the high-water mark drops to 0: an idle particle
    system dispatches zero groups (measured 0.013 ms per tick for the six
    small dispatches).
- **Budgets**: default `capacity / 4` per material, air 0;
  `Config.particle_budget` overrides the default, `Particles.setBudget(m,
  n)` changes one at run time. One explosion of dirt cannot take the
  particles water needs.
- **For the liquid solver (M6)**: spawn liquid particles by queueing
  requests with mode `LIQUID` (wake), keep their index stable for the owner
  image, release them with `release_particle` (sleep, reaction deletes),
  switch a particle to ballistic by rewriting its mode bits
  (`pmeta_with_mode`); the ballistic pass ignores `LIQUID` particles and
  picks up `BALLISTIC` ones on the next tick. The ballistic pass turns a
  landing ballistic water particle into a plain cell today; the hook for
  "lands in liquid -> becomes LIQUID again" is the `land()` call in
  `ballistic.comp`. Iterate `[0, PCTRL_HIGH_WATER)` (or dispatch indirect
  from `PCTRL_DISPATCH`) and test the mode.

**Alternatives**: compaction with a prefix sum each tick (indices move
every tick, which breaks the owner image's particle index and any CPU-side
handle); a single atomic stack with pops in any pass (a pop racing a push
in the same pass can read an index before it is written); a bump allocator
reset when empty (fragments under steady load).

**Consequences**: indices are stable for a particle's life. Index order and
claim races depend on GPU scheduling, so particle outcomes are not bit
reproducible (decision 51). The free stack is LIFO, so after heavy churn
the high-water mark can stay near the peak until the system empties.
