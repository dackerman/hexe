# Liquid recording modes: full, drain, idle, decided 12 ticks late

**Context**: "a still lake costs nothing". Gating every solver dispatch on
the GPU (indirect arguments set to zero when there are no particles) still
cost 0.26 ms per tick for about 110 empty dispatches and barriers. The CPU
must stop recording them, without knowing the GPU's particle count this
tick, and without making the simulation depend on frame pacing.

**Decision** (`Liquid.decide`):
- Every tick copies its counters into a host-visible ring indexed by tick.
  Recording tick T reads tick T - 12's counters. With 2 frames in flight and
  at most 4 ticks per frame, tick T - 9 is always complete when tick T is
  recorded, so the read never stalls and the choice depends only on ticks.
- Modes: `full` records everything. `drain` records everything, but the
  wake pass only decides: candidates are kept as requests (byte 0 of the
  wake word) instead of spawning. `idle` records only command wakes and wake
  detection (deferred), about 6 tiny dispatches.
- full -> drain when the observed tick had no particles, no grace, no
  candidates and no moving cellular solver liquid; drain -> idle when a tick
  observed after the drain began was quiet in the same way (no spawns since,
  so nothing can be awake); drain or idle -> full when the observed tick had
  wake candidates (or, in idle, moving cellular bodies of solver liquid).
- Grace: the GPU keeps the solver running for 30 ticks after the last awake
  particle or moving body of cellular solver liquid, so the imbalance check
  (decision 85) sees water that fell asleep.

**Measured**: still lake (bench_static with the solver on) 0.021 ms per
tick once idle (`zig build bench`); a gravel blob dropped into a sleeping
pool starts spawning particles 12 ticks after the impact is detected.

**Alternatives**: the latest completed frame's counters (latency 2 frames,
but the result depends on frame pacing); VK_EXT_conditional_rendering
(skips dispatches, not barriers); device-generated commands (too much).

**Consequences**: waking a fully idle world has 12 ticks (0.2 s) of
latency; the requests wait as cells, nothing is lost.
