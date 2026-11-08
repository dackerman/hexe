# Activity tiles: wake countdown, compaction after commands

**Context**: M2 asks for 32x32 tiles with one byte each, marking on change
(self and 8 neighbors), compaction to an active list, and indirect dispatch.

**Decision**:
- The byte is a **wake countdown**, not a flag: a change writes
  `TILE_WAKE_TICKS` (8) into the tile and its 8 neighbors; compaction puts
  every nonzero tile on the list and decrements it. A tile sleeps after 8
  quiet ticks. With a plain one-tick flag, a liquid edge whose random rolls
  all failed for one tick (about 2% per tick for water) froze the tile
  forever; the countdown makes that ~1e-14.
- **Compaction runs right after command application**, at the start of the
  tick, not at the end (architecture step 7). The marks it consumes are the
  previous tick's changes plus this tick's edits, so painted material moves
  in the same tick. One marks buffer suffices.
- `TILE_MARKS` holds 4096 countdown bytes followed by 4096 "active this
  tick" bytes (written by compaction, read by the F2 overlay). `TILE_LIST`
  holds `VkDispatchIndirectCommand` then packed tile coordinates; the
  engine zeroes the count with `vkCmdUpdateBuffer` and compaction appends
  with `atomicAdd`. List order varies; results do not (blocks are
  independent).
- Movement marks per workgroup (one tile): a shared flag, one thread writes
  the 9 bytes. Commands mark per 16x16 workgroup, origin aligned to 16 so a
  workgroup lies in one tile.
- `--no-sleep` (Config.sleep = false) makes every tile active; the
  determinism check runs both modes.

**Alternatives**: double-buffered flags (a second buffer for nothing), end of
tick compaction (painted cells wait a tick).

**Consequences**: a static world costs compaction (4096 threads) plus eight
empty indirect dispatches: 0.006 ms measured. Solvers that change cells
must call `mark_tile_and_neighbors` (common.glsl) when `frame.sleep`.
