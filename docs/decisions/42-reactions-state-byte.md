# The state byte per class, and electric charge

**Context**: the cell has one 8-bit state field (docs/01) and the flags
nibble is full (burning, moved, particle-backed, body-owned). Health,
lifetime counts (decisions/05), health-less burn fuel, boil progress and
electric charge all want it.

**Decision**: what the state byte holds, by material:

| material has | state byte | written by |
|---|---|---|
| health (wood, stone, steel...) | health; burning consumes it as fuel | `state_init`, damage (later), burning |
| lifetime (flame, smoke, steam, mud, blood) | lifetime count, one step per `lifetime_period` ticks | `state_init`, reactions pass |
| flammable, no health (oil, gunpowder) | 0, then `burn_fuel` from ignition | ignition, burning |
| a boil rule (water) | ticks held at the boil point | reactions pass |
| conductive (water, steel, molten steel) | bits 0-5: the above; bits 6-7: charge phase | as above; charge rule |

- **Charge** is a pulse (a Wireworld-like excitable medium): phase 3 =
  head, 2 and 1 = refractory tail, 0 = idle. Every substep a charged cell
  steps 3 -> 2 -> 1 -> 0, and an idle conductive cell with a conductive
  neighbor at 3 becomes 3. A pulse therefore runs through any connected
  conductor at one cell per substep (8 per tick) and never runs back.
  `CMD_ACTION_CHARGE` (CommandList.chargeCircle) starts a pulse in the
  conductive cells of a shape; a continuous source is a charge command
  every tick (or every few). A cell is "charged" while its phase is
  nonzero (`cell_charge(c) != 0`); gameplay (M9) reads that from the
  readback strips to shock entities.
- The loader rejects conductive materials whose health, lifetime count or
  burn fuel exceed 63, and boil rules together with health or lifetime;
  steel's health became 63 (decisions/40).

**Alternatives**: charge in the burning flag of non-flammable materials (one
bit: no refractory state, pulses would echo forever); a wider cell (format
change everywhere); a separate charge image (16 MB and another pass).

**Consequences**: health granularity for conductive materials is 0-63. Any
code that writes a conductive cell's state must keep bits 6-7
(`CONDUCTIVE_STATE_MASK`). Charge is not yet a heat or damage source.
