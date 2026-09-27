const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Modules
    const flacontainer = b.addModule("flacontainer", .{
        .root_source_file = b.path("modules/flacontainer/flacontainer.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ziggyflac = b.addModule("ziggyflac", .{
        .root_source_file = b.path("modules/ziggyflac/ziggyflac.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "flacontainer", .module = flacontainer },
        },
    });

    // Library installation
    const ziggyflac_lib = b.addLibrary(.{
        .name = "ziggyflac",
        .root_module = ziggyflac,
        .linkage = .static,
    });
    b.installArtifact(ziggyflac_lib);

    const flacontainer_lib = b.addLibrary(.{
        .name = "flacontainer",
        .root_module = flacontainer,
        .linkage = .static,
    });
    b.installArtifact(flacontainer_lib);

    // Tests
    const ziggyflac_mod_tests = b.addTest(.{
        .root_module = ziggyflac,
    });
    const flacontainer_mod_tests = b.addTest(.{
        .root_module = flacontainer,
    });
    const run_ziggyflac_mod_tests = b.addRunArtifact(ziggyflac_mod_tests);
    const run_flacontainer_mod_tests = b.addRunArtifact(flacontainer_mod_tests);

    // Test step
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_ziggyflac_mod_tests.step);
    test_step.dependOn(&run_flacontainer_mod_tests.step);
}
