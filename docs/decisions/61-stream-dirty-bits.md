# Chunk dirty bits derived from activity marks
**Context**: Eviction and save need to know which resident chunks changed.
The task allowed either a `mark_chunk_dirty` call in every cell-writing
shader or deriving dirtiness from the activity marks; seven agents edit the
cell-writing shaders in parallel.
**Decision**: derive. `dirty.comp` runs every tick after commands and
before compaction: a tile whose wake countdown equals `TILE_WAKE_TICKS` was
marked by a change since the last compaction (every pass that changes cells
must already call `mark_tile_and_neighbors`), so its slot's u32 in a
64-word buffer is set. Uploads write `TILE_WAKE_TICKS − 1` so fresh chunks
settle without counting as changed. The CPU reads the bits only when it
needs them (eviction, flush). No change to common.glsl or to any other
shader. With `--no-sleep` nothing marks tiles, so every slot counts as dirty.
**Alternatives**: `atomicOr` per moving workgroup in movement/commands
(touches other agents' shaders, every future pass must remember it);
per-tick readback of the bits (needless traffic, still one tick late).
**Consequences**: conservative: a change in a border tile marks the
neighbor chunk's adjacent tiles too, and a sync followed by a tick re-counts
marks that are still at 8; both only cause extra (lossless) parking. In
practice settling sand and water dirty many freshly loaded underground
chunks within seconds (37–50 % of streamed chunks get parked, ~9 KiB each).
New passes get dirty tracking for free as long as they mark tiles.
