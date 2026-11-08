# HUD: hand-drawn 5x7 font, text grid in a buffer, fullscreen fragment pass

**Context**: M0 needed an on-screen HUD with no font dependency.

**Decision**: `src/render/font.zig` holds a 5x7 bitmap font for ASCII 32..127
drawn for this project as readable `#`/`.` strings, parsed at comptime into
2 words per glyph (lowercase reuses uppercase). `src/render/hud.zig` formats
lines with `bufPrint` into a fixed 100x24 character grid (no allocation),
copies it into the frame slot's host-visible buffer, and draws a fullscreen
triangle with `shaders/render/hud.frag`, which looks up the character and
glyph bit per fragment in 6x8 cells at 2x scale over a translucent box, alpha
blended over the world. The HUD shows frame ms, grid ms, active tiles, every
named GPU pass (smoothed), and tool state.

**Alternatives**: an existing public-domain 8x8 font array (would need to be
transcribed from memory or downloaded), stb_truetype (dependency, overkill).

**Consequences**: uppercase-only text. Debug text for other subsystems can
call `engine.hud.print` before `engine.frame`.
