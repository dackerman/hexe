# Integration: what is not unified yet

**Context**: integration items left for their owners, recorded so they are
not mistaken for done.

**Decision** (each is a named TODO):
- TODO(bodies TerrainSource -> Mirror): bodies still read terrain through
  `SyncReadback` (synchronous tile copies). The readback mirror's regions
  carry material bytes without the body-owned flag the bodies layer needs
  to tell its own cells from terrain, are served one frame after the
  request while bodies prepare in the same tick, and its solid mask counts
  static and body cells but not powders. A `MirrorSource` needs a flag
  byte in the region readback and a request one frame ahead.
- TODO(air events -> event queue): air pressure events keep their own ring
  (slot 26, `Air.events()`); they should be EVENT_PRESSURE in the one queue.
- TODO(liquid shared arrays): the solver's particles stay in its private
  arrays (decision 116).
- TODO(liquid body coupling): body boundary velocities (classify.comp sets
  u = 0 on closed faces), buoyancy and drag on bodies from the liquid,
  explosion impulses on liquid particles.
- TODO(air gas from commands): painting a feeds_air gas with a command does
  not add air mass (reactions do, via air_gas_created).

**Consequences**: none of these is a regression against the branches.
