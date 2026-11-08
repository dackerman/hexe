# Air field boundaries: open edge at the seam, slip walls, liquid walls, conservation

**Context**: The window is a torus for the grid, but the far side of the
torus is a different part of the world; walls come from 2x2-coarsened
pixels; a 3 px corridor is a single lattice cell wide.

**Decision**:
- **Open edge, not wrapped.** The lattice is stored in torus coordinates
  but its edge is the window seam (`Air.seam`, lattice coordinates; 0 until
  streaming sets it to window origin / 2 and resets newly loaded chunks).
  A population pulled from across the seam is ambient air at rest, and a
  24-cell sponge band relaxes toward ambient density (strength 0.25 at the
  edge, quadratic falloff): the edges vent pressure instead of reflecting
  it, and an explosion near one edge never appears at the other.
- **Walls**: a lattice cell is a wall when solid + liquid pixels ≥ 2 of 4
  (liquids are walls for the air in v1). Axis links bounce back. A diagonal
  link from a wall reflects specularly when the wall is flat there (one of
  the two axis neighbors is wall), else bounces back; the result is
  `mix(bounce_back, specular, slip)` with **slip = 0.97**. Specular partners
  swap orphaned populations pairwise, so mass is conserved exactly for any
  slip (sealed rooms keep their mass). Measured with blast_scale 1000:
  pure bounce-back (no slip) killed a pulse in a one-cell corridor within a
  few cells (corridor reach 32 px vs 72 px in the open); slip 1.0 carried it
  across the whole 400 px test corridor; slip 0.9 reached only 0.9x the
  open: in a one-cell channel the loss compounds every step. With the final
  blast_scale 700, slip 0.97 gives 152 px vs 56 px open (`zig build
  air-test`), exactly the scenario file's plug pattern.
- **Walls appearing and disappearing** (prep pass): a cell that becomes a
  wall hands its air to its fluid 4-neighbors through `AIR_SOURCE`
  (flooding compresses air, bodies push it); a cell that becomes fluid
  starts at its fluid neighbors' mean density and takes that mass from them.
  Exception: a wall cell the blast emptied (node bit `NODE_BLASTED`) starts
  at the mean without taking it, otherwise each blown-out layer left a
  vacuum that threw the next layer, and a pool surface unravelled.
- First tick after init/reset: nodes only, no transfers.

**Alternatives**: wrapping the lattice like the grid (pressure from one
side of the world appears at the other); characteristic/non-reflecting
boundary conditions (more code for little visible gain over a sponge);
"> 2 of 4" as the wall rule to widen narrow corridors (the spec says ½).

**Consequences**: corridors carry blasts ~2.7x as far as open floors.
Wall roughness and slip are now a tuning knob (`Params.slip`). Moving
walls (body velocity) are not in the bounce-back yet.
