const std = @import("std");
const QuickJS = @import("quickjs.zig");

pub const ValueType = enum { Bool, Number, String, Symbol, Object, Promise, Array, Function, Exception, Null, Undefined, Uninitialized };

pub const Value = union(ValueType) {
    Bool: bool,
    Number: union {
        Int: i64,
        Float: f64,
    },
    String: Mapped([]const u8),
    Symbol,
    Object: Object,
    Promise: Promise,
    Array: Object,
    Function: Function,
    Exception,
    Null,
    Undefined,
    Uninitialized,
};

pub const Function = struct {
    ctx: ?*QuickJS.JSContext,
    value: QuickJS.JSValue,

    pub fn deinit(self: Function) void {
        QuickJS.JS_FreeValue(self.ctx, self.value);
    }

    pub fn call(self: Function, comptime ReturnType: type, args: anytype) !Mapped(ReturnType) {
        const ti = @typeInfo(@TypeOf(args));

        if (ti != .Struct or !ti.Struct.is_tuple) {
            @compileError("Unable to call function with arguments type " ++ @typeName(ReturnType) ++ ". Expected a tuple type.");
        }

        var values = [_]QuickJS.JSValue{QuickJS.UNDEFINED} ** args.len;

        defer inline for (values) |v| {
            if (QuickJS.JS_IsUndefined(v) == 0) {
                QuickJS.JS_FreeValue(self.ctx, v);
            }
        };

        inline for (args, 0..) |arg, i| {
            values[i] = try toValue(self.ctx, arg);
        }

        const ret = QuickJS.JS_Call(self.ctx, self.value, QuickJS.UNDEFINED, values.len, @ptrCast(&values));
        defer QuickJS.JS_FreeValue(self.ctx, ret);

        if (QuickJS.JS_IsException(ret) != 0) {
            return error.Exception;
        }

        return fromValueAlloc(ReturnType, QuickJS.getAllocator(self.ctx), self.ctx, ret);
    }
};

pub const Object = struct {
    ctx: ?*QuickJS.JSContext,
    value: QuickJS.JSValue,

    pub fn deinit(self: Object) void {
        QuickJS.JS_FreeValue(self.ctx, self.value);
    }

    pub fn keys(self: Object) !std.ArrayList([]const u8) {
        var arr = std.ArrayList([]const u8).init(QuickJS.getAllocator(self.ctx));
        errdefer arr.deinit();

        var count: u32 = 0;
        var ptab: [*c]QuickJS.JSPropertyEnum = undefined;

        const ret = QuickJS.JS_GetOwnPropertyNames(self.ctx, &ptab, &count, self.value, QuickJS.JS_GPN_STRING_MASK | QuickJS.JS_GPN_ENUM_ONLY);

        if (ret != 0) {
            return error.UnableToGetProperties;
        }

        for (0..count) |i| {
            const name = QuickJS.JS_AtomToCString(self.ctx, ptab[i].atom);
            defer QuickJS.JS_FreeCString(self.ctx, name);
            try arr.append(std.mem.span(name));
        }

        return arr;
    }

    pub fn hasProperty(self: Object, key: []const u8) !bool {
        const allocator = QuickJS.getAllocator(self.ctx);
        const ckey = try allocator.dupeZ(u8, key);
        defer allocator.free(ckey);

        const atom = QuickJS.JS_NewAtom(self.ctx, ckey.ptr);
        defer QuickJS.JS_FreeAtom(self.ctx, atom);

        return QuickJS.JS_HasProperty(self.ctx, self.value, atom) != 0;
    }

    pub fn getProperty(self: Object, comptime T: type, key: []const u8) !Mapped(T) {
        const allocator = QuickJS.getAllocator(self.ctx);
        const ckey = try allocator.dupeZ(u8, key);
        defer allocator.free(ckey);

        const val = QuickJS.JS_GetPropertyStr(self.ctx, self.value, ckey.ptr);
        defer QuickJS.JS_FreeValue(self.ctx, val);

        return fromValueAlloc(T, QuickJS.getAllocator(self.ctx), self.ctx, val);
    }

    pub fn setProperty(self: Object, key: []const u8, value: anytype) !void {
        const val = try toValue(self.ctx, value);
        errdefer QuickJS.JS_FreeValue(self.ctx, val);

        const allocator = QuickJS.getAllocator(self.ctx);
        const ckey = try allocator.dupeZ(u8, key);
        defer allocator.free(ckey);

        const res = QuickJS.JS_SetPropertyStr(self.ctx, self.value, ckey.ptr, val);

        if (res == 0) {
            return error.CanNotSetProperty;
        }
    }

    pub fn deleteProperty(self: Object, key: []const u8) !void {
        const allocator = QuickJS.getAllocator(self.ctx);
        const ckey = try allocator.dupeZ(u8, key);
        defer allocator.free(ckey);

        const atom = QuickJS.JS_NewAtom(self.ctx, ckey.ptr);
        defer QuickJS.JS_FreeAtom(self.ctx, atom);

        const res = QuickJS.JS_DeleteProperty(self.ctx, self.value, atom, 0);

        if (res == 0) {
            return error.CanNotDeleteProperty;
        }
    }
};

pub const Promise = struct {
    ctx: ?*QuickJS.JSContext,
    value: QuickJS.JSValue,

    pub fn deinit(self: Promise) void {
        QuickJS.JS_FreeValue(self.ctx, self.value);
    }
};

pub const MappingError = error{ FloatIncompatible, IntIncompatible, NeedsAllocator, CanNotConvert };

pub fn Mapped(comptime T: type) type {
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

pub fn toValue(ctx: ?*QuickJS.JSContext, value: anytype) MappingError!QuickJS.JSValue {
    return switch (@typeInfo(@TypeOf(value))) {
        .Bool => QuickJS.JS_NewBool(ctx, @intFromBool(value)),
        .Float, .ComptimeFloat => QuickJS.JS_NewFloat64(ctx, @floatCast(value)),
        .Int, .ComptimeInt => QuickJS.JS_NewInt64(ctx, std.math.cast(i64, value) orelse return MappingError.IntIncompatible),
        .Array => toValue(ctx, value[0..]),
        .Pointer => |ptr| switch (ptr.size) {
            .One => switch (@typeInfo(ptr.child)) {
                .Array => {
                    const Slice = []const std.meta.Elem(ptr.child);
                    return toValue(ctx, @as(Slice, value));
                },
                else => toValue(ctx, value.*),
            },
            .Slice => {
                if (ptr.child == u8) {
                    return QuickJS.JS_NewStringLen(ctx, value.ptr, value.len);
                }

                const jsarray = QuickJS.JS_NewArray(ctx);
                errdefer QuickJS.JS_FreeValue(ctx, jsarray);

                const push = QuickJS.JS_GetPropertyStr(ctx, jsarray, "push");
                defer QuickJS.JS_FreeValue(ctx, push);

                for (value) |arrvalue| {
                    var pushvalue = try toValue(ctx, arrvalue);
                    defer QuickJS.JS_FreeValue(ctx, pushvalue);

                    const res = QuickJS.JS_Call(ctx, push, jsarray, 1, @ptrCast(&pushvalue));
                    defer QuickJS.JS_FreeValue(ctx, res);
                }

                return jsarray;
            },
            else => MappingError.CanNotConvert,
        },
        .Struct => |st| {
            const jsobj = QuickJS.JS_NewObject(ctx);
            errdefer QuickJS.JS_FreeValue(ctx, jsobj);

            inline for (st.fields) |field| {
                const name = field.name;
                const fieldvalue = @field(value, name);

                const pushvalue = try toValue(ctx, fieldvalue);

                _ = QuickJS.JS_SetPropertyStr(ctx, jsobj, name, pushvalue);
            }

            return jsobj;
        },
        .Fn => |func| {
            const Closure = struct {
                fn run(c: ?*QuickJS.JSContext, _: QuickJS.JSValue, argcnt: c_int, values: [*c]QuickJS.JSValue) callconv(.C) QuickJS.JSValue {
                    comptime var types: [func.params.len]type = undefined;
                    comptime var buf: [128]u8 = undefined;

                    if (argcnt != func.params.len) {
                        return QuickJS.JS_ThrowTypeError(c, "Unable to call function, argument count mismatch.");
                    }

                    inline for (func.params, 0..) |param, i| {
                        if (param.is_generic or param.type == null) {
                            @compileError("Unable to map function with generic parameters to JS value.");
                        }

                        types[i] = param.type.?;
                    }

                    var arg_tuple: std.meta.Tuple(&types) = undefined;

                    var arena = std.heap.ArenaAllocator.init(QuickJS.getAllocator(c));
                    defer arena.deinit();
                    const allocator = arena.allocator();

                    inline for (types, 0..) |t, i| {
                        const arg = fromValueAlloc(t, allocator, c, values[i]) catch unreachable;
                        @field(arg_tuple, try std.fmt.bufPrintZ(&buf, "{d}", .{i})) = arg.value;
                    }

                    const ret = @call(.auto, value, arg_tuple);

                    if (func.return_type != null) {
                        return toValue(c, ret) catch unreachable;
                    }

                    return QuickJS.UNDEFINED;
                }
            };

            return QuickJS.JS_NewCFunction(ctx, Closure.run, "", func.params.len);
        },
        else => QuickJS.UNDEFINED,
    };
}

pub fn fromValue(comptime T: type, ctx: ?*QuickJS.JSContext, value: QuickJS.JSValue) !Mapped(T) {
    return fromValueAlloc(T, QuickJS.getAllocator(ctx), ctx, value);
}

pub fn fromValueAlloc(comptime T: type, allocator: std.mem.Allocator, ctx: ?*QuickJS.JSContext, value: QuickJS.JSValue) !Mapped(T) {
    if (T == void) {
        return Mapped(void){ .value = {} };
    }

    switch (T) {
        Function => {
            return if (QuickJS.JS_IsFunction(ctx, value) != 0) Mapped(T){ .value = Function{ .ctx = ctx, .value = value } } else MappingError.CanNotConvert;
        },
        Object => {
            return if (QuickJS.JS_IsObject(value) != 0) Mapped(T){ .value = Object{ .ctx = ctx, .value = value } } else MappingError.CanNotConvert;
        },
        else => switch (@typeInfo(T)) {
            .Bool => QuickJS.JS_ToBool(ctx, value) != 0,
            .Float => {
                var val: f64 = undefined;

                if (QuickJS.JS_ToFloat64(ctx, &val, value) == 0) {
                    return Mapped(T){ .value = @floatCast(val) };
                } else {
                    return MappingError.FloatIncompatible;
                }
            },
            .Int => {
                var val: i64 = undefined;

                if (QuickJS.JS_ToInt64(ctx, &val, value) == 0) {
                    const ivalue = std.math.cast(T, val) orelse return MappingError.IntIncompatible;
                    return Mapped(T){ .value = ivalue };
                } else {
                    return MappingError.IntIncompatible;
                }
            },
            else => {},
        },
    }

    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);

    arena.* = std.heap.ArenaAllocator.init(allocator);

    if (T == []u8 or T == []const u8) {
        const str = QuickJS.JS_ToCString(ctx, value);
        defer QuickJS.JS_FreeCString(ctx, str);

        const span = try arena.allocator().alloc(u8, std.mem.len(str));
        @memcpy(span, std.mem.span(str));

        return Mapped(T){ .value = span, .arena = arena };
    }

    const val = QuickJS.JS_JSONStringify(ctx, value, QuickJS.UNDEFINED, QuickJS.UNDEFINED);
    defer QuickJS.JS_FreeValue(ctx, val);

    const str = QuickJS.JS_ToCString(ctx, val);
    defer QuickJS.JS_FreeCString(ctx, str);

    const res = std.json.parseFromSliceLeaky(T, arena.allocator(), std.mem.span(str), .{ .allocate = .alloc_always }) catch return MappingError.CanNotConvert;

    return Mapped(T){ .value = res, .arena = arena };
}

pub fn getValueType(ctx: ?*QuickJS.JSContext, value: QuickJS.JSValue) ValueType {
    if (QuickJS.JS_IsNumber(value) != 0 or QuickJS.JS_IsBigInt(value) != 0 or QuickJS.JS_IsBigFloat(value) != 0) {
        return .Number;
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
