// World streaming (src/sim/stream.zig): chunk geometry and the per-slot
// dirty bits. Local to the streaming passes; the CPU mirrors these as
// comptime asserts in src/sim/stream.zig.
#ifndef HEXE_STREAM_GLSL
#define HEXE_STREAM_GLSL

#define STREAM_CHUNK_SIZE 256u
#define STREAM_CHUNKS_PER_SIDE 8u
#define STREAM_TILES_PER_CHUNK 8u

// One word per window chunk slot (slot.y * 8 + slot.x); nonzero = some
// cell of the slot changed since the CPU last cleared it.
HEXE_BUFFER(StreamDirtyBlock, , uint bits[];, g_stream_dirty);

#endif
