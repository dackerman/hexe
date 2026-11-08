# Streaming policy and the UploadSink interface
**Context**: The window must follow the camera, one row or column of chunks
per move, without per-tick allocation, and the GPU side is not written yet.
**Decision**: The window origin is the top-left resident chunk; window
coordinates are world mod 2048 so chunk (cx, cy) always lives in slot
(cx mod 8, cy mod 8). The window recenters on an axis when the camera is more
than 128 + 32 (hysteresis) cells from its center, one single-chunk step at a
time, x before y. A step processes `ops_per_tick` slots per tick (default 1):
evict (download + park if dirty), fetch (decompress or generate), upload.
Slots already swapped mid-move are tracked per slot, so `isResident` and
`worldOfWindow` are exact during a move. The GPU implements `UploadSink`
(`uploadChunk`, `downloadChunk`, `takeDirty`); dirty is per slot, set by the
sim when any cell changes, cleared by upload and by `takeDirty`; the CPU can
also `markDirty`. `teleport` and `loadAll` are blocking full reloads.
**Alternatives**: loading a whole column per tick (≈50 ms hitch with CPU
procgen); a worker thread for generation (later, if needed); a GPU-side
dirty bitmap read back per tick instead of a call per slot (an implementation
choice behind `takeDirty`).
**Consequences**: The camera keeps at least 768 cells of loaded world ahead
of it; a column takes 8 ticks, so streaming keeps up at any plausible camera
speed. `downloadChunk` is synchronous from the CPU's view; the GPU side may
need a staging copy and a fence wait for the evicted slot only.
