#version 460
// Sprite and debug-primitive batch: 6 vertices per QuadGpu, no vertex
// buffers. Positions are world pixels mapped into the scene image (one
// fragment per world pixel), wrapped on the torus relative to the camera.
#include "common.glsl"
#include "render/render.glsl"

layout(location = 0) out vec2 v_uv;
layout(location = 1) flat out uint v_index;

layout(push_constant) uniform PC {
    uint frame_slot;
    uint quads_slot;
    uint atlas_tex;
} pc;

#define FR g_render_frames[pc.frame_slot].f

const vec2 corners[6] = vec2[](vec2(0, 0), vec2(1, 0), vec2(0, 1), vec2(1, 0), vec2(1, 1), vec2(0, 1));

void main() {
    uint qi = uint(gl_VertexIndex) / 6u;
    vec2 c = corners[uint(gl_VertexIndex) % 6u];
    QuadGpu q = g_quads[pc.quads_slot].q[qi];
    vec2 anchor = q.p0 - vec2(FR.camera);
    anchor = mod(anchor + 512.0, float(WORLD_SIZE)) - 512.0;
    vec2 pos;
    v_uv = vec2(0.0);
    if (q.kind == QUAD_LINE) {
        vec2 d = q.p1 - q.p0;
        float len = length(d);
        vec2 t = len > 0.0 ? d / len : vec2(1.0, 0.0);
        vec2 n = vec2(-t.y, t.x);
        pos = anchor + 0.5 + t * (c.x * (len + 1.0) - 0.5) + n * ((c.y - 0.5) * q.width);
    } else {
        pos = anchor + c * q.p1;
        float u = (q.flags & QUAD_FLAG_FLIP_X) != 0u ? 1.0 - c.x : c.x;
        v_uv = q.uv.xy + vec2(u, c.y) * q.uv.zw;
    }
    v_index = qi;
    gl_Position = vec4(pos / vec2(FR.view_size) * 2.0 - 1.0, 0.0, 1.0);
}
