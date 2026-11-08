# Window seams: keep the tile column/row before each seam asleep
**Context**: The sim treats the 2048² window as a torus, but its leading
and trailing edges are 2048 cells apart in the world. Without a guard, water
at the bottom edge of the window fell through the wrap and rained out of
the sky at the top (seen in a headless `--world` screenshot), and sand and
water leaked between a freshly loaded edge chunk and the chunk on the
opposite edge.
**Decision**: Margolus blocks start inside their tile and reach one cell
right/down, so a seam is closed by keeping the tile column (row) just
before it off the active list. `Session` tells `Stream.setSeams` where the
seams are each tick: left of / above the origin slot, and during a move on
both sides of the slot column/row being swapped. `dirty.comp`, which runs
right before compaction, zeroes those tiles' wake marks (after reading them
for dirty bits).
**Alternatives**: a seam check in movement.comp (another agent's shader,
and every future solver would need it); clearing a band of cells.
**Consequences**: a 32-cell band at the far window edge (≥ 768 cells from
the camera) is frozen; material piles against it there instead of wrapping.
Settling also stopped spreading, so fewer chunks get parked (~37–50 % of
streamed chunks instead of ~65 %). Not effective with `--no-sleep`
(compaction ignores marks). The air field, liquid solver and particles wrap
the same way and must respect the same seams when they land
(`Stream.freeze_cols/freeze_rows`).
