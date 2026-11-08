// Event queue (GPU -> CPU), docs/decisions/53-event-queue.md. Include after
// common.glsl. Any sim shader may append; the queue is reset at the start of
// every tick and read back one tick late (src/sim/readback.zig `Mirror`).
//
// Buffer at SLOT_BUF_EVENTS, std430:
//   uint count;       events appended this tick (may exceed EVENT_CAPACITY)
//   uint dropped;     appends refused because the queue was full
//   uint pad[2];
//   uvec2 entries[EVENT_CAPACITY];
//     entries[i].x = x | y << 16     cell position, 0..WORLD_SIZE-1 each
//     entries[i].y = kind | payload << 16
// Kinds are shared with the data layer (src/data/materials.zig Event and
// docs/decisions/06-schema-additions.md): 0 none, 1 explode, 2 pressure; 3+
// are engine events. Mirrored in src/sim/readback.zig (test "events.glsl
// mirror").
#ifndef HEXE_EVENTS_GLSL
#define HEXE_EVENTS_GLSL

#define EVENT_CAPACITY 4096u
#define EVENT_HEADER_WORDS 4u
#define EVENT_NONE 0u
#define EVENT_EXPLODE 1u
#define EVENT_PRESSURE 2u
// CMD_EJECT ran: payload = radius (the M4 test event).
#define EVENT_EJECT 3u

HEXE_BUFFER(EventBlock, , uint count; uint dropped; uint pad0; uint pad1; uvec2 entries[];, g_event_buffers);
#define EVENTS g_event_buffers[SLOT_BUF_EVENTS]

// Append one event at cell `p` (wrapped). Returns false when the queue is
// full (the event is counted in `dropped`).
bool emit_event(ivec2 p, uint kind, uint payload) {
    uint i = atomicAdd(EVENTS.count, 1u);
    if (i >= EVENT_CAPACITY) {
        atomicAdd(EVENTS.dropped, 1u);
        return false;
    }
    uvec2 w = uvec2(wrap_coord(p));
    EVENTS.entries[i] = uvec2(w.x | (w.y << 16), (kind & 0xffffu) | ((payload & 0xffffu) << 16));
    return true;
}

#endif
