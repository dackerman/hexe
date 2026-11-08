// Explosion / pressure injections (CMD_INJECT_PRESSURE, src/sim/air.zig).
// The CPU uploads one Injection per active source per tick; inject_count
// sums integer weights over the fluid cells of the disc, inject_apply adds
// each cell's share of the mass and outward momentum every step. The total
// is fixed, so a confined blast concentrates in the cells that are open.
#ifndef HEXE_INJECT_GLSL
#define HEXE_INJECT_GLSL

struct Injection {
    vec2 center; // lattice coordinates (unwrapped)
    float radius; // lattice cells
    float mass; // total mass added per step (AIR_MASS_ONE = 1.0)
    float momentum; // total outward momentum added per step
    uint steps; // steps this tick
    uint pad0;
    uint pad1;
};

HEXE_BUFFER(InjectionBlock, readonly, Injection items[];, g_injections);
HEXE_BUFFER(InjectionCountBlock, , uint weights[];, g_injection_counts);

layout(push_constant) uniform PC {
    ivec2 origin; // unwrapped lattice cell of the dispatch's top-left, multiple of 16
    uvec2 size;
    uint ring_slot;
    uint index; // injection index in the ring
    uint counts_slot;
    uint counter; // index into weights[]
    uint node_slot;
    uint dist_slot; // apply: the buffer the next step pulls from
    ivec2 seam;
    float rho_max;
    uint mark;
} pc;

// Integer weight of lattice cell c in injection j, 0 outside or on walls.
uint inject_weight(Injection j, ivec2 c, out vec2 dir) {
    vec2 d = vec2(c) + 0.5 - j.center;
    float r = length(d);
    dir = r > 1e-3 ? d / r : vec2(0.0);
    if (r > j.radius) return 0u;
    ivec2 w = air_wrap(c);
    if (!air_inside(air_local(w, pc.seam))) return 0u;
    if ((imageLoad(g_uimages[pc.node_slot], w).x & NODE_WALL) != 0u) return 0u;
    float q = r / max(j.radius, 1e-3);
    return 1u + uint(255.0 * max(1.0 - q * q, 0.0));
}

#endif
