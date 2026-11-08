# Material schema additions

**Context**: Several behaviors in 03-materials.md and 04-fluids.md had no
field in the schema: steel "dent, ricochet" against a single-valued
`.impact`; stone blasting to gravel and concrete to rubble; glass raising a
pressure event; smoke blocking light; water extinguishing burning cells
(burning is a flag, not a material, so a pair reaction cannot express it);
steam adding mass to the air field; bedrock as connectivity anchor;
charcoal burning hotter; gunpowder appending an event on ignition; the
entity contact table.

**Decision**: Added, all defaulting to "not in this class":
`.id`, `.ricochet` (bool, alongside `.impact`), `.rubble` (break/chip
product, null = itself), `.pressure_event` (threshold, from 04-fluids),
`.blocks_light`, `.extinguishes`, `.feeds_air`, `.anchor`,
`.flammable.heat` (°C per tick while burning), `.flammable.event`, and
`.on_contact` fields `slow` (fraction removed), `drown`, `buoyant`, `burn`
and `corrode` (hp/s), `ignite`, `extinguish`, `wet`, `strip_armor`,
`oily`, `slippery`, `blind`, `bloody`. Event ids: `none = 0`,
`explode = 1`, `pressure = 2`. The schema block of 03-materials.md was
updated to list them (minimal edit, factual fix). Phase-specific fields
are rejected on the wrong phase (`slide` only on powders, `dispersion` on
liquids and gases, `solver = .flip` on liquids) to catch copy-paste errors.
Gunpowder ignition via flame is also a reaction (`gunpowder + flame →
smoke`, event `explode`) besides the heat path, to exercise the reaction
event field.

**Alternatives**: Encode multiple impacts as a list (`.impact = .{ .dent,
.ricochet }`) — breaks the spec's scalar spelling. Hard-code bedrock and
water by name in shaders — the project rule is that behavior is data.

**Consequences**: The GPU struct carries these as fields or flag bits.
Entity contact is CPU-only and not in the GPU table.
