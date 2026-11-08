# Blast units and the standard explosion

**Context**: the material tables carry `blast_threshold` numbers (sand 20,
water 10, wood 80, stone 200) without a unit; scenario 4 in
corridor_blast.zon expects the open blast to clear the plug at 40 px but
not 80, the corridor to clear 80 but not 160.

**Decision**:
- Gradient load units: Δdensity per lattice cell × `blast_scale` = **700**
  (sand flies at 0.029 per cell). Wall load units: × `wall_scale` = **1000**
  (1-health wood fails at 0.24 overpressure across a 2-cell wall, stone at
  0.6). Separate because they are different quantities (body force on loose
  material vs. pressure difference across a solid).
- Standard explosion: 1.5 density, 0.15 momentum per open-disc cell, 4
  steps; radius as given.
- Chosen with slip 0.97 by sweeping slip {0.7…1.0} × blast_scale {500,
  700, 1000} × density {1.0, 1.5}: at 700/0.97 the measured reach is open
  56 px, corridor 152 px, which matches every plug assertion in
  corridor_blast.zon. At 1000 the open blast reached 80.

**Alternatives**: rescaling the material table (another branch owns it).

**Consequences**: thresholds keep their meaning across materials; a
global retune is one parameter. Damage per excess unit (0.25 health) and
eject speeds are separate knobs.
