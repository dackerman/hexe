# Vulkan bindings: vulkan-zig master, generated from the vendored vk.xml

**Context**: D2 picks vulkan-zig; the toolchain is Zig 0.17.1 and the
registry is vendored at `vendor/vulkan-headers/registry/vk.xml`.

**Decision**: `build.zig.zon` pins vulkan-zig master at commit
`8a0bc54894ed546ad1ecc4c072e0070cef022ee4` (fetched with
`zig fetch --save git+https://github.com/Snektron/vulkan-zig.git`). It builds
unmodified with 0.17.1. `build.zig` passes the vendored `vk.xml` as the
`registry` option and imports the generated module as `vulkan`. The loader is
opened at runtime with `std.DynLib.openZ("libvulkan.so.1")` and
`vkGetInstanceProcAddr` feeds `BaseWrapper.load`; nothing links against
libvulkan. Code uses the non-proxy wrappers (`ctx.vkd.cmdDispatch(cmd, ...)`).
Zig 0.17 extracts packages into a project-local `zig-pkg/`, now in
`.gitignore`.

Notes for everyone writing Vulkan code here: dispatchable handles
(`Instance`, `Device`, `Queue`, `CommandBuffer`) are non-optional pointers;
non-dispatchable handles are enums whose empty value is `.null`; flag fields
have no `_bit` suffix (`.{ .compute = true }`, `.{ .shader_storage_write = true }`);
`ApiInfo` lists live in `vk.instance_extensions` / `vk.device_extensions`.

**Alternatives**: translate-c of `vulkan.h` (no error sets, no slices, loses
type safety on flags); hand-declared externs (too much surface).

**Consequences**: a vulkan-zig master that breaks with a later Zig would
need the pin bumped together with the toolchain. Debug builds enable
`VK_LAYER_KHRONOS_validation` when installed; it is not installed on the dev
machine, so validation is currently silently skipped (install
`vulkan-validation-layers` to get it; `--validation` forces the request).
