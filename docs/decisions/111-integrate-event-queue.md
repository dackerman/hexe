# Integration: one GPU -> CPU event queue

**Context**: reactions (M3) appended to a never-cleared ring at slot 13
(`uvec4(pos, kind, payload, tick)`, drained synchronously by
`Reactions.drainEvents`); particles (M4) appended to a per-tick queue at
slot 16 (`uvec2(pos, kind | payload << 16)`) that the readback mirror
copies every tick.

**Decision**: one queue, the particles one: slot 16, reset at the start of
each tick, copied into the mirror's per-tick history
(`Mirror.eventsAt(t)`, `droppedAt(t)`), so the tick of an event is the
tick whose readback holds it and the entry needs no tick word. The entry
stays 8 bytes but its second word is now `kind (8 bits) | payload << 8
(24 bits)`, so a particle index (owner value, up to 16M) fits. The ABI
lives in `shaders/sim/events.glsl` and its mirror `src/sim/events.zig`
(`Event`, `Kind`, `Ticked`). Kinds: 1 explode and 2 pressure (data
`materials.Event`, payload = material id), 3 eject (payload = radius),
128 particle_cell_changed (payload = owner value). The ring at slot 13 and
`drainEvents` are deleted. verify-determinism waits for each tick, reads
its events through the mirror, and compares the GPU and CPU sets as
(tick, x, y, kind, payload); the CPU reference also emits the eject
event of CMD_EJECT now.

**Alternatives**: keep the ring and let the mirror copy its new part
(needed wrap handling and a tick word); widen entries to uvec4 (64 KiB per
tick of readback instead of 32).

**Consequences**: events older than `readback.event_history` (8) ticks are
gone; gameplay drains every frame. The air field still keeps its own
pressure-event ring (slot 26, `Air.events()`) for its harness: folding it
into this queue (kind 2) is a follow-up, not done here.
