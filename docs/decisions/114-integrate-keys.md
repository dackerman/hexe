# Integration: sandbox key bindings

**Context**: the merged branches bound the same keys: main had F5 = world
save, F3 = air overlay, E = explosion and E (hold) = water spray, X =
eject and X = wood crate (a clash already on main); render added Tab
overlays, F5 light mode, F6-F8, T torch; liquid added L (solver on/off),
P (pour) and F3 (liquid overlay).

**Decision**:
| key | action | from |
|---|---|---|
| 1-9 / 0 | palette material / ignite brush | reactions |
| E | explosion at the cursor (game/explode.zig) | air |
| X | eject (cells fly) at the cursor | particles |
| Q / R (hold) | spray sand / water particles | particles (water moved from E) |
| C / Z / V / B | concrete crate / wood crate / slab / beam | bodies (wood moved from X) |
| Tab, Shift+Tab | cycle debug overlays | render |
| F2 | activity tiles overlay | render |
| F3 | air pressure overlay on/off | air (now an overlay mode) |
| F4 | lighting mode | render (moved from F5) |
| F5 | world save | stream |
| F6 / F7 / F8 / T | probe spacing / bloom / vignette / torch | render |
| L / P | liquid solver on/off / pour water | liquid |
| F1, F12, space, period, wheel, =/-, WASD | as before | |

The liquid overlay is Tab's liquid_particles mode (`--liquid-overlay`).

**Alternatives**: chorded keys (Shift+F5) for one of the F5 users; F5 is
the conventional quicksave key, so the save keeps it.

**Consequences**: docs/decisions/26, 56, 99 and 103 name the old keys;
this file wins where they disagree. The HUD hint lines list the new set.
