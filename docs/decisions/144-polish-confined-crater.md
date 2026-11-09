# Polish: a sealed crater dilutes its overpressure as it grows

**Context**: decision 133: a confined charge in stone kept breaking rock
for hundreds of ticks (a crater 500 px wide ate the walkway), so the level
carved its pressure corridor and open field in bedrock. Re-tested after
decision 107's pending store (the task's first question): still there, and
worse than reported. `air-test` (new check) and
`playtests/corridor_crater.hexe`: the standard blast charge (explosion r 6,
strength 1) in a 400 px, 3 px corridor through a 400 x 200 block of plain
stone breaks 7986 stone cells by tick 30, 41042 by tick 60 and 77339 (the
whole block but the corridor's rim) by tick 120.

Cause: stone is loaded by the wall load, which counts a face with no fluid
behind it as ambient one cell behind (static overpressure loads a face; the
steam room's wood wall relies on that). Stone chips above 0.4
overpressure. When the blast broke a stone cell into gravel, the lattice
cell opened (powder is not a wall) and decision 107 started it at its fluid
neighbors' mean density with no debt ("rock that opens starts at the
mean"). So every broken layer added air at the crater's pressure: the
sealed crater grew while keeping its overpressure, its wall load never
fell, and it kept breaking the next layer, about one lattice cell per
tick, for as long as there was stone.

**Decision** (`shaders/sim/air/prep.comp`): a lattice cell that opens
after the blast effects damaged it (node bit NODE_BLASTED) starts at
ambient density (1.0), not at the mean. Rock dug by a command or burnt
still starts at the mean (a pressurized room that is dug into keeps its
pressure, decision 107). Physically: the broken rock's volume joins the
crater at ambient pressure, so the pocket's pressure drops as it grows
(Boyle) and the crater stops once its wall load is under stone's
threshold. Trapped overpressure that does not break anything still stays
(no decay toward ambient), and static overpressure still loads thin walls
(the steam room).

**Measured** (ReleaseFast):
- `air-test` "confined charge" (new): before 7986 / 41042 / 77339 /
  77346 / 77346 stone cells broken at ticks 30 / 60 / 120 / 300 / 600; now
  128 at every one of them (0 growth after tick 60; the check allows 16).
- Open air (a charge on a stone floor and one beside a 20 px stone pillar,
  scratch playtest): 8 stone cells broken before and after: open blasts
  are unchanged.
- `air-test` otherwise identical to decision 107's numbers: corridor 152
  px vs open 40 px (3.80x), sealed steam room's wood wall breached at tick
  163 with the stone wall intact, flood harness 1.9323 at 3/4 full and
  2.6671 drained (Boyle 2.6667), 0 blast ejects in the quiet scenes.
- `playtests/gunpowder_ignite.hexe` (414 gunpowder cells on a stone
  floor): the crater under the pile was 1122 gravel cells at tick 61 with
  decision 141 alone, now 120.

**Alternatives**: decay toward ambient for sealed pockets (unphysical:
trapped overpressure stays); a per-cell damage cooldown (only slows the
growth); requiring a pressure gradient across the solid instead of static
overpressure on a face (stone faces backed by rock would never be loaded,
and the wood wall test of the steam room depends on static load); a debt
for blasted rock (decision 107 rejected debts paid where the hole is: a
crater sealed later becomes a vacuum).

**Consequences**: confined charges in stone now make small craters; the
level's corridor and field could go back to stone (left in bedrock).
Blasts that open a pressurized room create the new cells' air at ambient,
a little less air than before.
