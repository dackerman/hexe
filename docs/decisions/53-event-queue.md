# Event queue ABI

**Context**: interaction class "event emitter" (02-interaction-classes.md):
GPU rules append events, the CPU reacts next tick. Gunpowder ignition
(reactions branch) and pressure triggers (air branch) need a stable buffer
to append to before the readback side exists in their branch.

**Decision** (`shaders/sim/events.glsl`, `src/sim/readback.zig`):

- Buffer at the fixed slot `SLOT_BUF_EVENTS` (16), std430:
  `uint count; uint dropped; uint pad[2]; uvec2 entries[4096];`
  - `entries[i].x = x | y << 16` (wrapped cell position),
  - `entries[i].y = kind | payload << 16`.
- Append from any sim shader: `#include "sim/events.glsl"` after
  `common.glsl`, then `emit_event(ivec2 p, uint kind, uint payload)`.
  Returns false and counts `dropped` past 4096 events in a tick.
- Kinds: 0 none, 1 `EVENT_EXPLODE`, 2 `EVENT_PRESSURE` (the ids of the data
  layer's `materials.Event`, decision 06), 3 `EVENT_EJECT` (CMD_EJECT ran,
  payload = radius; the M4 test event). New kinds are defines in
  events.glsl plus a value in `readback.EventKind` (a test checks the
  mirror).
- Reset (count, dropped = 0) at the start of every tick, before command
  application; copied to the frame slot at the end of the tick; on the CPU
  `Mirror.events()` / `eventsAt(t)` (decision 52), as
  `readback.Event{ x: u16, y: u16, kind: EventKind, payload: u16 }`.
- **Wiring gunpowder** (for the integrator): the reactions pass calls
  `emit_event(p, EVENT_EXPLODE, material_or_strength)` when a cell with
  `burn_event = explode` ignites (once per cell: the reaction table's
  `emits_event` flag already picks one side of a pair). Gameplay, each
  frame: for every tick t since the last one handled, for each event of
  `mirror.eventsAt(t)` with kind `.explode`, push
  `list.eject(e.x, e.y, radius, speed)` (M4) or the air field's explosion
  command (M5).

**Alternatives**: per-kind queues (more slots, more copies); a ring that
persists across ticks (the CPU would need to acknowledge); events in the
particle control buffer (couples unrelated systems).

**Consequences**: one 32 KiB copy per tick. A tick with more than 4096
events loses the excess (counted); explosions chain over ticks anyway.
