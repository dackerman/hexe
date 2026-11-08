# SDL3 through build-system translate-c

**Context**: SDL3 3.4 is installed system-wide; Zig 0.17 moves C imports to
the build system.

**Decision**: `src/platform/sdl_c.h` includes `SDL3/SDL.h` and
`SDL3/SDL_vulkan.h`; `build.zig` runs `b.addTranslateC` on it and exposes the
result as the `sdl` module linked with system `SDL3`. Only
`src/platform/window.zig` (and the key constants in `src/app.zig`) use it.
Vulkan handles cross the boundary with `@ptrCast` / `@enumFromInt`.

**Alternatives**: `@cImport` (deprecated direction), hand-written externs
(the event union layout is error prone).

**Consequences**: the translated module is cached by the build; SDL header
upgrades are picked up automatically.
