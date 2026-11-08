# Chunk compression: RLE over u32 with variant XOR
**Context**: Chunks leaving the window are kept compressed in RAM and saved
to disk. Every cell carries 4 variant bits that are a per-pixel hash, so
plain RLE over u32 would see no runs at all.
**Decision**: Before run-length coding, each cell's variant is XORed with
`hash.baseVariant(world_x, world_y)`, the exact variant procgen assigns.
Unmoved pixels then have variant residual 0 and form long runs; pixels that
moved keep their own variant losslessly. Air (material 0) is special: its
variant is dropped on encode and decodes to the base variant, since air has
no visual and dug-out air should compress whatever variant the GPU left.
This is the only lossy part. Blob format: one format byte, then
`1 = rle`: pairs of (LEB128 run length − 1, u32 LE transformed value)
covering exactly 65536 cells, or `2 = raw`: 65536 u32 LE transformed values,
chosen when RLE would be larger than raw. The decoder rejects truncated,
overlong or trailing data. No deflate: a pristine chunk is tens of bytes and
an edited one a few KiB; deflate would cost CPU in the eviction path for
little gain.
**Alternatives**: plain u32 RLE (useless with variant noise); byte-plane RLE;
RLE + `std.compress.flate` (available in 0.17, could be added on disk only).
**Consequences**: The GPU should give newly spawned non-air cells
`baseVariant` of their spawn position (window → world needs the origin) so
they compress well too; any other choice is still correct, just larger.
Changing `baseVariant` changes the on-disk format: bump the save version.
