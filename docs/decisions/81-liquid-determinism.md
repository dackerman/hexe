# Liquid solver determinism: sorted gather, ranked spawns, two-phase passes

**Context**: docs/01-architecture.md requires a reproducible simulation (no
float atomics); every GPU race in the solver must resolve the same way
regardless of scheduling.

**Decision**:
- Binning: counting sort per 1024^2 grid cell (atomic integer counts, a
  work-efficient two-level scan, `scan_local.comp` + `scan_sums.comp`, 1024
  elements per block), scatter with atomic slots, then one thread per bin
  insertion-sorts its particle indices (`bin_fixup.comp`). The particle
  arrays are then reordered into the other set (`reorder.comp`), so the
  order is (cell, previous index) and each bin is contiguous. P2G is a
  per-face gather over the 3x3 neighboring bins in that order. The reorder
  is also the compaction of dead particles.
- Wake spawns: a candidate's particle index is count + (prefix of its tile
  in tile order) + (position inside the tile in thread and pixel order),
  computed by a count pass, a scan and a spawn pass. The neighborhood tests
  run once (mode 0) and are stored in bits 24-31 of the wake word, because
  spawning writes cells that neighbors test.
- One particle per pixel: `imageAtomicMin` of the index on the owner image.
- Passes that test neighbors while others change them are split into
  decide (mark `LQ_BIND_PENDING`) and apply: hole compaction (`drop.comp`)
  and sleep (`settle.comp`).
- Multigrid smoothing works in 32x32 tiles in shared memory; tiles run in
  checkerboard order (two dispatches) so no tile's halo changes while it is
  read. Prolongation into the halo is done by the first color only.
- Wake requests use atomic OR of thermometer codes (hop count h = h low
  bits), so racing writers commute.
- CPU-side recording decisions (decision 86) use counters from a fixed tick
  lag, never "the latest available".

**Verification**: `hexe --headless --liquid-test determinism` runs the dam
break and the basin showcase twice for 600 ticks and compares every cell
and every particle owner word: 0 differences. `zig build
verify-determinism` (solver off) still passes: with the solver off no cell
has the particle flag, and the one movement change (particle-backed cells
are static) is mirrored in the CPU reference.

**Alternatives**: fixed-point integer atomics for P2G (deterministic too,
but the architecture names sorted binning); radix sort (more passes);
Jacobi smoothing (deterministic without tile ordering but converges at half
the rate).

**Consequences**: the sort costs about 0.12 ms at 500K particles and 0.23
ms at 1M. Any new pass that reads neighbor cells while writing cells needs
the same decide/apply split.
