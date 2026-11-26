const std = @import("std");

/// Whether a missing `flac` executable fails the interoperability tests
/// (`required`) or skips them (`auto`).
const FlacInterop = enum { auto, required };

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

    // Interoperability tests: the encoder's output is decoded by the reference
    // `flac` decoder. They live in their own root module so that the build
    // option below stays out of the public `ziggyflac` module.
    const flac_interop = b.option(
        FlacInterop,
        "flac-interop",
        "Whether the interoperability tests need the reference `flac` decoder: " ++
            "`auto` (default) skips them when `flac` is not on PATH, " ++
            "`required` fails them instead",
    ) orelse .auto;
    const interop_options = b.addOptions();
    interop_options.addOption(bool, "flac_required", flac_interop == .required);

    const interop_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/interop/interop.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ziggyflac", .module = ziggyflac },
                .{ .name = "build_options", .module = interop_options.createModule() },
            },
        }),
    });
    const run_interop_tests = b.addRunArtifact(interop_tests);

    // Test step
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_ziggyflac_mod_tests.step);
    test_step.dependOn(&run_flacontainer_mod_tests.step);
    test_step.dependOn(&run_interop_tests.step);
}
