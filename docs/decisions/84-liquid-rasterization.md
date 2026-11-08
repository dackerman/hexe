# Liquid rasterization: two claim rounds, no upward choice, hole compaction

**Context**: one particle per pixel; the spec says the second particle in a
pixel is pushed to the nearest free pixel and merged if none is free for
several ticks. The first version (random free 8-neighbor) pumped energy.

**Decision** (`claim.comp`, `drop.comp`):
- Lift (start of the tick): each particle that owns a pixel turns it back
  into air (keeping its temperature, which heat may have changed). If the
  cell is no longer its own particle-backed cell of its material, another
  pass changed it (reaction, command, erase) and the particle dies. This is
  the reactions coupling: no delete list shared between passes.
- Round 0: every particle claims its own pixel if free; lowest index wins.
- Round 1 (losers): the nearest free pixel within radius 2 that is not
  behind a wall, same row or below before above at each radius; failing
  that, the first free pixel straight up through liquid within 32 (the
  surface). Winners move to the pixel center. Losers count overlap ticks and
  are merged (deleted) after 15.
- Why not upward by choice: relocating particles up into free pixels
  whenever two shared a pixel lifted them against gravity every tick; a
  resting pool heaped into a mound and boiled at 30-120 px/s. Going up only
  when nothing beside or below is free (real compression) conserves volume
  without the pump.
- Hole compaction: a slow (< 64 px/s) liquid particle with a free pixel
  directly below moves into it, decided against the pre-move cells (each
  hole has one candidate). Holes rise like bubbles; resting water packs to
  one particle per pixel the way cellular water would.
- Gas pixels count as free: a particle claiming one overwrites the gas.

**Measured** (pool scenario, 3360 cells poured): merges went from 410
(12%) with 8-neighbor search and 7-tick merges to 20 (0.6%). Dam break keeps
99.3% of its water over 900 ticks.

**Consequences**: a particle that is unclaimed in the tick the solver is
switched off (flush) is dropped. Rasterized cells take the material's
initial state byte; the state byte is not carried by particles.
