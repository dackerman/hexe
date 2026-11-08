# --world mode, material mapping, save on quit and F5
**Context**: The world needs a startup path, material ids from the table,
a camera in unbounded world coordinates and save/load.
**Decision**: `src/world_mode.zig` `Session` owns `Store`, `Prefetcher`,
`Streaming`; `--world [--seed N] [--save DIR]` in the app and headless.
Material ids come from `Table.byName`; missing names fall back to stone with
one warning listing them (the builtin table has 5 materials, so dirt, wood,
steel, concrete, bedrock, gravel, moss, gunpowder, oil and lava are stone
until the ZON loader lands). procgen now keeps lava cold when it aliases
stone. The camera is no longer wrapped in world mode; the renderer already
maps world → window with `wrap_coord`, so it is unchanged. Spawn: x = 0,
40 cells above the surface. `--save DIR` loads `world.zon` (its seed wins)
or creates it; F5 and quit run `Streaming.flush` + `Store.save`. Headless:
`--cam-path "X,Y -> X,Y over N ticks"` paced at 60 ticks/s (`--no-vsync`
unpaces), `--world-edit X,Y,R,MAT`, `--probe X,Y`, `--world-selftest`
(`zig build stream-test`). Command-spawned cells keep their hashed variant
rather than `baseVariant` (that would change commands.comp and the CPU
reference); edited pixels compress slightly worse.
**Alternatives**: a scene enum entry (scenes are pure command emitters);
wrapping the camera (breaks world coordinates for gameplay).
**Consequences**: at zoom 1 on a window wider than ~1700 px the view sees
past the 2048 window and shows wrapped chunks; keep zoom ≥ 2 or grow the
window. Gameplay uses `Session.worldToWindow`, `windowToWorld`,
`isResident`, `markDirty`, `save`.
