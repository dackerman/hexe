# Proving Grounds: scripted showcase, corridor and ruin tuning, bench

**Context**: `--demo-script` must trigger each event without a player and
photograph it; `--bench-demo` fires everything inside 5 s and times it.

**Decision**:
- Schedules (`level.auto_schedule`, `burst_schedule`): dam + pipe valve +
  U-tube plug, steam plug, corridor charge, field charge (60 ticks later,
  so the explosion drain's 64-per-tick cap cannot favour either), village
  ignition, glass gate (+ silo 50 ticks later), ruin pillar, five beam cuts.
  The events are commands in the scene (pure functions of tick); body
  actions in `level.script`.
- Pressure corridor and open field are carved in bedrock: a confined charge
  in stone cracked the rock around it, and stone breaking next to a fresh
  crater kept breaking for hundreds of ticks (a crater 500 px wide ate the
  walkway and S2). Reported as an engine behaviour; bedrock avoids it.
- The charge at each mouth is the standard blast (`explosion(r 6,
  strength 1)`, the player's blast charge) on a pile of gunpowder heated
  past ignition (ignite commands set the burning flag without the ignition
  event, so they never explode). Gunpowder events alone barely reached the
  corridor's plugs (the 3 px corridor is one lattice cell tall); the field
  pile alone blew several. Plugs are 2 x 3 sand every 32 px (the brief's
  64 px spacing left 1-2 plugs to compare). Measured, 50 ticks after each
  charge: corridor plugs gone to 190 px, field to 70-100 px; 140 ticks
  after: 290-320 px vs 100-130 px.
- Ruin: a 240 px gap (the bodies_beam span) with a 4 px steel beam welded in
  both blocks' concrete, a 50 px concrete crate at mid-span, a second beam
  60 px below. The torch takes 1/4, 2/4, 3/4 of the thickness at mid-span
  (sags 0 -> visibly V-shaped), then cuts through next to each weld; the
  crate falls onto the lower beam. The watchtower slab stands on one 16 px
  pillar 188 px tall; the charge blows 160 px of it out and the slab falls
  and breaks into pieces. The tower must lie inside the 256 px connectivity
  region of the charge (anything reaching its border counts as anchored), so
  nothing stands on the slab.
- Shots: zoom 2 at 1920 x 1080 (zoom 3-4 for the steam room and village);
  pressure-overlay shots switch the overlay on for the tick before the
  shot (the passes write the overlay while they run).

**Consequences**: `--bench-demo` (ReleaseFast, RTX 4090): 2.6 ms wall per
tick over the burst window with a 1920 x 1080 render every tick, worst
frame 4.6 ms, GPU 2.3 ms/tick (sum of pass means), dominated by
`lq_project` (0.92 ms mean, 2.2 ms max), then the render (0.33 ms) and
cascades (0.19 ms); bodies CPU 0.28 ms mean (1.3 max) plus a 1.7 ms mean
synchronous terrain readback.

**Update** (polish, decisions 141 and 144): ignite commands now send
gunpowder's explode event, so the corridor charge would explode without
being heated (kept as is); a confined charge in stone now stops breaking
rock once the pulse has passed (128 cells in the air-test's corridor
instead of the whole block), so the corridor and field could be carved in
stone again (left in bedrock).
