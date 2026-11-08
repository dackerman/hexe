# Sandbox input mapping

**Context**: M1 asks for painting, erasing, material selection, brush size,
pan and integer zoom; the keys were not specified.

**Decision** (`src/app.zig`): left mouse paints the selected material, right
mouse erases (paints air); keys 1-9 select material id 1-9 (ids follow the
table, so data-driven materials get keys automatically); wheel changes the
brush radius (1-200, steps of a quarter radius); WASD or arrows pan, middle
drag pans; `=`/`-` (and keypad +/-) zoom 1x-16x around the cursor; space
pauses, `.` steps one tick while paused; F1 toggles the HUD, F2 the activity
tile overlay, F12 writes `hexe-<tick>.png`; Esc quits. Painting emits fill
circles every radius/2 pixels along the cursor path, applied in the next
tick; strokes made while paused wait for the next tick.

**Alternatives**: scroll to zoom (conflicts with brush size), Noita-style
mappings (the game's controls are a later gameplay decision).

**Consequences**: purely a dev tool mapping; gameplay input (M4) replaces it.
