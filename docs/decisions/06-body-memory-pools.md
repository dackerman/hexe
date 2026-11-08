# Body memory pools

**Context**: the contract forbids heap allocation in the per-tick loop, but
bodies are created and split during ticks (destruction, connectivity
islands, rubble).

**Decision**: `BodyWorld.init` allocates everything from `Config`: body slots
with generation-checked handles and a free list; one pixel buffer
(`max_body_pixels`, 4 MiB by default) handed out by a first-fit span
allocator whose sorted free list coalesces neighbors (never more than
live allocations + 1 entries); beam slots with fixed segment and joint
arrays (`max_beams × max_beam_segments`); static tile slots sized from
`static_max_w/h`; and scratch for rectangle decomposition, connectivity
labels, split output, impact and break events. Creation fails with
`error.OutOf*` instead of growing. Box2D allocates internally for its own
bodies, shapes, contacts and joints.

**Alternatives**: a general-purpose allocator per body (simple, but
allocates in the tick); fixed-size bitmap slots (wastes memory, caps body
size harshly).

**Consequences**: memory is bounded and visible in `Config`. Fragmentation
can make a large bitmap fail while total free space suffices; reopen with
compaction if that shows up in play.
