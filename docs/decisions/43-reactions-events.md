# GPU event queue: a ring at SLOT_BUF_EVENTS

**Context**: material rules must reach gameplay (gunpowder `explode`,
`pressure` events, reactions with `.event`), and M6 needs to hear when a
reaction consumes a particle-backed cell. M4 owns the per-frame readback
mirror, which does not exist yet.

**Decision** (common.glsl `emit_event`, src/sim/reactions.zig):
- Buffer at fixed slot SLOT_BUF_EVENTS (13), host-visible device-local:
  header `count, capacity, dropped, pad`, then EVENT_CAPACITY (4096)
  `uvec4(x | y << 16, kind, payload, tick)`. `count` only grows; event i
  is at `events[i % 4096]`. Nothing ever clears it, so no pass has to run
  at frame start; a reader keeps the last count it saw and treats more
  than 4096 new events as overwritten.
- Kinds below 128 are data's `materials.Event` (1 explode, 2 pressure);
  the engine's start at 128: EVENT_PARTICLE_CELL_CHANGED (128) is appended
  when a reaction changes the material of a particle-backed cell, payload =
  owner image value (the particle index), for the liquid solver to delete
  the particle. Material events carry the material id as payload.
- Appenders: reaction entries with an event (the side flagged
  emits-event), ignition of a material with `burn_event`.
- `Reactions.drainEvents(out)` copies the events since the last drain
  (synchronous, GPU idle: tests and tools). verify-determinism compares
  the sorted GPU and CPU event sets.

**Alternatives**: a per-tick cleared list (needs a clear per tick and a
copy before the next clear); waiting for the M4 readback buffer (blocks
gunpowder now).

**Consequences**: the readback agent (M4) should copy the header and the
new part of the ring into its per-frame host mirror and drain from there,
and may replace `drainEvents`. Order within a tick is not deterministic;
sort before comparing.
