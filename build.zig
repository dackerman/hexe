const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{ .name = "hexe", .root_module = exe_mod });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run hexe").dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run all unit tests");
    const exe_tests = b.addTest(.{ .root_module = exe_mod });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    // --- world ---
    const world_mod = b.createModule(.{
        .root_source_file = b.path("src/world/world.zig"),
        .target = target,
        .optimize = optimize,
    });
    const world_tests = b.addTest(.{ .root_module = world_mod });
    test_step.dependOn(&b.addRunArtifact(world_tests).step);

    const worldgen_exe = b.addExecutable(.{
        .name = "worldgen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/worldgen.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "world", .module = world_mod }},
        }),
    });
    const worldgen_run = b.addRunArtifact(worldgen_exe);
    worldgen_run.addPassthruArgs();
    b.step("worldgen", "Generate a procgen preview image (world)").dependOn(&worldgen_run.step);
    // --- end world ---
}
