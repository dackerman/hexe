# Gas advection as paired discrete swaps

**Context**: gas cells should move with the air instead of only the random
rise rule, deterministically, without touching the Margolus shader, and
not at all when the air field is off.

**Decision**: a separate pass in the substep slot, before movement, over
last tick's active air tiles. Substep s pairs every pixel with its
neighbor along x (even s) or y (odd s), the pair parity flipping every
second substep, so pairs are disjoint (no races, any dispatch order). A
(gas, air) pair swaps when the air velocity at the gas pixel points from
the gas to the air, with probability |v_axis| × 0.5 (v in px/tick): each
pixel gets two chances per direction per tick, so gas follows the air at
its speed up to 2 px/tick (120 px/s), beyond which it saturates. Only
non-air gas with air; particle and body cells never move. Randomness:
`hash(x, y, tick, substep ^ salt)`. Changed tiles are marked. The Margolus
gas rules still run (buoyant rise and spread on top of the drift).

**Alternatives**: semi-Lagrangian back-tracing per gas cell (needs a
gather that can duplicate or lose cells); folding it into movement.comp
(the reference grid would need the air field).

**Consequences**: gas speed caps at 2 px/tick; strong blasts move smoke
less than the air. The determinism scene runs with the air field off, so
neither the CPU reference nor `verify-determinism` sees this pass. With
the air on, results are still bit-reproducible run to run on one GPU.
