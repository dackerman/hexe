# Sandbox keys for particles and the interim explosion

**Context**: M4 asks for a way for a human to spray particles and blow
things up in the windowed sandbox; decision 26 fixed the other keys.

**Decision** (`src/app.zig`): hold Q to spray sand particles from the
cursor, hold E to spray water particles (48 a frame, 260 +- 90 px/s, a
narrow upward cone); press X for an eject (the interim explosion) at the
cursor with the brush radius (at least 4) and 1000 px/s at the center. The
HUD gains a line with live particles, capacity and this tick's spawned,
landed, refused, lost and impacts; the "particles" and "readback" passes
appear in the per-pass GPU ms line. The loop polls the readback mirror at
the top of every iteration.

**Alternatives**: mouse buttons with modifiers (left and right are paint
and erase); a material-following spray (the selected material may be
static, which makes a confusing spray).

**Consequences**: dev tool mapping only; gameplay input replaces it.
