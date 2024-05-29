const std = @import("std");
const QuickJS = @import("quickjs.zig");
const runtime = @import("runtime.zig");

pub const ValueType = enum { Bool, Number, String, Symbol, Object, Promise, Array, Function, Exception, Null, Undefined, Uninitialized };

/// A value that represents a JavaScript value.
/// Can be any valid JavaScript value.
/// The value is reference counted and will be automatically freed when the last reference is dropped.
/// It is required to call `deinit` to free the allocated resources.
pub const Value = struct {
    ctx: ?*QuickJS.JSContext,
    value: QuickJS.JSValue,

    pub fn init(ctx: ?*QuickJS.JSContext, value: QuickJS.JSValue) Value {
        return Value{ .ctx = ctx, .value = value };
    }

    /// Deinitialize the value and release allocated resources.
    pub fn deinit(self: Value) void {
        QuickJS.FreeValue(self.ctx, self.value);
    }

    /// Get the underlying type of the value.
    pub fn getType(self: Value) ValueType {
        return getValueType(self.ctx, self.value);
    }

    /// Returns the value as a specific type.
    /// If the value is not compatible with the type, an error is returned.
    /// If the value requires allocation (structs, strings etc), an error is returned. Use `asAlloc` or `asBuf` instead.
    pub fn as(self: Value, comptime T: type) !T {
        const mapped = try fromJSValueAlloc(T, false, null, self.ctx, self.value);
        return mapped.value;
    }

    /// Returns the value as a specific type.
    /// If the value is not compatible with the type, an error is returned.
    /// The returned type has a `deinit` method that must be called to free the allocated memory.
    /// Allocation is done using the runtime allocator.
    pub fn asAlloc(self: Value, comptime T: type) !Mapped(T) {
        return fromJSValueAlloc(T, true, null, self.ctx, self.value);
    }

    /// Returns the value as a specific type.
    /// If the value is not compatible with the type, an error is returned.
    /// The returned type has a `deinit` method that must be called to free the allocated memory.
    /// Allocation is done using the provided allocator.
    pub fn asAllocIn(self: Value, comptime T: type, allocator: std.mem.Allocator) !Mapped(T) {
        return fromJSValueAlloc(T, true, allocator, self.ctx, self.value);
    }

    /// Returns the value as a specific type.
    /// If the value is not compatible with the type, an error is returned.
    /// The returned type uses the provided buffer to allocate memory.
    pub fn asBuf(self: Value, comptime T: type, buf: []u8) !Mapped(T) {
        const alloc = std.heap.FixedBufferAllocator.init(buf);
        const mapped = try fromJSValueAlloc(T, true, alloc.allocator(), self.ctx, self.value);
        return mapped.value;
    }
};

/// A JavaScript function reference.
/// The function can be called with the provided arguments.
/// It is required to call `deinit` to free the allocated resources.
pub const Function = struct {
    ctx: ?*QuickJS.JSContext,
    value: QuickJS.JSValue,

    /// Deinitialize the value and release allocated resources.
    pub fn deinit(self: Function) void {
        QuickJS.FreeValue(self.ctx, self.value);
    }

    /// Call the function with the provided arguments.
    /// The return type must be provided as a comptime parameter.
    /// Return type can be `Value` or any other type that can be mapped from a JS value.
    pub fn call(self: Function, comptime ReturnType: type, args: anytype) !Mapped(ReturnType) {
        const ti = @typeInfo(@TypeOf(args));

        if (ti != .Struct or !ti.Struct.is_tuple) {
            @compileError("Unable to call function with arguments type " ++ @typeName(ReturnType) ++ ". Expected a tuple type.");
        }

        var values = [_]QuickJS.JSValue{QuickJS.UNDEFINED} ** args.len;

        defer inline for (values) |v| {
            if (QuickJS.JS_IsUndefined(v) == 0) {
                QuickJS.FreeValue(self.ctx, v);
            }
        };

        inline for (args, 0..) |arg, i| {
            values[i] = try toJSValue(self.ctx, arg);
        }

        const ret = QuickJS.JS_Call(self.ctx, self.value, QuickJS.UNDEFINED, values.len, @ptrCast(&values));
        defer QuickJS.FreeValue(self.ctx, ret);

        if (QuickJS.JS_IsException(ret) != 0) {
            return error.Exception;
        }

        return fromJSValueAlloc(ReturnType, true, null, self.ctx, ret);
    }
};

/// A JavaScript object reference.
/// The object can be manipulated using the provided methods.
/// It is required to call `deinit` to free the allocated resources.
pub const Object = struct {
    ctx: ?*QuickJS.JSContext,
    value: QuickJS.JSValue,

    pub fn init(ctx: ?*QuickJS.JSContext, value: QuickJS.JSValue) Object {
        return Object{ .ctx = ctx, .value = value };
    }

    pub fn deinit(self: Object) void {
        QuickJS.FreeValue(self.ctx, self.value);
    }

    const KeysIterator = struct {
        obj: Object,
        index: u32 = 0,
        count: u32,
        ptab: [*c]QuickJS.JSPropertyEnum,

        pub fn deinit(self: KeysIterator) void {
            QuickJS.js_free(self.obj.ctx, self.ptab);
        }

        pub fn next(self: *KeysIterator) ?[]const u8 {
            if (self.index >= self.count) {
                return null;
            }

            const name = QuickJS.JS_AtomToCString(self.obj.ctx, self.ptab[self.index].atom);
            defer QuickJS.JS_FreeCString(self.obj.ctx, name);

            self.index += 1;

            return std.mem.span(name);
        }
    };

    /// Get an iterator over the object keys.
    /// The iterator will return the keys as strings.
    /// Call `deinit` to free the allocated resources.
    pub fn keys(self: Object) !KeysIterator {
        var count: u32 = 0;
        var ptab: [*c]QuickJS.JSPropertyEnum = undefined;

        const ret = QuickJS.JS_GetOwnPropertyNames(self.ctx, &ptab, &count, self.value, QuickJS.JS_GPN_STRING_MASK | QuickJS.JS_GPN_ENUM_ONLY);

        if (ret != 0) {
            return error.UnableToGetProperties;
        }

        return KeysIterator{ .obj = self, .count = count, .ptab = ptab };
    }

    /// Check if the object has a property with the provided key.
    pub fn hasProperty(self: Object, key: []const u8) !bool {
        const allocator = QuickJS.getAllocator(self.ctx);
        const ckey = try allocator.dupeZ(u8, key);
        defer allocator.free(ckey);

        const atom = QuickJS.JS_NewAtom(self.ctx, ckey.ptr);
        defer QuickJS.JS_FreeAtom(self.ctx, atom);

        return QuickJS.JS_HasProperty(self.ctx, self.value, atom) != 0;
    }

    /// Get a property from the object.
    pub fn getProperty(self: Object, key: []const u8) !Value {
        const allocator = QuickJS.getAllocator(self.ctx);
        const ckey = try allocator.dupeZ(u8, key);
        defer allocator.free(ckey);

        return Value.init(self.ctx, QuickJS.JS_GetPropertyStr(self.ctx, self.value, ckey.ptr));
    }

    /// Set a property on the object.
    pub fn setProperty(self: Object, key: []const u8, value: anytype) !void {
        const val = try toJSValue(self.ctx, value);
        errdefer QuickJS.FreeValue(self.ctx, val);

        const allocator = QuickJS.getAllocator(self.ctx);
        const ckey = try allocator.dupeZ(u8, key);
        defer allocator.free(ckey);

        const res = QuickJS.JS_SetPropertyStr(self.ctx, self.value, ckey.ptr, val);

        if (res == 0) {
            return error.CanNotSetProperty;
        }
    }

    /// Delete a property from the object.
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
        QuickJS.FreeValue(self.ctx, self.value);
    }
};

pub const MappingError = error{ FloatIncompatible, IntIncompatible, NeedsAllocator, CanNotConvert };

/// A mapped value that can be used to interact with JavaScript values.
/// It is required to call `deinit` to free the allocated resources.
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

fn toJSValue(ctx: ?*QuickJS.JSContext, value: anytype) MappingError!QuickJS.JSValue {
    const typeOf = @TypeOf(value);

    switch (typeOf) {
        Value => return value.value,
        Function => return value.value,
        Object => return value.value,
        Promise => return value.value,
        else => {},
    }

    return switch (@typeInfo(typeOf)) {
        .Bool => QuickJS.JS_NewBool(ctx, @intFromBool(value)),
        .Float, .ComptimeFloat => QuickJS.JS_NewFloat64(ctx, @floatCast(value)),
        .Int, .ComptimeInt => QuickJS.JS_NewInt64(ctx, std.math.cast(i64, value) orelse return MappingError.IntIncompatible),
        .Array => toJSValue(ctx, value[0..]),
        .Pointer => |ptr| switch (ptr.size) {
            .One => switch (@typeInfo(ptr.child)) {
                .Array => {
                    const Slice = []const std.meta.Elem(ptr.child);
                    return toJSValue(ctx, @as(Slice, value));
                },
                else => toJSValue(ctx, value.*),
            },
            .Slice => {
                if (ptr.child == u8) {
                    return QuickJS.JS_NewStringLen(ctx, value.ptr, value.len);
                }

                const jsarray = QuickJS.JS_NewArray(ctx);
                errdefer QuickJS.FreeValue(ctx, jsarray);

                const push = QuickJS.JS_GetPropertyStr(ctx, jsarray, "push");
                defer QuickJS.FreeValue(ctx, push);

                for (value) |arrvalue| {
                    var pushvalue = try toJSValue(ctx, arrvalue);
                    defer QuickJS.FreeValue(ctx, pushvalue);

                    const res = QuickJS.JS_Call(ctx, push, jsarray, 1, @ptrCast(&pushvalue));
                    defer QuickJS.FreeValue(ctx, res);
                }

                return jsarray;
            },
            else => MappingError.CanNotConvert,
        },
        .Struct => |st| {
            const jsobj = QuickJS.JS_NewObject(ctx);
            errdefer QuickJS.FreeValue(ctx, jsobj);

            inline for (st.fields) |field| {
                const name = field.name;
                const fieldvalue = @field(value, name);

                const pushvalue = try toJSValue(ctx, fieldvalue);

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

                    comptime var i = 0;

                    //var context: ?runtime.Context = null;

                    inline for (types) |t| {
                        // if (t == runtime.Context) {
                        //     if (context == null) {
                        //         const rt = QuickJS.JS_GetRuntime(c);
                        //         const state: *runtime.State = @ptrCast(@alignCast(QuickJS.JS_GetRuntimeOpaque(rt)));

                        //         const zrt = runtime.Runtime{ .rt = rt, .state = state };
                        //         context = runtime.Context{ .ctx = c, .runtime = &zrt };
                        //     }

                        //     @field(arg_tuple, try std.fmt.bufPrintZ(&buf, "{d}", .{i})) = context.? orelse unreachable;
                        // } else {
                        const arg = fromJSValueAlloc(t, true, allocator, c, values[i]) catch unreachable;
                        @field(arg_tuple, try std.fmt.bufPrintZ(&buf, "{d}", .{i})) = arg.value;
                        i += 1;
                        // }
                    }

                    const ret = @call(.auto, value, arg_tuple);

                    if (func.return_type != null) {
                        return toJSValue(c, ret) catch unreachable;
                    }

                    return QuickJS.UNDEFINED;
                }
            };

            return QuickJS.JS_NewCFunction(ctx, Closure.run, "", func.params.len);
        },
        else => QuickJS.UNDEFINED,
    };
}

fn fromJSValueAlloc(comptime T: type, comptime allocate: bool, allocator: ?std.mem.Allocator, ctx: ?*QuickJS.JSContext, value: QuickJS.JSValue) !Mapped(T) {
    if (T == void) {
        return Mapped(void){ .value = {} };
    }

    switch (T) {
        Value => {
            return Mapped(T){ .value = Value{
                .ctx = ctx,
                .value = QuickJS.DupValue(ctx, value),
            } };
        },
        Function => {
            return if (QuickJS.JS_IsFunction(ctx, value) != 0) Mapped(T){ .value = Function{
                .ctx = ctx,
                .value = QuickJS.DupValue(ctx, value),
            } } else MappingError.CanNotConvert;
        },
        Object => {
            return if (QuickJS.JS_IsObject(value) != 0) Mapped(T){ .value = Object{
                .ctx = ctx,
                .value = QuickJS.DupValue(ctx, value),
            } } else MappingError.CanNotConvert;
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

    if (!allocate) {
        return MappingError.NeedsAllocator;
    }

    const alloc = allocator orelse QuickJS.getAllocator(ctx);
    const arena = try alloc.create(std.heap.ArenaAllocator);
    errdefer alloc.destroy(arena);

    arena.* = std.heap.ArenaAllocator.init(alloc);

    if (T == []u8 or T == []const u8) {
        const str = QuickJS.JS_ToCString(ctx, value);
        defer QuickJS.JS_FreeCString(ctx, str);

        const span = try arena.allocator().alloc(u8, std.mem.len(str));
        @memcpy(span, std.mem.span(str));

        return Mapped(T){ .value = span, .arena = arena };
    }

    const val = QuickJS.JS_JSONStringify(ctx, value, QuickJS.UNDEFINED, QuickJS.UNDEFINED);
    defer QuickJS.FreeValue(ctx, val);

    const str = QuickJS.JS_ToCString(ctx, val);
    defer QuickJS.JS_FreeCString(ctx, str);

    const res = std.json.parseFromSliceLeaky(T, arena.allocator(), std.mem.span(str), .{ .allocate = .alloc_always }) catch return MappingError.CanNotConvert;

    return Mapped(T){ .value = res, .arena = arena };
}

fn getValueType(ctx: ?*QuickJS.JSContext, value: QuickJS.JSValue) ValueType {
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
