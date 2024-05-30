const runtime = @import("runtime.zig");
const mapping = @import("mapping.zig");

pub const Runtime = runtime.Runtime;
pub const Context = runtime.Context;

pub const Value = mapping.Value;
pub const ValueType = mapping.ValueType;

pub const Mapped = mapping.Mapped;

const std = @import("std");

test "create runtime" {
    const rt = try Runtime.init(std.testing.allocator);
    defer rt.deinit();
}

test "create context" {
    var rt = try Runtime.init(std.testing.allocator);
    defer rt.deinit();

    const ctx = try rt.newContext();
    defer ctx.deinit();
}

test "global" {
    var rt = try Runtime.init(std.testing.allocator);
    defer rt.deinit();

    const ctx = try rt.newContext();
    defer ctx.deinit();

    const global = ctx.global();
    defer global.deinit();

    try global.setProperty("foo", 123);

    const prop = try global.getProperty("foo");
    defer prop.deinit();

    try std.testing.expect(try prop.as(i32) == 123);
}

test "eval" {
    var rt = try Runtime.init(std.testing.allocator);
    defer rt.deinit();

    const ctx = try rt.newContext();
    defer ctx.deinit();

    const res = try ctx.evalAs(i32, "2 * 8");

    try std.testing.expectEqual(res, 16);
}

test "function" {
    const adder = struct {
        fn testadd(a: i32, b: i32) i32 {
            return a + b;
        }
    };

    var rt = try Runtime.init(std.testing.allocator);
    defer rt.deinit();

    const ctx = try rt.newContext();
    defer ctx.deinit();

    const global = ctx.global();
    defer global.deinit();

    try global.setProperty("add", adder.testadd);

    const res = try ctx.evalAs(i32, "add(6,7)");

    try std.testing.expectEqual(res, 13);
}
