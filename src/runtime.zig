const std = @import("std");
const mapping = @import("mapping.zig");
const QuickJS = @import("quickjs.zig");
const AllocContext = @import("alloc.zig");

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

/// QuickJS runtime, entry point of the library.
pub const Runtime = struct {
    rt: *QuickJS.JSRuntime,
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

            const timer = Timer{ .id = next_id, .timeout = std.time.milliTimestamp() + timeout, .ctx = ctx, .func = QuickJS.DupValue(ctx, func) };
            next_id += 1;

            state.timers.add(timer) catch return QuickJS.JS_ThrowTypeError(ctx, "Unable to create timer");

            return QuickJS.JS_NewInt32(ctx, timer.id);
        }
    };

    pub const State = struct {
        alloc: AllocContext,
        timers: std.PriorityQueue(Timer, void, Timer.compare),

        pub fn deinit(self: *State) void {
            self.timers.deinit();
            self.alloc.allocator.destroy(self);
        }
    };

    /// Initializes the QuickJS runtime.
    /// The provided allocator is used to allocate memory for the runtime.
    pub fn init(allocator: std.mem.Allocator) !Runtime {
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);

        state.* = .{
            .alloc = .{
                .allocator = allocator,
                .functions = .{
                    .js_malloc = AllocContext.malloc,
                    .js_free = AllocContext.free,
                    .js_realloc = AllocContext.realloc,
                    .js_malloc_usable_size = AllocContext.malloc_usable_size,
                },
            },
            .timers = std.PriorityQueue(Timer, void, Timer.compare).init(allocator, {}),
        };

        const runtime = QuickJS.JS_NewRuntime2(&state.alloc.functions, &state.alloc);
        errdefer QuickJS.JS_FreeRuntime(runtime);

        QuickJS.JS_SetRuntimeOpaque(runtime, state);

        if (runtime) |rt| {
            return Runtime{
                .rt = rt,
                .state = state,
            };
        }

        return RuntimeError.UnableToInitialize;
    }

    /// Deinitializes the QuickJS runtime.
    pub fn deinit(self: Runtime) void {
        QuickJS.JS_FreeRuntime(self.rt);
        self.state.deinit();
    }

    const TickResult = union(enum) { done, idleMs: u32, exception: mapping.Value };

    /// Executes the next tick of the runtime. All pending jobs (promise continuations, timers etc.) are executed.
    /// If there are no more pending jobs, the function returns `done`.
    /// If there are pending timers, the function returns `idleMs` with the number of milliseconds until the next timer.
    /// If an exception is thrown during the execution of a job, the function returns `exception` with the exception value.
    pub fn tick(self: *Runtime) TickResult {
        const now = std.time.milliTimestamp();

        w: while (true) {
            if (self.state.timers.peek()) |timer| {
                if (timer.timeout <= now) {
                    _ = self.state.timers.remove();

                    const tempfunc = QuickJS.DupValue(timer.ctx, timer.func);
                    defer QuickJS.FreeValue(timer.ctx, tempfunc);

                    const ret = QuickJS.JS_Call(timer.ctx, tempfunc, QuickJS.UNDEFINED, 0, null);

                    QuickJS.FreeValue(timer.ctx, ret);
                    QuickJS.FreeValue(timer.ctx, timer.func);
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

    /// Creates a new context for the runtime.
    pub fn newContext(self: *Runtime) !Context {
        return Context.init(self);
    }
};

const EvalError = error{Exception};

/// A single execution context with its own global variables and stack
/// Can share objects with other contexts of the same runtime.
pub const Context = struct {
    runtime: *Runtime,
    ctx: *QuickJS.JSContext,

    /// Initializes a new context for the provided runtime.
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

    /// Deinitializes the context.
    pub fn deinit(self: Context) void {
        QuickJS.JS_FreeContext(self.ctx);
    }

    /// Evaluates the provided code in the context and returns a `Value` with the result.
    pub fn eval(self: Context, code: [:0]const u8) !mapping.Value {
        return self.evalInternal(code, "<eval>", QuickJS.JS_EVAL_TYPE_GLOBAL);
    }

    /// Evaluates the provided code in the context and returns the resulting value mapped to T
    /// If the result can not be mapped to T, an error is returned.
    /// If an exception is thrown during the evaluation, an error is returned.
    /// If the resulting type needs to be allocated, returns an error. Please use `evalAsAlloc` instead.
    pub fn evalAs(self: Context, comptime T: type, code: [:0]const u8) !T {
        return (try self.eval(code)).as(T);
    }

    /// Same as `eval` but uses the runtime allocator to allocate memory.
    /// Can map to strings, arrays, structs, etc.
    /// Resulting struct needs to be deallocated manually using `deinit` method.
    pub fn evalAsAlloc(self: Context, comptime T: type, code: [:0]const u8) !mapping.Mapped(T) {
        return (try self.eval(code)).asAlloc(T);
    }

    /// Same as `eval` but uses the provided allocator to allocate memory.
    /// Can map to strings, arrays, structs, etc.
    /// Resulting struct needs to be deallocated manually using `deinit` method.
    pub fn evalAsAllocIn(self: Context, comptime T: type, allocator: std.mem.Allocator, code: [:0]const u8) !mapping.Mapped(T) {
        return (try self.eval(code)).asAllocIn(T, allocator);
    }

    /// Same as `eval` but uses the provided buffer as scratch space. If the buffer is not large enough, an error is returned.
    /// Can map to strings, arrays, structs, etc.
    pub fn evalAsBuf(self: Context, comptime T: type, code: [:0]const u8, buf: []u8) !mapping.Mapped(T) {
        return (try self.eval(code)).asBuf(T, buf);
    }

    /// Evaluates the provided code in the context as a module and returns a `Value` with the result.
    pub fn evalModule(self: Context, code: [:0]const u8, filename: [:0]const u8) !mapping.Value {
        return self.evalInternal(code, filename, QuickJS.JS_EVAL_TYPE_MODULE);
    }

    fn evalInternal(self: Context, code: [:0]const u8, filename: [:0]const u8, flags: c_int) !mapping.Value {
        const ret = QuickJS.JS_Eval(self.ctx, code, code.len, filename, flags);
        errdefer QuickJS.FreeValue(self.ctx, ret);

        if (QuickJS.JS_IsException(ret) != 0) {
            QuickJS.FreeValue(self.ctx, ret);
            return EvalError.Exception;
        }

        return mapping.Value.init(self.ctx, ret);
    }

    /// Returns the global object of the context.
    pub fn global(self: Context) mapping.Object {
        return mapping.Object.init(self.ctx, QuickJS.JS_GetGlobalObject(self.ctx));
    }
};
