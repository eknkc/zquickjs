const std = @import("std");
const Value = @import("value.zig");
const Runtime = @import("runtime.zig").Runtime;
const QuickJS = @import("quickjs.zig");
const mapping = @import("mapping.zig");

var buf: [1024]u8 = undefined;

pub fn deneme(a: i10, b: i32, name: []const u8) []u8 {
    return std.fmt.bufPrintZ(&buf, "name: {s}, a: {d}, b: {d}", .{ name, a, b }) catch unreachable;
}

pub fn am(a: anytype, b: void) void {
    std.debug.print("a: {any}, b: {any}\n", .{ a, b });
}

const Person = struct {
    name: []const u8,
    age: i32,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const amm = .{ 1, 2, 3, "am" };
    std.debug.assert(amm.len == 4);

    const allocator = gpa.allocator();

    var rt = try Runtime.init(allocator);
    defer rt.deinit();

    var context = try rt.newContext();
    defer context.deinit();

    const glbl = context.global();
    defer glbl.deinit();

    _ = try context.eval(void, "setTimeout(() => { printf(deneme) }, 1000)");

    am: while (true) {
        switch (rt.tick()) {
            .done => break :am,
            .idleMs => |ms| {
                std.debug.print("idle {d}\n", .{ms});
                std.time.sleep(ms * std.time.ns_per_ms);
            },
            .exception => |x| {
                std.debug.print("exception: {any}\n", .{x});
                // const err = try x.as([]u8);
                // defer err.deinit();
                // std.debug.print("err: {s}\n", .{err.value});
            },
        }
    }

    QuickJS.JS_RunGC(rt.rt);

    std.time.sleep(1000);
}
