#version 460
// HUD text: a grid of characters from a host-written buffer, drawn with an
// embedded 5x7 bitmap font (src/render/font.zig) in 6x8 cells, scaled by an
// integer factor, over a translucent box. Blended over the world.
#include "common.glsl"

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 o_color;

layout(push_constant) uniform PC {
    ivec2 origin; // framebuffer pixel of the HUD's top-left corner
    uint cols;
    uint rows;
    uint scale;
    uint text_slot; // buffer slot: one uint per character, row major
    uint font_slot; // buffer slot: 2 uints per glyph (8 rows of 8 bits), ASCII 32..127
    uint pad;
    vec4 fg;
    vec4 bg;
} pc;

HEXE_BUFFER(HudWords, readonly, uint words[];, g_hud_words);

#define GLYPH_W 6
#define GLYPH_H 8

void main() {
    ivec2 p = (ivec2(gl_FragCoord.xy) - pc.origin) / int(max(pc.scale, 1u));
    ivec2 cell = p / ivec2(GLYPH_W, GLYPH_H);
    if (any(lessThan(p, ivec2(0))) || cell.x >= int(pc.cols) || cell.y >= int(pc.rows)) discard;
    uint ch = g_hud_words[pc.text_slot].words[cell.y * int(pc.cols) + cell.x];
    ivec2 g = p - cell * ivec2(GLYPH_W, GLYPH_H);
    bool on = false;
    if (ch >= 32u && ch < 128u && g.x < 5 && g.y < 7) {
        uint glyph = ch - 32u;
        uint word = g_hud_words[pc.font_slot].words[glyph * 2u + uint(g.y >> 2)];
        uint row = (word >> (uint(g.y & 3) * 8u)) & 0xffu;
        on = ((row >> uint(4 - g.x)) & 1u) != 0u;
    }
    o_color = on ? pc.fg : pc.bg;
}
