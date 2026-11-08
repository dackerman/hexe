# Sim/render overlap: snapshots, two timelines

**Context**: decisions/23 left the queues strictly serial (render N waits
for sim N, sim N+1 waits for render N) because rendering reads the cell
image the sim writes. The architecture wants steps 3-7 (compute queue) to
overlap the render of the previous tick (graphics queue).

**Decision** (src/engine.zig):
- Two timeline semaphores, one per queue, so the queues signal
  independently (one shared timeline must be signalled in increasing
  order, which concurrent queues cannot guarantee).
- A ring of two snapshots (cells, tile marks; owner image and debug
  overlay image only when the overlay mode reads them). The last thing a
  frame's sim command buffer does is copy the live images into the ring
  entry the newest render is not reading (0.02-0.05 ms, timed as
  `snapshot`). The render waits for the sim value that wrote its snapshot;
  the next sim waits only for the render that last read the entry it is
  about to overwrite. Render N therefore runs while sim N+1 runs.
- Frames that render without ticking (paused) reuse the newest snapshot;
  a render before any snapshot reads the live images, and the next sim
  waits for it. Frames ticked without a view invalidate the ring.
- `Options.overlap = false` / `--no-overlap` reproduces the serial chain
  for A/B measurements.

**Alternatives**: rendering from the previous tick's image (the sim
writes in place, there is no previous image); copying only the view
rectangle (the view is known, but the copy is already cheap and whole
copies keep the light margin and overlays simple).

**Consequences** (RTX 4090, ReleaseFast): `--bench-render` GPU-bound case
(4 ticks of the fully active mixing scene per frame plus a zoom-1
1920x1080 render): 1.36-1.38 ms/frame serial, 1.12-1.17 ms/frame
overlapped (-16%); each side slows when sharing the GPU (sim 0.45 to
0.83 ms, render 0.83 to 1.10 ms), so the gain is the filled idle gaps, not
the sum. In the windowed app at 1920x1080, zoom 1, no vsync the frame time
is unchanged (lighting scene 1.63 vs 1.67 ms, mixing scene 0.79 vs
0.80 ms) because at ~600 fps only one frame in ten runs a 60 Hz tick; the
gain appears once the sim is several ms per tick. Snapshots cost 32 MB per
ring entry for cells and owner.
