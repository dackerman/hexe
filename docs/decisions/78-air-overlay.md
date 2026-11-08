# Air field debug overlay

**Context**: the render branch is adding a generic overlay compositor keyed
off `SLOT_IMG_DEBUG_OVERLAY`; this branch needed to see the field now.

**Decision**: when `Air.overlay` is set, a compute pass writes one RGBA8
texel per lattice cell: red = overpressure, blue = underpressure (|ρ−1| ×
4), green = speed (|v| px/tick × 1.5) with a faint direction tint, walls
dark grey, active air tile borders faint yellow; alpha = max channel.
`world.frag` adds it to the world color (world × 0.6 + overlay) behind
view flag bit 1. Toggles: F3 in the window, `--overlay air` headless
(screenshots too), `--screenshot-every N` for sequences.

**Alternatives**: sampling the float field directly in world.frag (couples
the render pass to the air format).

**Consequences**: the compositor can replace the world.frag hook; the image
stays. Costs ~0.01 ms when on, nothing when off.
