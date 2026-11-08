# Parked chunk store and save layout
**Context**: Chunks outside the window must keep player modifications.
docs/08 forbids heap allocation in the per-tick path, but the set of
modified chunks grows as the world is explored.
**Decision**: Three states: not generated (regenerated on demand), parked
(compressed in RAM), resident (in a GPU slot). Only modified chunks are ever
parked; a clean chunk evicted without a parked copy is dropped and
regenerated next time. A resident chunk keeps its parked copy; on eviction it
is replaced only if dirty. Parked blobs live in a pool of 4 KiB blocks
allocated at init (default 64 MiB) and chained per chunk; the coordinate map
is sized at init (default 8192 chunks). Running out returns
`error.ParkedPoolFull` / `TooManyParkedChunks` and leaves state untouched.
Save directory: `world.zon` with `.version = 1, .seed, .chunk_size = 256,
.codec = .rle_xor_variant`, plus one `cx_cy.chunk` per parked chunk
(e.g. `-3_12.chunk`): magic `HXCK`, u16 version, u16 reserved, i32 cx,
i32 cy, u32 payload length, then the compressed blob (all little-endian).
Loading reads every chunk file into the parked pool at startup.
**Alternatives**: per-blob heap allocation (violates the tick rule); one
region file per N×N chunks (fewer files, more format); lazy loading from
disk on fetch (needs file I/O in the tick path).
**Consequences**: RAM bounds explored-and-modified world size (about 16K
lightly edited chunks per 64 MiB). Save writes all parked chunks and leaves
stale files alone; since everything loaded stays parked, no stale file can
shadow newer data. If saves grow large, move to region files and lazy loads.
