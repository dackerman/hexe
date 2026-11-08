// hexe render definitions shared by the shaders under shaders/render/.
// Include after common.glsl. CPU mirrors: src/render/materials.zig
// (RenderMaterial, RFLAG_*), src/render/renderer.zig (RenderFrame,
// RFRAME_*, LightGpu, QuadGpu); the "render.glsl mirror" test checks every
// numeric #define here.
#ifndef HEXE_RENDER_GLSL
#define HEXE_RENDER_GLSL

// ---------------------------------------------------------------------------
// Render material table: the renderer's own view of each material, built on
// the CPU from the simulation's material table (src/render/materials.zig),
// so render shaders never depend on the sim's GPU layout. 12 words each.
//   ramp[8]  RGBA8 sRGB colors, R in the low byte, `ramp_len` of them valid
//   info     ramp_len | phase<<8 | RFLAG_*<<16
//   light    emissive | absorb<<8 | alpha<<16 | texture<<24
//            emissive: 0-255 light emitted by the material's own color
//            absorb:   0-255 light absorbed per world pixel (255 = opaque)
//            alpha:    0-255 visual coverage (translucent materials < 255)
//            texture:  0-255 amplitude of the static surface noise
//   glow     glow_from | glow_to<<8 | hot_index<<16 (temperature bytes;
//            glow when from < to; hot_index = brightest ramp entry)
// ---------------------------------------------------------------------------
#define RFLAG_TRANSLUCENT 1u
#define RFLAG_EMISSIVE 2u
#define RFLAG_GLOWS 4u
#define RFLAG_BLOCKS_LIGHT 8u
#define RFLAG_FLICKER 16u
#define RFLAG_LIQUID 32u
#define RFLAG_GAS 64u
#define RFLAG_AIR 128u
#define RENDER_MATERIAL_WORDS 12u

struct RenderMaterial {
    uint ramp[8];
    uint info;
    uint light;
    uint glow;
    uint pad;
};

uint rm_ramp_len(RenderMaterial m) { return max(m.info & 0xffu, 1u); }
uint rm_phase(RenderMaterial m) { return (m.info >> 8) & 0xffu; }
uint rm_flags(RenderMaterial m) { return m.info >> 16; }
float rm_emissive(RenderMaterial m) { return float(m.light & 0xffu) / 255.0; }
float rm_absorb(RenderMaterial m) { return float((m.light >> 8) & 0xffu) / 255.0; }
float rm_alpha(RenderMaterial m) { return float((m.light >> 16) & 0xffu) / 255.0; }
float rm_texture(RenderMaterial m) { return float(m.light >> 24) / 255.0; }
uint rm_glow_from(RenderMaterial m) { return m.glow & 0xffu; }
uint rm_glow_to(RenderMaterial m) { return (m.glow >> 8) & 0xffu; }
uint rm_hot_index(RenderMaterial m) { return (m.glow >> 16) & 0xffu; }

HEXE_BUFFER(RenderMaterialBlock, readonly, RenderMaterial m[];, g_render_materials);

// ---------------------------------------------------------------------------
// Per-frame render parameters, one host-visible buffer per frame slot.
// ---------------------------------------------------------------------------
#define RFRAME_LIGHT_MODE_MASK 3u
#define LIGHT_MODE_CASCADES 0u
#define LIGHT_MODE_SIMPLE 1u
#define LIGHT_MODE_OFF 2u
#define RFRAME_BLOOM 4u
#define RFRAME_VIGNETTE 8u
#define RFRAME_SKY 16u
#define RFRAME_TEXTURE 32u
#define RFRAME_OVERLAY_ADDITIVE 64u

#define MAX_LIGHTS 256u
#define MAX_CASCADES 6u
#define SCENE_MIPS 7u

struct RenderFrame {
    ivec2 camera;        // world pixel at the scene image's (0,0)
    uvec2 view_size;     // scene image size in world pixels
    ivec2 region_origin; // world pixel at the light region's (0,0), unwrapped
    uvec2 region_size;   // light region in world pixels (multiple of 32*spacing)
    uvec2 probes;        // cascade-0 probe grid = region_size / probe_spacing
    uint probe_spacing;  // world pixels between cascade-0 probes (power of 2)
    uint probe_shift;    // log2(probe_spacing)
    uint cascade_count;
    uint tick;
    uint overlay;        // OVERLAY_* (common.glsl)
    uint flags;          // RFRAME_*
    uint light_count;
    uint quad_count;
    // bindless slots
    uint cells_slot;     // r32ui cell snapshot (or the live cell image)
    uint owner_slot;     // r32ui owner snapshot (or live)
    uint tiles_slot;     // buffer, TILE_MARKS layout (snapshot or live)
    uint overlay_slot;   // rgba8 debug overlay image (snapshot or live)
    uint materials_slot; // RenderMaterial[256]
    uint lights_slot;    // LightGpu[light_count]
    uint skyline_slot;   // int per region column
    uint irradiance_tex; // sampled: final irradiance at probe resolution
    uint scene_img[SCENE_MIPS]; // rgba16f emission/opacity mips (storage)
    uint pad0;
    uint pad1;
    uint pad2;
    vec4 sky;            // rgb sky radiance, a = sky ambient strength
    vec4 ambient_surface; // rgb ambient near the surface, a = fade depth (px)
    vec4 ambient_cave;   // rgb ambient deep in caves, a = exposure
    vec4 tuning;         // x emissive gain, y glow gain, z bloom strength, w vignette
    vec4 tuning2;        // x background brightness, y wall light depth (px), z irradiance gain, w bloom threshold
    vec4 tuning3;        // x emission gain into the light scene, yzw reserved
};

HEXE_BUFFER(RenderFrameBlock, readonly, RenderFrame f;, g_render_frames);

// Point light: position in world pixels (unwrapped), radius, color (linear,
// may exceed 1).
struct LightGpu {
    vec2 pos;
    float radius;
    float pad;
    vec4 color;
};
HEXE_BUFFER(LightBlock, readonly, LightGpu l[];, g_lights);

// Point lights are drawn into the light scene as small emitting discs of
// this radius (world pixels).
float light_source_radius(float radius) { return clamp(radius / 12.0, 2.0, 6.0); }

// Sprite / debug primitive batch (src/render/sprites.zig), drawn at world
// pixel scale into the scene image after the world pass.
//   sprite: p0 top-left world pixel, p1 size; uv atlas texel rect; color tint
//   rect:   p0 top-left, p1 size, filled with color
//   line:   p0 to p1 (pixel coordinates), `width` pixels wide
#define QUAD_SPRITE 0u
#define QUAD_RECT 1u
#define QUAD_LINE 2u
#define QUAD_FLAG_FLIP_X 1u
#define QUAD_FLAG_LIT 2u
#define MAX_QUADS 8192u

struct QuadGpu {
    vec2 p0;
    vec2 p1;
    vec4 color;
    vec4 uv;
    uint kind;
    uint flags;
    float width;
    uint pad;
};
HEXE_BUFFER(QuadBlock, readonly, QuadGpu q[];, g_quads);

layout(set = 0, binding = BINDING_STORAGE_IMAGES, rgba16f) uniform image2D g_img_rgba16f[];
layout(set = 0, binding = BINDING_STORAGE_IMAGES, rgba8) uniform image2D g_img_rgba8[];
HEXE_BUFFER(IntBlock, , int v[];, g_ints);
HEXE_BUFFER(ByteBlock, readonly, uint8_t b[];, g_bytes);

// ---------------------------------------------------------------------------
// RGB9E5 shared-exponent packing (the GL_EXT_texture_shared_exponent
// encoding) for the cascade images: 4 bytes per radiance texel in an r32ui
// storage image, 9-bit mantissas.
// ---------------------------------------------------------------------------
uint pack_rgb9e5(vec3 c) {
    const float max_value = 65408.0; // (2^9 - 1) / 2^9 * 2^15
    c = clamp(c, vec3(0.0), vec3(max_value));
    float m = max(c.r, max(c.g, c.b));
    int e = max(-16, int(floor(log2(max(m, 1e-30))))) + 16;
    float scale = exp2(float(e - 24));
    if (floor(m / scale + 0.5) >= 512.0) {
        e += 1;
        scale *= 2.0;
    }
    uvec3 q = uvec3(floor(c / scale + 0.5));
    return q.r | (q.g << 9) | (q.b << 18) | (uint(e) << 27);
}

vec3 unpack_rgb9e5(uint v) {
    float scale = exp2(float(int(v >> 27) - 24));
    return vec3(uvec3(v, v >> 9, v >> 18) & 0x1ffu) * scale;
}

// ---------------------------------------------------------------------------
// Color helpers.
// ---------------------------------------------------------------------------
vec3 srgb_to_linear(vec3 c) {
    return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), greaterThan(c, vec3(0.04045)));
}
vec3 linear_to_srgb(vec3 c) {
    c = max(c, vec3(0.0));
    return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, greaterThan(c, vec3(0.0031308)));
}
float luminance(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }

vec3 ramp_color(RenderMaterial m, uint index) {
    return srgb_to_linear(unpackUnorm4x8(m.ramp[index & 7u]).rgb);
}

// Ramp entry for a cell's variant bits (ramp_len aware).
uint ramp_index(RenderMaterial m, uint variant) {
    return (variant * rm_ramp_len(m)) >> CELL_VARIANT_BITS;
}

// Smooth value noise in [0,1] on a lattice of `scale` pixels (static per
// world position; integer hash, so it is stable as the camera moves).
float value_noise(ivec2 p, int scale, uint salt) {
    ivec2 q = p >> findLSB(uint(scale));
    vec2 f = vec2(p - q * scale) / float(scale);
    f = f * f * (3.0 - 2.0 * f);
    float a = float(hash_salt(uint(q.x), uint(q.y), 0u, salt) & 0xffffu);
    float b = float(hash_salt(uint(q.x + 1), uint(q.y), 0u, salt) & 0xffffu);
    float c = float(hash_salt(uint(q.x), uint(q.y + 1), 0u, salt) & 0xffffu);
    float d = float(hash_salt(uint(q.x + 1), uint(q.y + 1), 0u, salt) & 0xffffu);
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y) / 65535.0;
}

// Temperature glow amount in [0,1] for a cell of material m.
float glow_amount(RenderMaterial m, uint temp) {
    if ((rm_flags(m) & RFLAG_GLOWS) == 0u) return 0.0;
    float from = float(rm_glow_from(m));
    float to = float(rm_glow_to(m));
    return clamp((float(temp) - from) / max(to - from, 1.0), 0.0, 1.0);
}

// Flicker in [0,1] that changes every couple of ticks, per cell.
float flicker(ivec2 w, uint tick) {
    uint h0 = hash_salt(uint(w.x) >> 1, uint(w.y) >> 1, tick >> 1, 0xf11cu);
    uint h1 = hash_salt(uint(w.x), uint(w.y), tick >> 2, 0xf11du);
    return 0.55 * float(h0 & 0xffu) / 255.0 + 0.45 * float(h1 & 0xffu) / 255.0;
}

#define BURN_COLOR vec3(1.0, 0.42, 0.08)

// Slow shimmer in [0,1] for glowing liquids: value noise drifting with the
// tick, so a lava pool's surface churns.
float shimmer(ivec2 w, uint tick) {
    int t = int(tick);
    return value_noise(w + ivec2(t / 6, -t / 9), 8, 0x5e1u) * 0.6 + value_noise(w + ivec2(-t / 4, t / 7), 4, 0x5e2u) * 0.4;
}

// Light a cell of material m emits (linear radiance, before the display or
// light-scene gain), from its emissive value, its temperature glow, burning
// and flicker.
vec3 cell_emission(RenderFrame fr, RenderMaterial m, uint c, ivec2 w, vec3 albedo) {
    vec3 e = vec3(0.0);
    uint fl = rm_flags(m);
    float em = rm_emissive(m);
    if (em > 0.0) {
        float k = em;
        if ((fl & RFLAG_FLICKER) != 0u) k *= 0.55 + 0.9 * flicker(w, fr.tick);
        else if ((fl & RFLAG_LIQUID) != 0u) k *= 0.7 + 0.6 * shimmer(w, fr.tick);
        e += albedo * k * fr.tuning.x;
    }
    float g = glow_amount(m, cell_temperature(c));
    if (g > 0.0) e += ramp_color(m, rm_hot_index(m)) * (g * g) * fr.tuning.y;
    if (cell_has(c, CELL_FLAG_BURNING)) e += BURN_COLOR * (0.6 + 1.2 * flicker(w, fr.tick)) * fr.tuning.x;
    return e;
}

#endif
