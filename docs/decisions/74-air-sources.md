# Air field sources: explosions, heat, gas mass

**Context**: Sources named in 04-fluids.md: explosion command, buoyancy
from hot cells, mass from gas creation, vents; units were open.

**Decision**:
- **Injection** (`CommandList.injectPressure(x, y, radius, density_delta,
  radial_momentum, steps)`): `density_delta` and `radial_momentum` are per
  lattice cell over the open disc; the total (× π r² in lattice cells) is
  fixed and shared among the fluid cells actually inside the disc with
  integer weights 1 + 255(1 − (d/r)²) (a counting pass sums them with
  integer atomics, then each step adds its share as Δf_i = w_i(Δρ + 3 e_i·Δm),
  which adds exactly that mass and momentum). A confined blast therefore
  concentrates. Density is capped at rho_max per cell. Up to 64 active
  injections; multi-tick injections continue across ticks.
- **Explosion** (`CommandList.explosion(x, y, radius, strength)`):
  density 1.5 × strength, momentum 0.15 × strength, over 4 steps. Strength
  barely changes the reach beyond 1 because the clamps saturate; radius
  matters more.
- **Buoyancy**: per lattice cell, upward force 2e-6 per temperature byte
  of the block's mean above ambient (byte 7, 20 °C), only for ≥ 2 bytes
  above. Cold air gets no force: unpainted cells are temperature 0
  (−40 °C) and made every tile in the window sink and stay awake.
- **Gas mass**: `air_gas_created(px, material)` adds `AIR_GAS_CELL_MASS`
  (0.5 of a lattice cell of ambient air) for `feeds_air` materials,
  `air_gas_removed` subtracts it. The reaction pass (M3, other branch) must
  call them; nothing on this branch creates gas, so the sealed-room test
  emulates the lava + water reaction from the CPU (steam puff + injection
  with zero momentum, 1.2 mass per tick).
- **Vents**: the open window edges and their sponge band (decision 71).
  World-generated vent cells are not implemented.

**Alternatives**: deriving gas mass from per-block gas counts each tick
(gas moving across block boundaries made strong fake pressure noise, and a
moving pixel cannot be told apart from a created one); set-point
overpressure for explosions (a corridor would get no stronger than the
open).

**Consequences**: 0.5 per steam pixel is a guess; a real lava/water
interface may throw water (phreatic blast) once the reactions call it.
Tune `AIR_GAS_CELL_MASS` then.
