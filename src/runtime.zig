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

    /// Runs the garbage collector.
    pub fn runGC(self: Runtime) void {
        QuickJS.JS_RunGC(self.rt);
    }

    pub fn setModuleLoader(self: Runtime, loader: fn (name: []const u8) ?[]const u8) void {
        const Loader = struct {
            pub fn load(ctx: ?*QuickJS.JSContext, name: [*c]const u8, _: ?*anyopaque) callconv(.C) ?*QuickJS.JSModuleDef {
                const namestr = std.mem.span(name);
                const code = loader(namestr);

                if (code) |c| {
                    const allocator = QuickJS.getAllocator(ctx);

                    const codeC = allocator.dupeZ(u8, c) catch {
                        _ = QuickJS.JS_ThrowReferenceError(ctx, "out of memory while loading module %s", name);
                        return null;
                    };

                    defer allocator.free(codeC);

                    const ret = QuickJS.JS_Eval(ctx, codeC, codeC.len, name, QuickJS.JS_EVAL_TYPE_MODULE | QuickJS.JS_EVAL_FLAG_COMPILE_ONLY);

                    if (QuickJS.JS_IsException(ret) != 0) {
                        return null;
                    }

                    const def: *QuickJS.JSModuleDef = @ptrCast(@alignCast(QuickJS.GET_PTR(ret)));
                    QuickJS.FreeValue(ctx, ret);

                    return def;
                } else {
                    _ = QuickJS.JS_ThrowReferenceError(ctx, "could not load module %s", name);
                    return null;
                }
            }
        };

        QuickJS.JS_SetModuleLoaderFunc(self.rt, null, Loader.load, null);
    }
};

const EvalError = error{Exception};

fn prnt(v: []u8) i32 {
    std.debug.print("{s}\n", .{v});
    return 0;
}

/// A single execution context with its own global variables and stack
/// Can share objects with other contexts of the same runtime.
pub const Context = struct {
    runtime: *Runtime,
    ctx: *QuickJS.JSContext,
    state: *State,

    pub const State = struct {
        pub const Arena = struct {
            ctx: *QuickJS.JSContext,
            arena: *std.heap.ArenaAllocator,
            values: std.ArrayList(QuickJS.JSValue),

            pub fn deinit(self: *Arena) void {
                for (self.values.items) |value| {
                    QuickJS.FreeValue(self.ctx, value);
                }

                const alloc = self.arena.child_allocator;
                self.arena.deinit();
                alloc.destroy(self.arena);
            }
        };

        arenas: std.SinglyLinkedList(Arena),
    };

    /// Initializes a new context for the provided runtime.
    pub fn init(runtime: *Runtime) !Context {
        const ctx = QuickJS.JS_NewContext(runtime.rt);
        errdefer QuickJS.JS_FreeContext(ctx);

        if (ctx) |c| {
            const am = QuickJS.JS_NewCModule(c, "deneme", initmodule);
            _ = QuickJS.JS_AddModuleExport(ctx, am, "hello");

            const ct = Context{
                .runtime = runtime,
                .ctx = c,
                .state = try runtime.state.alloc.allocator.create(State),
            };

            errdefer runtime.state.alloc.allocator.destroy(ct.state);

            ct.state.* = .{
                .arenas = std.SinglyLinkedList(State.Arena){},
            };

            QuickJS.JS_SetContextOpaque(c, ct.state);

            const glb = ct.global();
            defer glb.deinit();

            try glb.setProperty("printf", prnt);

            return ct;
        }

        return RuntimeError.UnableToInitialize;
    }

    pub const ArenaRef = struct {
        arenas: *std.SinglyLinkedList(State.Arena),
        node: *std.SinglyLinkedList(State.Arena).Node,

        pub fn deinit(self: *ArenaRef) void {
            const alloc = self.node.data.arena.child_allocator;

            self.node.data.deinit();
            self.arenas.remove(self.node);

            alloc.destroy(self.node);
        }
    };

    /// Begins a new arena in the context.
    /// Any allocations or values created in the arena will be deallocated when the arena is deinitialized.
    /// You do not need to explicitly free the values created in the arena.
    pub fn beginArena(self: Context) !ArenaRef {
        return self.beginArenaIn(QuickJS.getAllocator(self.ctx));
    }

    /// Begins a new arena in a specific allocator.
    /// Any allocations or values created in the arena will be deallocated when the arena is deinitialized.
    /// You do not need to explicitly free the values created in the arena.
    pub fn beginArenaIn(self: Context, allocator: std.mem.Allocator) !ArenaRef {
        var arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);

        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        const alloc = arena.allocator();

        const node = try allocator.create(std.SinglyLinkedList(State.Arena).Node);
        errdefer allocator.destroy(node);

        node.*.data = State.Arena{
            .ctx = self.ctx,
            .arena = arena,
            .values = try std.ArrayList(QuickJS.JSValue).initCapacity(alloc, 16),
        };

        self.state.arenas.prepend(node);

        return ArenaRef{
            .arenas = &self.state.arenas,
            .node = node,
        };
    }

    /// Deinitializes the context.
    pub fn deinit(self: Context) void {
        QuickJS.JS_FreeContext(self.ctx);
        self.runtime.state.alloc.allocator.destroy(self.state);
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
    pub fn evalAsBuf(self: Context, comptime T: type, code: [:0]const u8, buf: []u8) !T {
        return (try self.eval(code)).asBuf(T, buf);
    }

    /// Evaluates the provided code in the context as a module and returns a `Value` with the result.
    pub fn evalModule(self: Context, code: [:0]const u8, filename: [:0]const u8) !mapping.Value {
        return self.evalInternal(code, filename, QuickJS.JS_EVAL_TYPE_MODULE);
    }

    /// Creates a new JS `Value` from the provided value.
    pub fn createValue(self: Context, value: anytype) !mapping.Value {
        return mapping.Value.init(self.ctx, value);
    }

    fn evalInternal(self: Context, code: [:0]const u8, filename: [:0]const u8, flags: c_int) !mapping.Value {
        const ret = QuickJS.JS_Eval(self.ctx, code, code.len, filename, flags);
        errdefer QuickJS.FreeValue(self.ctx, ret);

        if (QuickJS.JS_IsException(ret) != 0) {
            return EvalError.Exception;
        }

        return mapping.Value.init(self.ctx, ret);
    }

    /// Returns the global object of the context.
    pub fn global(self: Context) mapping.Value {
        return mapping.Value.init(self.ctx, QuickJS.JS_GetGlobalObject(self.ctx));
    }

    /// Returns the latest exception thrown in the context.
    pub fn exception(self: Context) ?mapping.Value {
        if (QuickJS.JS_HasException(self.ctx) != 0) {
            return mapping.Value.init(self.ctx, QuickJS.JS_GetException(self.ctx));
        }

        return null;
    }
};
