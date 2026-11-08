# PNG encoder: stored deflate blocks

**Context**: headless screenshots need PNG output.

**Decision**: `src/util/png.zig` writes 8-bit RGBA, filter 0, and a zlib
stream of stored (uncompressed) deflate blocks with Adler-32, chunk CRC-32
from `std.hash`. It encodes into a caller-sized buffer (`encodedSize`). The
unit test inflates the output with `std.compress.flate` and compares.

**Alternatives**: `std.compress.flate.Compress` (new in this std, smaller
files, more to go wrong), filtering + compression for smaller files.

**Consequences**: a full 2048x2048 capture is ~16 MB. `--crop` keeps
screenshots small. Switch to the std compressor if file size starts to
matter.
