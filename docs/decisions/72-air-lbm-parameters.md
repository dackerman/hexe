# Air field LBM parameters, layout and cost

**Context**: 04-fluids.md fixes D2Q9 BGK, ping-pong, pull scheme, tau above
0.55, Mach ≤ 0.3, 4 steps per tick, 1.5 ms budget; the rest was open.

**Decision** (`Air.Params`, all runtime-tunable):
- tau 0.6 (ν = 0.033 lattice), 4 steps per tick (sound ≈ 4.6 px/tick,
  277 px/s), clamped to ≥ 0.55.
- Layout: two buffers of 9 planes × 1024² f32 (structure of arrays, x
  fastest), 72 MB total, pull stream fused with collision; parity tracked on
  the CPU, so odd step counts work. Workgroup 16×16 = one air tile.
- Stability: the equilibrium uses density clamped to [0.25, 4] and |u|
  clamped to 0.3 c_s; a cell whose post-collision populations go negative
  falls back to its clamped equilibrium. Forcing (buoyancy) by velocity
  shift (u_eq = u + τF/ρ); reported velocity (m + F/2)/ρ.
- The field image is written on the last step only.
- Cost (RTX 4090, `zig build bench`, ReleaseFast): `bench_air` with every
  tile every step: air.lbm 0.131 ms for 4 steps; all air passes 0.247 ms.
  Worst case, a window with no walls, all active: air.lbm 0.234 ms (75 MB
  per step at ≈1.3 TB/s effective, the working set mostly fits the 72 MB
  L2). With active tiles: 0.118 ms. Static world: 0.029 ms (prep +
  coarsening, which run on the full window). No layout tuning was needed;
  AoS, f16 storage and other workgroup shapes were not tried.

**Alternatives**: esoteric-twist / AA single buffer (halves memory, more
index logic; not needed at this budget); TRT/regularized collision (more
stable at low tau; BGK with clamps has been stable in every test).

**Consequences**: 72 MB VRAM for distributions. If the minimum-spec profile
(512² lattice) needs it, AA-pattern or f16 storage are the next steps.
