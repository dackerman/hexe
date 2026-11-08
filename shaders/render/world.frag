#version 460
// World pass, one fragment per world pixel of the view (the scene image is
// integer-upscaled to the window by composite.frag). Per cell:
//   albedo   material ramp entry picked by the variant bits (ramp_len aware)
//            plus a subtle static surface texture per material
//   light    ambient (by depth below the skyline) + irradiance from the
//            light region (radiance cascades / simple lights)
//   emission emissive materials, temperature glow toward the ramp's hot
//            end, burning cells and flame flicker
//   translucency  water, glass, steam, smoke blend over a dim procedural
//            back wall (or the sky above the skyline), since a cell holds
//            one material and there is nothing else behind it
// Ballistic particles in flight (r32ui particle overlay, snapshotted with the
// cells) replace the cell under them. Then the debug overlay of the current
// mode. Output is linear HDR.
#include "common.glsl"
#include "render/render.glsl"

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 o_color;

layout(push_constant) uniform PC {
    uint frame_slot;
} pc;

#define FR g_render_frames[pc.frame_slot].f
#include "render/shade.glsl"

RenderMaterial mat(uint id) { return g_render_materials[FR.materials_slot].m[id]; }
uint cell_at(ivec2 wu) { return imageLoad(g_uimages[FR.cells_slot], wrap_coord(wu)).x; }

// Rock wall behind the playfield: jittered cells (cobbles) of 10 px with
// darker seams, a per-cobble shade and a per-pixel speckle.
vec3 back_wall(ivec2 wu) {
    const int S = 10;
    ivec2 cell0 = ivec2(floor(vec2(wu) / float(S)));
    float f1 = 1e9;
    float f2 = 1e9;
    uint id = 0u;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            ivec2 cc = cell0 + ivec2(dx, dy);
            uint h = hash_salt(uint(cc.x), uint(cc.y), 0u, 0xb1u);
            vec2 site = vec2(cc * S) + vec2(float(h & 0xffu), float((h >> 8) & 0xffu)) / 255.0 * float(S);
            vec2 d = vec2(wu) + 0.5 - site;
            float dist = dot(d, d);
            if (dist < f1) {
                f2 = f1;
                f1 = dist;
                id = h;
            } else if (dist < f2) {
                f2 = dist;
            }
        }
    }
    float seam = sqrt(f2) - sqrt(f1);
    float shade = 0.75 + 0.25 * float((id >> 16) & 0xffu) / 255.0;
    float speck = float(hash_salt(uint(wu.x), uint(wu.y), 0u, 0xb3u) & 0xffu) / 255.0;
    float v = shade * (0.92 + 0.08 * speck) * (seam < 1.2 ? 0.7 : 1.0);
    v *= 0.85 + 0.3 * value_noise(wu, 32, 0xb2u);
    return vec3(0.12, 0.10, 0.09) * v;
}

vec3 sky_color(ivec2 wu) {
    float t = clamp(float(wu.y) / float(WORLD_SIZE / 2u), 0.0, 1.0);
    return mix(FR.sky.rgb * vec3(0.5, 0.6, 0.95), FR.sky.rgb * vec3(1.0, 0.96, 0.9), t);
}

// The sky shows behind air only above the terrain: open to the sky here and
// 24 px to either side, so narrow shafts show the back wall (they still let
// sky light in through the cascades).
vec3 background(ivec2 wu, vec3 light) {
    if ((FR.flags & RFRAME_SKY) != 0u && wu.y < surface_at(wu.x)) return sky_color(wu);
    return back_wall(wu) * light * FR.tuning2.x;
}

vec3 heat_color(uint t) {
    float c = float(temp_to_celsius(t));
    vec3 cold = vec3(0.1, 0.2, 0.9);
    vec3 mild = vec3(0.1, 0.75, 0.3);
    vec3 warm = vec3(1.0, 0.9, 0.15);
    vec3 hot = vec3(1.0, 0.2, 0.05);
    vec3 white = vec3(1.0);
    if (c < 20.0) return mix(cold, mild, clamp((c + 40.0) / 60.0, 0.0, 1.0));
    if (c < 500.0) return mix(mild, warm, (c - 20.0) / 480.0);
    if (c < 1000.0) return mix(warm, hot, (c - 500.0) / 500.0);
    return mix(hot, white, clamp((c - 1000.0) / 1000.0, 0.0, 1.0));
}

vec3 apply_overlay(vec3 col, ivec2 wu, uint c, vec3 light) {
    ivec2 w = wrap_coord(wu);
    switch (FR.overlay) {
    case OVERLAY_TILES: {
        uvec2 t = uvec2(w) >> TILE_SHIFT;
        bool is_active = uint(g_bytes[FR.tiles_slot].b[TILE_ACTIVE_OFFSET + tile_index(t)]) != 0u;
        bool edge = any(equal(uvec2(w) & (TILE_SIZE - 1u), uvec2(0u)));
        if (is_active) col = mix(col, vec3(1.0, 0.06, 0.01), edge ? 0.6 : 0.15);
        break;
    }
    case OVERLAY_AIR_PRESSURE:
    case OVERLAY_AIR_VELOCITY:
    case OVERLAY_LIQUID_PARTICLES: {
        vec4 o = imageLoad(g_img_rgba8[FR.overlay_slot], w >> int(DEBUG_OVERLAY_SHIFT));
        vec3 ol = srgb_to_linear(o.rgb);
        col = (FR.flags & RFRAME_OVERLAY_ADDITIVE) != 0u ? col + ol : mix(col, ol, o.a);
        break;
    }
    case OVERLAY_BODIES: {
        if (cell_has(c, CELL_FLAG_BODY)) {
            uint id = imageLoad(g_uimages[FR.owner_slot], w).x;
            uint h = hash_u32(id * 0x9e3779b9u + 1u);
            vec3 hc = srgb_to_linear(vec3(uvec3(h, h >> 8, h >> 16) & 0xffu) / 255.0 * 0.7 + 0.3);
            col = mix(col, hc, 0.7);
        } else {
            col *= 0.35;
        }
        break;
    }
    case OVERLAY_TEMPERATURE:
        if (cell_material(c) != MATERIAL_AIR) col = mix(col * 0.3, srgb_to_linear(heat_color(cell_temperature(c))), 0.75);
        else col *= 0.3;
        break;
    case OVERLAY_PARTICLE_CELLS:
        col = cell_has(c, CELL_FLAG_PARTICLE) ? mix(col, vec3(0.0, 0.9, 1.0), 0.8) : col * 0.4;
        break;
    case OVERLAY_LIGHT:
        col = light * 0.5;
        break;
    default:
        break;
    }
    return col;
}

void main() {
    ivec2 sp = ivec2(gl_FragCoord.xy);
    ivec2 wu = FR.camera + sp;
    ivec2 w = wrap_coord(wu);
    uint c = cell_at(wu);
    // Ballistic particles in flight draw over the cell they pass
    // (src/sim/particles.zig overlay, a whole cell value or 0).
    uint particle = imageLoad(g_uimages[FR.particles_slot], w).x;
    if (particle != 0u) c = particle;
    uint id = cell_material(c);
    RenderMaterial m = mat(id);
    uint fl = rm_flags(m);
    vec3 light = light_at(wu);

    vec3 col;
    if ((fl & RFLAG_AIR) != 0u) {
        col = background(wu, light);
    } else {
        vec3 albedo = ramp_color(m, ramp_index(m, cell_variant(c)));
        if ((fl & RFLAG_LIQUID) != 0u && (fl & RFLAG_TRANSLUCENT) != 0u) {
            // Translucent liquids: soften the per-pixel variant speckle
            // toward the ramp's mean and darken with depth below the surface.
            vec3 mean = vec3(0.0);
            uint len = rm_ramp_len(m);
            for (uint r = 0u; r < len; r++) mean += ramp_color(m, r);
            mean /= float(len);
            int depth = 0;
            for (int d = 1; d <= 12; d += 3) depth += cell_material(cell_at(wu - ivec2(0, d))) == id ? 1 : 0;
            albedo = mix(mean, albedo, 0.35) * (1.0 - 0.06 * float(depth));
        }
        float tex = rm_texture(m);
        if ((FR.flags & RFRAME_TEXTURE) != 0u && tex > 0.0) {
            float n = value_noise(wu, 16, 0x7e0u + id) * 0.7 + value_noise(wu, 4, 0x7f0u + id) * 0.3;
            albedo *= 1.0 + tex * (n * 2.0 - 1.0);
        }
        vec3 emission = cell_emission(FR, m, c, w, albedo);
        // Glow pulls a hot surface's color toward the ramp's hot end (hot
        // steel, cooling glass); emitters keep their ramp.
        float g = glow_amount(m, cell_temperature(c));
        if (g > 0.0 && (fl & RFLAG_EMISSIVE) == 0u) albedo = mix(albedo, ramp_color(m, rm_hot_index(m)), g * 0.5);
        // Emitters light themselves: no irradiance from their own glow.
        vec3 lit = (fl & RFLAG_EMISSIVE) != 0u ? albedo * ambient_at(wu) : albedo * light;
        if ((fl & RFLAG_LIQUID) != 0u && (fl & RFLAG_TRANSLUCENT) != 0u) {
            // Surface line and depth darkening make liquids read as bodies.
            uint above = cell_material(cell_at(wu - ivec2(0, 1)));
            if (above != id) lit = albedo * (light * 1.25 + 0.06);
        }
        if ((fl & RFLAG_FLICKER) != 0u) {
            // Flame: the color itself flickers toward the ramp's hot end.
            float f = flicker(w, FR.tick);
            albedo = mix(albedo, ramp_color(m, rm_hot_index(m)), f * 0.5);
            lit = albedo * (light + 0.5);
        }
        float alpha = rm_alpha(m);
        if (alpha < 1.0) {
            col = mix(background(wu, light), lit, alpha) + emission;
        } else {
            col = lit + emission;
        }
    }
    col = apply_overlay(col, wu, c, light);
    o_color = vec4(col, 1.0);
}
