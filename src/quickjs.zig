const std = @import("std");
const RuntimeState = @import("runtime.zig").Runtime.State;
const Context = @import("runtime.zig").Context;

pub const C = @cImport({
    @cInclude("quickjs.h");
});

pub inline fn HAS_PTR(v: C.JSValue) bool {
    return @as(c_uint, @bitCast(GET_TAG(v))) >= @as(c_uint, @bitCast(C.JS_TAG_FIRST));
}

pub inline fn GET_TAG(v: C.JSValue) c_int {
    if (@sizeOf(usize) >= 8) {
        return @intCast(v.tag);
    } else {
        return std.zig.c_translation.cast(i32, v >> 32);
    }
}

pub inline fn GET_PTR(v: C.JSValue) ?*anyopaque {
    if (@sizeOf(usize) >= 8) {
        return v.u.ptr;
    } else {
        return @ptrFromInt(@as(u32, @truncate(v)));
    }
}

pub inline fn MKVAL(tag: c_int, val: c_int) C.JSValue {
    if (@sizeOf(usize) >= 8) {
        return C.JSValue{ .tag = @intCast(tag), .u = .{ .int32 = val } };
    } else {
        return (@as(u64, tag) << 32) | @as(u64, val);
    }
}

pub inline fn FreeValue(ctx: ?*C.JSContext, v: C.JSValue) void {
    if (HAS_PTR(v)) {
        const p: [*c]C.JSRefCountHeader = @ptrCast(@alignCast(GET_PTR(v)));

        p.*.ref_count -= 1;

        if (p.*.ref_count <= 0) {
            C.__JS_FreeValue(ctx, v);
        }
    }
}

pub inline fn DupValue(_: ?*C.JSContext, v: C.JSValueConst) C.JSValue {
    if (HAS_PTR(v)) {
        const p: [*c]C.JSRefCountHeader = @ptrCast(@alignCast(GET_PTR(v)));
        p.*.ref_count += 1;
    }

    return @as(C.JSValue, v);
}

pub const NULL = MKVAL(C.JS_TAG_NULL, 0);
pub const UNDEFINED = MKVAL(C.JS_TAG_UNDEFINED, 0);

pub fn getArena(ctx: ?*C.JSContext) ?*Context.State.Arena {
    const ctopaque = C.JS_GetContextOpaque(ctx);
    const ctstate: *Context.State = @ptrCast(@alignCast(ctopaque));

    if (ctstate.arenas.first) |node| {
        return @fieldParentPtr("node", node);
    }

    return null;
}

pub fn getAllocator(ctx: ?*C.JSContext) std.mem.Allocator {
    if (getArena(ctx)) |arena| {
        return arena.arena.allocator();
    }

    const rtopaque = C.JS_GetRuntimeOpaque(C.JS_GetRuntime(ctx));
    const state: *RuntimeState = @ptrCast(@alignCast(rtopaque));

    return state.alloc.allocator;
}
