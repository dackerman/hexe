# Air field: walls and sources move air through a rate-limited pending store

**Context**: decision 117 stopped walls of liquid or body pixels from
moving any air when they appear or disappear, because each change moved a
quarter cell of air into each neighbor at once and the blast effects read
that gradient as an explosion. The cost was the behavior docs/04-fluids.md
calls the most important: water flooding a sealed room no longer
compressed its air pocket. Measuring main with the harness checks below
showed that 117 had not removed all the fake blasts either: with the air on,
`lighting` threw 238 to 282 water pixels in 400 ticks (steam condensing
under the skylight pane: `air_gas_removed` took half a cell of air at once,
and the implosion threw the droplets and loaded the glass to 1.5x its
threshold), the `liquid_dam` dam break threw 203 (FLIP) or 845 (cellular)
pixels (removing the 1 px wood dam, a static wall, took a whole cell of air
from the one open neighbor), and in `bodies_slab` removing the pillar loaded
the floor stone to twice its threshold.

**Decision** (`shaders/sim/air/prep.comp`, `shaders/sim/air/pending.comp`,
`Air.Params.pending_cap`, `pending_settle`):
- **Pending store**: two r32ui images (int32 fixed point, AIR_MASS_ONE =
  one cell of ambient air, ping-pong). Prep books into it, per lattice cell,
  instead of moving air:
  - a cell that becomes a wall: + the air it covered (its density);
  - a liquid wall that opens: the cell starts at its fluid neighbors' mean
    density (within two cells if no 4-neighbor is fluid, so a bubble opening
    in a pressurized pocket does not start at ambient) and books that as a
    debt;
  - everything the grid passes put into AIR_SOURCE this tick (gas created
    or removed by reactions, `air_emit_mass`).
- **Release** (pending.comp, after prep, whole window, gather form: each
  cell evaluates the same rule for itself and its 4 neighbors and keeps
  what it is owed; integer shares, mass exact, deterministic):
  - an open cell lets at most `pending_cap` = 1/128 of a cell per tick into
    its own AIR_SOURCE (applied by the first LBM step) and diffuses a fifth
    of the rest to each open 4-neighbor;
  - a wall cell with open 4-neighbors passes all of it to them, equally;
  - a buried wall (no open neighbor) passes it to the soft wall above (air
    rises through a pool like a bubble), else equally to its soft
    neighbors.
  - Hysteresis: node bits 12-14 count ticks since the cell last changed
    between wall and fluid; a cell moves nothing until it has kept its
    state `pending_settle` = 4 ticks. A liquid surface or a falling stream
    that flickers books +rho, -rho, ... and nothing reaches the air.
  So no cell ever gets more than 1/128 of a cell of air per tick, whatever
  happens around it; a backlog spreads over more cells, which release more.
- **Exceptions**, which move no air: walls with body pixels (node bit 15,
  `NODE_BODY_WALL`; 117 stays for bodies), rock that opens (dug by a
  command, burnt, or blasted: it starts at the mean with no debt), and
  streamed-in chunks (cleared). The instant transfer of decision 71 is gone.
- Static walls go through the same store (the task assumed they could keep
  the instant transfer; the dam break above says no).
- Diagnostics: the effects pass records the highest load on any pixel with
  a blast threshold, loose and solid separately, in thousandths of that
  threshold (`Air.Stats.peak_fly_load`, `peak_solid_load`,
  `Air.max_fly_load`, `max_solid_load`), so harnesses check a margin, not
  just a zero count of a chaotic quantity. The pressure overlay draws
  pending air in green.
- Tuning (flood harness, peak loose load / blast ejects): cap 1/16: 45K
  ejects; 1/32: loads above the threshold near the end, a few ejects; 1/64:
  peak 0.86; 1/128: peak 0.31, room density within 4% of Boyle's law while
  the water pours in.

**Verification** (`zig build air-test`, all PASS):
- New: `air_flood` scene, a sealed 96x96 bedrock room half full of water
  fed through a 1 px pipe from a reservoir above (cellular water). With
  the store off (117): density 1.0000 at 80% full. With it: rises
  monotonically (2e-3 tolerance), 1.9323 at 3/4 full (tick 592; Boyle's law
  on the lattice's own open volume 2.0211), 2.6671 when the reservoir has
  drained (Boyle 2.6667), 0 blast ejects, peak loose load 0.31. Bedrock
  because stone correctly starts to chip at 0.4 overpressure (wall load
  (rho - 1) / 2 x 1000 > 200).
- New: blast ejects and peak loads over `lighting` 400 ticks,
  `bodies_slab` 500 (bodies on), `liquid_dam` 400 with FLIP and cellular:
  0 ejects each; peak loose / solid loads 0.28 / 0.30, 0 / 0, 0.53 / 0.14,
  0.25 / 0.04 (main: 238-282, 0, 203, 839-845 ejects).
- Unchanged checks: corridor 152 px vs open 40 px (3.80x); sealed steam
  room passes (wood breached at tick 163 instead of 139, peak 1.236 instead
  of 1.193, ~320 ejects instead of 611: real boiling now feeds the room
  smoothly). Same results with `--air-all-active`.
- Cost: pending pass ~0.006 ms (median `air.prep` 0.0179 -> 0.0245 ms with
  every tile active); all air passes, medians, bench_air every tile 0.236
  ms, active tiles 0.134 ms, static world 0.038 ms. 8 MB VRAM.

**Alternatives**: rate-limited release into the adjacent open cells only
(up to five releases land in one cell, so the cap had to be 1/64, and
without diffusion the pocket lagged Boyle's law by 15-25% while filling); releasing upward first (the debt of a
flickering body edge went up and out while its air went down into the gap
below: a pump); bodies through the store (a falling body carries the air
it displaced inside it and squeezes it into the cracks and the sealed
crater it lands on: the floor broke); a debt for rock that opens (paid
where the hole is, it emptied the pillar's crater once the slab sealed
it); hysteresis alone; masking blast effects next to walls that changed
(hides real blasts at every liquid surface).

**Consequences**: flooding compresses sealed pockets again (and water
draining out of one books a debt that expands it). Bodies still move no air (117), so a body entering a sealed
room does not compress it; reopen if that matters (bodies would need their
displaced air handed to the cells they uncover in the same tick). Air
appears over a few ticks instead of at once (a stone wall painted into a
room raises its pressure gradually). Rock that opens creates its
air (a pressurized room that is dug into keeps its pressure). Gas mass from
reactions is rate-limited too: a steam burst raises pressure smoothly, no
phreatic blast (decision 74's speculation). Supersedes decision 71's
"walls appearing and disappearing" and 117's soft-wall rule. Node word
bits 12-15 are taken.
