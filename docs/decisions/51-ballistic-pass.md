# Ballistic pass: DDA, landing on support, impacts, determinism stance

**Context**: M4 asks for ballistic particles that integrate, raymarch the
grid, apply the target's impact response and land by atomic claim. The
details (what stops a particle, where it lands, what happens when it cannot,
how impacts scale, whether it is deterministic) were open.

**Decision** (`shaders/sim/particles/ballistic.comp`, one thread per index
below the high-water mark, after the liquid solver in architecture step 6):

- **Integrate**: `v.y += 196 * dt` (dt = 1/60), speed capped at 60 px per
  tick (3600 px/s). Gas particles get no gravity, damp 10% a tick and
  become a cell at their position as soon as it is air.
- **March**: Amanatides-Woo DDA from `floor(p)` to `floor(p + v dt)`, at
  most 160 cells. Air and gas cells are passable (debris flies through
  smoke); anything else is a hit. The last *air* cell seen is the landing
  candidate (`free_c`, with the value read, `free_v`).
- **On a hit**, in order:
  1. impact response of the target material (below), if faster than 90 px/s
     and the target is not body-owned;
  2. ricochet: targets with `MATERIAL_FLAG_RICOCHET` reflect the particle
     (restitution `material.restitution / 255`, default 0.5) when faster
     than 150 px/s; it keeps flying;
  3. **glance**: if the cell under `free_c` is passable (hitting a ceiling
     or the side of a wall in mid-air), reflect the normal velocity with
     0.2 and keep flying. Particles become cells only where something holds
     them up; otherwise debris stuck to ceilings and walls as cells and
     crawled down at the 8 px/tick grid limit (seen in the first
     screenshots);
  4. **land**: `imageAtomicCompSwap(cell, free_v, particle_cell(meta))`.
     On success the particle is released and the tile marked;
  5. on failure (no air on the path, or another particle won the cell) the
     particle bounces (restitution 0.3), its stuck counter rises, and it
     retries next tick; after 15 consecutive failures it is deleted
     (`PCTRL_LOST`).
- **Buried** particles (their cell was filled by another landing, or they
  spawned inside something) first look up to 128 cells straight up through
  loose cells (not through static solids or bodies) and land on top of the
  pile, then search the square rings of radius 1 to 4 around them. Without
  this, debris falling back into a crater buried the slow chips there and
  lost about 1% of the mass; with it the eject test loses 0-1 of 15 489.
- **Impact responses** (material `impact`):
  - *splash* (liquids) / *spray* (powders): at 200 px/s and above, up to
    1-3 target cells (hit cell and its two neighbors along the surface) fly
    back out: chance `min((speed - 200) * 0.2, 160) / 256` scaled by the
    projectile/target density ratio, speed 10-30% of the impact plus 10%
    upward, +-20% sideways. Kicked cells keep at most ~40% of the speed, so
    kick cascades die out within a few generations (an earlier 65% version
    kept a fountain alive for over 10 s).
  - *chip* (stone): above 300 px/s, with chance up to 25% (at 1324 px/s),
    1-3 surface cells fly off as the material's `rubble`; otherwise
    *dent*.
  - *dent* (steel): health (state byte) loses `max(1, speed * density /
    19200)`: sand at 128 px/s takes 1. At zero the cell becomes its rubble
    in place, or air without one.
  - *ricochet*: see above (steel has `.impact = .dent` plus the ricochet
    flag, as in the data layer).
- **Rendering**: ballistic particles are not cells. Each is drawn into the
  overlay image (`SLOT_IMG_PARTICLE_OVERLAY`, the cell word it would land
  as, with `CELL_FLAG_PARTICLE` so it is never zero); an erase pass clears
  each particle's previous pixel first. `shaders/render/world.frag` reads
  the overlay and draws it over the cell (three lines; the rendering
  branch owns that file and may restyle it).
- **Determinism**: positions and velocities are f32, as the fluids doc's
  layout requires; each particle's own trajectory is reproducible on one
  GPU (no float atomics), but the index order of spawns and the winner of a
  contested landing depend on scheduling. The particle passes therefore run
  in `zig build verify-determinism` but the seeded scenes spawn no
  particles; the command side of eject is checked separately (decision 54).

**Alternatives**: fixed-point positions and a two-phase deterministic claim
(propose with `atomicMin` of a hashed key, resolve in a second pass) plus a
sorted allocator: deterministic, but two more passes and a sort per tick;
worth revisiting if scenario tests need particle-exact replays. Landing at
the hit point without the support rule (simpler, but cells glued to
ceilings). A particle-particle collision grid (not needed for debris).

**Consequences**: measured cost (RTX 4090, `zig build bench`): 0.034 ms per
tick with 100 000 particles in free fall, 0.031 ms for a sand rain with
~64 000 live and ~430 landings per tick, 0.013 ms with none. Debris from a
950 px/s eject in an 800 px tall cave is all down after 6-8 s; most of that
is fall time after glancing off the ceiling. Air drag (M5) will shorten it.
