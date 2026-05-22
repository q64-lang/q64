//! q64-wasmtime-host — v0 wasmtime runtime adapter for q64.
//!
//! Loads a `.wat` or `.wasm` file, provides the q64 capability-face
//! imports (currently only `env.out`), and calls the module's
//! `_start` export. This is the "back of the pipeline" — the byte-
//! level golden the q64 toolchain's codegen will eventually produce
//! the same shape of, from `fn main { env.out("…") }` source.
//!
//! v0 ABI it implements (spec/env.md §"Capability faces"):
//!
//!   env.out :: (ptr: i32, len: i32) -> ()
//!     Writes `len` bytes from linear memory starting at `ptr` to
//!     the host's stdout, verbatim. UTF-8 is the producer contract;
//!     the host does not validate it.
//!
//! The module must export:
//!   - `memory` — a single linear memory.
//!   - `_start` — a `() -> ()` function the host invokes.

const std = @import("std");

const c = @cImport({
    @cInclude("wasm.h");
    @cInclude("wasmtime.h");
    @cInclude("wasmtime/wat.h");
});

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var err_buf: [4096]u8 = undefined;
    var err_w = std.Io.File.stderr().writer(io, &err_buf);

    var it = init.minimal.args.iterate();
    _ = it.next(); // argv0
    const path = it.next() orelse {
        try err_w.interface.writeAll("usage: q64-wasmtime-host <file.wat|file.wasm>\n");
        try err_w.interface.flush();
        std.process.exit(2);
    };
    if (it.next() != null) {
        try err_w.interface.writeAll("usage: q64-wasmtime-host <file.wat|file.wasm>\n");
        try err_w.interface.flush();
        std.process.exit(2);
    }

    const source = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 * 1024 * 1024)) catch |e| {
        try err_w.interface.print(
            "q64-wasmtime-host: cannot read {s}: {s}\n",
            .{ path, @errorName(e) },
        );
        try err_w.interface.flush();
        std.process.exit(2);
    };
    defer gpa.free(source);

    // -------------------------------------------------------------
    // Engine + store + context.
    // -------------------------------------------------------------
    const engine = c.wasm_engine_new() orelse return error.EngineNewFailed;
    defer c.wasm_engine_delete(engine);

    const store = c.wasmtime_store_new(engine, null, null) orelse return error.StoreNewFailed;
    defer c.wasmtime_store_delete(store);

    const context = c.wasmtime_store_context(store);

    // -------------------------------------------------------------
    // Source bytes → Wasm bytes. `.wat` goes through wat2wasm;
    // anything else is treated as raw `.wasm`.
    // -------------------------------------------------------------
    var wasm_bytes: c.wasm_byte_vec_t = undefined;
    if (std.mem.endsWith(u8, path, ".wat")) {
        const wat_err = c.wasmtime_wat2wasm(@ptrCast(source.ptr), source.len, &wasm_bytes);
        if (wat_err) |e| {
            try printErrorAndDelete(io, e, "wat2wasm");
            std.process.exit(1);
        }
    } else {
        c.wasm_byte_vec_new(&wasm_bytes, source.len, @ptrCast(source.ptr));
    }
    defer c.wasm_byte_vec_delete(&wasm_bytes);

    // -------------------------------------------------------------
    // Compile module.
    // -------------------------------------------------------------
    var module: ?*c.wasmtime_module_t = null;
    {
        const mod_err = c.wasmtime_module_new(
            engine,
            @ptrCast(wasm_bytes.data),
            wasm_bytes.size,
            &module,
        );
        if (mod_err) |e| {
            try printErrorAndDelete(io, e, "module_new");
            std.process.exit(1);
        }
    }
    defer c.wasmtime_module_delete(module);

    // -------------------------------------------------------------
    // Linker: define env.out :: (i32, i32) -> ().
    // -------------------------------------------------------------
    const linker = c.wasmtime_linker_new(engine) orelse return error.LinkerNewFailed;
    defer c.wasmtime_linker_delete(linker);

    var param_types = [_]?*c.wasm_valtype_t{
        c.wasm_valtype_new(c.WASM_I32),
        c.wasm_valtype_new(c.WASM_I32),
    };
    var params_vec: c.wasm_valtype_vec_t = undefined;
    c.wasm_valtype_vec_new(&params_vec, param_types.len, @ptrCast(&param_types));

    var results_vec: c.wasm_valtype_vec_t = undefined;
    c.wasm_valtype_vec_new_empty(&results_vec);

    const env_out_type = c.wasm_functype_new(&params_vec, &results_vec) orelse
        return error.FuncTypeNewFailed;
    defer c.wasm_functype_delete(env_out_type);

    {
        const link_err = c.wasmtime_linker_define_func(
            linker,
            "env",
            "env".len,
            "out",
            "out".len,
            env_out_type,
            envOutCallback,
            null,
            null,
        );
        if (link_err) |e| {
            try printErrorAndDelete(io, e, "linker_define_func env.out");
            std.process.exit(1);
        }
    }

    // -------------------------------------------------------------
    // Instantiate.
    // -------------------------------------------------------------
    var instance: c.wasmtime_instance_t = undefined;
    var inst_trap: ?*c.wasm_trap_t = null;
    {
        const inst_err = c.wasmtime_linker_instantiate(linker, context, module, &instance, &inst_trap);
        if (inst_err) |e| {
            try printErrorAndDelete(io, e, "linker_instantiate");
            std.process.exit(1);
        }
        if (inst_trap) |t| {
            try printTrapAndDelete(io, t, "instantiate");
            std.process.exit(1);
        }
    }

    // -------------------------------------------------------------
    // Look up `_start` and call it.
    // -------------------------------------------------------------
    var start_item: c.wasmtime_extern_t = undefined;
    if (!c.wasmtime_instance_export_get(context, &instance, "_start", "_start".len, &start_item)) {
        try err_w.interface.writeAll("q64-wasmtime-host: module has no `_start` export\n");
        try err_w.interface.flush();
        std.process.exit(1);
    }
    if (start_item.kind != c.WASMTIME_EXTERN_FUNC) {
        try err_w.interface.writeAll("q64-wasmtime-host: `_start` is not a function\n");
        try err_w.interface.flush();
        std.process.exit(1);
    }

    var call_trap: ?*c.wasm_trap_t = null;
    {
        const call_err = c.wasmtime_func_call(
            context,
            &start_item.of.func,
            null,
            0,
            null,
            0,
            &call_trap,
        );
        if (call_err) |e| {
            try printErrorAndDelete(io, e, "func_call _start");
            std.process.exit(1);
        }
        if (call_trap) |t| {
            try printTrapAndDelete(io, t, "_start");
            std.process.exit(1);
        }
    }
}

// =====================================================================
// env.out host callback
// =====================================================================
//
// Called from C, so we can't accept an `Io` parameter. Reach for the
// process-wide single-threaded Io. Fine for v0 since the host is
// strictly single-threaded; revisit when we add concurrency.

fn envOutCallback(
    env_: ?*anyopaque,
    caller: ?*c.wasmtime_caller_t,
    args: [*c]const c.wasmtime_val_t,
    nargs: usize,
    results: [*c]c.wasmtime_val_t,
    nresults: usize,
) callconv(.c) ?*c.wasm_trap_t {
    _ = env_;
    _ = results;
    _ = nresults;

    if (nargs != 2) return trap("env.out: expected (i32, i32)");

    const ptr_i32 = args[0].of.i32;
    const len_i32 = args[1].of.i32;
    if (ptr_i32 < 0 or len_i32 < 0) return trap("env.out: negative ptr/len");

    var memory_item: c.wasmtime_extern_t = undefined;
    if (!c.wasmtime_caller_export_get(caller, "memory", "memory".len, &memory_item)) {
        return trap("env.out: module has no `memory` export");
    }
    if (memory_item.kind != c.WASMTIME_EXTERN_MEMORY) {
        return trap("env.out: `memory` export is not a memory");
    }

    const ctx = c.wasmtime_caller_context(caller);
    const data = c.wasmtime_memory_data(ctx, &memory_item.of.memory);
    const data_size = c.wasmtime_memory_data_size(ctx, &memory_item.of.memory);

    const ptr: usize = @intCast(ptr_i32);
    const len: usize = @intCast(len_i32);
    if (ptr + len > data_size) return trap("env.out: out-of-bounds write");

    const slice = data[ptr .. ptr + len];
    const io = std.Io.Threaded.global_single_threaded.io();
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    w.interface.writeAll(slice) catch return trap("env.out: stdout write failed");
    w.interface.flush() catch return trap("env.out: stdout flush failed");

    return null;
}

// =====================================================================
// Diagnostic helpers
// =====================================================================

fn trap(msg: []const u8) ?*c.wasm_trap_t {
    return c.wasmtime_trap_new(msg.ptr, msg.len);
}

fn printErrorAndDelete(io: std.Io, err: *c.wasmtime_error_t, ctx_label: []const u8) !void {
    var msg: c.wasm_byte_vec_t = undefined;
    c.wasmtime_error_message(err, &msg);
    defer c.wasm_byte_vec_delete(&msg);
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    try w.interface.print(
        "q64-wasmtime-host: {s}: {s}\n",
        .{ ctx_label, msg.data[0..msg.size] },
    );
    try w.interface.flush();
    c.wasmtime_error_delete(err);
}

fn printTrapAndDelete(io: std.Io, t: *c.wasm_trap_t, ctx_label: []const u8) !void {
    var msg: c.wasm_byte_vec_t = undefined;
    c.wasm_trap_message(t, &msg);
    defer c.wasm_byte_vec_delete(&msg);
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    try w.interface.print(
        "q64-wasmtime-host: trap during {s}: {s}\n",
        .{ ctx_label, msg.data[0..msg.size] },
    );
    try w.interface.flush();
    c.wasm_trap_delete(t);
}
