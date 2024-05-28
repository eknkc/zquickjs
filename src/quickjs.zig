const std = @import("std");
const RuntimeState = @import("runtime.zig").Runtime.State;

pub const QuickJS = @cImport({
    @cInclude("quickjs.h");
});

pub usingnamespace QuickJS;

pub inline fn MKVAL(tag: c_int, val: c_int) QuickJS.JSValue {
    if (@sizeOf(usize) == 8) {
        return QuickJS.JSValue{ .tag = @intCast(tag), .u = .{ .int32 = val } };
    } else {
        return (@as(u64, tag) << 32) | @as(u64, val);
    }
}

pub const NULL = MKVAL(QuickJS.JS_TAG_NULL, 0);
pub const UNDEFINED = MKVAL(QuickJS.JS_TAG_UNDEFINED, 0);

pub fn getAllocator(ctx: ?*QuickJS.JSContext) std.mem.Allocator {
    const rtopaque = QuickJS.JS_GetRuntimeOpaque(QuickJS.JS_GetRuntime(ctx));
    const state: *RuntimeState = @ptrCast(@alignCast(rtopaque));

    return state.allocator;
}
