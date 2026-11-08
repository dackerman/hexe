// Lighting lookups shared by the world pass and the sprite pass: irradiance
// from the light region (radiance cascades or simple lights), ambient by
// depth below the skyline, and the sky test. Include after render.glsl and
// define FR (the RenderFrame) first.
#ifndef HEXE_SHADE_GLSL
#define HEXE_SHADE_GLSL

// Skyline of the light-region column holding unwrapped world x: the first
// opaque row from the top of the world (WORLD_SIZE when none).
int skyline_at(int wx) {
    int col = clamp(wx - FR.region_origin.x, 0, int(FR.region_size.x) - 1);
    return g_ints[FR.skyline_slot].v[col];
}

bool under_open_sky(ivec2 wu) {
    return (FR.flags & RFRAME_SKY) != 0u && wu.y < skyline_at(wu.x);
}

// Irradiance at the center of world pixel wu (unwrapped), bilinear between
// cascade-0 probes.
vec3 irradiance_at(ivec2 wu) {
    uint mode = FR.flags & RFRAME_LIGHT_MODE_MASK;
    if (mode == LIGHT_MODE_OFF) return vec3(1.0);
    vec2 rp = (vec2(wu - FR.region_origin) + 0.5) / float(FR.probe_spacing);
    rp = clamp(rp, vec2(0.5), vec2(FR.probes) - 0.5);
    vec2 size = vec2(textureSize(sampler2D(g_textures[FR.irradiance_tex], g_samplers[SAMPLER_LINEAR_CLAMP]), 0));
    return textureLod(sampler2D(g_textures[FR.irradiance_tex], g_samplers[SAMPLER_LINEAR_CLAMP]), rp / size, 0.0).rgb * FR.tuning2.z;
}

// Terrain surface height: the skyline here and 24 px to either side, so a
// narrow shaft does not carry the surface down into the rock.
int surface_at(int wx) {
    return min(skyline_at(wx), min(skyline_at(wx - 24), skyline_at(wx + 24)));
}

// Ambient light: the surface value near and above the terrain surface,
// fading to the cave value with depth below it.
vec3 ambient_at(ivec2 wu) {
    float depth = float(wu.y - surface_at(wu.x));
    float t = smoothstep(0.0, max(FR.ambient_surface.a, 1.0), depth);
    return mix(FR.ambient_surface.rgb, FR.ambient_cave.rgb, t);
}

vec3 light_at(ivec2 wu) {
    return ambient_at(wu) + irradiance_at(wu);
}

#endif
