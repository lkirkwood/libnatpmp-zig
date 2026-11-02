const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // Translate the C headers.
    const translated_natpmp = b.addTranslateC(.{
        .root_source_file = b.path("include/natpmp.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const mod = b.addModule(
        "natpmp_zig",
        .{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{
                    .name = "natpmp_c",
                    .module = translated_natpmp.createModule(),
                },
            },
        },
    );
    mod.linkSystemLibrary("natpmp", .{});

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
        .use_llvm = true,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    // Client stuff

    const client_mod = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "natpmp", .module = mod },
        },
    });

    const client_exe = b.addExecutable(.{
        .name = "natpmpctl",
        .use_llvm = true,
        .root_module = client_mod,
    });
    b.installArtifact(client_exe);

    const client_exe_tests = b.addTest(.{
        .root_module = client_mod,
        .use_llvm = true,
    });

    const check_client_exe = b.addExecutable(.{
        .name = "natpmpctl",
        .root_module = client_mod,
    });

    const check_client_step = b.step("check", "Check the program compiles.");
    check_client_step.dependOn(&check_client_exe.step);
    check_client_step.dependOn(&client_exe_tests.step);
}
