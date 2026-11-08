//! CPU reference of the grid: command application, activity compaction and
//! Margolus movement, bit-exact with shaders/sim/grid/*.comp. Function names
//! follow the shader functions they mirror. Any change to a grid shader must
//! be made here too; `zig build verify-determinism` compares the two over a
//! seeded 300-tick scenario, cell by cell.
const std = @import("std");
const cell = @import("../cell.zig");
const materials = @import("../materials.zig");
const commands = @import("../commands.zig");

const Phase = materials.Phase;
const static: u32 = @backingInt(Phase.static);
const powder: u32 = @backingInt(Phase.powder);
const liquid: u32 = @backingInt(Phase.liquid);
const gas: u32 = @backingInt(Phase.gas);

pub const World = struct {
    gpa: std.mem.Allocator,
    cells: []u32,
    /// Same layout as the GPU TILE_MARKS buffer (marks, then active flags).
    marks: [cell.tile_mark_bytes]u8 = @splat(0),
    table: *const materials.Table,
    sleep: bool,
    tick: u32 = 0,

    pub fn init(gpa: std.mem.Allocator, table: *const materials.Table, sleep: bool) !World {
        const cells = try gpa.alloc(u32, cell.world_size * cell.world_size);
        @memset(cells, 0);
        return .{ .gpa = gpa, .cells = cells, .table = table, .sleep = sleep };
    }

    pub fn deinit(self: *World) void {
        self.gpa.free(self.cells);
    }

    inline fn get(self: *const World, x: u32, y: u32) u32 {
        return self.cells[cell.index(x, y)];
    }
    inline fn set(self: *World, x: u32, y: u32, v: u32) void {
        self.cells[cell.index(x, y)] = v;
    }

    /// One tick, in pipeline order: commands, compaction, 8 substeps.
    pub fn step(self: *World, cmds: []const commands.CommandGpu) void {
        for (cmds) |c| self.applyCommand(c);
        self.compact();
        var s: u32 = 0;
        while (s < cell.substeps) : (s += 1) self.substep(s);
        self.tick +%= 1;
    }

    fn markTileAndNeighbors(self: *World, tx: u32, ty: u32) void {
        var dy: i32 = -1;
        while (dy <= 1) : (dy += 1) {
            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1) {
                const nx: u32 = @bitCast(@as(i32, @intCast(tx)) + dx);
                const ny: u32 = @bitCast(@as(i32, @intCast(ty)) + dy);
                self.marks[cell.tileIndex(nx, ny)] = cell.tile_wake_ticks;
            }
        }
    }

    fn spawnCell(self: *const World, material: u32, variant: u32) u32 {
        const mt = &self.table.gpu[material & 0xff];
        return cell.make(material, mt.spawn_temp, mt.initial_state, 0, variant);
    }

    /// shaders/sim/grid/commands.comp, one dispatch.
    pub fn applyCommand(self: *World, c: commands.CommandGpu) void {
        const box = commands.bounds(c) orelse return;
        const groups_x = (box.w + 15) / 16;
        const groups_y = (box.h + 15) / 16;
        const coverage = (c.flags >> commands.coverage_shift) & 0xff;
        for (0..groups_y) |gy| {
            for (0..groups_x) |gx| {
                var changed = false;
                for (0..16) |ly| {
                    for (0..16) |lx| {
                        const ix: u32 = @intCast(gx * 16 + lx);
                        const iy: u32 = @intCast(gy * 16 + ly);
                        if (ix >= box.w or iy >= box.h) continue;
                        const px = box.x + @as(i32, @intCast(ix));
                        const py = box.y + @as(i32, @intCast(iy));
                        if (!commands.insideShape(c, px, py)) continue;
                        const wx = cell.wrap(px);
                        const wy = cell.wrap(py);
                        const old = self.get(wx, wy);
                        const h = cell.hashSalt(wx, wy, c.seed, cell.salt_spawn_variant);
                        var replace = c.flags & commands.flag_only_air == 0 or cell.material(old) == materials.air;
                        if (coverage != 0 and (h & 0xff) >= coverage) replace = false;
                        if (replace) {
                            const v = self.spawnCell(c.material, h >> 28);
                            if (v != old) {
                                self.set(wx, wy, v);
                                changed = true;
                            }
                        }
                    }
                }
                if (changed and self.sleep) {
                    const cx = cell.wrap(box.x + @as(i32, @intCast(gx * 16)));
                    const cy = cell.wrap(box.y + @as(i32, @intCast(gy * 16)));
                    self.markTileAndNeighbors(cx >> cell.tile_shift, cy >> cell.tile_shift);
                }
            }
        }
    }

    /// shaders/sim/grid/activity.comp.
    pub fn compact(self: *World) void {
        for (0..cell.tile_count) |i| {
            const wake = self.marks[i];
            const active = !self.sleep or wake != 0;
            self.marks[i] = if (wake > 0) wake - 1 else 0;
            self.marks[cell.tile_active_offset + i] = @intFromBool(active);
        }
    }

    pub fn activeTiles(self: *const World) u32 {
        var n: u32 = 0;
        for (self.marks[cell.tile_active_offset..][0..cell.tile_count]) |a| n += a;
        return n;
    }

    /// shaders/sim/grid/movement.comp, one substep over the active tiles.
    pub fn substep(self: *World, s: u32) void {
        const off = margolusOffset(s);
        for (0..cell.tile_count) |ti| {
            if (self.marks[cell.tile_active_offset + ti] == 0) continue;
            const tx: u32 = @intCast(ti % cell.tiles_per_side);
            const ty: u32 = @intCast(ti / cell.tiles_per_side);
            var tile_moved = false;
            for (0..16) |ly| {
                for (0..16) |lx| {
                    const ox = (tx * cell.tile_size + @as(u32, @intCast(lx)) * 2 + off[0]) & cell.world_mask;
                    const oy = (ty * cell.tile_size + @as(u32, @intCast(ly)) * 2 + off[1]) & cell.world_mask;
                    if (self.block(ox, oy, s)) tile_moved = true;
                }
            }
            if (tile_moved and self.sleep) self.markTileAndNeighbors(tx, ty);
        }
    }

    /// One Margolus block; returns whether any cell moved.
    fn block(self: *World, ox: u32, oy: u32, s: u32) bool {
        const x1 = (ox + 1) & cell.world_mask;
        const y1 = (oy + 1) & cell.world_mask;
        const px = [4]u32{ ox, x1, ox, x1 };
        const py = [4]u32{ oy, oy, y1, y1 };
        var b: Block = undefined;
        var orig: [4]u32 = undefined;
        for (0..4) |i| {
            orig[i] = self.get(px[i], py[i]);
            b.cell[i] = orig[i];
            b.moved[i] = false;
        }
        const m0 = cell.material(orig[0]);
        const uniform = m0 == cell.material(orig[1]) and m0 == cell.material(orig[2]) and m0 == cell.material(orig[3]);
        if (!uniform) {
            for (0..4) |i| b.cache(self.table, i);
            const h = cell.hash(ox, oy, self.tick, s);
            const h2 = cell.hashU32(h ^ 0x5bd1e995);

            b.ruleVertical(0, 2, h & 0xff);
            b.ruleVertical(1, 3, (h >> 8) & 0xff);

            const rd = (h >> 16) & 0xff;
            if (h & 0x0100_0000 != 0) {
                b.diagonalDown(0, 3, 1, rd);
                b.diagonalDown(1, 2, 0, rd);
            } else {
                b.diagonalDown(1, 2, 0, rd);
                b.diagonalDown(0, 3, 1, rd);
            }

            const ru = (h2 >> 16) & 0xff;
            if (h & 0x0200_0000 != 0) {
                b.gasDiagonalUp(2, 1, 3, ru);
                b.gasDiagonalUp(3, 0, 2, ru);
            } else {
                b.gasDiagonalUp(3, 0, 2, ru);
                b.gasDiagonalUp(2, 1, 3, ru);
            }

            b.lateral(0, 1, h2 & 0xff);
            b.lateral(2, 3, (h2 >> 8) & 0xff);
        }
        var any = false;
        for (0..4) |i| {
            const v = cell.withFlag(b.cell[i], cell.flag_moved, b.moved[i]);
            any = any or b.moved[i];
            if (v != orig[i]) self.set(px[i], py[i], v);
        }
        return any;
    }
};

/// shaders/sim/grid/block.glsl margolus_offset.
pub fn margolusOffset(substep: u32) [2]u32 {
    const s = substep & 3;
    return .{ @intFromBool(s == 1 or s == 2), s & 1 };
}

inline fn matPhase(move: u32) u32 {
    return move & 0xff;
}
inline fn matDispersion(move: u32) u32 {
    return (move >> 8) & 0xff;
}
inline fn matSlide(move: u32) u32 {
    return (move >> 16) & 0xff;
}
inline fn matVerticalChance(move: u32) u32 {
    return move >> 24;
}
inline fn dispersionChance(d: u32) u32 {
    return @min(d * 32, 255);
}

/// shaders/sim/grid/block.glsl `Block` and rules (powder.glsl, liquid.glsl,
/// gas.glsl, movement.comp).
const Block = struct {
    cell: [4]u32,
    move: [4]u32,
    key: [4]u32,
    moved: [4]bool,

    fn cache(b: *Block, table: *const materials.Table, i: usize) void {
        const mt = &table.gpu[cell.material(b.cell[i])];
        b.move[i] = mt.moveWord();
        b.key[i] = mt.sort_key;
        // Particle-backed cells belong to the liquid solver: static here.
        if (cell.has(b.cell[i], cell.flag_particle)) {
            b.move[i] = static;
            b.key[i] = materials.sort_key_static;
        }
        b.moved[i] = false;
    }

    inline fn phase(b: *const Block, i: usize) u32 {
        return matPhase(b.move[i]);
    }
    inline fn isAir(b: *const Block, i: usize) bool {
        return cell.material(b.cell[i]) == materials.air;
    }
    inline fn isFluid(b: *const Block, i: usize) bool {
        const p = b.phase(i);
        return p == liquid or p == gas;
    }

    fn swap(b: *Block, i: usize, j: usize) void {
        std.mem.swap(u32, &b.cell[i], &b.cell[j]);
        std.mem.swap(u32, &b.move[i], &b.move[j]);
        std.mem.swap(u32, &b.key[i], &b.key[j]);
        b.moved[i] = true;
        b.moved[j] = true;
    }

    fn canSink(b: *const Block, upper: usize, lower: usize) bool {
        return !b.moved[upper] and !b.moved[lower] and b.phase(upper) != static and
            b.isFluid(lower) and b.key[upper] > b.key[lower];
    }

    fn ruleVertical(b: *Block, upper: usize, lower: usize, rnd8: u32) void {
        if (!b.canSink(upper, lower)) return;
        const mover = if (b.phase(upper) == gas) b.move[lower] else b.move[upper];
        if (cell.chance8(rnd8, matVerticalChance(mover))) b.swap(upper, lower);
    }

    fn diagonalDown(b: *Block, from: usize, to: usize, side: usize, rnd8: u32) void {
        const p = b.phase(from);
        if (p != powder and p != liquid) return;
        if (!b.isFluid(side) or !b.canSink(from, to)) return;
        // powder_diagonal_chance / liquid_diagonal_chance
        const chance: u32 = if (p == powder) matSlide(b.move[from]) else 255;
        if (cell.chance8(rnd8, chance)) b.swap(from, to);
    }

    fn gasDiagonalUp(b: *Block, from: usize, to: usize, side: usize, rnd8: u32) void {
        if (b.phase(from) != gas or b.isAir(from)) return;
        if (b.phase(to) != gas or !b.isFluid(side)) return;
        if (!b.canSink(to, from)) return;
        if (cell.chance8(rnd8, matVerticalChance(b.move[from]))) b.swap(from, to);
    }

    fn liquidLateral(b: *Block, l: usize, r: usize, rnd8: u32) bool {
        const pl = b.phase(l);
        const pr = b.phase(r);
        const mover = if (pl == liquid and pr == gas)
            b.move[l]
        else if (pr == liquid and pl == gas)
            b.move[r]
        else
            return false;
        if (cell.chance8(rnd8, dispersionChance(matDispersion(mover)))) b.swap(l, r);
        return true;
    }

    fn gasLateral(b: *Block, l: usize, r: usize, rnd8: u32) void {
        if (b.phase(l) != gas or b.phase(r) != gas) return;
        const al = b.isAir(l);
        const ar = b.isAir(r);
        if (al == ar) return;
        const mover = if (al) b.move[r] else b.move[l];
        if (cell.chance8(rnd8, dispersionChance(matDispersion(mover)))) b.swap(l, r);
    }

    fn lateral(b: *Block, l: usize, r: usize, rnd8: u32) void {
        if (b.moved[l] or b.moved[r]) return;
        // Both moved last substep: they most likely just swapped with each
        // other; swapping back would only jitter.
        if (cell.has(b.cell[l], cell.flag_moved) and cell.has(b.cell[r], cell.flag_moved)) return;
        if (!b.liquidLateral(l, r, rnd8)) b.gasLateral(l, r, rnd8);
    }
};

// ---- tests: behavior of the rules on the CPU (the GPU is checked against
// ---- this by --verify-determinism) ----

const builtin = @import("../materials_builtin.zig");

fn countMaterial(w: *const World, mat: u32) usize {
    var n: usize = 0;
    for (w.cells) |c| n += @intFromBool(cell.material(c) == mat);
    return n;
}

fn testWorld(table: *const materials.Table) !World {
    return World.init(std.testing.allocator, table, true);
}

test "sand falls, piles and is conserved" {
    const table = builtin.table();
    var w = try testWorld(&table);
    defer w.deinit();
    var list: commands.CommandList = .{};
    list.begin(0);
    list.fillRect(900, 1100, 1100, 1110, builtin.stone, .{});
    list.fillRect(990, 900, 1010, 960, builtin.sand, .{});
    w.step(list.slice());
    const sand0 = countMaterial(&w, builtin.sand);
    try std.testing.expectEqual(@as(usize, 20 * 60), sand0);
    for (0..200) |_| w.step(&.{});
    try std.testing.expectEqual(sand0, countMaterial(&w, builtin.sand));
    // Everything rests on the floor: nothing left above y = 1040, a pile
    // wider than the column touches the floor.
    var above: usize = 0;
    var floor_row: usize = 0;
    for (0..cell.world_size) |x| {
        for (0..1040) |y| above += @intFromBool(cell.material(w.get(@intCast(x), @intCast(y))) == builtin.sand);
        floor_row += @intFromBool(cell.material(w.get(@intCast(x), 1099)) == builtin.sand);
    }
    try std.testing.expectEqual(@as(usize, 0), above);
    try std.testing.expect(floor_row > 20);
    // Settled: the world went to sleep.
    for (0..20) |_| w.step(&.{});
    try std.testing.expectEqual(@as(u32, 0), w.activeTiles());
}

test "water spreads flat, smoke rises, sand sinks in water" {
    const table = builtin.table();
    var w = try testWorld(&table);
    defer w.deinit();
    var list: commands.CommandList = .{};
    list.begin(0);
    list.fillRect(500, 1000, 640, 1010, builtin.stone, .{}); // floor
    list.fillRect(500, 900, 510, 1000, builtin.stone, .{}); // walls
    list.fillRect(630, 900, 640, 1000, builtin.stone, .{});
    list.fillRect(520, 940, 540, 1000, builtin.water, .{}); // a water column, 1200 cells
    list.fillRect(560, 990, 580, 1000, builtin.smoke, .{}); // smoke on the floor
    list.fillRect(525, 900, 535, 910, builtin.sand, .{}); // sand falling into the water
    w.step(list.slice());
    for (0..800) |_| w.step(&.{});
    // 1200 water over 120 columns, with 100 sand under it: about 10.8 rows.
    var lo: u32 = 1000;
    var hi: u32 = 0;
    for (510..630) |x| {
        var top: u32 = 1000;
        for (900..1000) |y| {
            if (cell.material(w.get(@intCast(x), @intCast(y))) == builtin.water) {
                top = @intCast(y);
                break;
            }
        }
        lo = @min(lo, top);
        hi = @max(hi, top);
    }
    try std.testing.expect(hi - lo <= 3); // flat surface
    try std.testing.expect(lo >= 986 and hi <= 992);
    // Smoke left the basin upward.
    var smoke_inside: usize = 0;
    for (510..630) |x| for (900..1000) |y| {
        smoke_inside += @intFromBool(cell.material(w.get(@intCast(x), @intCast(y))) == builtin.smoke);
    };
    try std.testing.expectEqual(@as(usize, 0), smoke_inside);
    try std.testing.expectEqual(@as(usize, 200), countMaterial(&w, builtin.smoke));
    try std.testing.expectEqual(@as(usize, 1200), countMaterial(&w, builtin.water));
    // Sand sank to the floor under the water.
    var sand_floor: usize = 0;
    for (510..630) |x| sand_floor += @intFromBool(cell.material(w.get(@intCast(x), 999)) == builtin.sand);
    try std.testing.expect(sand_floor > 0);
}

test "static never moves and wrap is seamless" {
    const table = builtin.table();
    var w = try testWorld(&table);
    defer w.deinit();
    var list: commands.CommandList = .{};
    list.begin(0);
    list.fillRect(100, 100, 110, 110, builtin.stone, .{});
    list.fillRect(-4, cell.world_size - 20, 4, cell.world_size - 12, builtin.sand, .{});
    w.step(list.slice());
    for (0..30) |_| w.step(&.{});
    for (100..110) |x| for (100..110) |y| {
        try std.testing.expectEqual(builtin.stone, cell.material(w.get(@intCast(x), @intCast(y))));
    };
    // The sand fell across the bottom edge and is now near the top.
    var near_top: usize = 0;
    for (0..400) |y| for (0..8) |dx| {
        const x: u32 = @intCast((cell.world_size - 4 + dx) % cell.world_size);
        near_top += @intFromBool(cell.material(w.get(x, @intCast(y))) == builtin.sand);
    };
    try std.testing.expect(near_top > 0);
    try std.testing.expectEqual(@as(usize, 64), countMaterial(&w, builtin.sand));
}
