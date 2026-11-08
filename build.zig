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

    // --- data ---
    // Material/scenario data layer (src/data), its tests, and `zig build docs`.
    const data_options = b.addOptions();
    data_options.addOption([]const u8, "materials_dir", "materials");
    data_options.addOption([]const u8, "scenarios_dir", "scenarios");
    const data_mod = b.createModule(.{
        .root_source_file = b.path("src/data/data.zig"),
        .target = target,
        .optimize = optimize,
    });
    data_mod.addOptions("build_options", data_options);
    exe_mod.addImport("data", data_mod);

    const data_tests = b.addTest(.{ .root_module = data_mod });
    const run_data_tests = b.addRunArtifact(data_tests);
    run_data_tests.setCwd(b.path(".")); // tests read materials/ and scenarios/
    run_data_tests.has_side_effects = true; // rerun when data files change
    test_step.dependOn(&run_data_tests.step);

    const gendocs = b.addExecutable(.{
        .name = "gendocs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gendocs.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "data", .module = data_mod }},
        }),
    });
    const run_gendocs = b.addRunArtifact(gendocs);
    run_gendocs.setCwd(b.path("."));
    run_gendocs.addArgs(&.{ "materials", "docs/materials.md" });
    b.step("docs", "Regenerate docs/materials.md from materials/").dependOn(&run_gendocs.step);
    // --- end data ---
}
