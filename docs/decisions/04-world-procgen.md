# CPU procedural generation rules
**Context**: docs/01 says procgen runs on the GPU eventually; M4 needs a
procgen now. Generation must be deterministic per (seed, cx, cy) and chunks
must agree at seams although pools and structures cross them.
**Decision**: CPU procgen in `src/world/procgen.zig`, f32 noise with integer
hashing (no transcendental math), own simplex and value noise.
- Surface: y < 0 is always sky; surface height = 112 ± 80 from 1D fbm.
  Dirt 16–44 cells deep, then stone. World floor at 32 chunks (8192 cells):
  a noisy 4–40 cell bedrock band above it, bedrock everywhere below.
- Caves: density sampled on a 4-cell lattice and bilinearly interpolated,
  edges roughened with value noise. Open = max of (a) a primary ridged
  tunnel network: distance to the zero set of a domain-warped simplex
  (|n| / |∇n| from lattice central differences), half-width 9–25 cells so
  the 34-cell player can mostly walk them; (b) a secondary crawlway network
  (half-width ≤ 10) gated to some regions; (c) caverns from 2-octave fbm,
  larger with depth. Caves fade out in the first 90 cells below the surface
  except where an entrance noise opens shafts.
- Pockets in stone: sand, gravel, dirt (shallow), oil (deep, sealed ≥ a few
  cells from caves). Gunpowder caches: small lenses on a 192-cell grid.
- Pools: seeds on a 64-cell grid drop to a cave floor and flood upward to the
  highest level that does not leak out of a 192 × 176 box or exceed 6000
  cells (binary search). Water above 60 % of world depth, lava below (lava
  wins overlaps). Moss on exposed stone within 5 cells of water.
- Structures: wooden platforms spanning caves (with posts), buried wooden
  cabins with doorways and powder crates, deeper concrete ruins with steel
  girders, pillars, crumbling walls, rubble and powder caches.
- Seams: each chunk evaluates the base terrain over the chunk plus a margin
  (200 cells sideways, 180 up/down) that contains every pool or structure
  that can touch it, and every feature is a function of its seed and the base
  terrain only. A test generates a 3 × 3 block and checks no liquid borders
  air across a seam.
- Material ids come from a caller-filled `MaterialIds`; variants are
  `hash.baseVariant` (see 02).
**Alternatives**: GPU procgen now (blocked on the GPU layer; the rules here
are integer-hash + simple float and port directly); cellular-automaton cave
smoothing (needs iterations across seams); Perlin worms (harder to bound).
**Consequences**: About 6 ms per chunk in ReleaseFast on the dev machine
(`zig build worldgen -Doptimize=ReleaseFast` prints it), so streaming
processes one chunk per tick by default. Pools that would need more than the
box are simply not placed. Reopen when procgen moves to the GPU or the cave
style needs to change.
