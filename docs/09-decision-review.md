# Decision Review

**How to play**: `zig build run -Doptimize=ReleaseFast` starts the Proving
Grounds level as the witch. Zones, tools and controls are in
[07-tech-demo.md](07-tech-demo.md); the final key map and why is
[127](decisions/127-gameplay-key-map.md). `-- --sandbox` opens the paint
sandbox and `-- --world` the streamed world (keys in
[114](decisions/114-integrate-keys.md)).

This is a single-sitting review of the implementation decisions agents made
while building M0-M9 and the demo level, and integrating the branches on
`main`. It covers the 112 files in [decisions/](decisions/) (01-133, with
gaps) and the integration fixes noted in the merge commits. The design-level decisions D1-D10 in
[06-decisions.md](06-decisions.md) are only mentioned where the build
departed from them.

How to use it: read section 1 first. It lists every place the code does
something the design documents did not say, or said differently. Sections
2-6 go subsystem by subsystem, then list what is not done, what has been
verified, and where decision files disagree. Every entry links to its decision file, which has the
alternatives and measurements. Where decision files disagree, the higher
number usually supersedes the lower; the integration files 110-119 win over
everything before them, and the later fixes 106-108 win over the
integration files where they say so.

Nothing here was re-measured or re-run for this review. Numbers are as the agents
recorded them on the RTX 4090.

## 1. Departures from the design documents

| # | design doc said | built instead | why | file |
|---|---|---|---|---|
| 1 | Margolus, four rotating offsets, 8 px/tick | Offset order (0,0),(1,1),(1,0),(0,1). Falling reaches 8 px/tick, lateral flow only 4 px/tick | The listed order would halve falling to 4 px/tick | [28](decisions/28-margolus-rules.md) |
| 2 | Activity tile: one-byte flag; compaction at step 7 | Byte is an 8-tick wake countdown; compaction runs right after commands at the start of the tick | A one-tick flag froze liquid edges whose rolls all failed for one tick; painted cells move the same tick | [29](decisions/29-activity-tiles.md) |
| 3 | Reactions gather before each of the 8 movement substeps | Pair reactions only in substeps 0-3 (domino tilings, each pair offered once per tick); per-tick rules (emission, burning, lifetime) in substep 0 only; conduction every substep | Race-free pairing, per-tick chance semantics | [41](decisions/41-reactions-pass.md) |
| 4 | Lifetime "uses state byte" | Lifetime and burn time stored as count (≤255) plus period; GPU decrements every `period` ticks | Smoke 1200 and mud 3600 ticks do not fit 8 bits | [05](decisions/05-state-byte-durations.md) |
| 5 | Steel health 255 | Steel health 63; conductive materials keep charge phase in state bits 6-7, loader rejects >63 | The flags nibble is full; charge needs two bits | [40](decisions/40-reactions-material-table.md), [42](decisions/42-reactions-state-byte.md) |
| 6 | Ambient 20 °C | Ambient is temperature byte 8 (24 °C); an empty world is `ambientAir`, not zero words (zero is -40 °C) | 8 °C byte granularity; a -40 °C world kept tiles awake | [09](decisions/09-world-cell-temperature.md), [40](decisions/40-reactions-material-table.md) |
| 7 | Material schema in 03 | Fields added: `.id`, `.ricochet`, `.rubble`, `.pressure_event`, `.blocks_light`, `.extinguishes`, `.feeds_air`, `.anchor`, `.flammable.heat/.event/.flame`, `on_contact` fields, `restitution`. 03's schema block was edited for 06's additions; `restitution` (110) was not | Behaviors in 03/04 had no field | [06](decisions/06-schema-additions.md), [40](decisions/40-reactions-material-table.md), [110](decisions/110-integrate-material-layout.md) |
| 8 | GPU material table (size not fixed) | One 192-byte all-`uint` `MaterialGpu` from the data layer, replacing the 176-byte (03) and 128-byte (30) drafts; renderer derives its own 48-byte table | One source of truth, tested against the GLSL text | [110](decisions/110-integrate-material-layout.md), [101](decisions/101-render-materials.md) |
| 9 | Procgen runs on the GPU | CPU procgen (~6 ms/chunk) on up to 15 worker threads with camera-driven prefetch | GPU layer did not exist; rules are integer hash + simple float and port directly | [12](decisions/12-world-procgen.md), [62](decisions/62-stream-prefetch.md) |
| 10 | Liquid leaving the window is frozen into cells before eviction | Not done. Downloads do not freeze liquid particles or resolve body-owned cells | Left for the solver and bodies owners | [60](decisions/60-stream-gpu-sink.md) |
| 11 | Window is a torus; solvers wrap the same way | Grid: tile column/row before each seam kept asleep (32-cell frozen band). Air: open edge at the seam with a 24-cell sponge, not wrapped. Liquid and ballistic particles: no seam handling | Water rained out of the sky through the wrap; pressure appeared on the far side | [64](decisions/64-stream-window-seams.md), [71](decisions/71-air-boundaries.md) |
| 12 | Air: bounce-back walls | Mix of bounce-back and specular, slip 0.97, mass-conserving | Pure bounce-back killed pulses in 1-cell corridors | [71](decisions/71-air-boundaries.md) |
| 13 | Flooding a room compresses the air pocket; bodies are moving walls | Wall changes and gas sources book their air into a pending store released at most 1/128 cell per cell per tick, with 4 ticks of hysteresis. Flooding compresses sealed rooms again (Boyle's law within 4 %). Walls with body pixels and rock that opens move no air, so bodies do not compress rooms. Moving-wall velocity not implemented | Instant transfers read as explosions (thrown lava, broken glass and floors); 117's fix had removed compression and still left fake blasts | [107](decisions/107-air-soft-wall-compression.md), supersedes [117](decisions/117-integrate-air-soft-walls.md) and [71](decisions/71-air-boundaries.md) |
| 14 | Coarsened mask carries body velocity | It does not; SOLID_COARSE is static count + body count << 3 | Bodies landed after air | [70](decisions/70-air-field-abi.md), [117](decisions/117-integrate-air-soft-walls.md) |
| 15 | World-generated vent cells | Not implemented; only open window edges vent | Not needed for M5 scenarios | [74](decisions/74-air-sources.md) |
| 16 | Gas advection: semi-Lagrangian step | Paired discrete swaps in a separate pass, gas speed capped at 2 px/tick | Semi-Lagrangian on cells duplicates or loses cells | [76](decisions/76-air-gas-advection.md) |
| 17 | `blast_threshold` (unitless) vs "pressure gradient magnitude" | Two loads with separate scales: gradient × 700 for fly materials, wall pressure difference × 1000 for chip/break solids | Uniform room pressure blew pools apart under one rule | [75](decisions/75-air-blast-loads.md), [77](decisions/77-air-blast-scaling.md) |
| 18 | Liquid obstacles from the coarsened mask | Liquid classifies obstacles itself at pixel resolution (cut-cell face weights 0/1/2); powders and other liquids are obstacles | 2x2 counts leak through 1-px walls on odd columns | [80](decisions/80-liquid-integration.md) |
| 19 | Geometric multigrid, red-black GS, 4-6 V-cycles | Unsmoothed aggregation (Galerkin), RB-GS inside 32x32 shared-memory tiles in checkerboard order, correction 1.5, 4 V-cycles, levels 1024 down to a coarsest 32² (one workgroup, 40 iterations; 04 does not state a coarsest size, 16² was expected), projected p ≥ 0 | Deterministic tile-local smoothing; p ≥ 0 stops liquid hanging from ceilings | [82](decisions/82-liquid-multigrid.md) |
| 20 | One particle buffer for flying pixels and liquid | Two buffers: solver keeps private sorted A/B sets; particles leaving the liquid hand off to the shared ballistic buffer and back via `liquid_wake_at` | Full unification touches every liquid kernel; left to the liquid owner | [116](decisions/116-integrate-liquid.md), [80](decisions/80-liquid-integration.md) |
| 21 | Second particle in a pixel: separation force, merge after several ticks | Two claim rounds (own pixel, then nearest free within 2, never upward by choice), hole compaction, merge after 15 overlap ticks | Random free-neighbor search pumped energy; pools mounded and boiled | [84](decisions/84-liquid-rasterization.md) |
| 22 | Reactions append the owner index to a delete list | No delete list: at lift each particle checks its cell is still its own and dies otherwise. EVENT_PARTICLE_CELL_CHANGED (128) is still emitted | Simpler coupling, no shared list | [84](decisions/84-liquid-rasterization.md), [43](decisions/43-reactions-events.md) |
| 23 | Sleep when all 8 neighbors are liquid/solid; wake spawns with zero velocity | Sleep when slow 16 ticks and supported from below (air beside allowed). Poured/painted solver liquid starts asleep and falls cellularly. Woken particles inherit grid velocity (240 px/s down if falling) | The 8-neighbor rule jammed moving water; zero-velocity wake throttled pours | [85](decisions/85-liquid-sleep-wake.md) |
| 24 | Explosion impulse on liquid particles; buoyancy/drag on bodies from particles | Explosions only wake liquid. Bodies use a cellular buoyancy sampler; no liquid-solver forces on bodies | Cross-branch hooks not finished | [97](decisions/97-bodies-gpu-fluid-forces.md), [115](decisions/115-integrate-explode.md), [119](decisions/119-integrate-open-items.md) |
| 25 | Bodies rasterize "clearing last tick's cells first" | Write first, then clear last tick's footprint where not reclaimed; unchanged bodies skipped | Resting bodies wrote nothing and kept cell state | [90](decisions/90-bodies-gpu-rasterization.md) |
| 26 | Connectivity: iterative label propagation (GPU) | CPU flood fill over 256-448 px regions, 1 ms/tick budget; structures held only outside the region count as anchored | Cheap on CPU, bitmaps are needed on CPU for Box2D | [93](decisions/93-bodies-gpu-connectivity.md) |
| 27 | Bodies collide with the readback mirror's mask | `TerrainSource` with `SyncReadback`: synchronous 64x64 tile copies; solid includes powders. Serializes CPU recording with the GPU when bodies exist | The Mirror lacks the body-owned flag and is a frame later | [92](decisions/92-bodies-gpu-terrain-source.md), [119](decisions/119-integrate-open-items.md) |
| 28 | Commands include rasterize body, delete body, load chunk, save chunk | Bodies upload instances and bitmaps directly; chunks go through the stream sink (`UploadSink`) | Not per-pixel fills | [90](decisions/90-bodies-gpu-rasterization.md), [60](decisions/60-stream-gpu-sink.md) |
| 29 | Whole simulation reproducible (D6) | Grid, reactions, air, liquid solver alone: reproducible. Ballistic landing, spawn index order and body eject order are not. Box2D results differ between Debug and ReleaseFast | f32 particles with atomic claims; a deterministic claim needs 2 more passes and a sort | [51](decisions/51-ballistic-pass.md), [90](decisions/90-bodies-gpu-rasterization.md), [116](decisions/116-integrate-liquid.md), [14](decisions/14-box2d-build-and-bindings.md) |
| 30 | Scenario 1: U-tube equalizes within 2 s | Asserted within 4 px by tick 780, 12 s after the pour | The tube is a ~4 s oscillator; damping strong enough kills waves | [87](decisions/87-liquid-scenarios.md), [116](decisions/116-integrate-liquid.md) |
| 31 | Scenario 3: wood wall fails before stone | Runs in `air-test`, not `scenarios`. Breach = a 16 px vent; "no wood left" not asserted; 2 px stone divider between lava and water (makes no steam while the FLIP solver is awake, see row 44) | Real steam explosion on contact; pieces wait for connectivity | [79](decisions/79-air-scenario-harness.md), [118](decisions/118-integrate-harnesses.md), [132](decisions/132-level-steam-room.md) |
| 32 | Scenario 4: plugs destroyed at 2x distance | Measured as blown plugs (< half of 6 sand pixels left) in `air-test`; .zon SKIPs | Mass is now conserved: blast ejects are particles that reland | [118](decisions/118-integrate-harnesses.md), merge `9dff1d2` |
| 33 | Scenario 5: a stone drops into the pool | A gravel blob | Scenarios have no rigid bodies; static stone does not fall | [08](decisions/08-scenario-format.md) |
| 34 | Scenario 6: identical cells after 600 ticks | `determinism.zon` SKIPs (has an explosion); covered by verify-determinism with particles absent and by `liquid-test determinism` with hand-off off | Ballistic landing is order-nondeterministic | [118](decisions/118-integrate-harnesses.md) |
| 35 | `water_spreads_flat` 900 ticks | 2400 ticks | Cellular water flattens diffusively at 4 px/tick | [44](decisions/44-reactions-scenario-runner.md) |
| 36 | One event queue | Two: the shared per-tick queue at slot 16, and air's own pressure-event ring at slot 26 | Folding air in was left as a follow-up | [111](decisions/111-integrate-event-queue.md) |
| 37 | GPU resources ~180 MB | Renderer alone ~270 MiB (snapshot rings, cascades, light mips) | Resource table predates lighting | [100](decisions/100-render-pipeline.md) |
| 38 | Gas creation adds mass at the cell | Reaction gas mass goes through the pending store (row 13): a steam burst raises pressure smoothly, no phreatic blast; painted walls raise pressure over a few ticks | Same rate limit that removed fake blasts | [107](decisions/107-air-soft-wall-compression.md) |
| 39 | D9: one gravity, 196 px/s², for all solvers | Characters fall at 760 px/s² (3.9x); bodies, particles and liquid keep 196, so bodies fall slower than the witch | Real gravity made jumps floaty at character scale | [122](decisions/122-gameplay-feel.md) |
| 40 | 04: entity knockback from pressure-gradient samples | Knockback from the rise of overpressure at the character's center (1500 px/s per unit rise along the wind, +45 % up); damage above 0.08 overpressure; air off falls back to the bodies' radial falloff | The LBM gradient is small and noisy; the rise is robust | [125](decisions/125-gameplay-blast-knockback.md) |
| 41 | 07: level loaded into the streamed window with procedural caves around it | Handcrafted 2048 x 1536 map in the scene window, open sky above y 400, bedrock below y 1536 and at the x seam; no streaming. The witch is not wired to `--world` | Fewer moving parts; the stream would have to carry the level's commands | [131](decisions/131-level-handcrafted-map.md), [129](decisions/129-gameplay-app-modes.md) |
| 42 | Building the world is ordinary commands | The whole map is emitted at tick 0 (~600 of 1024 commands) and its destruction events are dropped at tick 1 | Walls built later blasted huts; map-spanning carve events stayed queued and starved connectivity (a blown pillar never came loose) | [131](decisions/131-level-handcrafted-map.md) |
| 43 | Lava keeps lighting and heating its rooms | The level repaints every lava body as fresh lava every 20 ticks ("fed from below"); glassworks lava fed at 1256 °C | Lava enclosed by cold rock froze to stone in ~300 ticks (emission drains the emitter) | [132](decisions/132-level-steam-room.md) |
| 44 | 07 steam room: lava floor, water tank, wooden plug | Lava under a 2 px stone divider that stops short of the east wall, leaving a 16 px open-lava strip where water flashes to steam; wood wall health 12, ending 44 px above the floor | Awake FLIP water cannot boil: rasterization resets the state byte that holds the boil counter. Water poured straight on lava crusts it | [132](decisions/132-level-steam-room.md) |
| 45 | 07 glassworks: a gate the player can open | Steel floor gate, plus a sand silo with a wooden gate | Wood under lava burns through by itself | [132](decisions/132-level-steam-room.md) |
| 46 | 07 pressure corridor: sand plugs every 64 px | Plugs every 32 px; corridor and open field carved in bedrock; each charge is the standard blast on a pile of gunpowder heated past ignition | 64 px left 1-2 plugs to compare; stone next to a fresh crater kept breaking for hundreds of ticks | [133](decisions/133-level-showcase.md) |
| 47 | Ignition (any source) makes gunpowder explode | `ignite` commands set the burning flag without the ignition event, so command-ignited gunpowder never explodes; only heat or flame ignition emits EVENT_EXPLODE | Found by the level agent; not changed | [133](decisions/133-level-showcase.md) |
| 48 | Weapons are command emitters; flying things are particles | Fire bolt, spit and blast charge are 64 CPU projectiles ray-marched against the mirror, one tick late | GPU particles give no impact callback and no character hits | [124](decisions/124-gameplay-projectiles.md) |

## 2. Decisions by subsystem

### Data layer (01-08)

- [01](decisions/01-material-ids.md) Air is built in as id 0; files carry explicit `.id` (acid 1 ... wood 30); new files take the lowest free id, so ids never shift.
- [02](decisions/02-zon-loading.md) ZON via `std.zon.parse`, all numbers range-checked by the loader, all errors collected. `.break` is spelled `.@"break"`.
- [03](decisions/03-gpu-table-layout.md) Reaction table 256x256 x 8 B, symmetric, pair temperature, "no rule" encoded so it cannot fire. The 176 B material size is superseded by 40/110.
- [04](decisions/04-phase-change-semantics.md) °C to byte rounds to nearest; melt/boil fire on `t > at`, freeze on `t < at`; ping-pong chains rejected at load. Steam condenses by reactions with cold solids.
- [05](decisions/05-state-byte-durations.md) Count + period (departure 4). Lifetime with health is rejected.
- [06](decisions/06-schema-additions.md) Schema additions (departure 7). Gunpowder + flame is also a reaction with an `explode` event.
- [08](decisions/08-scenario-format.md) Scenario format: y down, `.rect/.circle/.line`, `.only`, assertions `count/at/none/particles/pressure/deterministic`.

Tuning knobs ([07](decisions/07-invented-material-values.md), all in `materials/*.zon`): conductivities (steel 220 ... air 8), drag (gases 255, water 200), dispersion (steam 6, smoke 4), burn heat (charcoal 40, wood/oil 24), spawn temperatures (flame 900 °C, steam 110 °C), lifetimes (mud 3600, blood 1800 ticks), liquid blast thresholds (water 10 ... molten steel 60), every reaction chance (water+flame 60, sand+lava 16, acid on steel 8, moss 1), ramps.

### World (09-13, 108)

- [09](decisions/09-world-cell-temperature.md) Ambient byte 8; procgen writes initial health from a `SpawnState` table.
- [108](decisions/108-procgen-spawn-state-from-table.md) `world_mode.spawnState` now fills `SpawnState` from the loaded table's `state_init`, so generated steel starts at health 63, uncharged. The struct defaults remain for CPU tests and the worldgen tool.
- [10](decisions/10-world-chunk-compression.md) RLE over u32 after XOR with the base variant; dug air loses its variant (only lossy part). Changing `baseVariant` changes the save format.
- [11](decisions/11-world-save-layout.md) Only modified chunks are parked, in a 64 MiB pool of 4 KiB blocks; save dir is `world.zon` plus one `cx_cy.chunk` per parked chunk; all loaded at startup.
- [12](decisions/12-world-procgen.md) CPU procgen rules: surface, ridged tunnels sized for the player, caverns, pockets, pools by binary-search flooding, cabins and ruins, margin evaluation for seam agreement.
- [13](decisions/13-world-streaming.md) Chunk (cx, cy) lives in slot (cx mod 8, cy mod 8); recenters at 160 px from center with hysteresis, one chunk op per tick.

Tuning knobs: surface 112 ± 80, tunnel half-width 9-25, pool cap 6000 cells in 192x176, water above 60 % depth, recenter 128 + 32, parked pool 64 MiB / 8192 chunks.

### CPU bodies (14-19)

- [14](decisions/14-box2d-build-and-bindings.md) Box2D v3.2.0 via its own `build.zig`, SIMD on with runtime AVX2 dispatch, single-threaded. Determinism holds per build mode only.
- [15](decisions/15-body-units.md) World units are pixels (`b2SetLengthUnitsPerMeter(20)`), y down, mass in kg with densities x 1.25e-4.
- [16](decisions/16-collision-decomposition.md) Greedy rectangles for body and static shapes; static terrain in 64 px tiles rebuilt on hash change, exact within 24 px of a body, 4x4 coarse elsewhere.
- [17](decisions/17-beam-yield-fracture.md) Beams: segment inertia x 60 to stop rope-like sag; viscoplastic yield by rest-angle flow; fracture on smoothed moment, force or plastic angle; capacity scales with thickness².
- [18](decisions/18-impacts-and-forces.md) Impacts thresholded on reduced mass x approach speed, not Box2D's solver impulse; blast and fluid force APIs.
- [19](decisions/19-body-memory-pools.md) All body memory preallocated; first-fit pixel span allocator; `error.OutOf*` instead of growth.

Tuning knobs: `beam_inertia_scale` 60; the steel/wood/concrete yield/fracture/ductility/smoothing/flow table in 17 (steel yield 5e5, fracture 1.25e6; wood 6e4 / 6.6e4; concrete 1e5 brittle); hit threshold 20 px/s, impact impulse 500; substeps 4. These live in code, not ZON.

### Foundation (20-34)

- [20](decisions/20-vulkan-bindings.md) vulkan-zig pinned at a master commit, loader opened at runtime. Validation layers are not installed, so validation has never run.
- [21](decisions/21-bindless-descriptors.md) One bindless set, one pipeline layout, 128 B push constants; fixed slots for shared resources (final map in 112).
- [22](decisions/22-dedicated-allocations.md), [23](decisions/23-frame-sync.md) One allocation per resource, CONCURRENT sharing; async compute queue; 23's single serial timeline is superseded by 104.
- [24](decisions/24-hud-font.md), [25](decisions/25-png-encoder.md), [27](decisions/27-sdl-translate-c.md), [32](decisions/32-shader-build.md) Hand-drawn 5x7 uppercase font; stored-deflate PNG (16 MB full captures); SDL3 via build translate-c; glslc per shader with depfiles, warnings fail the build.
- [26](decisions/26-input-mapping.md) Sandbox mouse/keys (keys superseded by 114).
- [28](decisions/28-margolus-rules.md) Offset order (departure 1), sort keys (gases < air 256 < 512 + density < statics), moved-flag rule against diffusive lateral swaps, gas rise chance from density.
- [29](decisions/29-activity-tiles.md) Countdown tiles (departure 2); `--no-sleep` for checks.
- [30](decisions/30-material-table.md) 128 B engine table; superseded by 40/110.
- [31](decisions/31-commands.md) 8-word commands, 1024 per tick, one dispatch per command with barriers so later commands win.
- [33](decisions/33-verification.md), [34](decisions/34-bench.md) Mirror test for `common.glsl` defines; bit-exact CPU reference over 300 ticks with and without sleep; four bench scenes, first 10 ticks excluded.

Tuning knobs: `TILE_WAKE_TICKS` 8, gas vertical chance `clamp(160 - 12*density, 24, 200)`, lateral chance `dispersion * 32`.

### Reactions (40-44)

- [40](decisions/40-reactions-material-table.md) Data layer's table becomes the engine's (192 B); hot reload every 30 ticks keeps old tables on error.
- [41](decisions/41-reactions-pass.md) Two-dispatch gather/commit, domino pairing, rule order (pair, heat, burning, phase, lifetime, fire products, charge). Measured 0.44-0.57 ms/tick all active.
- [42](decisions/42-reactions-state-byte.md) Charge is a Wireworld-like pulse (head, two tail phases) at 8 cells/tick; not yet a heat or damage source.
- [43](decisions/43-reactions-events.md) Event ring at slot 13; superseded by 111.
- [44](decisions/44-reactions-scenario-runner.md) Runner places each scenario at (16, 16) in a bedrock ring; `.requires` makes missing systems SKIP.

Tuning knobs: conduction shift 13 (k/1024 of a gap per tick), `EMIT_DRAIN_SHIFT` 2, BURN_TEMP byte 118 (900 °C), contact ignition 24/256, flame 40/256 and smoke 10/256 per tick, `BOIL_LATENT` 40 ticks.

### Particles and readback (50-56)

- [50](decisions/50-particle-buffer.md) SoA at fixed slots 17-24, atomic free stack plus spawn queue, pushes and pops never in the same pass; per-material budgets (capacity / 4).
- [51](decisions/51-ballistic-pass.md) DDA march, land only where supported (glance off ceilings), buried-particle search, impact responses, overlay image for drawing. Not bit reproducible.
- [52](decisions/52-readback-mirror.md) Full solid/liquid masks, up to 64 material regions, events and counters every tick, polled without waiting; 0.064 ms/tick.
- [53](decisions/53-event-queue.md) Per-tick queue at slot 16 (final form in 111).
- [54](decisions/54-commands-m4.md) Line, spray, eject (interim explosion) commands; final encoding in 113.
- [55](decisions/55-material-particle-fields.md), [56](decisions/56-sandbox-particle-tools.md) Rubble, restitution and ricochet fields (final form in 110); spray and eject keys (final in 114).

Tuning knobs: speed cap 3600 px/s, impact min 90 px/s, ricochet 150 px/s, glance 0.2, failed-landing bounce 0.3 and 15 retries, splash chance and the ~40 % speed kept by kicked cells, chip 300 px/s up to 25 %, dent `speed*density/19200`, eject falloff and 40 px/s fly threshold, air drag 2/s (115, lowered at merge `0fb1ae9`).

### Streaming (60-64)

- [60](decisions/60-stream-gpu-sink.md) Uploads via a 16-entry staging ring, recorded in the next tick; downloads synchronous with `deviceWaitIdle` (0.4-0.7 ms per sync, eviction ticks 1-3 ms).
- [61](decisions/61-stream-dirty-bits.md) Chunk dirty bits derived from activity marks; conservative.
- [62](decisions/62-stream-prefetch.md) Worker-thread procgen; 0 stalls at 600 px/s; rare 7-10 ms outliers on eviction ticks.
- [63](decisions/63-stream-world-mode.md) `--world`, F5/quit saves, headless camera paths and edits. At zoom 1 on wide windows the view shows wrapped chunks.
- [64](decisions/64-stream-window-seams.md) Frozen seam band (departure 11).

### Air field (70-79, 107)

- [70](decisions/70-air-field-abi.md) Slots, GLSL API (`air_velocity`, `air_gas_created`), blast-eject and air-event buffers (renumbered at merge to 25-28).
- [71](decisions/71-air-boundaries.md) Open seam edge, slip walls, wall-change mass transfer, `NODE_BLASTED` exception.
- [72](decisions/72-air-lbm-parameters.md) tau 0.6, 4 steps/tick, density clamp [0.25, 4], |u| ≤ 0.3 c_s; 0.12-0.25 ms.
- [73](decisions/73-air-active-tiles.md) Air tiles sleep on velocity, not density, so a pressurized room at rest sleeps and keeps its pressure.
- [74](decisions/74-air-sources.md), [75](decisions/75-air-blast-loads.md), [77](decisions/77-air-blast-scaling.md) Injection by integer weights, standard explosion, buoyancy, gas mass; gradient vs wall loads; scales chosen by sweeping against corridor_blast.
- [76](decisions/76-air-gas-advection.md) Gas swaps (departure 16).
- [107](decisions/107-air-soft-wall-compression.md) Pending-mass store (departures 13, 38). New `air_flood` scene and zero-eject checks over `lighting`, `bodies_slab` and `liquid_dam`; peak blast loads recorded as a fraction of threshold. Node bits 12-15 are now taken. 8 MB VRAM, ~0.006 ms.
- [78](decisions/78-air-overlay.md), [79](decisions/79-air-scenario-harness.md) Debug overlay (now mode 2/3 of the shared image); `air-test` harness.

Tuning knobs: tau 0.6, slip 0.97, sponge 24 cells at 0.25, `AIR_WAKE_TICKS` 4, wake velocity 2e-4, `pending_cap` 1/128, `pending_settle` 4 ticks, explosion 1.5 density / 0.15 momentum per cell over 4 steps, buoyancy 2e-6 per byte, `AIR_GAS_CELL_MASS` 0.5, `blast_scale` 700, `wall_scale` 1000, damage 0.25 health per excess unit, eject speed 3x air velocity capped at 8 px/tick.

### Liquid (80-87)

- [80](decisions/80-liquid-integration.md) Private particle arrays and obstacle classification; wake image at slot 14, `CMD_WAKE_LIQUID` 32.
- [81](decisions/81-liquid-determinism.md) Counting sort plus per-bin insertion sort, ranked wake spawns, decide/apply splits, checkerboard tiles. Verified 0 differences over 600 ticks.
- [82](decisions/82-liquid-multigrid.md) Departure 19; residual 5-8 %, ~1 ms/tick projection.
- [83](decisions/83-liquid-transfer-dynamics.md) FLIP 0.95 blend, RK2 then pixel march (never crosses 1-px walls), speed cap 480 px/s, settling drag, density correction.
- [84](decisions/84-liquid-rasterization.md), [85](decisions/85-liquid-sleep-wake.md) Departures 21-23.
- [86](decisions/86-liquid-idle.md) Recording modes full/drain/idle decided from counters 12 ticks old; a still lake costs 0.021 ms; waking an idle world has 0.2 s latency.
- [87](decisions/87-liquid-scenarios.md) `liquid-test` harness; U-tube result (departure 30).

Tuning knobs: FLIP/PIC 0.95, correction 1.5, 4 V-cycles, 2+2 smoothing, 40 coarsest iterations, `settle_rate` 4/s, `settle_speed` 64 px/s, `band_factor` 3, density target `32(n-4)/4`, sleep 16 ticks under 8 px/s, wake thresholds 20 px/s and 80 px/s² x dt, command wake margin 16 px, powder wake 4 hops, `wake_budget` 65536, merge after 15 overlap ticks, grace 30 ticks, decision lag 12 ticks. All settable with `--liquid-param`.

### Bodies on the GPU (90-99)

- [90](decisions/90-bodies-gpu-rasterization.md) Inverse-mapped 16.16 rasterization, claim image with tick stamp (lowest id wins), write-then-clear. Bitmaps hold static-phase materials only. A reaction on a body cell is undone when the body moves.
- [91](decisions/91-bodies-gpu-eject-queue.md) Eject queue at slot 4; fallback reinserts cells straight up. After 115 only refused particle spawns reach it.
- [92](decisions/92-bodies-gpu-terrain-source.md) TerrainSource/SyncReadback (departure 27); pending-extraction overlay.
- [93](decisions/93-bodies-gpu-connectivity.md) CPU connectivity (departure 26); fragments under 4 px become rubble.
- [94](decisions/94-bodies-gpu-breakup.md) Breakup on Δv vs threshold with a shape factor; dissolve under 150 px or severity > 4; crush disc plus transverse and radial cracks. Resting bodies are never frozen back into terrain.
- [95](decisions/95-bodies-gpu-beams-in-world.md) Beams span the gap and weld at rock faces; cuts weaken joints by remaining thickness²; anchors release when the rock behind is gone; 12 sparks per break.
- [96](decisions/96-bodies-gpu-torus-frame.md) Unwrapped coordinates, recentered by 2048 px; re-welded anchors lose their plastic bend.
- [97](decisions/97-bodies-gpu-fluid-forces.md) Blast from destruction events, pluggable fluid sampler, cellular buoyancy default.
- [98](decisions/98-bodies-gpu-materials.md), [99](decisions/99-bodies-gpu-sandbox-and-scenes.md) Materials by name (now from the library); bodies off by default except windowed app and `bodies_*` scenes.

Tuning knobs: breakup thresholds (concrete/stone 300, glass 120, wood 600, steel 4000 px/s), shape factor clamp 0.35-1, dissolve 150 px / severity 4 / pieces 60 px, crack counts, kick 35 px/s per severity, connectivity region 256/448 and budget 1 ms, blast 1.5 r for ejects and 4x radius / 40 per unit overpressure for explosions (115), water drag 2 x mass x fraction, beam segment ~10 px.

### Rendering (100-106)

- [100](decisions/100-render-pipeline.md) World rendered at one texel per world pixel into RGBA16F, integer upscale, luminance ACES, dither.
- [101](decisions/101-render-materials.md) Derived render table with per-name art overrides; procedural back wall behind translucent cells and air; emission and temperature glow.
- [102](decisions/102-radiance-cascades.md) 2D radiance cascades with bilinear-fix merge, RGB9E5, skyline sky, wall dilation; 0.31 ms at zoom 2, 1.12 ms at zoom 1. Simple-light and off modes.
- [103](decisions/103-render-overlays.md) Nine overlay modes, one shared RGBA8 image (slot 2).
- [104](decisions/104-render-snapshot-overlap.md) Two timelines and a two-entry snapshot ring: render N overlaps sim N+1 (-16 % when GPU-bound).
- [106](decisions/106-render-skyline-fix.md) The sky-or-back-wall surface is now the skyline under a 1D opening then closing (radius 24): small objects in the open no longer get fake back-wall slabs beside them; shafts up to 48 px still show the back wall. Cascades keep the raw skyline. +5 us.
- [105](decisions/105-sprites-and-world-text.md) One 512² atlas, 8192 quads per frame, world-anchored HUD text; sprites do not occlude light.

Tuning knobs: art overrides (absorption, alpha) per name, probe spacing 2, ~16 march steps, ambient fade 260 px, wall dilation 10 px, light disc radius `clamp(r/12, 2, 6)`, bloom and exposure.

### Integration (110-119)

- [110](decisions/110-integrate-material-layout.md) One material layout; `rubble` = own id means none; `restitution` added (steel 150).
- [111](decisions/111-integrate-event-queue.md) One queue, 8-bit kind / 24-bit payload, 8 ticks of history.
- [112](decisions/112-integrate-overlay.md) Final slot map (also in `common.glsl`).
- [113](decisions/113-integrate-command-kinds.md) Shape x action encoding; kinds 5, 6, 8 retired; line radius moved to material bits 16-31.
- [114](decisions/114-integrate-keys.md) Final key table (E explode, X eject, Z wood crate, F4 light mode, F5 save). Overrides 26, 56, 99, 103.
- [115](decisions/115-integrate-explode.md) `game/explode.zig` is the single gameplay explosion call; gunpowder events drain one tick late (radius 6, strength 1, max 64 per drain).
- [116](decisions/116-integrate-liquid.md), [117](decisions/117-integrate-air-soft-walls.md), [118](decisions/118-integrate-harnesses.md) Departures 20, 13, 30-34.
- Merge fixes not in decision files: the command applier was recorded twice after the particles merge (`9dff1d2`, fixed); slots renumbered (air buffers 25-28, particle overlay 13, inject_pressure 9); streamed chunks reset air to ambient (`0fb1ae9`).

### Gameplay (120-129)

- [120](decisions/120-gameplay-readback-info.md) Region readback carries an info byte per cell (charged, burning, body-owned, particle-backed); `Mirror.info`, `Mirror.regionView`. Readback stays 0.07 ms.
- [121](decisions/121-gameplay-collision.md) Characters are pixel AABBs moved one pixel at a time per axis (no tunnelling), 3 px step-up and slope snap, push-out up to 8-10 px, drop-through for platforms ≤ 3 px. Solid = mirror mask plus powders from the entity's region.
- [122](decisions/122-gameplay-feel.md) Movement and camera tuning (departure 39); swimming, breath, camera lead toward the cursor, 1.5 s death fade.
- [123](decisions/123-gameplay-status-effects.md) One `Status` of timers (burning, wet, oily, stunned, bloody, blind, breath); damage scales with cells touched, full at 6; shocks from charged cells; contact values come from the material files.
- [124](decisions/124-gameplay-projectiles.md) CPU projectiles (departure 48).
- [125](decisions/125-gameplay-blast-knockback.md) Knockback from air samples (departure 40); a witch 40 px from a charge flies ~70 px and loses ~24 hp.
- [126](decisions/126-gameplay-enemy-ai.md) Walker and flyer with local rules, no pathing (walkers fall into pits); enemies beyond 700 px freeze; death spawns a flesh-and-bone body and blood.
- [127](decisions/127-gameplay-key-map.md) Play mode is the default; play keys and tool timings; the cutter is a drag with destruction events along it. docs/07's controls table is the final map; 26 and 114 still describe the sandbox.
- [128](decisions/128-gameplay-playtests.md) `--script` headless playtests (`playtests/*.hexe`) with view screenshots; not pass/fail and not reproducible.
- [129](decisions/129-gameplay-app-modes.md) `runPlay` unless `--sandbox`/`--world`; R re-creates the whole engine (~0.2 s); input edges latched until a tick consumes them.

Tuning knobs: gravity 760, jump 270 px/s, 45 % on release, coyote 0.10 s, buffer 0.12 s, terminal 540, run 120, accel 1500 / friction 1800 / air 900; swim gravity x0.25, buoyancy 330, drag 4/s; breath 5 s then 15 hp/s; camera lead 30 % at 7/s; burning 6 hp/s for 4 s; shock 20 hp (40 wet), 0.6 s stun; knockback 1500 px/s per unit rise, damage 150 hp per unit above 0.08, `blast_factor` walker 0.8 / witch 1 / flyer 3; walker 60 hp, 40/82 px/s, sight 200/300 px, melee 12 hp; flyer 25 hp, spit every 2 s; fire bolt 430 px/s, 18 hp; blast charge fuse 1.6 s, radius 10, strength 1.6; tool cooldowns in 127.

### Demo level (130-133)

- [130](decisions/130-level-layout.md) Three tiers under an open sky (surface zones, tier-2 waterworks/steam room/corridor, tier-3 glassworks/electric pool/arena/acid pit); ledge shafts every 28 px; anything that would hang free is tied to rock. Scenes `proving_grounds`, `_auto`, `_burst`. The rock band y 900-1200 is spare.
- [131](decisions/131-level-handcrafted-map.md) Handcrafted map built in one tick (departures 41, 42).
- [132](decisions/132-level-steam-room.md) Lava upkeep, steam room and glassworks (departures 43-45). No material file was changed. Once vented the room throws lava and stone into the gallery.
- [133](decisions/133-level-showcase.md) Showcase schedules, corridor in bedrock with 32 px plugs (departure 46), ruin beams and watchtower inside the 256 px connectivity region. Corridor plugs gone to 290-320 px vs 100-130 px in the field 140 ticks after the charge.

Tuning knobs: lava repaint period 20 ticks, glassworks lava 1256 °C, steam-room wood health 12 and open-lava strip 16 px, plug spacing 32 px, charge `explosion(r 6, strength 1)`, field charge 60 ticks after the corridor's, glass cool-down 420 ticks, ruin beam 4 px over 240 px.

## 3. Open items

- [ ] Bodies read terrain through `SyncReadback`, not the Mirror. `src/sim/terrain_source.zig`. The flag byte now exists ([120](decisions/120-gameplay-readback-info.md)); still needed: a request one frame ahead and powders in the solid definition. Costs 1.7 ms mean per tick in `--bench-demo`. ([119](decisions/119-integrate-open-items.md), [133](decisions/133-level-showcase.md))
- [ ] Air pressure events in their own ring (slot 26, `Air.events()` in `src/sim/air.zig`), not EVENT_PRESSURE in the shared queue. ([111](decisions/111-integrate-event-queue.md))
- [ ] Liquid particles in private arrays, not the shared buffer. `src/sim/liquid.zig`, `shaders/sim/liquid/liquid.glsl`. ([116](decisions/116-integrate-liquid.md))
- [ ] Body boundary velocity in the liquid solve: `shaders/sim/liquid/classify.comp` sets `u = 0` on closed faces.
- [ ] Liquid-solver buoyancy/drag on bodies: only `cellularFluid` in `src/sim/bodies_sim.zig` (`default_fluid`).
- [ ] Explosion impulses on liquid particles (only a wake today).
- [ ] Painting a `feeds_air` gas by command adds no air mass (`commands.comp`; reactions do call `air_gas_created`).
- [ ] Bodies move no air, so a body entering a sealed room does not compress it. ([107](decisions/107-air-soft-wall-compression.md))
- [ ] Coarse mask carries no body velocity; air has no moving walls. ([70](decisions/70-air-field-abi.md), [71](decisions/71-air-boundaries.md))
- [ ] World-generated vents. ([74](decisions/74-air-sources.md))
- [ ] Liquid solver and ballistic particles ignore window seams (`Stream.freeze_cols/rows` used only by `dirty.comp` and air). ([64](decisions/64-stream-window-seams.md))
- [ ] Chunk eviction does not freeze liquid particles or resolve body-owned cells. `src/sim/stream.zig`. ([60](decisions/60-stream-gpu-sink.md))
- [ ] Reactions on body-owned cells (burning wood bodies) are undone when the body moves. ([90](decisions/90-bodies-gpu-rasterization.md))
- [ ] EVENT_PARTICLE_CELL_CHANGED (128) is emitted but nothing consumes it. ([84](decisions/84-liquid-rasterization.md), [111](decisions/111-integrate-event-queue.md))
- [ ] Charge is not a heat or damage source; entity shock needs M9. ([42](decisions/42-reactions-state-byte.md))
- [ ] Entity contact (`on_contact`) is parsed but has no consumer. ([06](decisions/06-schema-additions.md))
- [ ] Beam and breakup parameters live in code (`bodies_materials.zig`), not ZON. ([17](decisions/17-beam-yield-fracture.md), [94](decisions/94-bodies-gpu-breakup.md))
- [ ] Scenario files `corridor_blast`, `sealed_steam_room`, `determinism` SKIP; their assertions wait for the owner. ([118](decisions/118-integrate-harnesses.md))
- [ ] Multigrid runs over the full 1024² grid; restricting to fluid tiles is the noted next optimization. ([82](decisions/82-liquid-multigrid.md))
- [ ] GPU procgen. ([12](decisions/12-world-procgen.md))
- [ ] Minimum-spec profile: render memory and capacities not reduced. ([100](decisions/100-render-pipeline.md), [72](decisions/72-air-lbm-parameters.md))
- [ ] Vulkan validation layers not installed; no run has been validated. ([20](decisions/20-vulkan-bindings.md))
- [ ] Awake FLIP water cannot boil: rasterization writes the material's initial state, resetting the boil counter in the state byte. Liquid layer, `shaders/sim/liquid/claim.comp` (state not carried by particles, [84](decisions/84-liquid-rasterization.md)). ([132](decisions/132-level-steam-room.md))
- [ ] `ignite` commands do not emit the ignition event, so command-ignited gunpowder never explodes. `shaders/sim/grid/commands.comp` / `reactions.comp`. ([133](decisions/133-level-showcase.md))
- [ ] Destruction events whose region spans the map stay queued while any cluster overlaps them and starve connectivity. Suggested fix: expire an event once its cluster ran, in `src/sim/bodies_sim.zig`. The level works around it at tick 1. ([131](decisions/131-level-handcrafted-map.md))
- [ ] Stone next to a fresh crater keeps breaking for hundreds of ticks after a confined charge (reported as engine behavior; the level uses bedrock). ([133](decisions/133-level-showcase.md))
- [ ] Enclosed lava freezes in ~300 ticks because emission drains the emitter; the level repaints it. Heat model in `reactions.comp` ([41](decisions/41-reactions-pass.md), [132](decisions/132-level-steam-room.md))
- [ ] The witch is not wired to `--world`; it keeps the sandbox. ([129](decisions/129-gameplay-app-modes.md))
- [ ] Explosion drain caps at 64 per drain; the showcase staggers charges to avoid it. ([115](decisions/115-integrate-explode.md), [133](decisions/133-level-showcase.md))
- [ ] Four 5.7 MB `playtest-*.png` files were committed at the repository root by the level merge (`9b597a8`); probably accidental.

## 4. Verification status

Build targets (from [08-engineering.md](08-engineering.md)):

| target | covers | recorded result |
|---|---|---|
| `zig build test` | CPU unit tests: packing, hash, torus, ZON validation, layout vs GLSL text, CPU reference behaviors, Box2D wrappers, procgen seams | required before every report (08); no failure recorded |
| `zig build verify-determinism` | GPU grid + reactions vs CPU reference, 300 ticks, sleep on/off, event sets; `determinism_commands` for command kinds. Air, liquid, bodies off; no particles | 0 differences |
| `zig build scenarios` | `scenarios/*.zon` headless | 8 pass, 3 skip |
| `zig build gpu-test` | particles land and conserve cells, mirror, events one tick late | eject test loses 0-1 of 15 489 cells ([51](decisions/51-ballistic-pass.md)) |
| `zig build air-test` | sealed room, corridor blast, `air_flood`, zero-eject checks over flowing liquid and bodies | all PASS after 107: corridor 152 px vs open 40 px, flood 1.93 at 3/4 full (Boyle 2.02), 0 fake ejects ([107](decisions/107-air-soft-wall-compression.md)) |
| `zig build liquid-test` | U-tube, dam break, pool sleep, reactions coupling, determinism (air off, hand-off off) | U-tube within 4 px from tick 710; dam keeps 99.3 % of its water; determinism 0 differences |
| `zig build stream-test` | upload, dirty bits, download, save, reload (`--world-selftest`) | no result restated in the decision files |
| `zig build bench`, `bench-render` | per-pass GPU ms, overlap | numbers in the decision files |
| `zig build bodies-demo` | CPU beam bend and snap (ASCII) | matches 17 |
| `zig build worldgen`, `docs`, `shaders` | tools | build |
| `--script playtests/NAME.hexe` | headless scripted play with view screenshots | looked at, not pass/fail ([128](decisions/128-gameplay-playtests.md)) |
| `--demo-script PREFIX`, `--bench-demo` | level showcase screenshots; every event in 5 s, timed | 2.6 ms wall per tick with a 1080p render, GPU 2.3 ms, `lq_project` 0.92 ms mean ([133](decisions/133-level-showcase.md)) |

Verified headless: everything in the table, the `bodies_*` scenes (headless reports with cell census), lighting and overlays via `--view-screenshot` PNGs the agents looked at, `--world` streaming with camera paths and the world self-test.

Gameplay and the level were verified headless through playtest scripts and the showcase: view screenshots looked at and printed state read, not asserted. Character collision, timers, oil, drowning and shocks have unit tests in `zig build test`.

Only smoke-tested windowed: the app starts and runs at 60 fps with bodies on ([99](decisions/99-bodies-gpu-sandbox-and-scenes.md)); windowed frame times were measured ([104](decisions/104-render-snapshot-overlap.md)); R reset ran windowed via `--reset-at` (400 frames, reset at 200, [129](decisions/129-gameplay-app-modes.md)). No agent played the window interactively. Untested by hand: the play key map (127), the sandbox key table (114), painting and erasing, hot reload in the app, F5 save in `--world`, torch, overlay cycling, the beam placement clicks, and whether one tick of latency is perceptible (an M4 done criterion).

## 5. Contradictions between decision files

Recorded, not resolved, except where marked.

1. **Resolved by [108](decisions/108-procgen-spawn-state-from-table.md).** Procgen spawned steel with state 255 ([09](decisions/09-world-cell-temperature.md)) while [40](decisions/40-reactions-material-table.md)/[42](decisions/42-reactions-state-byte.md) cap it at 63, so generated steel started as a charge-pulse head.
2. Ambient: byte 8, 24 °C, empty air is `ambientAir` (09, 40) vs buoyancy above "byte 7, 20 °C" and unpainted cells at -40 °C ([74](decisions/74-air-sources.md)).
3. Material table size: 176 B (03), 128 B (30), 192 B (40, 110); [101](decisions/101-render-materials.md) still describes the older layouts.
4. Id 255: "no transition" (30), "no rubble" (55), body-owned marker (92, 110), while 03/40/110 encode "none" as the material's own id.
5. Event queue: slot 13 ring, uvec4 (43) vs slot 16, `kind | payload << 16` (53) vs `kind 8 bits | payload << 8` (111). 53's text still shows the old encoding.
6. Slots: 50, 70, 80, 91 and 103 overlap (image 8, buffers 20-24, overlay 2/12/15); [70](decisions/70-air-field-abi.md) says integration "renumbers nothing". Final map in 112.
7. Command kinds: inject_pressure kind 3 (70) is fill_line in [54](decisions/54-commands-m4.md); 54 calls inject_charge a no-op while 42 implements charge. Settled by 113.
8. Keys: 26, 56, 99, 103, 114 and [127](decisions/127-gameplay-key-map.md) disagree (F5, X, E, F3, R, P, 1-9). F3 is the air overlay in the sandbox (114) and timings in play (127). 99 makes right mouse the eject tool; 26 makes it erase.
9. "Solid": mirror mask = static or body-owned, no powder (52); TerrainSource = static or powder, not body (92); SOLID_COARSE = static or body (70); liquid obstacles include powders (80); character collision = mask plus powders ([121](decisions/121-gameplay-collision.md)).
10. Particle mode values: FREE 0 / BALLISTIC 1 / LIQUID 2 with temperature in bits 16-23 (50) vs dead 0 / liquid 1 / ballistic 2 with temperature in bits 24-31 (80).
11. Reaction deletes: 43 adds EVENT 128 for the solver to delete particles; 84 uses a lift check and says no delete list is shared. EVENT 128 has no consumer.
12. Bodies hot reload: not refreshed (98) vs `reloadTables` re-uploads the bodies table (110).
13. U-tube: 87 records 3,250 of the 4,880 expected water cells; 116 relaxes the timing and does not mention the total.
14. `particles` assertion: awake liquid cells (08), always 0 until M6 (44), live particle count (52).
15. Blast impulse on bodies: 1.5 r per destruction event (97) vs 4x radius and 40 per unit overpressure for explosions (115); characters use a third rule (125).
16. Determinism: 76 calls the air-on path bit-reproducible; 51, 90, 116, 118, 128 and 132 rule out whole-sim determinism; D6 claims it.
17. Stale fallbacks: 63 (missing materials become stone), 98 and 100 (builtin tables) describe code 110 deleted.
18. Air wall changes: 71 moves air instantly, 117 makes liquid and body walls move none, 107 books it into a rate-limited store. **107 supersedes 117's consequence** that flooding no longer compresses sealed rooms (117 now carries a superseded note). 74's phreatic-blast speculation is also void under 107.
19. Sealed-room steam: 118 says water behind the stone divider "really boils"; 132 says water on a hot divider never boils while the FLIP solver is awake. They may differ in whether the solver runs in each harness; neither says.
20. Tick-0 walls: 131 builds the map in tick 0 because walls built later "push their air out as blasts". That was measured before 107, which routes static walls through the store too.
21. Defaults overtaken by the merge: 129 sets `default_scene = .lighting` until the level lands and 130 says the camera starts at the world center until the spawn is wired; the level merge sets `.proving_grounds` and uses `level.spawn_point`.
22. Gravity: D9 says all solvers share units so falls agree; 122 gives characters 760 px/s² against 196 for everything else.

## 6. Later decisions

Decisions after 133 are appended by later agents and are not covered here.
