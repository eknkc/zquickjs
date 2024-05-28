const std = @import("std");
const QuickJS = @import("quickjs.zig");
const native_endian = @import("builtin").target.cpu.arch.endian();

const AllocContext = @This();

allocator: std.mem.Allocator,
functions: QuickJS.JSMallocFunctions,

const HEADER_SIZE: usize = 16;

pub fn malloc(st: [*c]QuickJS.JSMallocState, size: usize) callconv(.C) ?*anyopaque {
    if (size == 0 or st.*.malloc_size + size > st.*.malloc_limit) {
        return null;
    }

    var context: *AllocContext = @ptrCast(@alignCast(st.*.@"opaque"));

    const allocated = context.allocator.alloc(u8, size + HEADER_SIZE) catch return null;
    std.mem.writeInt(usize, allocated[0..@sizeOf(usize)], allocated.len, native_endian);

    st.*.malloc_count += 1;
    st.*.malloc_size += allocated.len;

    return allocated[HEADER_SIZE..].ptr;
}

pub fn realloc(st: [*c]QuickJS.JSMallocState, ptr: ?*anyopaque, size: usize) callconv(.C) ?*anyopaque {
    var context: *AllocContext = @ptrCast(@alignCast(st.*.@"opaque"));

    if (ptr == null) {
        return malloc(st, size);
    }

    const allocated: [*]u8 = @ptrFromInt(@intFromPtr(ptr) - HEADER_SIZE);
    const allocatedsize = std.mem.readInt(usize, allocated[0..@sizeOf(usize)], native_endian);

    if (size == 0) {
        free(st, ptr);
        return null;
    }

    if (st.*.malloc_size - allocatedsize + size + HEADER_SIZE > st.*.malloc_limit) {
        return null;
    }

    const newp = context.allocator.realloc(allocated[0..allocatedsize], size + HEADER_SIZE) catch return null;
    std.mem.writeInt(usize, newp[0..@sizeOf(usize)], newp.len, native_endian);

    st.*.malloc_size += newp.len;
    st.*.malloc_size -= allocatedsize;

    return newp[HEADER_SIZE..].ptr;
}

pub fn free(st: [*c]QuickJS.JSMallocState, ptr: ?*anyopaque) callconv(.C) void {
    var context: *AllocContext = @ptrCast(@alignCast(st.*.@"opaque"));

    if (ptr) |p| {
        const allocated: [*]u8 = @ptrFromInt(@intFromPtr(p) - HEADER_SIZE);
        const size = std.mem.readInt(usize, allocated[0..@sizeOf(usize)], native_endian);

        context.allocator.free(allocated[0..size]);

        st.*.malloc_count -= 1;
        st.*.malloc_size -= size;
    }
}

pub fn malloc_usable_size(_: ?*const anyopaque) callconv(.C) usize {
    return 0;
}
