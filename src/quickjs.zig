const std = @import("std");
const RuntimeState = @import("runtime.zig").Runtime.State;
const Context = @import("runtime.zig").Context;

pub const QuickJS = @cImport({
    @cInclude("quickjs.h");
});

pub usingnamespace QuickJS;

pub inline fn HAS_PTR(v: QuickJS.JSValue) bool {
    return @as(c_uint, @bitCast(GET_TAG(v))) >= @as(c_uint, @bitCast(QuickJS.JS_TAG_FIRST));
}

pub inline fn GET_TAG(v: QuickJS.JSValue) c_int {
    if (@sizeOf(usize) >= 8) {
        return @intCast(v.tag);
    } else {
        return std.zig.c_translation.cast(i32, v >> 32);
    }
}

pub inline fn GET_PTR(v: QuickJS.JSValue) ?*anyopaque {
    if (@sizeOf(usize) >= 8) {
        return v.u.ptr;
    } else {
        return @ptrFromInt(@as(u32, @truncate(v)));
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
    if (HAS_PTR(v)) {
        const p: [*c]QuickJS.JSRefCountHeader = @ptrCast(@alignCast(GET_PTR(v)));

        p.*.ref_count -= 1;

        if (p.*.ref_count <= 0) {
            QuickJS.__JS_FreeValue(ctx, v);
        }
    }
}

pub inline fn DupValue(_: ?*QuickJS.JSContext, v: QuickJS.JSValueConst) QuickJS.JSValue {
    if (HAS_PTR(v)) {
        const p: [*c]QuickJS.JSRefCountHeader = @ptrCast(@alignCast(GET_PTR(v)));
        p.*.ref_count += 1;
    }

    return @as(QuickJS.JSValue, v);
}

pub const NULL = MKVAL(QuickJS.JS_TAG_NULL, 0);
pub const UNDEFINED = MKVAL(QuickJS.JS_TAG_UNDEFINED, 0);

pub fn getArena(ctx: ?*QuickJS.JSContext) ?*Context.State.Arena {
    const ctopaque = QuickJS.JS_GetContextOpaque(ctx);
    const ctstate: *Context.State = @ptrCast(@alignCast(ctopaque));

    if (ctstate.arenas.first) |node| {
        return &node.*.data;
    }

    return null;
}

pub fn getAllocator(ctx: ?*QuickJS.JSContext) std.mem.Allocator {
    if (getArena(ctx)) |arena| {
        return arena.arena.allocator();
    }

    const rtopaque = QuickJS.JS_GetRuntimeOpaque(QuickJS.JS_GetRuntime(ctx));
    const state: *RuntimeState = @ptrCast(@alignCast(rtopaque));

    return state.alloc.allocator;
}
