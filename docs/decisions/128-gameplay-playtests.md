# Gameplay: headless scripted playtests

**Context**: gameplay has to be looked at (docs/08 "Visual checks"), and
there is no way to press keys in a headless run.

**Decision**: `--script FILE` (`src/game/playtest.zig`) runs a text
script headless with bodies, air and (by default) the liquid solver on:
`scene`, `spawn`, `ticks`, `zoom`, `liquid on|off`, `air on|off`, then
`at T VERB ...` lines: hold / release / tap a key, tool N, aim X Y,
aimrel DX DY (from the witch), aimenemy DX DY, fill / circle / ignite /
charge / explode, enemy KIND X Y, center X Y | player, shot NAME (view
screenshot with sprites and the game HUD to PREFIX-NAME.png), census X Y
W H (material count by synchronous readback), help, note. The game log
is echoed with tick numbers and every shot prints the witch's and the
enemies' state. Scripts live in `playtests/`: walk, firebolt, blast,
extinguish, walker_death, flyer_blast, lightning_water, swim, hazards,
lighting_cave.

**Alternatives**: a binary input recording (unreadable, breaks with every
tuning change); built-in Zig scenarios only (less handy for the level).

**Consequences**: not a pass/fail suite: the shots are looked at and the
printed state read. Runs are not bit-reproducible (the GPU ballistic pass
and the mirror's latency vary).
