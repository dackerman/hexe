# Impact breakup: thresholds, cracks, rubble

**Context**: bodies must break on hard landings by material threshold
(concrete low, wood medium, steel very high), small bodies dissolving into
rubble cells the grid takes over.

**Decision** (`BodySim.considerBreak`, `breakBody`, `dissolve`):
- Threshold on Δv = `Impact.normal_impulse` / body mass (px/s; for a
  terrain impact this is the approach speed): concrete 300, stone 300,
  glass 120, wood 600, steel 4000 (`bodies_materials.zig`), times a shape
  factor `clamp(2 * short / long, 0.35, 1)` from the bitmap: a 40x40 crate
  keeps the full threshold, a 200x16 slab breaks at 105 px/s (a 28 px drop).
  Severity = Δv / threshold. One break per body per tick; beam segments are
  excluded (their joints yield and fracture instead).
- Bodies under 150 px or severity over 4 **dissolve**: every pixel is written
  back at its current world position as the material's rubble (`concrete ->
  rubble`, `stone -> gravel`, `glass -> sand`; powder, so the grid takes
  over) into air or gas cells; materials without rubble go to the eject queue.
- Otherwise: a crush disc of radius `clamp(2 + 3s, 3, 14)` px at the impact;
  `clamp(floor(long / short * s / 2), 1, 10)` transverse cracks spread along
  the long axis with jitter (how a slab landing flat fails) plus two radial
  cracks from the impact, each a 2 px wide random walk; removed pixels become
  rubble; `splitBody` on the rest; pieces under 60 px dissolve; survivors get
  a kick away from the impact (35 px/s per unit severity, mostly upward) and
  a random spin.
- Freezing resting bodies back into static cells (optional in the brief) is
  not done: sleeping bodies already cost nothing on the GPU, and connectivity
  would turn them back into bodies on the next nearby destruction.

**Alternatives**: thresholding Box2D's solver impulse (spread over several
steps by soft contacts, see decision 18); Voronoi fracture (more code, needs
a seed layout per material); breaking only into rubble (no chunks).

**Consequences**: `bodies_slab`: the 200x16 slab falls 100 px and lands at
198 px/s, severity 1.9: 9 pieces, 329 gravel cells. The 40x40 concrete crate
dropped 180 px (266 px/s) survives. Values are tuning, ready to move into the
material ZON files.
