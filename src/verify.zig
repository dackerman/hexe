//! `zig build verify-determinism`: the GPU grid against the CPU reference,
//! bit for bit, on the seeded determinism scenario; plus the cell accessor
//! and hash mirrors run on the GPU.
const std = @import("std");
const gpu = @import("gpu/gpu.zig");
const vk = gpu.vk;
const shaders = @import("shaders");
const Cli = @import("main.zig").Cli;
const Engine = @import("engine.zig").Engine;
const cell = @import("sim/cell.zig");
const commands = @import("sim/commands.zig");
const scenes = @import("sim/scenes.zig");
const materials = @import("sim/materials.zig");
const reference = @import("sim/reference/grid.zig");
const reactions = @import("sim/reactions.zig");

pub fn run(gpa: std.mem.Allocator, io: std.Io, cli: Cli, lib: *const materials.Library) !u8 {
    _ = io;
    var failures: u32 = 0;
    const modes = [_]bool{ true, false };
    for (modes, 0..) |sleep, n| {
        if (!cli.sleep and sleep) continue;
        const engine = try gpa.create(Engine);
        defer gpa.destroy(engine);
        try engine.init(gpa, .{ .tables = lib.tables, .ids = lib.ids(), .validation = cli.validation orelse false, .pipeline = .{ .sleep = sleep } });
        defer engine.deinit();
        if (n == 0) failures += try accessorTest(gpa, engine);
        failures += try determinism(gpa, engine, lib, cli, sleep);
    }
    if (failures == 0) {
        std.debug.print("verify-determinism: PASS\n", .{});
        return 0;
    }
    std.debug.print("verify-determinism: FAIL ({d} failures)\n", .{failures});
    return 1;
}

fn accessorTest(gpa: std.mem.Allocator, engine: *Engine) !u32 {
    const ctx = &engine.ctx;
    const n = 4096;
    var input = try gpu.Buffer.initSlotted(ctx, n * 4, .{}, .cpu_to_gpu);
    defer input.deinit(ctx);
    var output = try gpu.Buffer.initSlotted(ctx, n * 4 * cell.accessor_test_stride, .{}, .gpu_to_cpu);
    defer output.deinit(ctx);
    cell.accessorTestSamples(input.typed(u32));
    const pipeline = try gpu.pipelines.createCompute(ctx, &shaders.test_cell_accessors_comp);
    defer gpu.pipelines.destroy(ctx, pipeline);
    try ctx.runOnce(.compute, recordAccessor, .{ ctx, pipeline, input.slot, output.slot, @as(u32, n) });
    const got = output.typed(u32);
    _ = gpa;
    var bad: u32 = 0;
    for (input.typed(u32), 0..) |c, i| {
        const want = cell.accessorTestExpected(c, @intCast(i));
        for (want, 0..) |w, k| {
            const g = got[i * cell.accessor_test_stride + k];
            if (g != w) {
                if (bad < 10) std.debug.print("  accessor mismatch: sample {d} (0x{x:0>8}) field {d}: gpu 0x{x} cpu 0x{x}\n", .{ i, c, k, g, w });
                bad += 1;
            }
        }
    }
    std.debug.print("cell accessors + hash, {d} samples x {d} fields: {s}\n", .{ n, cell.accessor_test_stride, if (bad == 0) "match" else "MISMATCH" });
    return @intFromBool(bad != 0);
}

fn recordAccessor(cmd: vk.CommandBuffer, ctx: *gpu.Context, pipeline: vk.Pipeline, in_slot: u32, out_slot: u32, count: u32) void {
    ctx.vkd.cmdBindPipeline(cmd, .compute, pipeline);
    gpu.pipelines.push(ctx, cmd, extern struct { a: u32, b: u32, n: u32 }{ .a = in_slot, .b = out_slot, .n = count });
    ctx.vkd.cmdDispatch(cmd, (count + 63) / 64, 1, 1);
    gpu.memory.memoryBarrier(ctx, cmd, .{ .compute_shader = true }, .{ .shader_storage_write = true }, .{ .host = true }, .{ .host_read = true });
}

fn determinism(gpa: std.mem.Allocator, engine: *Engine, lib: *const materials.Library, cli: Cli, sleep: bool) !u32 {
    const ticks: u32 = if (cli.ticks == 0) 300 else cli.ticks;
    const seed = cli.seed;
    const scene: scenes.Scene = .determinism;
    const ids = lib.ids();

    for (0..ticks) |_| try engine.frame(1, .{ .scene = scene, .seed = seed }, null);
    const gpu_cells = try gpa.alloc(u32, cell.world_size * cell.world_size);
    defer gpa.free(gpu_cells);
    try engine.readbackCells(gpu_cells);
    var gpu_events: [reactions.event_capacity]reactions.EventGpu = undefined;
    const drained = engine.pipeline.reactions.drainEvents(&gpu_events);

    var world = try reference.World.init(gpa, lib.tables, sleep);
    defer world.deinit();
    var list: commands.CommandList = .{};
    var t: u32 = 0;
    while (t < ticks) : (t += 1) {
        list.begin(t);
        scenes.emit(scene, t, seed, &ids, &list);
        try world.step(list.slice());
    }

    var mismatches: usize = 0;
    var counts: [256]usize = @splat(0);
    var moved: usize = 0;
    var burning: usize = 0;
    var charged: usize = 0;
    for (gpu_cells, world.cells, 0..) |g, c, i| {
        counts[cell.material(c)] += 1;
        moved += @intFromBool(cell.has(c, cell.flag_moved));
        burning += @intFromBool(cell.has(c, cell.flag_burning));
        charged += @intFromBool(lib.tables.materials[cell.material(c)].flags & materials.Flag.conductive != 0 and cell.state(c) >> cell.charge_shift != 0);
        if (g != c) {
            if (mismatches < 10) {
                const x = i % cell.world_size;
                const y = i / cell.world_size;
                std.debug.print("  cell ({d},{d}): gpu 0x{x:0>8} ({s}) cpu 0x{x:0>8} ({s})\n", .{ x, y, g, lib.name(@intCast(cell.material(g))), c, lib.name(@intCast(cell.material(c))) });
            }
            mismatches += 1;
        }
    }
    std.debug.print("determinism (sleep {s}, seed {d}, {d} ticks): {d} cells differ; active tiles cpu {d} gpu {d}; {d} moved in last substep, {d} burning, {d} charged\n", .{
        if (sleep) "on" else "off", seed, ticks, mismatches, world.activeTiles(), engine.last.active_tiles, moved, burning, charged,
    });
    std.debug.print("  ", .{});
    for (lib.set.materials) |m| {
        if (counts[m.id] > 0 and m.id != 0) std.debug.print("{s} {d}  ", .{ m.def.name, counts[m.id] });
    }
    std.debug.print("\n", .{});

    // Events: the same set on both sides (GPU order is not deterministic).
    const cpu_events = world.events.items;
    std.mem.sort(reactions.EventGpu, gpu_events[0..drained.n], {}, reactions.EventGpu.lessThan);
    std.mem.sort(reactions.EventGpu, cpu_events, {}, reactions.EventGpu.lessThan);
    const events_ok = drained.lost == 0 and drained.n == cpu_events.len and
        std.mem.eql(u8, std.mem.sliceAsBytes(gpu_events[0..drained.n]), std.mem.sliceAsBytes(cpu_events));
    std.debug.print("  events: gpu {d} (lost {d}) cpu {d}: {s}\n", .{ drained.n, drained.lost, cpu_events.len, if (events_ok) "match" else "MISMATCH" });
    return @intFromBool(mismatches != 0) + @intFromBool(!events_ok);
}
