//! CPU reference of the grid: command application, activity compaction, the
//! reactions and heat pass and Margolus movement, bit-exact with
//! shaders/sim/grid/*.comp. Function names follow the shader functions they
//! mirror. Any change to a grid shader must be made here too; `zig build
//! verify-determinism` compares the two over a seeded 300-tick scenario,
//! cell by cell, and the event sets.
const std = @import("std");
const cell = @import("../cell.zig");
const materials = @import("../materials.zig");
const commands = @import("../commands.zig");
const rx = @import("../reactions.zig");

const Phase = materials.Phase;
const Flag = materials.Flag;
const MaterialGpu = materials.MaterialGpu;
const static: u32 = @backingInt(Phase.static);
const powder: u32 = @backingInt(Phase.powder);
const liquid: u32 = @backingInt(Phase.liquid);
const gas: u32 = @backingInt(Phase.gas);
const mask_words = cell.tile_size;

/// Events per worker per substep before they are dropped (counted).
const worker_event_capacity = 1024;
const max_workers = 16;

pub const World = struct {
    gpa: std.mem.Allocator,
    cells: []u32,
    /// The reactions pass's NEXT image: valid where `masks` has a bit.
    next: []u32,
    /// Change mask per tile (by tile index, not list order), one word per row.
    masks: []u32,
    /// Same layout as the GPU TILE_MARKS buffer (marks, then active flags).
    marks: [cell.tile_mark_bytes]u8 = @splat(0),
    tables: *const materials.Tables,
    sleep: bool,
    tick: u32 = 0,
    /// Every event appended so far, in no particular order within a substep.
    events: std.ArrayList(rx.EventGpu) = .empty,
    workers: usize = 1,

    pub fn init(gpa: std.mem.Allocator, tables: *const materials.Tables, sleep: bool) !World {
        const cells = try gpa.alloc(u32, cell.world_size * cell.world_size);
        errdefer gpa.free(cells);
        @memset(cells, materials.ambientAir(tables));
        const next = try gpa.alloc(u32, cell.world_size * cell.world_size);
        errdefer gpa.free(next);
        const masks = try gpa.alloc(u32, cell.tile_count * mask_words);
        @memset(masks, 0);
        const cpus = std.Thread.getCpuCount() catch 1;
        return .{ .gpa = gpa, .cells = cells, .next = next, .masks = masks, .tables = tables, .sleep = sleep, .workers = std.math.clamp(cpus, 1, max_workers) };
    }

    pub fn deinit(self: *World) void {
        self.events.deinit(self.gpa);
        self.gpa.free(self.masks);
        self.gpa.free(self.next);
        self.gpa.free(self.cells);
    }

    inline fn get(self: *const World, x: u32, y: u32) u32 {
        return self.cells[cell.index(x, y)];
    }
    inline fn set(self: *World, x: u32, y: u32, v: u32) void {
        self.cells[cell.index(x, y)] = v;
    }
    /// common.glsl load_cell: wrapping read.
    inline fn load(self: *const World, x: i32, y: i32) u32 {
        return self.cells[cell.index(cell.wrap(x), cell.wrap(y))];
    }
    inline fn mat(self: *const World, m: u32) *const MaterialGpu {
        return &self.tables.materials[m & 0xff];
    }

    /// One tick, in pipeline order: commands, compaction, 8 x {reactions,
    /// movement}.
    pub fn step(self: *World, cmds: []const commands.CommandGpu) !void {
        for (cmds) |c| self.applyCommand(c);
        self.compact();
        var s: u32 = 0;
        while (s < cell.substeps) : (s += 1) {
            try self.reactions(s);
            self.substep(s);
        }
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

    /// common.glsl spawn_cell.
    fn spawnCell(self: *const World, material: u32, variant: u32) u32 {
        const mt = self.mat(material);
        return cell.make(material, mt.temperature, mt.state_init, 0, variant);
    }

    /// common.glsl cell_ignite.
    fn ignite(self: *const World, c: u32, material: u32) u32 {
        const mt = self.mat(material);
        const st = if (mt.flags & Flag.has_health != 0) cell.state(c) else mt.burn_fuel;
        return cell.withFlag(cell.withState(c, st), cell.flag_burning, true);
    }

    /// shaders/sim/grid/commands.comp apply_command.
    fn commandResult(self: *const World, c: commands.CommandGpu, old: u32, h: u32) u32 {
        const action = c.kind >> commands.action_shift;
        const om = cell.material(old);
        const omt = self.mat(om);
        switch (action) {
            @backingInt(commands.Action.ignite) => {
                if (omt.flags & Flag.flammable == 0 or cell.has(old, cell.flag_burning)) return old;
                return self.ignite(old, om);
            },
            @backingInt(commands.Action.heat) => return cell.withTemperature(old, (c.flags >> commands.temp_shift) & 0xff),
            @backingInt(commands.Action.charge) => {
                if (omt.flags & Flag.conductive == 0 or cell.state(old) >> cell.charge_shift != 0) return old;
                return cell.withState(old, (cell.state(old) & cell.conductive_state_mask) | (cell.charge_head << cell.charge_shift));
            },
            else => {},
        }
        const material = c.material & 0xff;
        if (c.flags & commands.flag_only_air != 0 and om != materials.air) return old;
        if (c.flags & commands.flag_only_material != 0 and om != (c.material >> commands.only_shift) & 0xff) return old;
        var v = self.spawnCell(material, h >> 28);
        if (c.flags & commands.flag_set_temp != 0) v = cell.withTemperature(v, (c.flags >> commands.temp_shift) & 0xff);
        if (c.flags & commands.flag_set_state != 0) v = cell.withState(v, c.flags >> commands.state_shift);
        return v;
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
                        const hit = coverage == 0 or (h & 0xff) < coverage;
                        const v = self.commandResult(c, old, h);
                        if (hit and v != old) {
                            self.set(wx, wy, v);
                            changed = true;
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

    // ------------------------------------------------ reactions and heat

    fn tileActiveAt(self: *const World, x: i32, y: i32) bool {
        return self.marks[cell.tile_active_offset + cell.tileIndex(cell.wrap(x) >> cell.tile_shift, cell.wrap(y) >> cell.tile_shift)] != 0;
    }

    /// shaders/sim/grid/reactions.comp + reactions_commit.comp, one substep.
    /// The gather runs on worker threads (it only reads `cells`); commit,
    /// marking and event merging are serial.
    pub fn reactions(self: *World, s: u32) !void {
        var tiles: [cell.tile_count]u16 = undefined;
        var n_tiles: usize = 0;
        for (0..cell.tile_count) |ti| {
            if (self.marks[cell.tile_active_offset + ti] != 0) {
                tiles[n_tiles] = @intCast(ti);
                n_tiles += 1;
            }
        }
        if (n_tiles == 0) return;
        var next_tile: std.atomic.Value(usize) = .init(0);
        var outs: [max_workers]WorkerOut = undefined;
        const n_workers = @min(self.workers, (n_tiles + 7) / 8);
        var threads: [max_workers]?std.Thread = @splat(null);
        for (0..n_workers) |i| {
            outs[i] = .{};
            if (i == 0) continue;
            threads[i] = std.Thread.spawn(.{}, workerRun, .{ self, s, tiles[0..n_tiles], &next_tile, &outs[i] }) catch null;
        }
        workerRun(self, s, tiles[0..n_tiles], &next_tile, &outs[0]);
        for (threads[0..n_workers]) |t| if (t) |th| th.join();
        for (outs[0..n_workers]) |*o| try self.events.appendSlice(self.gpa, o.events[0..o.n]);

        for (tiles[0..n_tiles]) |ti| {
            const mask = self.masks[@as(usize, ti) * mask_words ..][0..mask_words];
            var any: u32 = 0;
            const tx: u32 = ti % cell.tiles_per_side;
            const ty: u32 = ti / cell.tiles_per_side;
            for (mask, 0..) |w, row| {
                any |= w;
                var bits = w;
                while (bits != 0) : (bits &= bits - 1) {
                    const col: u32 = @ctz(bits);
                    const i = cell.index(tx * cell.tile_size + col, ty * cell.tile_size + @as(u32, @intCast(row)));
                    self.cells[i] = self.next[i];
                }
            }
            if (any != 0 and self.sleep) self.markTileAndNeighbors(tx, ty);
        }
    }

    const WorkerOut = struct {
        events: [worker_event_capacity]rx.EventGpu = undefined,
        n: usize = 0,
        dropped: usize = 0,

        fn emit(o: *WorkerOut, x: i32, y: i32, kind: u32, payload: u32, tick: u32) void {
            if (o.n >= worker_event_capacity) {
                o.dropped += 1;
                return;
            }
            o.events[o.n] = .{ .pos = cell.wrap(x) | (cell.wrap(y) << 16), .kind = kind, .payload = payload, .tick = tick };
            o.n += 1;
        }
    };

    fn workerRun(self: *World, s: u32, tiles: []const u16, next_tile: *std.atomic.Value(usize), out: *WorkerOut) void {
        while (true) {
            const k = next_tile.fetchAdd(1, .monotonic);
            if (k >= tiles.len) return;
            const ti = tiles[k];
            const tx: u32 = ti % cell.tiles_per_side;
            const ty: u32 = ti / cell.tiles_per_side;
            const mask = self.masks[@as(usize, ti) * mask_words ..][0..mask_words];
            for (0..cell.tile_size) |row| {
                var w: u32 = 0;
                for (0..cell.tile_size) |col| {
                    const x = tx * cell.tile_size + @as(u32, @intCast(col));
                    const y = ty * cell.tile_size + @as(u32, @intCast(row));
                    const c = self.get(x, y);
                    const r = self.reactCell(@intCast(x), @intCast(y), c, s, out);
                    if (r != c) {
                        self.next[cell.index(x, y)] = r;
                        w |= @as(u32, 1) << @intCast(col);
                        // Particle-backed cells report their owner; the
                        // reference has no owner image (always 0).
                        if (cell.has(c, cell.flag_particle) and cell.material(r) != cell.material(c))
                            out.emit(@intCast(x), @intCast(y), @backingInt(rx.Event.particle_cell_changed), 0, self.tick);
                    }
                }
                mask[row] = w;
            }
        }
    }

    fn isBurning(self: *const World, c: u32) bool {
        return cell.has(c, cell.flag_burning) and self.mat(cell.material(c)).flags & Flag.flammable != 0;
    }

    /// reactions.comp catalyst_near.
    fn catalystNear(self: *const World, fx: i32, fy: i32, dx: i32, dy: i32, cat: u32) bool {
        const gx = fx + dx;
        const gy = fy + dy;
        const px = dy;
        const py = dx;
        const pts = [6][2]i32{
            .{ fx - dx, fy - dy }, .{ gx + dx, gy + dy },
            .{ fx + px, fy + py }, .{ fx - px, fy - py },
            .{ gx + px, gy + py }, .{ gx - px, gy - py },
        };
        for (pts) |q| if (cell.material(self.load(q[0], q[1])) == cat) return true;
        return false;
    }

    /// reactions.comp burn_out.
    fn burnOut(self: *const World, b: u32, t: u32, variant: u32) u32 {
        const bt = self.mat(b);
        const flammable = b != materials.air and bt.flags & Flag.flammable != 0;
        if (!flammable) return cell.make(b, t, bt.state_init, 0, variant);
        const st = if (bt.flags & Flag.has_health != 0) bt.state_init else bt.burn_fuel;
        return cell.make(b, t, st, cell.flag_burning, variant);
    }

    const dirs = [4][2]i32{ .{ 0, -1 }, .{ 1, 0 }, .{ 0, 1 }, .{ -1, 0 } };

    /// reactions.comp react_cell.
    fn reactCell(self: *const World, x: i32, y: i32, c: u32, s: u32, out: *WorkerOut) u32 {
        if (cell.has(c, cell.flag_body)) return c;
        const tick = self.tick;
        const m = cell.material(c);
        const mt = self.mat(m);
        const mflags = mt.flags;
        const variant = cell.variant(c);
        const tick_step = s == 0;
        const h = cell.hashPass(@bitCast(x), @bitCast(y), tick, s, rx.salt_cell);

        var n: [4]u32 = undefined;
        for (0..4) |i| n[i] = self.load(x + dirs[i][0], y + dirs[i][1]);

        // ---- pair reaction ----
        if (s < 4) {
            const horiz = s & 1 == 0;
            const parity = s >> 1;
            const coord: u32 = @bitCast(if (horiz) x else y);
            const first = (coord -% parity) & 1 == 0;
            const ddx: i32 = if (horiz) 1 else 0;
            const ddy: i32 = if (horiz) 0 else 1;
            const qi: usize = if (horiz) (if (first) 1 else 3) else (if (first) 2 else 0);
            const qx = x + dirs[qi][0];
            const qy = y + dirs[qi][1];
            const cq = n[qi];
            const mq = cell.material(cq);
            const e = self.tables.reactions[m * 256 + mq];
            if (e.chance != 0 and !cell.has(cq, cell.flag_body) and self.tileActiveAt(qx, qy)) {
                const fx = if (first) x else qx;
                const fy = if (first) y else qy;
                const hp = cell.hashPass(cell.wrap(fx), cell.wrap(fy), tick, s, rx.salt_pair);
                const tp = (cell.temperature(c) + cell.temperature(cq)) >> 1;
                var fire = tp >= e.min_temp and tp <= e.max_temp and cell.chance8(hp & 0xff, e.chance);
                if (fire and e.flags & materials.ReactionFlag.has_catalyst != 0) fire = self.catalystNear(fx, fy, ddx, ddy, e.catalyst);
                if (fire) {
                    const r: u32 = e.self_result;
                    if (e.flags & materials.ReactionFlag.emits_event != 0 and e.event != 0 and (m != mq or first)) out.emit(x, y, e.event, m, tick);
                    if (r != m) return self.spawnCell(r, variant);
                }
            }
        }

        // ---- heat ----
        var t: i32 = @intCast(cell.temperature(c));
        const flammable = mflags & Flag.flammable != 0;
        var burning = flammable and cell.has(c, cell.flag_burning);
        const conductive = mflags & Flag.conductive != 0;
        const k = mt.conductivity;
        const emit_self = mt.emits_heat + (if (burning) mt.burn_heat else 0);
        var flow: i32 = 0;
        var emit: i32 = 0;
        var given: i32 = 0;
        var extinguisher_near = false;
        var fire_near = false;
        var head_near = false;
        const flame = mt.flame;
        const self_gas = (mt.move & 0xff) == gas;
        for (n) |nc| {
            const nm = cell.material(nc);
            const nt = self.mat(nm);
            const nflags = nt.flags;
            const tn: i32 = @intCast(cell.temperature(nc));
            flow += @as(i32, @intCast(@min(k, nt.conductivity))) * (tn - t);
            const nburning = nflags & Flag.flammable != 0 and cell.has(nc, cell.flag_burning);
            if (tick_step and nm != m) {
                const en = nt.emits_heat + (if (nburning) nt.burn_heat else 0);
                if (tn > t and !self_gas) {
                    emit += @intCast(@min(en, @as(u32, @intCast(tn - t)) >> rx.emit_gap_shift));
                } else if (t > tn and (nt.move & 0xff) != gas) {
                    given += @intCast(@min(emit_self, @as(u32, @intCast(t - tn)) >> rx.emit_gap_shift));
                }
            }
            extinguisher_near = extinguisher_near or nflags & Flag.extinguisher != 0;
            fire_near = fire_near or nburning or (flame != materials.air and nm == flame);
            head_near = head_near or (nflags & Flag.conductive != 0 and cell.state(nc) >> cell.charge_shift == cell.charge_head);
        }
        t += (flow + @as(i32, @intCast(h & 8191))) >> rx.heat_shift;
        t += emit - (given >> rx.emit_drain_shift);
        if (burning and tick_step and t < @as(i32, rx.burn_temp)) t = @min(t + @as(i32, @intCast(mt.burn_heat)), @as(i32, rx.burn_temp));
        t = std.math.clamp(t, 0, 255);
        var tu: u32 = @intCast(t);

        const st = cell.state(c);
        var life = if (conductive) st & cell.conductive_state_mask else st;
        var charge = if (conductive) st >> cell.charge_shift else 0;

        // ---- burning ----
        if (flammable) {
            const doused = extinguisher_near and (mt.move & 0xff) != liquid;
            if (burning) {
                if (doused) {
                    burning = false;
                    tu = @min(tu, mt.ignite_at);
                } else if (tick_step and tick % mt.burn_period == 0) {
                    if (life <= 1) return self.burnOut(mt.burns_to, tu, variant);
                    life -= 1;
                }
            } else if (!doused) {
                var ign = tu > mt.ignite_at;
                if (!ign and tick_step and fire_near) ign = ((h >> 16) & 0xff) < rx.ignite_contact_chance;
                if (ign) {
                    burning = true;
                    if (mflags & Flag.has_health == 0) life = mt.burn_fuel;
                    if (mt.burn_event != 0) out.emit(x, y, mt.burn_event, m, tick);
                }
            }
        }

        // ---- phase change ----
        var to = m;
        if (tu > mt.boil_at) {
            to = mt.boil_to;
        } else if (tu > mt.melt_at) {
            to = mt.melt_to;
        } else if (tu < mt.freeze_at) {
            to = mt.freeze_to;
        }
        if (to != m) return cell.make(to, tu, self.mat(to).state_init, 0, variant);

        // ---- lifetime ----
        if (mflags & Flag.has_lifetime != 0 and !burning and tick_step and tick % mt.lifetime_period == 0) {
            if (life <= 1) return self.spawnCell(mt.decays_to, variant);
            life -= 1;
        }

        // ---- fire products ----
        if (m == materials.air and tick_step) {
            const start = h & 3;
            for (0..4) |j| {
                const nc = n[(start + j) & 3];
                if (!self.isBurning(nc)) continue;
                const bt = self.mat(cell.material(nc));
                const r = (h >> 20) & 0xff;
                if (r < rx.flame_chance and bt.flame != materials.air) return self.spawnCell(bt.flame, h >> 28);
                if (r >= rx.flame_chance and r < rx.flame_chance + rx.smoke_chance and bt.smoke != materials.air) return self.spawnCell(bt.smoke, h >> 28);
                break;
            }
        }

        // ---- charge ----
        if (conductive) {
            if (charge > 0) {
                charge -= 1;
            } else if (head_near) charge = cell.charge_head;
        }

        const ns = if (conductive) (life & cell.conductive_state_mask) | (charge << cell.charge_shift) else life;
        const r = cell.withState(cell.withTemperature(c, tu), ns);
        return cell.withFlag(r, cell.flag_burning, burning);
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
            for (0..4) |i| b.cache(self.tables, i);
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

    fn cache(b: *Block, tables: *const materials.Tables, i: usize) void {
        const mt = &tables.materials[cell.material(b.cell[i])];
        b.move[i] = mt.move;
        b.key[i] = mt.sort_key;
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

fn countMaterial(w: *const World, mat: u32) usize {
    var n: usize = 0;
    for (w.cells) |c| n += @intFromBool(cell.material(c) == mat);
    return n;
}

fn testWorld(tables: *const materials.Tables) !World {
    return World.init(std.testing.allocator, tables, true);
}

test "sand falls, piles and is conserved" {
    var lib = try materials.Library.builtin(std.testing.allocator);
    defer lib.deinit(std.testing.allocator);
    const ids = lib.ids();
    var w = try testWorld(lib.tables);
    defer w.deinit();
    var list: commands.CommandList = .{};
    list.begin(0);
    list.fillRect(900, 1100, 1100, 1110, ids.stone, .{});
    list.fillRect(990, 900, 1010, 960, ids.sand, .{});
    try w.step(list.slice());
    const sand0 = countMaterial(&w, ids.sand);
    try std.testing.expectEqual(@as(usize, 20 * 60), sand0);
    for (0..200) |_| try w.step(&.{});
    try std.testing.expectEqual(sand0, countMaterial(&w, ids.sand));
    // Everything rests on the floor: nothing left above y = 1040, a pile
    // wider than the column touches the floor.
    var above: usize = 0;
    var floor_row: usize = 0;
    for (0..cell.world_size) |x| {
        for (0..1040) |y| above += @intFromBool(cell.material(w.get(@intCast(x), @intCast(y))) == ids.sand);
        floor_row += @intFromBool(cell.material(w.get(@intCast(x), 1099)) == ids.sand);
    }
    try std.testing.expectEqual(@as(usize, 0), above);
    try std.testing.expect(floor_row > 20);
    // Settled: the world went to sleep.
    for (0..20) |_| try w.step(&.{});
    try std.testing.expectEqual(@as(u32, 0), w.activeTiles());
}

test "water spreads flat, smoke rises, sand sinks in water" {
    var lib = try materials.Library.builtin(std.testing.allocator);
    defer lib.deinit(std.testing.allocator);
    const ids = lib.ids();
    var w = try testWorld(lib.tables);
    defer w.deinit();
    var list: commands.CommandList = .{};
    list.begin(0);
    list.fillRect(500, 1000, 640, 1010, ids.stone, .{}); // floor
    list.fillRect(500, 900, 510, 1000, ids.stone, .{}); // walls
    list.fillRect(630, 900, 640, 1000, ids.stone, .{});
    list.fillRect(520, 940, 540, 1000, ids.water, .{}); // a water column, 1200 cells
    list.fillRect(560, 990, 580, 1000, ids.smoke, .{}); // smoke on the floor
    list.fillRect(525, 900, 535, 910, ids.sand, .{}); // sand falling into the water
    try w.step(list.slice());
    for (0..800) |_| try w.step(&.{});
    // 1200 water over 120 columns, with 100 sand under it: about 10.8 rows.
    var lo: u32 = 1000;
    var hi: u32 = 0;
    for (510..630) |x| {
        var top: u32 = 1000;
        for (900..1000) |y| {
            if (cell.material(w.get(@intCast(x), @intCast(y))) == ids.water) {
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
        smoke_inside += @intFromBool(cell.material(w.get(@intCast(x), @intCast(y))) == ids.smoke);
    };
    try std.testing.expectEqual(@as(usize, 0), smoke_inside);
    try std.testing.expectEqual(@as(usize, 200), countMaterial(&w, ids.smoke));
    try std.testing.expectEqual(@as(usize, 1200), countMaterial(&w, ids.water));
    // Sand sank to the floor under the water.
    var sand_floor: usize = 0;
    for (510..630) |x| sand_floor += @intFromBool(cell.material(w.get(@intCast(x), 999)) == ids.sand);
    try std.testing.expect(sand_floor > 0);
}

test "static never moves and wrap is seamless" {
    var lib = try materials.Library.builtin(std.testing.allocator);
    defer lib.deinit(std.testing.allocator);
    const ids = lib.ids();
    var w = try testWorld(lib.tables);
    defer w.deinit();
    var list: commands.CommandList = .{};
    list.begin(0);
    list.fillRect(100, 100, 110, 110, ids.stone, .{});
    list.fillRect(-4, cell.world_size - 20, 4, cell.world_size - 12, ids.sand, .{});
    try w.step(list.slice());
    for (0..30) |_| try w.step(&.{});
    for (100..110) |x| for (100..110) |y| {
        try std.testing.expectEqual(@as(u32, ids.stone), cell.material(w.get(@intCast(x), @intCast(y))));
    };
    // The sand fell across the bottom edge and is now near the top.
    var near_top: usize = 0;
    for (0..400) |y| for (0..8) |dx| {
        const x: u32 = @intCast((cell.world_size - 4 + dx) % cell.world_size);
        near_top += @intFromBool(cell.material(w.get(x, @intCast(y))) == ids.sand);
    };
    try std.testing.expect(near_top > 0);
    try std.testing.expectEqual(@as(usize, 64), countMaterial(&w, ids.sand));
}

// ---- reactions: mechanism tests on a small synthetic set (short burn
// ---- times keep them fast in Debug) and the shipped set ----

fn testSrc(comptime name: []const u8, comptime body: []const u8) @import("data").materials.Source {
    return .{ .path = "t/" ++ name ++ ".zon", .text = ".{ .name = \"" ++ name ++ "\", " ++ body ++ ", .ramp = .{ 1, 2, 3, 4 } }" };
}

const synthetic_sources = [_]@import("data").materials.Source{
    testSrc("floor", ".id = 1, .phase = .static, .density = 1000, .conductivity = 30"),
    testSrc("wood", ".id = 2, .phase = .static, .density = 60, .health = 8, .conductivity = 10, .flammable = .{ .ignite_at = 300, .burn_ticks = 40, .to = \"coal\", .smoke = \"smoke\", .heat = 24 }"),
    testSrc("coal", ".id = 3, .phase = .static, .density = 50, .health = 4, .conductivity = 15, .flammable = .{ .ignite_at = 400, .burn_ticks = 40, .to = \"ash\", .smoke = \"smoke\", .heat = 40 }"),
    testSrc("ash", ".id = 4, .phase = .powder, .density = 30, .slide = 220, .conductivity = 10"),
    testSrc("smoke", ".id = 5, .phase = .gas, .density = 8, .dispersion = 4, .lifetime = 60, .decays_to = \"air\", .conductivity = 10"),
    testSrc("flame", ".id = 6, .phase = .gas, .density = 3, .dispersion = 2, .lifetime = 10, .decays_to = \"air\", .temperature = 900, .conductivity = 80, .emits_heat = 60"),
    testSrc("water", ".id = 7, .phase = .liquid, .density = 100, .dispersion = 5, .conductivity = 60, .conductive = true, .extinguishes = true"),
    testSrc("oil", ".id = 8, .phase = .liquid, .density = 80, .dispersion = 4, .conductivity = 20, .flammable = .{ .ignite_at = 250, .burn_ticks = 30, .to = \"smoke\", .smoke = \"smoke\", .heat = 24 }"),
    testSrc("ice", ".id = 9, .phase = .static, .density = 90, .temperature = -10, .conductivity = 60, .melt = .{ .at = 0, .to = \"water\" }"),
    testSrc("rod", ".id = 10, .phase = .static, .density = 800, .health = 63, .conductivity = 220, .conductive = true"),
};

const TestSet = struct {
    lib: materials.Library,
    fn init() !TestSet {
        var diag: materials.Diagnostics = .init(std.testing.allocator);
        defer diag.deinit();
        var set = @import("data").materials.loadSources(std.testing.allocator, &synthetic_sources, &diag) catch |err| {
            std.debug.print("{f}\n", .{diag});
            return err;
        };
        errdefer set.deinit();
        return .{ .lib = .{ .set = set, .tables = try materials.gpu_tables.build(std.testing.allocator, &set) } };
    }
    fn deinit(self: *TestSet) void {
        self.lib.deinit(std.testing.allocator);
    }
    fn id(self: *const TestSet, name: []const u8) u8 {
        return self.lib.id(name).?;
    }
};

fn countIn(w: *const World, mat: u32, x0: u32, y0: u32, x1: u32, y1: u32) usize {
    var n: usize = 0;
    for (y0..y1) |y| for (x0..x1) |x| {
        n += @intFromBool(cell.material(w.get(@intCast(x), @intCast(y))) == mat);
    };
    return n;
}

test "wood burns to coal then ash, with smoke and flame" {
    var ts = try TestSet.init();
    defer ts.deinit();
    var w = try testWorld(ts.lib.tables);
    defer w.deinit();
    var list: commands.CommandList = .{};
    list.begin(0);
    list.fillRect(100, 140, 140, 150, ts.id("floor"), .{});
    list.fillRect(110, 132, 126, 140, ts.id("wood"), .{});
    try w.step(list.slice());
    list.begin(1);
    list.igniteRect(110, 132, 126, 140);
    try w.step(list.slice());
    var saw_smoke = false;
    var saw_flame = false;
    var saw_coal = false;
    for (0..200) |_| {
        try w.step(&.{});
        saw_smoke = saw_smoke or countMaterial(&w, ts.id("smoke")) > 0;
        saw_flame = saw_flame or countMaterial(&w, ts.id("flame")) > 0;
        saw_coal = saw_coal or countMaterial(&w, ts.id("coal")) > 0;
    }
    try std.testing.expect(saw_smoke and saw_flame and saw_coal);
    try std.testing.expectEqual(@as(usize, 0), countMaterial(&w, ts.id("wood")));
    try std.testing.expectEqual(@as(usize, 0), countMaterial(&w, ts.id("coal")));
    try std.testing.expectEqual(@as(usize, 16 * 8), countMaterial(&w, ts.id("ash")));
}

test "heat ignites wood next to burning wood" {
    var ts = try TestSet.init();
    defer ts.deinit();
    var w = try testWorld(ts.lib.tables);
    defer w.deinit();
    var list: commands.CommandList = .{};
    list.begin(0);
    list.fillRect(100, 100, 140, 104, ts.id("wood"), .{});
    try w.step(list.slice());
    list.begin(1);
    list.igniteRect(100, 100, 102, 104); // light one end only
    try w.step(list.slice());
    for (0..30) |_| try w.step(&.{});
    var burning: usize = 0;
    for (100..104) |y| for (100..140) |x| {
        burning += @intFromBool(cell.has(w.get(@intCast(x), @intCast(y)), cell.flag_burning));
    };
    try std.testing.expect(burning > 8); // the fire spread beyond the lit cells
}

test "water douses burning wood but burning oil floats on water and keeps burning" {
    var ts = try TestSet.init();
    defer ts.deinit();
    var w = try testWorld(ts.lib.tables);
    defer w.deinit();
    var list: commands.CommandList = .{};
    list.begin(0);
    list.fillRect(90, 140, 170, 150, ts.id("floor"), .{});
    list.fillRect(90, 100, 94, 140, ts.id("floor"), .{});
    list.fillRect(166, 100, 170, 140, ts.id("floor"), .{});
    list.fillRect(94, 130, 166, 140, ts.id("water"), .{});
    list.fillRect(110, 126, 150, 128, ts.id("oil"), .{});
    list.fillRect(40, 136, 60, 140, ts.id("wood"), .{});
    list.fillRect(40, 140, 60, 142, ts.id("floor"), .{});
    try w.step(list.slice());
    for (0..20) |_| try w.step(&.{});
    list.begin(w.tick);
    list.igniteRect(90, 100, 170, 140);
    list.igniteRect(40, 136, 60, 140);
    try w.step(list.slice());
    // Douse the wood from above.
    list.begin(w.tick);
    list.fillRect(40, 130, 60, 136, ts.id("water"), .{});
    try w.step(list.slice());
    try w.step(&.{});
    var wood_burning: usize = 0;
    var oil_burning: usize = 0;
    for (w.cells) |c| {
        if (!cell.has(c, cell.flag_burning)) continue;
        if (cell.material(c) == ts.id("wood")) wood_burning += 1;
        if (cell.material(c) == ts.id("oil")) oil_burning += 1;
    }
    try std.testing.expect(oil_burning > 0);
    // Only the wood's bottom row may still burn (water reaches it later).
    try std.testing.expect(wood_burning < 20 * 4);
    // The oil floats: no oil below the water surface.
    try std.testing.expectEqual(@as(usize, 0), countIn(&w, ts.id("oil"), 94, 133, 166, 140));
}

test "ice melts to water and keeps its temperature" {
    var ts = try TestSet.init();
    defer ts.deinit();
    var w = try testWorld(ts.lib.tables);
    defer w.deinit();
    var list: commands.CommandList = .{};
    list.begin(0);
    list.fillRect(100, 100, 104, 104, ts.id("ice"), .{});
    try w.step(list.slice());
    list.begin(1);
    list.heatRect(100, 100, 104, 104, 30); // 200 C
    try w.step(list.slice());
    try std.testing.expectEqual(@as(usize, 0), countMaterial(&w, ts.id("ice")));
    try std.testing.expectEqual(@as(usize, 16), countMaterial(&w, ts.id("water")));
    var hottest: u32 = 0;
    for (w.cells) |c| {
        if (cell.material(c) == ts.id("water")) hottest = @max(hottest, cell.temperature(c));
    }
    try std.testing.expect(hottest > 20); // melted at 200 C, not respawned at 20 C
}

test "a charge pulse runs along a rod and does not come back" {
    var ts = try TestSet.init();
    defer ts.deinit();
    var w = try testWorld(ts.lib.tables);
    defer w.deinit();
    var list: commands.CommandList = .{};
    list.begin(0);
    list.fillRect(100, 100, 300, 101, ts.id("rod"), .{});
    try w.step(list.slice());
    list.begin(1);
    list.chargeCircle(100, 100, 0);
    try w.step(list.slice());
    // 8 substeps per tick: after this tick and the next, the head is ~16 cells along.
    try w.step(&.{});
    var head: ?u32 = null;
    var charged: usize = 0;
    for (100..300) |x| {
        const c = w.get(@intCast(x), 100);
        const q = cell.state(c) >> cell.charge_shift;
        if (q != 0) charged += 1;
        if (q == cell.charge_head) head = @intCast(x);
        try std.testing.expectEqual(@as(u32, 63), cell.state(c) & cell.conductive_state_mask); // health kept
    }
    try std.testing.expect(head != null and head.? > 110 and head.? < 125);
    try std.testing.expect(charged <= 3);
    for (0..40) |_| try w.step(&.{});
    var left: usize = 0;
    for (100..300) |x| left += @intFromBool(cell.state(w.get(@intCast(x), 100)) >> cell.charge_shift != 0);
    try std.testing.expectEqual(@as(usize, 0), left); // ran off the end, no echo
}

test "shipped set: water on lava makes stone and steam" {
    var diag: materials.Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    var lib = try materials.Library.loadDir(std.testing.io, std.testing.allocator, materials.default_dir, &diag);
    defer lib.deinit(std.testing.allocator);
    const ids = lib.ids();
    var w = try testWorld(lib.tables);
    defer w.deinit();
    var list: commands.CommandList = .{};
    list.begin(0);
    list.fillRect(100, 140, 200, 150, ids.bedrock, .{});
    list.fillRect(100, 120, 150, 140, ids.lava, .{});
    list.fillRect(150, 120, 200, 140, ids.water, .{});
    try w.step(list.slice());
    for (0..30) |_| try w.step(&.{});
    try std.testing.expect(countMaterial(&w, ids.stone) > 10);
    try std.testing.expect(countMaterial(&w, lib.id("steam").?) > 10);
}
