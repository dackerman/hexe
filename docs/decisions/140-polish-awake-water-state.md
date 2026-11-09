# Polish: awake water keeps its state byte; gas bubbles up through it

**Context**: decision 132 found that water resting on the steam room's hot
2 px divider never boiled while the liquid solver ran. Decision 84 had the
claim pass write every rasterized particle's cell with the material's
initial state byte, so the per-cell counters that live in the state byte
(decision 42) were reset every tick for awake water: the boil latency (40
ticks held at the boil point, decision 41) and the charge phase (bits 6-7).
Measured on main with a new scene (`liquid_boil`: 216 x 48 water kept
awake by a wake command every 8 ticks, on a 2 px stone divider over a
40 px lava bath): the bottom row reaches the boil point and counts to
39, then restarts; 0 steam cells in 600 ticks. A lightning bolt into an
awake pool (`playtests/lightning_water_awake.hexe`) left the walker in it
alive: the pulse head was reset to idle at the tick boundary.

Carrying the state byte exposed a second loss: the compaction pass
(`drop.comp`) moves a slow particle into a free pixel below it, and a gas
pixel counts as free, so the steam that formed at the bottom of the pool was
overwritten by the water above it the same tick (about 420 water cells
vanished in 600 ticks, still 0 steam).

**Decision**:
- New per-particle array `pstate` (two sets like the other particle
  arrays, `LQ_BUF_PSTATE`, `Buf.pstate`): lift stores the cell's state byte
  (temperature was already carried in the info word, which has no spare
  byte), the sort copies it, the wake pass sets it from the sleeping cell,
  and claim writes it back instead of `state_init`. Particles handed to
  the shared ballistic buffer still land with the initial state (a droplet
  in flight loses its boil count; P_META has no free byte either).
- Gas other than air is displaced, not destroyed:
  - `drop.comp`: a particle dropping into a gas pixel swaps it up into the
    pixel it leaves (a bubble rises one pixel per tick through awake
    water). Deterministic: each hole has one candidate.
  - `claim.comp` + new `bubble.comp`: a winner that claims a pixel holding
    a gas other than air records it (`LQ_BUF_DISPLACED`); after the claim
    rounds the gas moves straight up through liquid to the first air pixel
    within 64 px (compare-and-swap on the cell, so bubbles in one column
    stack). Blocked by a solid, it is lost and counted
    (`Stats.total_bubbles_lost`). Which of two different gases ends up
    higher in one column depends on scheduling; cell counts do not.

**Measured** (`zig build liquid-test`, check `boil`, ReleaseFast):
- main: 0 steam in 600 ticks (bottom row's boil count peaks at 39).
- state carried, no bubble rule: 0 steam, water count 10368 -> 9947.
- both: first 20 steam cells at tick 225, up to 187 steam cells (113 at
  tick 600; steam condenses again on the cold walls), 174 gas cells moved
  by bubble.comp; the cellular reference (solver off, same scene) peaks at
  149. Check: >= 50 steam cells with >= 2000 particle-backed water cells
  the whole time.
- `playtests/lightning_water_awake.hexe` (pool fully particle-backed: the
  census shows 12000 of 12000 water cells particle-backed at ticks 89 and
  109): main, walker alive after two bolts; now "walker died
  (electrocuted)" at tick 113, as in the cellular `lightning_water`.
- Freezing is not affected (no counter: `freeze_at` is a plain threshold).
- Determinism checks of the liquid test unchanged (dam, basin: 0 cells
  differ).

**Alternatives**: keeping the old cell's state when a particle reclaims a
pixel of its own material (lift has already turned the pixel into air, and
particles move between pixels); packing the state into the info word (it
is full: material, mode, overlap, rest, variant, temperature); treating
gas as not free for particles (the gas would sit under awake water forever:
movement treats particle-backed cells as static).

**Consequences**: 8 MB more VRAM at the 1M capacity (pstate x2, displaced).
Supersedes decision 84's "the state byte is not carried by particles".
