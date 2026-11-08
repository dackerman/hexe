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

    // --- bodies ---
    // Box2D v3.2.0 (package dependency, built by its own build.zig: SIMD on,
    // SSE2 baseline with runtime AVX2 dispatch, -ffp-contract=off) and the CPU
    // rigid-body layer in src/sim/bodies.zig. `box2d` is also importable from
    // the exe module so main can pull in src/sim/bodies.zig by path.
    // See docs/decisions/01-box2d-build-and-bindings.md.
    {
        const box2d_dep = b.dependency("box2d", .{ .target = target, .optimize = optimize });
        const box2d_mod = box2d_dep.module("box2d");
        exe_mod.addImport("box2d", box2d_mod);

        const bodies_mod = b.createModule(.{
            .root_source_file = b.path("src/sim/bodies.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "box2d", .module = box2d_mod }},
        });
        const bodies_tests = b.addTest(.{ .name = "bodies-test", .root_module = bodies_mod });
        test_step.dependOn(&b.addRunArtifact(bodies_tests).step);

        const demo_mod = b.createModule(.{
            .root_source_file = b.path("tools/bodies_demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "bodies", .module = bodies_mod }},
        });
        const demo = b.addExecutable(.{ .name = "bodies-demo", .root_module = demo_mod });
        const demo_run = b.addRunArtifact(demo);
        demo_run.addPassthruArgs();
        b.step("bodies-demo", "Headless beam bend-and-snap demo (ASCII)").dependOn(&demo_run.step);
    }
    // --- end bodies ---
}
