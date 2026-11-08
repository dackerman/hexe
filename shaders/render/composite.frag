#version 460
// Final pass at window resolution: integer upscale of the scene image (each
// world pixel covers `scale` x `scale` fragments, nearest), bloom added
// (bilinear), exposure, hue-preserving filmic tone map, vignette, sRGB
// encode.
#include "common.glsl"
#include "render/render.glsl"

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 o_color;

layout(push_constant) uniform PC {
    uint frame_slot;
    uint scene_tex;
    uint bloom_tex;
    uint scale;
    uvec2 extent;
} pc;

#define FR g_render_frames[pc.frame_slot].f

// ACES filmic fit (K. Narkowicz).
float aces(float x) {
    return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
}

// Hue-preserving: the curve is applied to luminance and the color scaled,
// so saturated emitters (lava red, flame orange) keep their hue instead of
// drifting to yellow; channels pushed past 1 fade toward white.
vec3 tonemap(vec3 c) {
    float l = luminance(c);
    if (l <= 0.0) return vec3(0.0);
    c *= aces(l) / l;
    float m = max(c.r, max(c.g, c.b));
    if (m > 1.0) c = mix(c / m, vec3(1.0), clamp((m - 1.6) * 0.12, 0.0, 0.6));
    return c;
}

void main() {
    ivec2 fp = ivec2(gl_FragCoord.xy);
    ivec2 sp = fp / int(max(pc.scale, 1u));
    vec3 c = texelFetch(sampler2D(g_textures[pc.scene_tex], g_samplers[SAMPLER_NEAREST_CLAMP]), sp, 0).rgb;
    if ((FR.flags & RFRAME_BLOOM) != 0u) {
        vec2 bsize = vec2(textureSize(sampler2D(g_textures[pc.bloom_tex], g_samplers[SAMPLER_LINEAR_CLAMP]), 0));
        vec2 uv = (gl_FragCoord.xy / float(max(pc.scale, 1u))) * 0.5 / bsize;
        uv = min(uv, (vec2(FR.view_size) * 0.5 - 0.5) / bsize);
        c += textureLod(sampler2D(g_textures[pc.bloom_tex], g_samplers[SAMPLER_LINEAR_CLAMP]), uv, 0.0).rgb * FR.tuning.z;
    }
    c = tonemap(c * FR.ambient_cave.a);
    if ((FR.flags & RFRAME_VIGNETTE) != 0u) {
        vec2 q = gl_FragCoord.xy / vec2(pc.extent) - 0.5;
        float v = 1.0 - FR.tuning.w * smoothstep(0.25, 0.75, length(q * vec2(1.0, float(pc.extent.y) / float(pc.extent.x)) * 1.6));
        c *= v;
    }
    o_color = vec4(linear_to_srgb(c), 1.0);
}
