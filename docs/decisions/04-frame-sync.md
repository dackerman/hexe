# Queues, frames in flight and the timeline semaphore

**Context**: M0 asked for a graphics+present queue, a separate compute queue
when available, two frames in flight and timeline semaphores.

**Decision** (`src/engine.zig`):
- The simulation records into a compute-queue command buffer (async compute
  family 2 on the 4090), rendering into a graphics-queue command buffer.
- One timeline semaphore orders all GPU work. Each frame: the sim submission
  waits for the previous value and signals +1; the render submission waits
  for the sim value (fragment stage) and the swapchain acquire, and signals +1
  plus a per-swapchain-image binary semaphore for present.
- Two frame slots. A slot owns its command pools, timestamp query pool,
  acquire semaphore, HUD text buffer, per-tick stats buffer and its regions of
  the command upload ring. The CPU waits for the slot's last timeline value
  before reusing it, then collects its timestamps (one frame of latency).
- Fixed 60 Hz ticks: the windowed loop accumulates wall time and records 0-4
  ticks into the frame's single sim command buffer. Headless records exactly
  one tick per frame.

**Alternatives**: everything on one queue (simpler, but the architecture
wants async compute for steps 3-7); fences per frame (timeline values are
simpler to reason about across two queues).

**Consequences**: today the chain is strictly serial (render N waits sim N,
sim N+1 waits render N) because render reads the cell image that sim writes.
Overlapping sim N+1 with render N (architecture "Frame pipeline") needs a
copy of the rendered state or a render-only snapshot; that belongs to the
rendering milestone. CPU recording does overlap the GPU by one frame.
