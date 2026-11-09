# macOS Vulkan loader search path

**Context**: The native Apple Silicon build and CPU tests passed, but a
Homebrew-only runtime installation failed at startup with
`VulkanLoaderMissing`. macOS did not search Homebrew's library directory
when SDL loaded `libvulkan.1.dylib` by name.

**Decision**: Add an optional `-Dvulkan-prefix` build option. On macOS its
`lib/` directory becomes an executable runtime search path, including for
the test, verification, and benchmark executables. Document the Homebrew
build using the Vulkan loader's formula prefix, alongside `-Dsdl3-prefix`.

**Alternatives**: Set `DYLD_FALLBACK_LIBRARY_PATH` at launch, use the Vulkan
SDK's environment script, or hard-code Homebrew paths in the loader. The
SDK remains supported; explicit prefixes also cover nonstandard installs
without adding platform-specific installation paths to engine code.

**Consequences**: Homebrew builds can launch directly without environment
setup when built with both prefixes. The resulting executables depend on
those local installations; this does not create a distributable app bundle.
The native build, CPU tests, headless PNG output, and windowed startup were
checked on an Apple M3 Max with MoltenVK 1.4.2; full GPU regression testing
and performance qualification remain separate work.
