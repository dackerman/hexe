# `--air-test` stands in for the scenario runner on scenarios 3 and 4

**Context**: `zig build scenarios` (reactions branch) and the M3 materials
(wood, lava, steam, bedrock) and reactions are not on this branch.

**Decision**: `src/air_test.zig`, run by `zig build air-test` (ReleaseFast)
or `hexe --headless --air-test [--screenshot DIR] [--air-all-active]`,
builds both setups in code with a test material table (builtin + wood,
`wood_weak` = wood at health 1, lava, steam, bedrock, a blast-immune
pressure plate with glass's `pressure_event` 30):
- Sealed room: geometry of sealed_steam_room.zon; the lava + water
  reaction is emulated (decision 74). Pass criteria: room mean density
  (256² field readback) monotonic over ticks 1-120 and > 1.02 at 120; the
  wood wall **breached** (≥ ¼ blown out) before any stone of the right wall
  is lost; right wall intact at the end; the plate reports a pressure
  event. "None wood left" from the .zon is not asserted: once breached the
  room vents and the pieces between the holes stay until connectivity (M7).
- Corridor blast: corridor as in corridor_blast.zon (3 px, closed 8 px
  behind the blast) vs an open floor, 2x3 sand plugs every 8 px from 16 to
  392 px; asserts corridor reach ≥ 2 × open and the .zon's six plug
  assertions.

**Consequences**: when the scenario runner lands, the .zon files should run
as is except the "wood none" assertion (see above) and the steam source
(real reactions). Delete or keep the harness as a fast air regression.
