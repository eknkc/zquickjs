const std = @import("std");
const Context = @import("runtime.zig").Context;
const Q = @import("quickjs.zig");

const QuickJS = Q.QuickJS;

const Value = @This();

const Type = enum { Bool, Int, BigInt, Float, String, Symbol, Object, Array, Function, Exception, Null, Undefined, Uninitialized };

ctx: *Context,
value: QuickJS.JSValue,
type: Type,

fn js_call_zig_fn(_: ?*QuickJS.JSContext, this: QuickJS.JSValue, num: c_int, _: [*c]QuickJS.JSValue) callconv(.C) QuickJS.JSValue {
    std.debug.print("this: {any}, num: {d}\n", .{ this, num });

    return Q.UNDEFINED;
}

const FnPtr = struct { ptr: usize, type_info: std.builtin.Type };

pub fn from(ctx: *Context, value: anytype) Value {
    const val = fromRaw(ctx.ctx, value);
    return Value.init(ctx, val);
}

fn fromRaw(ctx: ?*QuickJS.JSContext, value: anytype) QuickJS.JSValue {
    const type_info = @typeInfo(@TypeOf(value));

    if (type_info == .Bool) {
        return QuickJS.JS_NewBool(ctx, if (value) 1 else 0);
    } else if (type_info == .Int and type_info.Int.bits <= 32) {
        return QuickJS.JS_NewInt32(ctx, @intCast(value));
    } else if (type_info == .Int or type_info == .ComptimeInt) {
        return QuickJS.JS_NewInt64(ctx, @intCast(value));
    } else if (type_info == .Float or type_info == .ComptimeFloat) {
        return QuickJS.JS_NewFloat64(ctx, @floatCast(value));
    } else if (type_info == .Pointer) {
        const ptypeinfo = @typeInfo(type_info.Pointer.child);

        if (type_info.Pointer.size == .Slice and type_info.Pointer.child == u8) {
            return QuickJS.JS_NewStringLen(ctx, value.ptr, value.len);
        }

        if (ptypeinfo == .Array and ptypeinfo.Array.child == u8) {
            return QuickJS.JS_NewStringLen(ctx, value, value.len);
        }
    } else if (type_info == .Fn) {
        const Str = struct {
            fn runThings(c: ?*QuickJS.JSContext, _: QuickJS.JSValue, _: c_int, values: [*c]QuickJS.JSValue) callconv(.C) QuickJS.JSValue {
                comptime var types: [type_info.Fn.params.len]type = undefined;

                inline for (type_info.Fn.params, 0..) |param, i| {
                    types[i] = param.type.?;
                }

                var arg_tuple: std.meta.Tuple(&types) = undefined;

                inline for (types, 0..) |t, i| {
                    comptime var buf: [128]u8 = undefined;

                    const arg = asRaw(c, values[i], t) catch unreachable;
                    defer arg.deinit();

                    @field(arg_tuple, try std.fmt.bufPrintZ(&buf, "{d}", .{i})) = arg.value;
                }

                const ret = @call(.auto, value, arg_tuple);

                if (type_info.Fn.return_type != null) {
                    return fromRaw(c, ret);
                }

                return Q.UNDEFINED;
            }
        };

        return QuickJS.JS_NewCFunction(ctx, Str.runThings, "zig_fn", 0);
    }

    @compileLog(type_info.Pointer);
    @compileError("type not supported");
}

pub fn init(ctx: *Context, value: QuickJS.JSValue) Value {
    return Value{
        .ctx = ctx,
        .value = value,
        .type = getType(ctx.ctx, value),
    };
}

fn getType(ctx: *QuickJS.JSContext, value: QuickJS.JSValue) Type {
    if (QuickJS.JS_IsNumber(value) != 0) {
        if (QuickJS.JS_IsBigInt(ctx, value) != 0) {
            return .BigInt;
        }

        return .Int;
    } else if (QuickJS.JS_IsString(value) != 0) {
        return .String;
    } else if (QuickJS.JS_IsSymbol(value) != 0) {
        return .Symbol;
    } else if (QuickJS.JS_IsArray(ctx, value) != 0) {
        return .Array;
    } else if (QuickJS.JS_IsFunction(ctx, value) != 0) {
        return .Function;
    } else if (QuickJS.JS_IsException(value) != 0) {
        return .Exception;
    } else if (QuickJS.JS_IsObject(value) != 0) {
        return .Object;
    } else if (QuickJS.JS_IsNull(value) != 0) {
        return .Null;
    } else if (QuickJS.JS_IsUndefined(value) != 0) {
        return .Undefined;
    } else if (QuickJS.JS_IsBool(value) != 0) {
        return .Bool;
    }

    return .Uninitialized;
}

pub fn deinit(self: Value) void {
    QuickJS.JS_FreeValue(self.ctx.ctx, self.value);
}

pub fn AsResult(comptime T: type) type {
    return struct {
        value: T,
        arena: ?*std.heap.ArenaAllocator = null,

        pub fn deinit(self: @This()) void {
            if (self.arena) |arena| {
                const alloc = arena.child_allocator;
                arena.deinit();
                alloc.destroy(arena);
            }
        }
    };
}

pub fn as(self: Value, comptime T: type) !AsResult(T) {
    return asRaw(self.ctx.ctx, self.value, T);
}

pub fn asRaw(ctx: ?*QuickJS.JSContext, value: QuickJS.JSValue, comptime T: type) !AsResult(T) {
    const type_info = @typeInfo(T);

    if (type_info == .Bool) {
        return AsResult(bool){ .value = QuickJS.JS_ToBool(ctx, value) != 0 };
    } else if (type_info == .Int and type_info.Int.signedness == .signed and type_info.Int.bits >= 32 and type_info.Int.bits < 64) {
        var val: i32 = undefined;

        if (QuickJS.JS_ToInt32(ctx, &val, value) == 0) {
            return AsResult(T){ .value = @intCast(val) };
        }
    } else if (type_info == .Int and type_info.Int.signedness == .unsigned and type_info.Int.bits >= 64) {
        var val: i64 = undefined;

        if (QuickJS.JS_ToInt64(ctx, &val, value) == 0) {
            return AsResult(T){ .value = @intCast(val) };
        }
    } else if (type_info == .Float and type_info.Float.bits >= 64) {
        var val: f64 = undefined;

        if (QuickJS.JS_ToFloat64(ctx, &val, value) == 0) {
            return AsResult(T){ .value = @floatCast(val) };
        }
    }

    const alloc = std.heap.c_allocator;
    const arena = try alloc.create(std.heap.ArenaAllocator);
    errdefer alloc.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(alloc);

    if (T == []u8) {
        const str = QuickJS.JS_ToCString(ctx, value);
        defer QuickJS.JS_FreeCString(ctx, str);

        const span = try arena.allocator().alloc(u8, std.mem.len(str));
        @memcpy(span, std.mem.span(str));

        return AsResult([]u8){ .value = span, .arena = arena };
    }

    const val = QuickJS.JS_JSONStringify(ctx, value, Q.UNDEFINED, Q.UNDEFINED);
    defer QuickJS.JS_FreeValue(ctx, val);

    const str = QuickJS.JS_ToCString(ctx, val);
    defer QuickJS.JS_FreeCString(ctx, str);

    const res = try std.json.parseFromSliceLeaky(T, arena.allocator(), std.mem.span(str), .{});

    return AsResult(T){ .value = res, .arena = arena };
}

const PropertiesError = error{ NotAnObject, UnableToGetProperties };

const PropertiesIterator = struct {
    value: *Value,
    state: State,

    const State = struct {
        index: u32 = 0,
        count: u32,

        properties: [*c]QuickJS.JSPropertyEnum,
        last: ?[*c]const u8 = null,
    };

    pub fn init(value: *Value) !PropertiesIterator {
        if (value.type != .Object) {
            return PropertiesError.NotAnObject;
        }

        var count: u32 = 0;
        var ptab: [*c]QuickJS.JSPropertyEnum = undefined;

        const ret = QuickJS.JS_GetOwnPropertyNames(value.ctx.ctx, &ptab, &count, value.value, QuickJS.JS_GPN_STRING_MASK | QuickJS.JS_GPN_ENUM_ONLY);

        if (ret != 0) {
            return PropertiesError.UnableToGetProperties;
        }

        return PropertiesIterator{ .value = value, .state = State{ .count = count, .properties = ptab } };
    }

    pub fn deinit(self: PropertiesIterator) void {
        QuickJS.js_free(self.value.ctx.ctx, self.state.properties);

        if (self.state.last) |last| {
            QuickJS.JS_FreeCString(self.value.ctx.ctx, last);
        }
    }

    pub fn next(self: *PropertiesIterator) ?[]const u8 {
        if (self.state.index < self.state.count) {
            const entry = self.state.properties[self.state.index];

            if (self.state.last) |last| {
                QuickJS.JS_FreeCString(self.value.ctx.ctx, last);
            }

            self.state.last = QuickJS.JS_AtomToCString(self.value.ctx.ctx, entry.atom);
            self.state.index += 1;

            return std.mem.span(self.state.last.?);
        }

        return null;
    }
};

pub fn properties(self: *Value) !PropertiesIterator {
    return PropertiesIterator.init(self);
}
