const std = @import("std");
const mapping = @import("mapping.zig");
const QuickJS = @import("quickjs.zig");
const native_endian = @import("builtin").target.cpu.arch.endian();

const RuntimeError = error{UnableToInitialize};

fn js_print(ctx: ?*QuickJS.JSContext, _: QuickJS.JSValue, argc: c_int, argv: [*c]QuickJS.JSValue) callconv(.C) QuickJS.JSValue {
    const stdout = std.io.getStdOut().writer();

    const args = argv[0..@as(usize, @intCast(argc))];

    for (args, 0..) |arg, index| {
        if (index > 0) {
            stdout.writeAll(" ") catch {};
        }
        const str = QuickJS.JS_ToCString(ctx, arg);
        defer QuickJS.JS_FreeCString(ctx, str);

        std.debug.print("{s}\n", .{str});
    }

    stdout.writeAll("\n") catch {};

    const ret = QuickJS.JS_NewInt32(ctx, 0);
    std.debug.print("ret: {any}\n", .{ret});

    return ret;
}

fn initmodule(ctx: ?*QuickJS.JSContext, module: ?*QuickJS.JSModuleDef) callconv(.C) c_int {
    _ = QuickJS.JS_SetModuleExport(ctx, module, "hello", QuickJS.JS_NewCFunction(ctx, js_print, "print", 1));
    return 0;
}

const AllocContext = struct {
    allocator: std.mem.Allocator,
    allocations: std.AutoHashMap(usize, usize),
    functions: QuickJS.JSMallocFunctions,

    const HEADER_SIZE: usize = 16;

    pub fn deinit(self: *AllocContext) void {
        self.allocations.deinit();
        self.allocator.destroy(self);
    }

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
};

pub const Runtime = struct {
    rt: *QuickJS.JSRuntime,
    alloc_context: *AllocContext,
    state: *State,

    var next_id: i32 = 0;

    pub const Timer = struct {
        id: i32,
        timeout: i64,
        ctx: ?*QuickJS.JSContext,
        func: QuickJS.JSValue,

        fn compare(_: void, a: Timer, b: Timer) std.math.Order {
            return std.math.order(a.timeout, b.timeout);
        }

        fn setTimeout(ctx: ?*QuickJS.JSContext, _: QuickJS.JSValue, argc: c_int, argv: [*c]QuickJS.JSValue) callconv(.C) QuickJS.JSValue {
            const runtime = QuickJS.JS_GetRuntime(ctx);
            const state: *State = @ptrCast(@alignCast(QuickJS.JS_GetRuntimeOpaque(runtime)));

            if (argc < 1 or QuickJS.JS_IsFunction(ctx, argv[0]) == 0) {
                return QuickJS.JS_ThrowTypeError(ctx, "setTimeout requires a function as first argument");
            }

            const func = argv[0];
            var timeout: i32 = 0;

            if (argc > 1 and QuickJS.JS_IsNumber(argv[1]) != 0) {
                _ = QuickJS.JS_ToInt32(ctx, &timeout, argv[1]);
            }

            const timer = Timer{ .id = next_id, .timeout = std.time.milliTimestamp() + timeout, .ctx = ctx, .func = QuickJS.JS_DupValue(ctx, func) };
            next_id += 1;

            state.timers.add(timer) catch return QuickJS.JS_ThrowTypeError(ctx, "Unable to create timer");

            return QuickJS.JS_NewInt32(ctx, timer.id);
        }
    };

    pub const State = struct {
        allocator: std.mem.Allocator,
        timers: std.PriorityQueue(Timer, void, Timer.compare),

        pub fn deinit(self: *State) void {
            self.timers.deinit();
            self.allocator.destroy(self);
        }
    };

    pub fn init(allocator: std.mem.Allocator) !Runtime {
        const ctx = try allocator.create(AllocContext);
        errdefer allocator.destroy(ctx);

        const state = try allocator.create(State);
        errdefer allocator.destroy(state);

        ctx.* = .{ .allocator = allocator, .allocations = std.AutoHashMap(usize, usize).init(allocator), .functions = .{
            .js_malloc = AllocContext.malloc,
            .js_free = AllocContext.free,
            .js_realloc = AllocContext.realloc,
            .js_malloc_usable_size = AllocContext.malloc_usable_size,
        } };

        state.* = .{ .allocator = allocator, .timers = std.PriorityQueue(Timer, void, Timer.compare).init(allocator, {}) };

        const runtime = QuickJS.JS_NewRuntime2(&ctx.functions, ctx);
        //const runtime = QuickJS.JS_NewRuntime();
        errdefer QuickJS.JS_FreeRuntime(runtime);

        QuickJS.JS_SetRuntimeOpaque(runtime, state);

        if (runtime) |rt| {
            return Runtime{
                .rt = rt,
                .alloc_context = ctx,
                .state = state,
            };
        }

        return RuntimeError.UnableToInitialize;
    }

    pub fn deinit(self: Runtime) void {
        QuickJS.JS_FreeRuntime(self.rt);
        self.alloc_context.deinit();
        self.state.deinit();
    }

    const TickResult = union(enum) { done, idleMs: u32, exception: mapping.Value };

    pub fn tick(self: *Runtime) TickResult {
        const now = std.time.milliTimestamp();

        w: while (true) {
            if (self.state.timers.peek()) |timer| {
                if (timer.timeout <= now) {
                    _ = self.state.timers.remove();

                    const tempfunc = QuickJS.JS_DupValue(timer.ctx, timer.func);
                    defer QuickJS.JS_FreeValue(timer.ctx, tempfunc);

                    const ret = QuickJS.JS_Call(timer.ctx, tempfunc, QuickJS.UNDEFINED, 0, null);

                    QuickJS.JS_FreeValue(timer.ctx, ret);
                    QuickJS.JS_FreeValue(timer.ctx, timer.func);
                } else {
                    break :w;
                }
            } else {
                break :w;
            }
        }

        p: while (true) {
            var context: ?*QuickJS.JSContext = undefined;
            const status = QuickJS.JS_ExecutePendingJob(self.rt, &context);

            if (status <= 0) {
                // if (status < 0) {
                //     return .{ .exception = mapping.Value{ .ctx = context, .value = QuickJS.JS_GetException(context) } };
                // }

                break :p;
            }
        }

        if (self.state.timers.peek()) |timer| {
            return .{ .idleMs = @intCast(timer.timeout - now) };
        }

        return .done;
    }

    pub fn newContext(self: *Runtime) !Context {
        return Context.init(self);
    }
};

const EvalError = error{Exception};

pub const Context = struct {
    runtime: *Runtime,
    ctx: *QuickJS.JSContext,

    pub fn init(runtime: *Runtime) !Context {
        const ctx = QuickJS.JS_NewContext(runtime.rt);
        errdefer QuickJS.JS_FreeContext(ctx);

        if (ctx) |c| {
            const am = QuickJS.JS_NewCModule(c, "deneme", initmodule);
            _ = QuickJS.JS_AddModuleExport(ctx, am, "hello");

            var context = Context{ .runtime = runtime, .ctx = c };

            const g = context.global();
            defer g.deinit();

            _ = QuickJS.JS_SetProperty(c, g.value, QuickJS.JS_NewAtom(c, "setTimeout"), QuickJS.JS_NewCFunction(c, Runtime.Timer.setTimeout, "setTimeout", 2));
            _ = QuickJS.JS_SetProperty(c, g.value, QuickJS.JS_NewAtom(c, "printf"), QuickJS.JS_NewCFunction(c, js_print, "printf", 2));

            return context;
        }

        return RuntimeError.UnableToInitialize;
    }

    pub fn deinit(self: Context) void {
        QuickJS.JS_FreeContext(self.ctx);
    }

    pub fn eval(self: *Context, comptime T: type, code: [:0]const u8) !mapping.Mapped(T) {
        return self.evalInternal(T, code, "<eval>", QuickJS.JS_EVAL_TYPE_GLOBAL);
    }

    pub fn evalPrimitive(self: *Context, comptime T: type, code: [:0]const u8) !T {
        const ret = QuickJS.JS_Eval(self.ctx, code, code.len, "<eval>", QuickJS.JS_EVAL_TYPE_GLOBAL);
        errdefer QuickJS.JS_FreeValue(self.ctx, ret);

        if (QuickJS.JS_IsException(ret) != 0) {
            QuickJS.JS_FreeValue(self.ctx, ret);
            return EvalError.Exception;
        }

        return mapping.fromValue(T, QuickJS.getAllocator(self.ctx), self.ctx, ret);
    }

    pub fn evalFile(self: *Context, comptime T: type, code: [:0]const u8, filename: [:0]const u8) !mapping.Mapped(T) {
        return self.evalInternal(code, T, filename, QuickJS.JS_EVAL_TYPE_GLOBAL);
    }

    pub fn evalModule(self: *Context, comptime T: type, code: [:0]const u8, filename: [:0]const u8) !mapping.Mapped(T) {
        return self.evalInternal(code, T, filename, QuickJS.JS_EVAL_TYPE_MODULE);
    }

    fn evalInternal(self: *Context, comptime T: type, code: [:0]const u8, filename: [:0]const u8, flags: c_int) !mapping.Mapped(T) {
        const ret = QuickJS.JS_Eval(self.ctx, code, code.len, filename, flags);
        errdefer QuickJS.JS_FreeValue(self.ctx, ret);

        if (QuickJS.JS_IsException(ret) != 0) {
            QuickJS.JS_FreeValue(self.ctx, ret);
            return EvalError.Exception;
        }

        return mapping.fromValueAlloc(T, QuickJS.getAllocator(self.ctx), self.ctx, ret);
    }

    pub fn global(self: *Context) mapping.Object {
        return mapping.Object{ .ctx = self.ctx, .value = QuickJS.JS_GetGlobalObject(self.ctx) };
    }
};
