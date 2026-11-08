// Particle buffer ABI (docs/04-fluids.md "Particle layout",
// docs/decisions/50-particle-buffer.md). Include after common.glsl. Shared by
// the ballistic pass (this directory), the liquid solver (FLIP, M6) and any
// pass that turns cells into particles (impacts, blast thresholds, commands).
// Mirrored in src/sim/particles.zig (test "particles.glsl mirror").
//
// Structure of arrays, one entry per particle index 0..capacity-1, each at a
// fixed bindless slot:
//   P_POS[i]      vec2   position in world pixels, [0, WORLD_SIZE) (wrapped)
//   P_VEL[i]      vec2   velocity, px/s
//   P_AFFINE[i]   vec4   APIC affine matrix (c00 c01 c10 c11); FLIP only,
//                        zeroed at spawn
//   P_META[i]     uint   material | mode | stuck | temperature | variant
//   P_BINDING[i]  uint   cell binding: FLIP's claimed pixel (x | y << 16);
//                        PARTICLE_UNBOUND for ballistic particles
//
// Mode: FREE (slot unused), BALLISTIC (shaders/sim/particles/ballistic.comp
// owns it), LIQUID (the FLIP solver owns it). Whoever owns a particle may
// switch its mode by rewriting P_META (pmeta_with_mode).
//
// Allocation: an atomic free stack (P_FREE, count PCTRL_FREE_COUNT) plus a
// spawn queue (P_SPAWN, PCTRL_SPAWN_COUNT requests this tick).
//   - Any pass may *request* a particle: spawn_particle / eject_cell reserve
//     a queue entry (bounded by PCTRL_SPAWN_LIMIT, a snapshot of the free
//     count taken at the end of the previous tick, and by the per-material
//     budget PCTRL_BUDGET) and write the request.
//   - Any pass may *release* a particle it owns: release_particle pushes its
//     index on the free stack.
//   - Only spawn.comp pops the free stack, once per tick after every other
//     particle pass, turning the queued requests into particles. So pushes
//     and pops never share a pass, and a reserved request always gets an
//     index. New particles first move in the next tick.
#ifndef HEXE_PARTICLES_GLSL
#define HEXE_PARTICLES_GLSL

#define PARTICLE_MODE_FREE 0u
#define PARTICLE_MODE_BALLISTIC 1u
#define PARTICLE_MODE_LIQUID 2u

// P_META bit layout.
#define PMETA_MATERIAL_SHIFT 0u
#define PMETA_MODE_SHIFT 8u
#define PMETA_STUCK_SHIFT 10u
#define PMETA_TEMP_SHIFT 16u
#define PMETA_VARIANT_SHIFT 24u
// Ticks a ballistic particle may fail to land before it is deleted.
#define PMETA_STUCK_MAX 15u
#define PARTICLE_UNBOUND 0xffffffffu
#define PARTICLE_NONE 0xffffffffu
// Workgroup size of every pass over particle indices.
#define PARTICLE_GROUP 256u

// PCTRL word offsets (uint array at SLOT_BUF_PARTICLE_CTRL).
#define PCTRL_DISPATCH 0u
#define PCTRL_HIGH_WATER 3u
#define PCTRL_SPAWN_DISPATCH 4u
#define PCTRL_FREE_COUNT 7u
#define PCTRL_SPAWN_COUNT 8u
#define PCTRL_SPAWN_LIMIT 9u
#define PCTRL_LIVE 10u
#define PCTRL_CAPACITY 11u
#define PCTRL_SPAWNED 12u
#define PCTRL_LANDED 13u
#define PCTRL_REFUSED 14u
#define PCTRL_LOST 15u
#define PCTRL_IMPACTS 16u
#define PCTRL_STATS_FIRST 12u
#define PCTRL_STATS_COUNT 5u
#define PCTRL_QUEUE_CAPACITY 17u
#define PCTRL_REBUILD_DISPATCH 18u
#define PCTRL_HEADER_WORDS 32u
#define PCTRL_MAT_LIVE 32u
#define PCTRL_BUDGET 288u
#define PCTRL_WORDS 544u

// MaterialGpu.misc2 impact byte (src/sim/materials.zig Impact).
#define IMPACT_NONE 0u
#define IMPACT_SPLASH 1u
#define IMPACT_SPRAY 2u
#define IMPACT_CHIP 3u
#define IMPACT_DENT 4u
#define IMPACT_RICOCHET 5u

// CMD_EJECT (src/sim/commands.zig eject_min_speed, eject_damage_shift).
#define EJECT_MIN_SPEED 40u
#define EJECT_DAMAGE_SHIFT 2u

uint mat_health(MaterialGpu m) { return (m.misc0 >> 8) & 0xffu; }
uint mat_impact(MaterialGpu m) { return (m.misc2 >> 16) & 0xffu; }
uint mat_rubble(MaterialGpu m) { return m.impact2 & 0xffu; }
uint mat_restitution(MaterialGpu m) { return (m.impact2 >> 8) & 0xffu; }

struct SpawnRequest {
    vec2 pos;
    vec2 vel;
    uint meta;
    uint binding;
    uint pad0;
    uint pad1;
};

HEXE_BUFFER(ParticleCtrlBlock, , uint w[];, g_particle_ctrl);
HEXE_BUFFER(ParticlePosBlock, , vec2 pos[];, g_particle_pos);
HEXE_BUFFER(ParticleVelBlock, , vec2 vel[];, g_particle_vel);
HEXE_BUFFER(ParticleAffineBlock, , vec4 affine[];, g_particle_affine);
HEXE_BUFFER(ParticleMetaBlock, , uint meta[];, g_particle_meta);
HEXE_BUFFER(ParticleBindingBlock, , uint binding[];, g_particle_binding);
HEXE_BUFFER(ParticleFreeBlock, , uint free_list[];, g_particle_free);
HEXE_BUFFER(ParticleSpawnBlock, , SpawnRequest req[];, g_particle_spawn);
#define PCTRL g_particle_ctrl[SLOT_BUF_PARTICLE_CTRL].w
#define P_POS g_particle_pos[SLOT_BUF_PARTICLE_POS].pos
#define P_VEL g_particle_vel[SLOT_BUF_PARTICLE_VEL].vel
#define P_AFFINE g_particle_affine[SLOT_BUF_PARTICLE_AFFINE].affine
#define P_META g_particle_meta[SLOT_BUF_PARTICLE_META].meta
#define P_BINDING g_particle_binding[SLOT_BUF_PARTICLE_BINDING].binding
#define P_FREE g_particle_free[SLOT_BUF_PARTICLE_FREE].free_list
#define P_SPAWN g_particle_spawn[SLOT_BUF_PARTICLE_SPAWN].req
#define P_OVERLAY g_uimages[SLOT_IMG_PARTICLE_OVERLAY]

uint pmeta_make(uint material, uint mode, uint temperature, uint variant) {
    return (material & 0xffu) | ((mode & 3u) << PMETA_MODE_SHIFT) | ((temperature & 0xffu) << PMETA_TEMP_SHIFT) |
        ((variant & 0xfu) << PMETA_VARIANT_SHIFT);
}
uint pmeta_material(uint m) { return m & 0xffu; }
uint pmeta_mode(uint m) { return (m >> PMETA_MODE_SHIFT) & 3u; }
uint pmeta_stuck(uint m) { return (m >> PMETA_STUCK_SHIFT) & 0xfu; }
uint pmeta_temperature(uint m) { return (m >> PMETA_TEMP_SHIFT) & 0xffu; }
uint pmeta_variant(uint m) { return (m >> PMETA_VARIANT_SHIFT) & 0xfu; }
uint pmeta_with_mode(uint m, uint mode) { return bitfieldInsert(m, mode, int(PMETA_MODE_SHIFT), 2); }
uint pmeta_with_stuck(uint m, uint s) { return bitfieldInsert(m, min(s, 15u), int(PMETA_STUCK_SHIFT), 4); }

// A particle carrying cell `c` (its temperature and shade) as `material`.
uint pmeta_from_cell(uint c, uint material, uint mode) {
    return pmeta_make(material, mode, cell_temperature(c), cell_variant(c));
}

// The cell a particle becomes when it lands: its material at full state
// (health / lifetime), keeping its temperature and variant.
uint particle_cell(uint meta) {
    uint m = pmeta_material(meta);
    return cell_make(m, pmeta_temperature(meta), mat_initial_state(MATERIALS[m]), 0u, pmeta_variant(meta));
}

// Overlay value drawn by the world pass (nonzero even for material 0).
uint particle_overlay_value(uint meta) {
    return cell_make(pmeta_material(meta), pmeta_temperature(meta), 0u, CELL_FLAG_PARTICLE, pmeta_variant(meta));
}

// What a removed cell becomes.
uint air_hole() { return spawn_cell(MATERIAL_AIR, 0u); }

// Cheap pre-check (non-atomic) before destroying a cell for a particle.
bool particle_can_spawn(uint material) {
    uint m = material & 0xffu;
    return PCTRL[PCTRL_SPAWN_COUNT] < PCTRL[PCTRL_SPAWN_LIMIT] && PCTRL[PCTRL_MAT_LIVE + m] < PCTRL[PCTRL_BUDGET + m];
}

// Reserve a spawn queue entry for one particle of `material`; PARTICLE_NONE
// when the queue (capacity) or the material's budget is exhausted.
uint particle_reserve(uint material) {
    uint m = material & 0xffu;
    uint live = atomicAdd(PCTRL[PCTRL_MAT_LIVE + m], 1u);
    if (live >= PCTRL[PCTRL_BUDGET + m]) {
        atomicAdd(PCTRL[PCTRL_MAT_LIVE + m], 0xffffffffu);
        atomicAdd(PCTRL[PCTRL_REFUSED], 1u);
        return PARTICLE_NONE;
    }
    uint k = atomicAdd(PCTRL[PCTRL_SPAWN_COUNT], 1u);
    if (k >= PCTRL[PCTRL_SPAWN_LIMIT]) {
        atomicAdd(PCTRL[PCTRL_MAT_LIVE + m], 0xffffffffu);
        atomicAdd(PCTRL[PCTRL_REFUSED], 1u);
        return PARTICLE_NONE;
    }
    return k;
}

// Request a particle (any mode). It exists from the end of this tick's
// particle section on. Returns false if refused (capacity or budget).
bool spawn_particle(vec2 pos, vec2 vel, uint meta, uint binding) {
    uint k = particle_reserve(pmeta_material(meta));
    if (k == PARTICLE_NONE) return false;
    P_SPAWN[k] = SpawnRequest(pos, vel, meta, binding, 0u, 0u);
    return true;
}

// Free particle `i` (owned by the caller's pass). Never call from spawn.comp.
void release_particle(uint i) {
    uint meta = P_META[i];
    P_META[i] = 0u;
    atomicAdd(PCTRL[PCTRL_MAT_LIVE + pmeta_material(meta)], 0xffffffffu);
    uint j = atomicAdd(PCTRL[PCTRL_FREE_COUNT], 1u);
    P_FREE[j] = i;
}

// Turn the cell at wrapped `w`, last seen as `c`, into a ballistic particle
// of `material` (its own material, or rubble) flying at `vel` px/s, leaving
// air. Atomic: fails if the cell changed since `c` was read, if it is air,
// body-owned or particle-backed, or if the particle is refused (the cell is
// then left as it was). Marks the cell's tile and neighbors active.
bool eject_observed(ivec2 w, uint c, vec2 vel, uint material) {
    if (cell_material(c) == MATERIAL_AIR || (c & (CELL_FLAG_BODY | CELL_FLAG_PARTICLE)) != 0u) return false;
    if (!particle_can_spawn(material)) return false;
    uint hole = air_hole();
    if (imageAtomicCompSwap(CELLS, w, c, hole) != c) return false;
    uint k = particle_reserve(material);
    if (k == PARTICLE_NONE) {
        imageAtomicCompSwap(CELLS, w, hole, c);
        return false;
    }
    P_SPAWN[k] = SpawnRequest(vec2(w) + 0.5, vel, pmeta_from_cell(c, material, PARTICLE_MODE_BALLISTIC), PARTICLE_UNBOUND, 0u, 0u);
    mark_tile_and_neighbors(uvec2(w) >> TILE_SHIFT);
    return true;
}

// The cell at `p` (wrapped) flies as itself. The entry point for blast
// thresholds (air field, M5) and impacts.
bool eject_cell(ivec2 p, vec2 vel) {
    ivec2 w = wrap_coord(p);
    uint c = imageLoad(CELLS, w).x;
    return eject_observed(w, c, vel, cell_material(c));
}

// The cell at `p` flies as `material` (e.g. its rubble).
bool eject_cell_as(ivec2 p, vec2 vel, uint material) {
    ivec2 w = wrap_coord(p);
    uint c = imageLoad(CELLS, w).x;
    return eject_observed(w, c, vel, material);
}

#endif
