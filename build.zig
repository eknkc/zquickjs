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

    zquickjs.addIncludePath(.{
        .path = "c/quickjs",
    });

    zquickjs.addCSourceFiles(.{ .files = &.{
        "c/quickjs/cutils.c",
        "c/quickjs/libregexp.c",
        "c/quickjs/libunicode.c",
        "c/quickjs/libbf.c",
        "c/quickjs/quickjs.c",
    }, .flags = &.{} });

    zquickjs.addCMacro("CONFIG_VERSION", "\"2021-03-27\"");
    zquickjs.addCMacro("CONFIG_BIGNUM", "1");

    if (target.result.cpu.arch.isWasm()) {
        zquickjs.addCMacro("EMSCRIPTEN", "1");
        zquickjs.addCMacro("FE_DOWNWARD", "0");
        zquickjs.addCMacro("FE_UPWARD", "0");
    }

    const lib = b.addStaticLibrary(.{
        .name = "zquickjs",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    lib.root_module.addIncludePath(.{
        .path = "c/quickjs",
    });

    const install_docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Copy documentation artifacts to prefix path");
    docs_step.dependOn(&install_docs.step);
}
