# Benchmark scenes and the definition of grid time

**Context**: M2's budgets (static world under 0.2 ms, fully active under
2.5 ms) need fixed scenes and a definition.

**Decision**: `zig build bench` builds ReleaseFast and runs, headless, 300
ticks each of: `bench_static` (stone lower half, a flat sand layer, a flat
water pool on a stone shelf; everything at rest after tick 0) with sleep;
`bench_active` (the whole torus filled with 50% coverage sand, no floor, so
it falls forever and every tile stays active) with sleep; `bench_active`
with sleep disabled; and `bench_mixed` (sand, water and smoke scattered
over the torus, sinking, rising and spreading forever, which exercises every
rule branch) with sleep. The first 10 ticks are excluded (scene
creation, clock ramp). Grid time = commands + activity + movement GPU
timestamps per tick (all 8 substeps). `--profile path` writes
`tick,pass,ms` rows for every tick (also `active_tiles`).

**Alternatives**: wall clock (includes CPU submission and idle gaps), a
random-noise active scene that compacts (it settles within a few hundred
ticks).

**Consequences**: free-falling sand organizes into alternating rows, so
every block moves every substep: the heaviest write load the grid sees.
Numbers measured on the RTX 4090 are in the M2 commit message and the
foundation report.
