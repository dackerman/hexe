# Polish: every ignition of gunpowder sends its explode event, once

**Context**: decision 43 appends a material's `burn_event` when the
reactions pass ignites it (by heat or by contact with fire). The ignite
command (`CMD_ACTION_IGNITE`: the fire bolt's impact, the flyer's spit,
the lightning bolt, scripts) sets the burning flag directly, so a cell it
lit was already burning when the reactions pass saw it and never sent the
event: it burnt to smoke without exploding. Decision 133 heated the level's
corridor charge past ignition to work around it.

**Decision**:
- `commands.comp`: an ignite command that lights a cell whose material has
  a `burn_event` appends it (payload: the material), like the reactions
  pass's ignition. Mirrored in the CPU reference (`applyCommand`).
- `reactions.comp`: burning out into a flammable product that starts
  burning is an ignition too: it sends the product's `burn_event` (no
  material uses it today; mirrored).
- Once per cell: a cell that is already burning does not send the same
  event again from a pair reaction (gunpowder + flame -> smoke with
  `.event = .explode`). Ignition (heat, contact, command, burn-out) only
  ever happens to a cell that is not burning, so each gunpowder cell sends
  exactly one explode event whichever way it is lit. Mirrored.
- Chains: `Explosions.drain` turns each EVENT_EXPLODE into `explode()`
  (decision 115) plus an ignite command of radius 12 (`event_fireball`):
  the fireball lights flammables around it, so a pile next to an exploding
  one goes up (its cells send their own events). Only material-event
  explosions do this; the blast charge and scene explosions do not ignite.
- `determinism_commands` lights a gunpowder patch with the ignite command,
  so verify-determinism compares the new events (40 explode events, GPU and
  CPU match).

**Measured** (ReleaseFast, playtests, census readbacks):
- `playtests/gunpowder_ignite.hexe` (414 gunpowder cells lit at once by an
  ignite command, the level's old corridor charge): main: the pile burns
  to smoke, 35 cells of the stone floor below turn to gravel, the witch
  70-100 px away takes no damage; now: the pile explodes, a V crater
  (1122 gravel of 3300 stone cells under it), debris thrown 100+ px, the
  witch knocked back (vx -134 px/s) and hurt (hp 85).
- `playtests/gunpowder_firebolt.hexe` (fire bolt into one of two 30 x 14
  piles 10 px apart): main: the bolt's own ignite disc fizzles and the rest
  goes up by contact; most of the second pile is scattered, not lit (276
  gunpowder cells left in the area at tick 200). Now: both piles go up
  (110 left, most of them thrown before the fireball reached them), the
  witch at 60 px is knocked back (vx -300) and hurt (hp 66).

**Alternatives**: having the ignite command heat flammables past ignition
instead of setting the flag (one ignition path, but the command would also
heat everything it touches); a chain by heat only (gunpowder burns for one
tick: too little heat reaches the next pile before the blast scatters it).

**Consequences**: a gunpowder pile is now as strong as its cell count
(one standard blast per cell, at most 64 per tick through the drain):
large piles make large craters (decision 144 measures the crater rule).
The level's corridor charge no longer needs to be heated to explode (kept,
it is harmless). Payload and position of the command's event follow the
reactions pass's convention.
