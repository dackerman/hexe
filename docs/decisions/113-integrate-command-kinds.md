# Integration: one command encoding

**Context**: reactions encoded `kind = shape | action << 8` (circle 1,
rect 2; fill, ignite, heat, charge) with temperature/state overrides in
`flags` bits 16-31; particles added flat kinds fill_line 3, spray 4,
set_temperature 5, ignite 6, eject 7, inject_charge 8 (no effect) and air
inject_pressure 9, with the line radius in `flags` bits 16-31; the liquid
solver added wake_liquid 32.

**Decision**: reactions' shape x action encoding, which is the more general
one (any action on any shape) and is mirrored bit-exact in the CPU
reference:
- shapes (bits 0-7) circle 1, rect 2, line 3 take actions (bits 8-15)
  fill 0, ignite 1, heat 2, charge 3;
- spray 4, eject 7, inject_pressure 9 and wake_liquid 32 keep their ids
  with action 0;
- 5, 6, 8 are retired, not reused: `setTemperature`, `igniteCircle`,
  `chargeCircle` push circle | heat / ignite / charge. inject_charge now
  starts reactions' charge pulse (one encoding);
- the line radius moved from `flags` 16-31 (which carry the temperature
  and state overrides) to `material` bits 16-31.

**Alternatives**: keep the flat kinds and add a kind per (shape, action)
(13 kinds for what one byte expresses).

**Consequences**: any action works on lines and rects too. Code that built
kind 5/6/8 by number breaks; nothing outside commands.zig did.
