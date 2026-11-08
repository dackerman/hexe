#version 460
// World-anchored HUD text (floating signs): one quad per glyph, positioned
// in window pixels by the CPU (src/render/hud.zig printWorld). No vertex
// buffers: 6 vertices per glyph from a host-written buffer.
#include "common.glsl"

layout(location = 0) out vec2 v_local;
layout(location = 1) flat out uint v_glyph;

layout(push_constant) uniform PC {
    uint glyph_slot; // buffer: 4 words per glyph: x, y, char, rgba8 color
    uint font_slot;
    uint scale;
    uint pad;
    vec2 extent;
} pc;

HEXE_BUFFER(GlyphWords, readonly, uint words[];, g_glyph_words);

const vec2 corners[6] = vec2[](vec2(0, 0), vec2(1, 0), vec2(0, 1), vec2(1, 0), vec2(1, 1), vec2(0, 1));

void main() {
    uint gi = uint(gl_VertexIndex) / 6u;
    vec2 c = corners[uint(gl_VertexIndex) % 6u];
    vec2 origin = vec2(int(g_glyph_words[pc.glyph_slot].words[gi * 4u]), int(g_glyph_words[pc.glyph_slot].words[gi * 4u + 1u]));
    vec2 size = vec2(7.0, 9.0) * float(pc.scale); // 6x8 cell + 1 px drop shadow
    vec2 pos = origin + c * size;
    v_local = c * vec2(7.0, 9.0);
    v_glyph = gi;
    gl_Position = vec4(pos / pc.extent * 2.0 - 1.0, 0.0, 1.0);
}
