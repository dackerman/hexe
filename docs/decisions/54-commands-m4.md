# M4 command kinds: line, spray, temperature, ignite, eject, charge hook

**Context**: M4's command list asks for fill, line, spray, ignite, set
temperature and an explode heuristic until the air field (M5). Decision 31
fixed the 8-word encoding, one dispatch per command, and that every kind
editing cells is mirrored in the CPU reference.

**Decision** (`src/sim/commands.zig`, `shaders/sim/grid/commands.comp`,
`src/sim/reference/grid.zig`), all in the existing 8 words:

| kind | id | encoding | effect |
|---|---|---|---|
| `fill_line` | 3 | (x0,y0)-(x1,y1), radius in `flags >> 16`, only-air and coverage as fills | capsule test, exact integer (cross product squared in 64 bits) |
| `spray` | 4 | origin (x0,y0), count x1 (<= 65535), speed `y1 & 0xffff`, spread `y1 >> 16` px/s, direction `flags & 0xfff`, cone half-angle `(flags >> 12) & 0xfff` (1/4096 turns, 0 = +x, 1024 = down) | particles via `shaders/sim/particles/spray.comp`; no cell changes |
| `set_temperature` | 5 | circle (x0,y0,r=x1), degrees C in y1 | every cell's temperature byte |
| `ignite` | 6 | circle | `CELL_FLAG_BURNING` on cells whose material is flammable |
| `eject` | 7 | circle, center speed y1 px/s | the interim explosion, below |
| `inject_charge` | 8 | circle, charge y1 | reserved hook: no effect |

**Eject** (until the air field replaces it): speed falls off quadratically,
`speed = y1 * (r^2 - d^2) / r^2` in integers. Loose cells (powder, liquid,
gas) at >= 40 px/s fly as ballistic particles (`eject_observed`), radially
with +-26 degrees of spread, 45-120% of the speed and an upward bias of
15-40%; solids with health lose `speed >> 2` and at zero fly as their
rubble (or become air without one); health-less solids (bedrock-like),
body-owned and particle-backed cells are untouched. It emits `EVENT_EJECT`
at the center. A blast should cover what it throws: debris from inside a
radius-80 eject in a radius-90 hill hit the unmoved shell and refilled the
crater, so scenes size the radius to the target.

**Reference**: fill_line, set_temperature and ignite are mirrored exactly.
For eject the reference mirrors the cell edit (which cells empty, which
solids lose how much health) assuming the particle budget is not exhausted;
on the GPU a refused particle leaves the loose cell in place, or rubble in
place for a destroyed solid. `verify-determinism` runs a second scene,
`determinism_commands`, 8 ticks with every new kind and compares right
after the eject tick (the particles it queued have not moved yet): 0 cells
differ, sleep on and off.

**Ignite** sets the flag only. The reactions branch owns burning (and
decision 05's health-less fuel: oil and gunpowder get their state from
`burn_fuel` on ignition); when it lands, ignite should also set that state,
or the reactions pass should treat "burning with state 0" as "just lit".

**Inject charge**: the state byte meaning of charge is the reactions
branch's (field propagation); no encoding was visible when this was
written. The kind, CPU helper and bounds exist so gameplay can emit it;
`commands.comp` and the reference ignore it (`bounds` returns null). Wire
it by giving it a bounds case, a branch in `commands.comp` and the same in
the reference.

**Alternatives**: a separate pass per new kind (more pipelines, same
dispatch count); float capsule tests (CPU and GPU would differ at the
edge); eject as a fill of air plus a CPU-side particle spawn (no access to
the cells' materials on the CPU).

**Consequences**: commands.comp needs `shaderInt64` (enabled when present;
the 4090 has it). Command count per tick is unchanged (1024); a spray of
65 535 particles is one command.
