# Gameplay: an info byte per cell in the region readback

**Context**: entity contact needs more than the material of the cells
around a character: electricity is a charge phase in the state byte of
conductive cells (decision 42), and "burning" is a cell flag. The readback
mirror delivered material bytes only (decision 52).

**Decision**: every requested region is read back as two planes of the same
shape: the material bytes, then an info byte per cell
(`shaders/sim/readback/region.comp` `cell_info`, `readback.Info`):
bit 0 charged (conductive material with a nonzero charge phase), bit 1
burning, bit 2 body-owned, bit 3 particle-backed. `Mirror.info(x, y)` reads
it; `Mirror.regionView(x, y, w, h)` returns a region containing a rectangle
for fast repeated lookups (an entity's collision and contact scan run
hundreds of lookups per tick). `readback.cellInfo` is the CPU definition;
the GPU mirror test compares both planes against a synchronous readback.

**Alternatives**: bit 7 of the material byte for "charged" (no space for
the other flags, and the loader allows ids up to 255); a whole-world
charge mask like the solid mask (512 KiB more per tick for a few entity
strips); reading the state byte (gameplay would need each material's
state layout).

**Consequences**: region bytes per request double (an entity strip of
48 x 67 is 6.4 KiB); readback stays 0.07 ms in `zig build bench`. The
body-owned bit is also what the bodies layer's TODO(MirrorSource) in
decision 119 asked for.
