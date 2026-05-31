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
//!   env.out :: (ptr, len) -> ()
//!     Writes `len` bytes from linear memory starting at `ptr` to
//!     the host's stdout, verbatim. UTF-8 is the producer contract;
//!     the host does not validate it. ptr/len are i64 on wasm64
//!     (Memory64) and i32 on wasm32 (spec/memory.md §"The platform"):
//!     the host introspects the module's `env.out` import to define a
//!     matching func type and reads each arg by its runtime kind, so one
//!     binary runs modules of either address space.
//!
//! The module must export:
//!   - `memory` — a single linear memory (32-bit on wasm32, Memory64 on wasm64).
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
    // q64 emits 64-bit (Memory64) modules; memory64 is off by default in
    // wasmtime, so enable it on the engine config. `new_with_config`
    // takes ownership of the config — don't free it here.
    const config = c.wasm_config_new() orelse return error.ConfigNewFailed;
    c.wasmtime_config_wasm_memory64_set(config, true);
    const engine = c.wasm_engine_new_with_config(config) orelse return error.EngineNewFailed;
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
    // Linker: define env.out :: (ptr, len) -> (). q64 emits ptr/len as i64 on
    // wasm64 (Memory64) and i32 on wasm32, so the host func type must match the
    // module's import — introspect it. The callback then reads each arg by its
    // runtime kind, so one host binary runs modules of either address space.
    // -------------------------------------------------------------
    const env_out_i32 = envOutWantsI32(module);

    const linker = c.wasmtime_linker_new(engine) orelse return error.LinkerNewFailed;
    defer c.wasmtime_linker_delete(linker);

    const arg_valkind: c.wasm_valkind_t = if (env_out_i32) c.WASM_I32 else c.WASM_I64;
    var param_types = [_]?*c.wasm_valtype_t{
        c.wasm_valtype_new(arg_valkind),
        c.wasm_valtype_new(arg_valkind),
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

    if (nargs != 2) return trap("env.out: expected (ptr, len)");

    // ptr/len are i32 (wasm32) or i64 (wasm64); read each by its runtime kind
    // so the host is address-space-agnostic.
    const ptr_i64 = argAddr(args[0]);
    const len_i64 = argAddr(args[1]);
    if (ptr_i64 < 0 or len_i64 < 0) return trap("env.out: negative ptr/len");

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

    const ptr: usize = @intCast(ptr_i64);
    const len: usize = @intCast(len_i64);
    if (ptr + len > data_size) return trap("env.out: out-of-bounds write");

    const slice = data[ptr .. ptr + len];
    const io = std.Io.Threaded.global_single_threaded.io();
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    w.interface.writeAll(slice) catch return trap("env.out: stdout write failed");
    w.interface.flush() catch return trap("env.out: stdout flush failed");

    return null;
}

/// Read a wasm value as an address, accepting either an i32 (wasm32) or i64
/// (wasm64) pointer/length and widening to i64.
fn argAddr(v: c.wasmtime_val_t) i64 {
    return switch (v.kind) {
        c.WASMTIME_I32 => v.of.i32,
        else => v.of.i64,
    };
}

/// Inspect the module's imports for `env`/`out` and report whether its first
/// parameter is i32 (wasm32). The host defines a matching func type. Defaults
/// to i64 (wasm64) when the import is absent or not a function.
fn envOutWantsI32(module: ?*c.wasmtime_module_t) bool {
    var imports: c.wasm_importtype_vec_t = undefined;
    c.wasmtime_module_imports(module, &imports);
    defer c.wasm_importtype_vec_delete(&imports);
    var i: usize = 0;
    while (i < imports.size) : (i += 1) {
        const it = imports.data[i] orelse continue;
        if (!nameEql(c.wasm_importtype_module(it), "env")) continue;
        if (!nameEql(c.wasm_importtype_name(it), "out")) continue;
        const ft = c.wasm_externtype_as_functype(@constCast(c.wasm_importtype_type(it))) orelse return false;
        const ps = c.wasm_functype_params(ft);
        if (ps.*.size >= 1) return c.wasm_valtype_kind(ps.*.data[0]) == c.WASM_I32;
        return false;
    }
    return false;
}

/// Compare a `wasm_name_t` (byte vector, not NUL-terminated) to a Zig slice.
fn nameEql(name: ?*const c.wasm_name_t, s: []const u8) bool {
    const n = name orelse return false;
    if (n.*.size != s.len) return false;
    return std.mem.eql(u8, n.*.data[0..s.len], s);
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
