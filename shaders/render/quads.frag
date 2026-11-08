#version 460
// Sprite and debug-primitive batch. Sprites sample the RGBA8 atlas
// (nearest, sRGB colors), are tinted, and are lit by the same ambient and
// irradiance as the world when QUAD_FLAG_LIT is set; debug primitives are
// flat colors. Alpha blended into the scene image.
#include "common.glsl"
#include "render/render.glsl"

layout(location = 0) in vec2 v_uv;
layout(location = 1) flat in uint v_index;
layout(location = 0) out vec4 o_color;

layout(push_constant) uniform PC {
    uint frame_slot;
    uint quads_slot;
    uint atlas_tex;
} pc;

#define FR g_render_frames[pc.frame_slot].f
#include "render/shade.glsl"

void main() {
    QuadGpu q = g_quads[pc.quads_slot].q[v_index];
    vec4 c = q.color;
    if (q.kind == QUAD_SPRITE) {
        vec4 t = texelFetch(sampler2D(g_textures[pc.atlas_tex], g_samplers[SAMPLER_NEAREST_CLAMP]), ivec2(floor(v_uv)), 0);
        if (t.a < 0.5) discard;
        c.rgb *= srgb_to_linear(t.rgb);
        c.a *= t.a;
    }
    if ((q.flags & QUAD_FLAG_LIT) != 0u) c.rgb *= light_at(FR.camera + ivec2(gl_FragCoord.xy));
    o_color = c;
}
