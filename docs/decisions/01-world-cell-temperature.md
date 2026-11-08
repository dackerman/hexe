# Ambient temperature byte and world cell helpers
**Context**: The cell format stores temperature as a byte t with °C = 8·t − 40.
Ambient 20 °C falls between t = 7 (16 °C) and t = 8 (24 °C), and procgen has to
write some value into every cell. `src/sim/cell.zig` does not exist yet.
**Decision**: Ambient is t = 8 (24 °C): `celsiusToByte` rounds to nearest with
ties up, so 20 °C → 8. Lava spawns at 1100 °C → t = 143 (1104 °C). The world
layer has its own `src/world/cell.zig` (pack/unpack, flag bits, conversions)
with the exact bit layout of docs/01; the integrator dedupes it against
`src/sim/cell.zig`. Procgen also writes the initial state byte (health) from
the docs/03 table: stone 200, concrete 180, steel 255, wood 120, others 0
(`procgen.SpawnState`, overridable by the caller until the material loader
provides it).
**Alternatives**: t = 7 (16 °C, rounds down); a per-material spawn
temperature table in procgen (deferred to the material loader).
**Consequences**: 4 °C warmer than nominal ambient; water is 76 °C from
freezing and 76 °C from boiling in byte terms, which is fine. When the
material loader lands, spawn temperature and state should come from it and
`SpawnState` goes away.
