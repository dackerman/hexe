# Shader build: glslc per file, depfiles, generated `shaders` module

**Context**: shaders must compile in `build.zig` and an edit to any shader or
include must rebuild.

**Decision**: `build.zig` lists every shader in `shader_sources`. Each runs
`glslc -O --target-env=vulkan1.3 -std=460 -Werror -I shaders -MD -MF <dep>`;
the depfile makes edits to `common.glsl` and other includes rebuild exactly
the dependents. Outputs are copied into one generated directory with a
generated `shaders.zig` exposing `pub const <path_with_underscores>
align(4) = @embedFile(...)`, imported as the `shaders` module
(`&shaders.sim_grid_movement_comp`). `zig build shaders` compiles all and
installs the `.spv` files under `zig-out/shaders/`. The raw `common.glsl` is
also embedded (`common_glsl`) for the CPU mirror test.

**Alternatives**: one glslc call over a directory glob (no per-file
dependency tracking), runtime compilation.

**Consequences**: adding a shader is one line in `shader_sources`.
Warnings fail the build.
