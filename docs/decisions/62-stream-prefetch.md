# Background chunk generation with camera-driven prefetch
**Context**: CPU procgen costs 3–7 ms per chunk; `Streaming` ran it on the
main thread one chunk per tick, a 7 ms hitch every tick of a move.
**Decision**: `src/world/prefetch.zig`: N = CPU count − 1 worker threads
(capped at 15, each owns a `Generator` with ~5 MiB scratch) and 64 chunk
buffers. The main thread only `request`s (priority + LRU stamp), checks
`isReady`, `acquire`s a finished buffer (uploaded straight from it, no copy)
and `release`s it. `Streaming` stays single-threaded: with a prefetcher
attached it never generates in `tick`; a move whose next chunk is not ready
waits (counted as a stall). Each tick it requests, in priority order, the
current move's remaining loads, the ring of chunks just outside the
(post-move) window on the side(s) the smoothed camera velocity points to,
then the rest of the ring. Parked chunks are decompressed on the main thread
(cheap). `loadAll` queues all 64 and waits: 9–25 ms at startup with 15
workers. Full buffers evict the stalest queued/finished entry of equal or
worse priority, never one being generated or acquired.
**Alternatives**: `std.Thread.Pool` with a job per chunk (no priorities or
cancellation of stale requests); generating on the GPU (docs/01; later).
**Consequences**: camera at 600 px/s (10 cells/tick): 0 stalls; main-thread
streaming mean 0.047–0.066 ms/tick, p99 1.2–1.6 ms, max usually 2–3 ms
with rare 7–10 ms outliers (all on eviction ticks: device wait + download +
compress, see 60). Worker memory ~75 MiB.
