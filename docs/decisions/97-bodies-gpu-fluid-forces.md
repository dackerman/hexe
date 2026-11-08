# Forces on bodies: blast from ejects, fluid sampler hook, cellular buoyancy

**Context**: bodies should be pushed by blasts and carried by fluids; the air
field and the liquid solver are not on this branch.

**Decision**:
- **Blast**: every destruction event calls `applyBlast(x, y, 1.5 r,
  1.5 r)` (strength in impulse per body pixel, so Δv ≈ 1.5 r / density:
  a 30 px eject throws wood at 600 px/s, barely moves steel);
  `DestructionEvent.strength` overrides it for explosions.
- **Fluid hook**: `BodySim.fluid_sampler: ?FluidSampler`; `sample(ctx, sim,
  RasterBody) ?FluidSample{velocity, drag, angular_drag, buoyancy}` is called
  once per live body per tick before the step and fed to
  `BodyWorld.applyFluid`. `applyFluidForces(sampler)` is public for callers
  that want to apply more than one.
- **Default sampler** (cellular liquids, from the terrain source): cheap
  reject when no liquid lies on the border of the body's box; otherwise each
  row's run of body-owned cells counts as submerged when a liquid cell borders
  it on either side. Buoyancy = ρ_liquid · submerged · 196 upward
  (ρ = grid density · 1.25e-3 kg/px, water 0.125), drag = 2 · mass ·
  fraction submerged per second, angular drag likewise.

**Consequences**: in `bodies_water` the concrete crate (0.30 kg/px) sinks and
rests on the bottom, the wood crate (0.075 kg/px) floats at the surface
(still bobbing slowly at tick 400; an air pocket follows it under the water
until the cellular water closes it). The air field (M5) and the FLIP solver (M6) replace the default
with samplers of pressure gradient / velocity at body positions. 200 dry
bodies cost 0.07 ms per tick in the sampler.
