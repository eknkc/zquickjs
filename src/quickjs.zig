const std = @import("std");
const RuntimeState = @import("runtime.zig").Runtime.State;

pub const QuickJS = @cImport({
    @cInclude("quickjs.h");
});

pub usingnamespace QuickJS;

pub inline fn GETTAG(v: QuickJS.JSValue) c_int {
    if (@sizeOf(usize) >= 8) {
        return @intCast(v.tag);
    } else {
        return std.zig.c_translation.cast(i32, v >> 32);
    }
}

pub inline fn MKVAL(tag: c_int, val: c_int) QuickJS.JSValue {
    if (@sizeOf(usize) >= 8) {
        return QuickJS.JSValue{ .tag = @intCast(tag), .u = .{ .int32 = val } };
    } else {
        return (@as(u64, tag) << 32) | @as(u64, val);
    }
}

pub inline fn FreeValue(ctx: ?*QuickJS.JSContext, v: QuickJS.JSValue) void {
    if (GETTAG(v) >= QuickJS.JS_TAG_FIRST) {
        const p: [*c]QuickJS.JSRefCountHeader = @ptrCast(@alignCast(QuickJS.JS_VALUE_GET_PTR(v)));

        p.*.ref_count -= 1;

        if (p.*.ref_count <= 0) {
            QuickJS.__JS_FreeValue(ctx, v);
        }
    }
}

pub inline fn DupValue(_: ?*QuickJS.JSContext, v: QuickJS.JSValueConst) QuickJS.JSValue {
    if (GETTAG(v) >= QuickJS.JS_TAG_FIRST) {
        const p: [*c]QuickJS.JSRefCountHeader = @ptrCast(@alignCast(QuickJS.JS_VALUE_GET_PTR(v)));
        p.*.ref_count += 1;
    }

    return @as(QuickJS.JSValue, v);
}

pub const NULL = MKVAL(QuickJS.JS_TAG_NULL, 0);
pub const UNDEFINED = MKVAL(QuickJS.JS_TAG_UNDEFINED, 0);

pub fn getAllocator(ctx: ?*QuickJS.JSContext) std.mem.Allocator {
    const rtopaque = QuickJS.JS_GetRuntimeOpaque(QuickJS.JS_GetRuntime(ctx));
    const state: *RuntimeState = @ptrCast(@alignCast(rtopaque));

    return state.alloc.allocator;
}
