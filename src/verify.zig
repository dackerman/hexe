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
const materials_builtin = @import("sim/materials_builtin.zig");
const reference = @import("sim/reference/grid.zig");

pub fn run(gpa: std.mem.Allocator, io: std.Io, cli: Cli) !u8 {
    _ = io;
    const table = materials_builtin.table();
    var failures: u32 = 0;
    const modes = [_]bool{ true, false };
    for (modes, 0..) |sleep, n| {
        if (!cli.sleep and sleep) continue;
        const engine = try gpa.create(Engine);
        defer gpa.destroy(engine);
        try engine.init(gpa, .{ .table = &table, .validation = cli.validation orelse false, .pipeline = .{ .sleep = sleep, .air = false } });
        defer engine.deinit();
        if (n == 0) failures += try accessorTest(gpa, engine);
        failures += try determinism(gpa, engine, &table, cli, sleep, .determinism, if (cli.ticks == 0) 300 else cli.ticks);
        // M4 commands (line, temperature, ignite, eject's cell edits) on a
        // fresh world, compared right after the eject tick: the particles it
        // spawned have not moved yet (docs/decisions/54-commands-m4.md).
        const e2 = try gpa.create(Engine);
        defer gpa.destroy(e2);
        try e2.init(gpa, .{ .table = &table, .validation = cli.validation orelse false, .pipeline = .{ .sleep = sleep, .air = false } });
        defer e2.deinit();
        failures += try determinism(gpa, e2, &table, cli, sleep, .determinism_commands, scenes.determinism_commands_ticks);
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

fn determinism(gpa: std.mem.Allocator, engine: *Engine, table: *const @import("sim/materials.zig").Table, cli: Cli, sleep: bool, scene: scenes.Scene, ticks: u32) !u32 {
    const seed = cli.seed;

    for (0..ticks) |_| try engine.frame(1, .{ .scene = scene, .seed = seed }, null);
    const gpu_cells = try gpa.alloc(u32, cell.world_size * cell.world_size);
    defer gpa.free(gpu_cells);
    try engine.readbackCells(gpu_cells);

    var world = try reference.World.init(gpa, table, sleep);
    defer world.deinit();
    var list: commands.CommandList = .{};
    var t: u32 = 0;
    while (t < ticks) : (t += 1) {
        list.begin(t);
        scenes.emit(scene, t, seed, &list);
        world.step(list.slice());
    }

    var mismatches: usize = 0;
    var counts: [256]usize = @splat(0);
    var moved: usize = 0;
    for (gpu_cells, world.cells, 0..) |g, c, i| {
        counts[cell.material(c)] += 1;
        moved += @intFromBool(cell.has(c, cell.flag_moved));
        if (g != c) {
            if (mismatches < 10) {
                const x = i % cell.world_size;
                const y = i / cell.world_size;
                std.debug.print("  cell ({d},{d}): gpu 0x{x:0>8} (m{d}) cpu 0x{x:0>8} (m{d})\n", .{ x, y, g, cell.material(g), c, cell.material(c) });
            }
            mismatches += 1;
        }
    }
    std.debug.print("{s} (sleep {s}, seed {d}, {d} ticks): {d} cells differ; active tiles cpu {d} gpu {d}; stone {d} sand {d} water {d} smoke {d}, {d} moved in last substep\n", .{
        @tagName(scene),                 if (sleep) "on" else "off", seed,                            ticks,                          mismatches,
        world.activeTiles(),             engine.last.active_tiles,   counts[materials_builtin.stone], counts[materials_builtin.sand], counts[materials_builtin.water],
        counts[materials_builtin.smoke], moved,
    });
    return @intFromBool(mismatches != 0);
}
