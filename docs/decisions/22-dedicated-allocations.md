# Memory: one dedicated allocation per resource, CONCURRENT sharing

**Context**: M0 needed a device memory allocator.

**Decision**: `src/gpu/memory.zig` gives every `Buffer` and `Image` its own
`vkAllocateMemory` (with `VkMemoryDedicatedAllocateInfo`). Three locations:
`gpu_only` (device local), `cpu_to_gpu` (host visible + coherent, prefers
device-local BAR memory, persistently mapped) and `gpu_to_cpu` (host visible +
coherent, prefers cached, mapped). Resources are created with
`VK_SHARING_MODE_CONCURRENT` across the graphics and compute families, so
work can move between the two queues without ownership transfers.

**Alternatives**: a suballocator or VMA. The engine has a few dozen
long-lived resources; the driver limit is 4096 allocations.

**Consequences**: resources must be created at init, not per tick. If a
subsystem ever needs thousands of small buffers (per-body data, say), add a
suballocator here rather than per subsystem. CONCURRENT sharing is free on
NVIDIA; revisit on hardware where it costs compression.
