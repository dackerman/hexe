#version 460
// World-anchored HUD text: the HUD's 5x7 font (src/render/font.zig) with a
// one-pixel drop shadow, alpha blended over the composited frame.
#include "common.glsl"

layout(location = 0) in vec2 v_local;
layout(location = 1) flat in uint v_glyph;
layout(location = 0) out vec4 o_color;

layout(push_constant) uniform PC {
    uint glyph_slot;
    uint font_slot;
    uint scale;
    uint pad;
    vec2 extent;
} pc;

HEXE_BUFFER(GlyphWords, readonly, uint words[];, g_glyph_words);

bool glyph_on(uint ch, ivec2 g) {
    if (ch < 32u || ch >= 128u || g.x < 0 || g.y < 0 || g.x >= 5 || g.y >= 7) return false;
    uint word = g_glyph_words[pc.font_slot].words[(ch - 32u) * 2u + uint(g.y >> 2)];
    uint row = (word >> (uint(g.y & 3) * 8u)) & 0xffu;
    return ((row >> uint(4 - g.x)) & 1u) != 0u;
}

void main() {
    uint ch = g_glyph_words[pc.glyph_slot].words[v_glyph * 4u + 2u];
    uint color = g_glyph_words[pc.glyph_slot].words[v_glyph * 4u + 3u];
    ivec2 g = ivec2(floor(v_local));
    if (glyph_on(ch, g)) {
        o_color = unpackUnorm4x8(color);
    } else if (glyph_on(ch, g - ivec2(1))) {
        o_color = vec4(0.0, 0.0, 0.0, 0.85);
    } else {
        discard;
    }
}
