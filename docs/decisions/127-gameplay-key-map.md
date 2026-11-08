# Gameplay: the key map and tool details

**Context**: docs/07 gives the tool table and controls; the sandbox keys
(decision 114) clash with them (1-0 palette, WASD pan, space pause, R
water spray, P pour, F3 air overlay).

**Decision**:
- The windowed app starts the playable mode; the sandbox keeps decision
  114's map behind `--sandbox` (and `--world`).
- Play keys: A/D (arrows) move, Space/W/Up jump and swim up, S/Down drop
  through and dive, mouse aims in world space, LMB/RMB primary/secondary,
  wheel brush size (painter: material), 1-9/0 tools, P pause, period
  single step, R reset, F1 help, F3 timings, Tab/Shift+Tab overlays,
  =/- zoom, Escape quit. Kept from the sandbox: E explosion, X eject,
  C/Z/V crates and slab, L liquid solver, F2 tiles, F4 light mode, F6
  quality, F7 bloom, F8 vignette, F12 screenshot. Dropped in play: Q/R
  sprays (tools 3-5), P pour (tool 3 secondary), B beam (tool 8
  secondary), T torch (the wand is a light), F3 air overlay (Tab).
- Tools: click tools fire on press with a cooldown (fire bolt 15 ticks,
  charge 30, lightning 20, blobs/box 20); hold tools repeat (sprays every
  tick, dig every 2, dirt every 3, gunpowder every 3, painter every tick).
  Sprays leave the wand toward the cursor (10 particles per tick, 300
  px/s, cone 0.03 turn). The water jet also douses where its line meets a
  surface (water cells into the air, flame and smoke there, every 3 ticks)
  and extinguishes burning characters on its line: thrown particles only
  douse where they land, which left fires burning. The cutter is a drag
  (press, release: a 1 px line of air, at most 240 px, with destruction
  events along it so beams and bodies are cut and connectivity runs);
  its secondary places a steel beam between two clicks. The water column
  is 12 x 40 px; lava/acid blobs r8; the box is an 18 px wooden crate body.
  Lightning: the arc stops at the first character or solid/liquid cell
  within 320 px; a character it hits is shocked directly; the hit point
  pulses charge for 10 ticks and is ignited; the secondary lays a line of
  charge along the arc every 4 ticks.

**Alternatives**: keep the sandbox as the default and gate play behind a
flag (docs/07 wants the demo playable from `zig build run`).

**Consequences**: docs/07's controls table is the final map. Decisions 26
and 114 still describe the sandbox.
