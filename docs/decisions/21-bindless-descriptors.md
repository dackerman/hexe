# One bindless descriptor set and one pipeline layout for everything

**Context**: M0 needed a descriptor strategy that later subsystems (reactions,
particles, air, liquid, bodies, rendering) can extend without touching each
other's code.

**Decision**: `src/gpu/descriptors.zig` creates a single descriptor set with
four `PARTIALLY_BOUND | UPDATE_AFTER_BIND` array bindings: 0 storage images
(64), 1 storage buffers (256), 2 sampled images (64), 3 immutable samplers
(nearest/linear x clamp/repeat). Every pipeline uses `ctx.pipeline_layout`:
set 0 plus one 128-byte push-constant range visible to all stages. The set is
bound once per command buffer by the engine.

Slots: world resources shared by many passes have fixed slots declared in
`shaders/common.glsl` (`SLOT_IMG_CELLS`, `SLOT_IMG_OWNER`, `SLOT_BUF_MATERIALS`,
`SLOT_BUF_TILE_MARKS`, `SLOT_BUF_TILE_LIST`, `SLOT_BUF_COMMANDS`) and mirrored
in `src/gpu/constants.zig`. Images below 16 and buffers below 32 are reserved
for such shared resources; a new shared world resource takes the next free
fixed slot (add the define, the mirror, and the `Shared` field). Subsystem
private resources call `Buffer.initSlotted` / `ctx.descriptors.allocImageSlot`
at init and pass the slot number in push constants. Slots are never freed.

Shaders declare typed views of binding 1 with
`HEXE_BUFFER(Block, qualifiers, members, instance)`; several declarations may
alias the binding. Storage images of other formats are declared by the shader
that needs them on binding 0 with its own format qualifier
(`layout(set=0, binding=BINDING_STORAGE_IMAGES, rgba16f) uniform image2D x[]`).

**Alternatives**: per-pass descriptor sets (pool and layout management in
every subsystem), push descriptors (an extension, per-dispatch writes),
buffer device addresses (no help for images).

**Consequences**: adding a pass needs no descriptor code. Capacities are
fixed (raise the constants if a solver needs more). A slot's descriptor can
be rewritten between submissions (update-after-bind), but not while a
command buffer that uses that slot is pending.
