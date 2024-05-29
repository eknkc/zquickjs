const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zquickjs = b.addModule("zquickjs", .{
        .root_source_file = .{ .path = "src/root.zig" },
        .link_libc = true,
        .target = target,
        .optimize = optimize,
    });

    setupModule(zquickjs, target);

    const lib = b.addStaticLibrary(.{
        .name = "zquickjs",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    setupModule(&lib.root_module, target);

    zquickjs.linkLibrary(lib);

    const install_docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Copy documentation artifacts to prefix path");
    docs_step.dependOn(&install_docs.step);

    const tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    setupModule(&tests.root_module, target);

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");

    test_step.dependOn(&run_tests.step);
}

fn setupModule(module: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    module.link_libc = true;

    module.addIncludePath(.{
        .path = "c/quickjs",
    });

    module.addCSourceFiles(.{ .files = &.{
        "c/quickjs/cutils.c",
        "c/quickjs/libregexp.c",
        "c/quickjs/libunicode.c",
        "c/quickjs/libbf.c",
        "c/quickjs/quickjs.c",
    }, .flags = &.{} });

    module.addCMacro("CONFIG_VERSION", "\"2021-03-27\"");
    module.addCMacro("CONFIG_BIGNUM", "1");

    if (target.result.cpu.arch.isWasm()) {
        module.addCMacro("EMSCRIPTEN", "1");
        module.addCMacro("FE_DOWNWARD", "0");
        module.addCMacro("FE_UPWARD", "0");
    }
}
