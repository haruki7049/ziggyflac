const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Modules
    const mod = b.addModule("ziggyflac", .{
        .root_source_file = b.path("src/ziggyflac.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Library installation
    const lib = b.addLibrary(.{
        .name = "ziggyflac",
        .root_module = mod,
        .linkage = .static,
    });
    b.installArtifact(lib);

    // Tests
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Test step
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}
