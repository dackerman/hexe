# Integration: one debug overlay image, final slot map

**Context**: the renderer (M8) defined an RGBA8 1024^2 debug overlay at
image slot 2 with mode ids written by sim passes under `Frame.overlay`;
the air field (M5) owned its own RGBA8 overlay at slot 12; the liquid
solver (M6) had a 2048^2 RGBA8 overlay at slot 15; particles (M4) draw
ballistic particles into an r32ui image at slot 13 read by world.frag.

**Decision**:
- Slot 2, owned by the renderer, is the only debug overlay image.
  `air/overlay.comp` writes it only while `Frame.overlay` is air_pressure
  (2) or air_velocity (3); the liquid solver clears and writes it (one
  texel per 2x2 pixels, additive colors) while it is liquid_particles (4).
  Air's image at 12 and the liquid's at 15 are gone; `--overlay air` and
  `--liquid-overlay` map to modes 2 and 4.
- The ballistic particle overlay (13) is copied into the render snapshot
  with the cells (`snap_particles`, `RenderFrame.particles_slot`) so
  overlapped renders see the particles of the snapshot's tick; world.frag
  draws a particle over the cell under it.
- Image slots: 0 cells, 1 owner, 2 debug overlay, 8 solid coarse (static
  count | body count << 3 since decision 117), 9 liquid coarse, 10 air, 11
  air source, 13 particle overlay, 14 liquid wake; 3-7, 12, 15 free.
  Buffer slots: 0 materials, 1 tile marks, 2 tile list, 3 commands, 4
  eject queue, 12 reactions, 16 events, 17-24 particles, 25 blast ejects,
  26 air events, 27-28 air tiles. The map is also at the top of the slot
  section of common.glsl.

**Alternatives**: keep air's slot 12 and move the renderer's (the renderer
owns the image and composites it, so its slot was kept); a world-sized
liquid overlay (4x the memory for a debug view).

**Consequences**: sim overlays cost nothing unless their mode is shown.
The liquid overlay is half resolution.
