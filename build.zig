const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const zquickjs = b.addModule("zquickjs", .{
        .root_source_file = .{ .path = "src/root.zig" },
    });

    zquickjs.addIncludePath(.{
        .path = "c/quickjs",
    });

    const lib = b.addStaticLibrary(.{
        .name = "zquickjs",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    zquickjs.linkLibrary(lib);

    bindQuickjsLibc(lib, target);

    b.installArtifact(lib);

    const install_docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Copy documentation artifacts to prefix path");
    docs_step.dependOn(&install_docs.step);
}

fn bindQuickjsLibc(step: *std.Build.Step.Compile, target: std.Build.ResolvedTarget) void {
    step.addIncludePath(.{ .path = "c/quickjs" });

    step.addCSourceFiles(.{ .files = &.{
        "c/quickjs/cutils.c",
        "c/quickjs/libregexp.c",
        "c/quickjs/libunicode.c",
        "c/quickjs/libbf.c",
        "c/quickjs/quickjs.c",
    }, .flags = &.{} });

    step.defineCMacro("CONFIG_VERSION", "\"2021-03-27\"");
    step.defineCMacro("CONFIG_BIGNUM", "1");

    if (target.result.cpu.arch.isWasm()) {
        step.defineCMacro("EMSCRIPTEN", "1");
        step.defineCMacro("FE_DOWNWARD", "0");
        step.defineCMacro("FE_UPWARD", "0");
    }

    step.linkLibC();
}
