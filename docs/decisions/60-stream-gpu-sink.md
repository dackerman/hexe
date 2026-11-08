# GPU upload sink: staging ring, uploads recorded in the next tick, synchronous batched downloads
**Context**: `Streaming` (docs/decisions/13) calls `uploadChunk`,
`downloadChunk` and `takeDirty` synchronously from the CPU tick. The cell
image is in use by up to two frames in flight; uploads must not race them
and must not stall the main thread.
**Decision**: `src/sim/stream.zig` (`Pipeline.stream`, inert until
`enable`). `uploadChunk` memcpys the 256 KiB chunk into one of 16 entries of
a host-visible staging ring and queues it; the next recorded tick's first
pass (before commands, so a command aimed at the new chunk lands on it)
copies it with `vkCmdCopyBufferToImage`, then `upload.comp` clears the
owner region, clears the slot's dirty bit and wakes the slot's 8×8 tiles
(and raises the surrounding ring of tiles) to `TILE_WAKE_TICKS − 1`. Each
entry remembers the timeline value of the submission that consumed it; reuse
waits on the engine's timeline semaphore (in practice already signaled). If
16 uploads queue without a tick (startup's 64), they are flushed with
`runOnce`. `takeDirty` / `downloadChunk` sync once per "snapshot" (until the
next tick or upload): `deviceWaitIdle`, one `runOnce` that applies pending
uploads, runs the dirty pass, copies the 64 dirty words to the host and
clears them; the first download then copies every dirty slot in the same
row and column as the requested one into a 16 MiB host buffer, so an evicted
column (with `Streaming.Config.batch_evict`, which evicts the whole outgoing
row/column in the first tick of a move) or a flush costs one wait and one
copy.
**Alternatives**: asynchronous downloads read back two frames later (needs
an async eviction API in `Streaming` and a guard for chunks re-entering
before their download lands); per-slot synchronous downloads (8 waits per
move); uploads in a separate submission.
**Consequences**: measured 0.4–0.7 ms per sync (14–23 per 600-tick run), so
eviction ticks cost 1–3 ms of main thread. Downloads do not yet freeze
liquid particles or resolve body-owned cells (owners of those layers must
hook in before eviction). Paused (no ticks recorded) means queued uploads
wait until unpause.
