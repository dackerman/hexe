# Material id assignment

**Context**: The cell format stores a material id in 8 bits; the loader has
to turn names into ids. 03-materials.md says air is 0 and nothing else.
Sorting by name is simple but adding `clay.zon` would shift every id after
it, which silently corrupts a live world on hot reload and any saved chunk.

**Decision**: Air is 0 and built in (a file named `air.zon` is an error).
A material file may set `.id = N` (1–255); explicit ids are taken first and
must be unique. Files without `.id` get the lowest free ids in name order.
The shipped files all carry explicit ids equal to their name-sorted order
at the time of writing (acid = 1 … wood = 30), so the two rules agree today
and a new file without an id takes the next free slot without moving
anything. Unused ids in the GPU table hold an inert magenta/black
placeholder flagged `missing`. A hot reload reports `ids_changed` when any
material of the previous set is gone or moved.

**Alternatives**: Pure name order (rejected: unstable under additions).
Mandatory explicit ids (safe, but noisy for quick experiments). A content
hash of the name (collisions in 8 bits).

**Consequences**: Ids are stable as long as nobody edits `.id`. Renaming a
material keeps its id if the file keeps `.id`. Saves and the GPU agent can
rely on the id list in `docs/materials.md`. Widening the id to 10 bits
later only changes `max_materials` and the table sizes.
