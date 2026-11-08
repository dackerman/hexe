# Decision Log

Each entry records what was decided, why, and what would make us revisit it.
Add new entries at the bottom; never edit an old one, supersede it.

## D1 — The GPU owns the world

**Decision**: the cell grid lives on the GPU and is authoritative. The CPU
sends commands and reads a one-tick-stale mirror.
**Why**: it is the only way to run the grid, two fluid solvers and lighting
at the target scale, and it removes the per-frame upload that a CPU-owned
grid would need for rendering.
**Cost**: gameplay cannot read a pixel and react in the same tick. Every
world mutation is a command. Scripting is harder than Noita's Lua.
**Revisit if**: gameplay latency proves intolerable in M4. Fallback is a
CPU-owned grid with SIMD and threads, GPU only for fluids and rendering.

## D2 — Vulkan via vulkan-zig, SDL3 for the platform

**Decision**: raw Vulkan 1.3 with generated Zig bindings. SDL3 for window,
input, audio and surface creation.
**Why**: async compute, timeline semaphores and indirect dispatch without
an abstraction deciding for us. SDL3 is already on the machine.
**Revisit if**: boilerplate is still blocking M1 after two weeks. Fallback
is SDL3 GPU; the architecture is unchanged.

## D3 — GLSL to SPIR-V with glslc

**Decision**: shaders in GLSL 4.6 compiled at build time.
**Why**: mature, installed, well understood. Zig's SPIR-V backend is not
production ready. Slang is attractive but not installed and adds a
dependency.
**Revisit if**: Zig's SPIR-V backend stabilizes, which would allow sharing
the cell format and material structs between CPU and GPU in one language.

## D4 — Margolus block automaton for grid movement

**Decision**: 2 × 2 blocks, rotating offsets, one thread per block, in place.
**Why**: race-free, deterministic, no double buffering, trivial rules. The
one-cell-per-substep limit is covered by substeps and by particles.
**Alternatives rejected**: propose-and-resolve gather (more passes, more
bandwidth, same result), atomic claims (nondeterministic).

## D5 — Pressure is simulated: LBM for air, FLIP for liquid

**Decision**: a D2Q9 lattice Boltzmann air field and a FLIP/APIC liquid
solver with multigrid projection, both at half pixel resolution, with
liquids sleeping to cellular cells when still.
**Why**: pressure waves, sealed-room pressure, water momentum and flow are
the design's identity. Cellular-only could not provide them. The sleeping
representation keeps the particle cap a cap on active water only.
**Cost**: active window 2048 instead of 4096, a longer build, two solvers to
tune, seams between sleeping and active liquid.
**Alternatives rejected**: per-cell fill levels (no momentum, no gas
pressure), compressible Euler for air (harder boundaries than LBM),
free-surface LBM for liquid (less mature than FLIP for splashing).

## D6 — Deterministic everywhere

**Decision**: integer-only grid shaders, hashed randomness, and a sorted
gather transfer in the liquid solver instead of float atomics.
**Why**: exact scenario tests, replayable bugs, and the option of replays
or lockstep multiplayer later. The cost is one extra sort pass per tick.
**Revisit if**: the liquid transfer sort costs more than 1 ms on the target
card and no multiplayer is planned.

## D7 — Box2D v3 for bodies

**Decision**: link Box2D v3's C API. Beams are segment chains with weld
joints that yield and break.
**Why**: writing a rigid body engine is not the project. Box2D is small, C,
fast, and Zig links C without friction. Plastic bending via joint rest-angle
adjustment gives "bends then breaks" without a soft-body solver.
**Revisit if**: body counts or pixel-body fidelity exceed what Box2D handles
well; a custom position-based solver would be the next step.

## D8 — Materials in ZON, one file each

**Decision**: data in Zig Object Notation, hot reloaded, validated on load,
documentation generated from it.
**Why**: ZON is native to Zig, needs no parser dependency, and reads like a
struct literal. One file per material makes diffs and reviews clean.

## D9 — Physical scale

**Decision**: 1 px = 5 cm, player about 34 px tall, gravity 196 px/s², fixed
60 Hz tick, sim window 2048 px, view 640 × 360 px at 3× on 1080p.
**Why**: all solvers share units so blast radii, falls and water columns
agree. Slightly more character detail than Noita.
**Revisit if**: the view feels too tight or too far; changing the view scale
does not touch the simulation.

## D10 — Interaction classes before materials

**Decision**: the engine ships a fixed list of interaction classes, each with
a representative material in version one. New materials are data; new
classes are engine work with a documented procedure.
**Why**: the materials list will grow for years. The mechanisms should not
have to.
