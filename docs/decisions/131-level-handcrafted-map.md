# Proving Grounds: handcrafted map, built in one tick

**Context**: docs/07 suggests loading the map into the streamed window with
procedural caves around it. The brief allows a handcrafted 2048 x 1536 map
with stone borders and sky instead.

**Decision**:
- Handcrafted map in the scene window (no world streaming): open sky above
  y 400 so sunlight enters, bedrock below y 1536 and a bedrock wall at the
  torus seam; dirt, gravel and bedrock pockets in the stone for texture
  (full-coverage blobs only: speckled powder leaves stone crumbs that
  connectivity turns into bodies).
- Everything is emitted at tick 0 (about 600 commands of the 1024 budget).
  The air field reads the first tick's walls without mass-conservation
  transfers; walls built on later ticks push their air out as blasts that
  broke huts and threw the ruin over in the first attempt.
- The bodies layer reads each air fill as a destruction event; the build's
  carves span the map, and an event is kept while any queued cluster
  overlaps it, so they stayed queued forever, ran connectivity 2x per tick
  and starved real events (a blown pillar never came loose).
  `level.script` drops the queued events at tick 1 (`sim.event_len = 0`):
  building is not destruction. The layout was checked to have no loose
  piece (0 loose components after the build).

**Alternatives**: procedural fill via world_mode (more moving parts: the
stream would have to carry the level's commands); carving with non-air
fills (no way to make air without an air fill).

**Consequences**: a scene that carves big regions after tick 0 would hit the
same connectivity starvation; worth a fix in bodies_sim (expire events whose
cluster was processed once). Reopen if the level moves into the streamed
world.

**Update** (docs/decisions/143-polish-connectivity-backlog.md): fixed in
bodies_sim: an event drops once its own clamped cluster has run, stale
events expire after 60 ticks, and a window-wide erase is no event. Without
the tick-1 drop the build now costs 21 connectivity runs and leaves 0 loose
bodies (2 crumbs under 4 px become gravel); the drop is kept for those.
