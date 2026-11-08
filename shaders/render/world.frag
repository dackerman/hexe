#version 460
// World pass: maps each cell's material and variant to the material's color
// ramp. Integer upscale: one world pixel covers `scale` x `scale` fragments.
// The world is a torus, so the view wraps.
#include "common.glsl"

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 o_color;

layout(push_constant) uniform PC {
    ivec2 camera; // world pixel shown at the viewport's top-left corner
    ivec2 viewport_origin; // framebuffer pixel of the viewport's top-left corner
    uint scale; // integer zoom, >= 1
    uint flags; // WORLD_VIEW_FLAG_*
} pc;

#define WORLD_VIEW_FLAG_TILES 1u
#define WORLD_VIEW_FLAG_LIQUID 2u

// Liquid solver debug overlay (src/sim/liquid.zig), RGBA8: awake liquid
// particles cyan, ballistic yellow, transparent elsewhere.
layout(set = 0, binding = BINDING_STORAGE_IMAGES, rgba8) uniform readonly image2D g_rgba8_images[];

vec4 cell_color(uint c) {
    uint m = cell_material(c);
    MaterialGpu mt = MATERIALS[m];
    uint len = max(mat_ramp_len(mt), 1u);
    uint idx = (cell_variant(c) * len) >> CELL_VARIANT_BITS;
    return unpackUnorm4x8(mt.ramp[idx]);
}

void main() {
    ivec2 fp = ivec2(gl_FragCoord.xy) - pc.viewport_origin;
    ivec2 world = pc.camera + fp / int(max(pc.scale, 1u));
    ivec2 w = wrap_coord(world);
    uint c = imageLoad(CELLS, w).x;
    vec4 color = cell_color(c);
    if ((pc.flags & WORLD_VIEW_FLAG_TILES) != 0u) {
        uvec2 t = uvec2(w) >> TILE_SHIFT;
        bool is_active = uint(TILE_MARKS[TILE_COUNT + tile_index(t)]) != 0u;
        bool edge = any(equal(uvec2(w) & (TILE_SIZE - 1u), uvec2(0u)));
        if (is_active) color.rgb = mix(color.rgb, vec3(1.0, 0.25, 0.1), edge ? 0.6 : 0.12);
    }
    if ((pc.flags & WORLD_VIEW_FLAG_LIQUID) != 0u) {
        vec4 o = imageLoad(g_rgba8_images[SLOT_IMG_LIQUID_OVERLAY], w);
        color.rgb = mix(color.rgb, o.rgb, o.a * 0.75);
        // Sleeping solver liquid (plain cells) dimmed, so awake water stands out.
        if (o.a == 0.0 && cell_material(c) != MATERIAL_AIR && (MATERIALS[cell_material(c)].misc0 & 0xffu) == 1u &&
            mat_phase(MATERIALS[cell_material(c)].move) == PHASE_LIQUID) color.rgb *= 0.55;
    }
    o_color = vec4(color.rgb, 1.0);
}
