# Integration: air walls of liquid and bodies; streamed-in chunks

**Context**: the air field treats a 2x2 block as a wall when 2 of its
pixels are static, body-owned or liquid, and conserves mass when walls
change: a new wall pushes its air into its neighbors, a new fluid cell
takes its air from them. Once reactions and the liquid solver kept liquids
moving, and bodies moved through the world, these blocks toggled every
tick; each toggle moved a quarter cell of air at once, a gradient the
blast effects read as an explosion: lava and water were thrown about,
glass broke, the floor under falling bodies broke. Streaming a chunk in
looked like 256x256 pixels of wall changes (11K blast particles per tick
in `--world`).

**Decision**:
- SOLID_COARSE holds static count | body count << 3 (`coarse_solid`,
  `coarse_static` in air_api.glsl). A wall with fewer than 2 static
  pixels (liquid or body) is marked `NODE_LIQUID_WALL` and its appearance
  or disappearance moves no air.
- World streaming reports the chunk slots it uploads
  (`Stream.takeUploaded`); the pipeline hands them to the air field
  (`Air.fresh_slots`), whose prep pass resets their lattice cells to
  ambient air at rest with no transfers.
- Air.seam follows the window origin (world mode).

**Alternatives**: spreading the transferred mass over several steps;
removing liquids from the wall definition (air would flow through water).

**Consequences**: liquid flooding a sealed room no longer compresses its
air, and a body moving into a sealed room neither. The sealed-room harness
gets its pressure from emulated and real steam, not from water.

**Superseded** for liquid walls, static walls and gas sources by
docs/decisions/107-air-soft-wall-compression.md: their mass goes through a
rate-limited pending store, so flooding compresses sealed rooms again
without fake blasts; walls with body pixels still move no air.
