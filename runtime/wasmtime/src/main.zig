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
const render = @import("render.zig");

const c = @cImport({
    @cInclude("wasm.h");
    @cInclude("wasmtime.h");
    @cInclude("wasmtime/wat.h");
});

// Accumulated `qview` display list, recorded by the host's qview callbacks and
// rasterized to a PNG after `_start` when `--png <path>` is given. Globals
// because the wasmtime callbacks are bare C functions (single-run process).
var g_display: std.ArrayListUnmanaged(render.Op) = .empty;
var g_alloc: std.mem.Allocator = undefined;

// env.kv_increment's v0 key-value store: counter per str key (the empty key is
// the keyless form's single counter). Process-global because the wasmtime
// callback is a bare C function; one run = one store. Keys are duped into
// g_alloc (the guest-memory slice is transient).
var g_kv_store: std.StringHashMapUnmanaged(i64) = .empty;

// The qube's command-line arguments (`env.args`): argv[0] is the program path,
// followed by anything after a `--` separator on the host command line. Set in
// main; read by `envArgsCallback`. `g_ptr_width` is the module's address width
// (4 on wasm32, 8 on wasm64) — the cell pointers/lengths are stored at it.
var g_args: std.ArrayListUnmanaged([]const u8) = .empty;
var g_ptr_width: usize = 8;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    // The qview display list lives for the whole run and is freed at exit; use
    // the page allocator so the leak-checked gpa doesn't flag it.
    g_alloc = std.heap.page_allocator;
    const io = init.io;

    var err_buf: [4096]u8 = undefined;
    var err_w = std.Io.File.stderr().writer(io, &err_buf);

    // usage: q64-wasmtime-host <file.wasm> [--png out.png] [--size WxH] [--bg RRGGBB]
    // The `--png` flags render the accumulated qview display list to an image —
    // the headless render-capture of a GUI qube (the native window is `qube run`).
    var it = init.minimal.args.iterate();
    _ = it.next(); // argv0
    var path: ?[]const u8 = null;
    var png_path: ?[]const u8 = null;
    var contact_path: ?[]const u8 = null;
    var cv_w: u32 = 360;
    var cv_h: u32 = 360;
    var cv_bg: u32 = 0x14161C;
    var cols: u32 = 4;
    var cell_w: u32 = 160;
    var cell_h: u32 = 160;
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--png")) {
            png_path = it.next();
        } else if (std.mem.eql(u8, arg, "--contact")) {
            contact_path = it.next();
        } else if (std.mem.eql(u8, arg, "--cols")) {
            if (it.next()) |n| cols = std.fmt.parseInt(u32, n, 10) catch cols;
        } else if (std.mem.eql(u8, arg, "--cell")) {
            if (it.next()) |dim| {
                if (std.mem.indexOfScalar(u8, dim, 'x')) |xi| {
                    cell_w = std.fmt.parseInt(u32, dim[0..xi], 10) catch cell_w;
                    cell_h = std.fmt.parseInt(u32, dim[xi + 1 ..], 10) catch cell_h;
                }
            }
        } else if (std.mem.eql(u8, arg, "--size")) {
            if (it.next()) |dim| {
                if (std.mem.indexOfScalar(u8, dim, 'x')) |xi| {
                    cv_w = std.fmt.parseInt(u32, dim[0..xi], 10) catch cv_w;
                    cv_h = std.fmt.parseInt(u32, dim[xi + 1 ..], 10) catch cv_h;
                }
            }
        } else if (std.mem.eql(u8, arg, "--bg")) {
            if (it.next()) |hex| cv_bg = std.fmt.parseInt(u32, hex, 16) catch cv_bg;
        } else if (std.mem.eql(u8, arg, "--")) {
            // Everything after `--` is the qube's own argv (env.args[1..]).
            while (it.next()) |qa| try g_args.append(g_alloc, qa);
        } else if (path == null) {
            path = arg;
        }
    }
    const wasm_path = path orelse {
        try err_w.interface.writeAll("usage: q64-wasmtime-host <file.wasm> [--png out.png] [--size WxH] [--bg RRGGBB]\n");
        try err_w.interface.flush();
        std.process.exit(2);
    };

    const source = std.Io.Dir.cwd().readFileAlloc(io, wasm_path, gpa, .limited(16 * 1024 * 1024)) catch |e| {
        try err_w.interface.print(
            "q64-wasmtime-host: cannot read {s}: {s}\n",
            .{ wasm_path, @errorName(e) },
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
    if (std.mem.endsWith(u8, wasm_path, ".wat")) {
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
    const env_out_i32 = moduleAddrIsI32(module);
    // env.args layout uses the module's address width; argv[0] is the program.
    g_ptr_width = if (env_out_i32) 4 else 8;
    try g_args.insert(g_alloc, 0, wasm_path);

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

    // env.err :: (ptr, len) -> () — the stderr twin of env.out (same
    // address-width signature, `wasi:cli/stderr`). Reuses `env_out_type`.
    {
        const link_err = c.wasmtime_linker_define_func(
            linker,
            "env",
            "env".len,
            "err",
            "err".len,
            env_out_type,
            envErrCallback,
            null,
            null,
        );
        if (link_err) |e| {
            try printErrorAndDelete(io, e, "linker_define_func env.err");
            std.process.exit(1);
        }
    }

    // -------------------------------------------------------------
    // env.fs_read :: (dest, path_ptr, path_len) -> i64 (spec/env.md
    // §"Wire ABI: fs.read"). Same address-width introspection as env.out.
    // Defined unconditionally; modules that don't import it are unaffected.
    // -------------------------------------------------------------
    {
        var fs_param_types = [_]?*c.wasm_valtype_t{
            c.wasm_valtype_new(arg_valkind),
            c.wasm_valtype_new(arg_valkind),
            c.wasm_valtype_new(arg_valkind),
        };
        var fs_params_vec: c.wasm_valtype_vec_t = undefined;
        c.wasm_valtype_vec_new(&fs_params_vec, fs_param_types.len, @ptrCast(&fs_param_types));
        var fs_result_types = [_]?*c.wasm_valtype_t{c.wasm_valtype_new(c.WASM_I64)};
        var fs_results_vec: c.wasm_valtype_vec_t = undefined;
        c.wasm_valtype_vec_new(&fs_results_vec, fs_result_types.len, @ptrCast(&fs_result_types));
        const fs_type = c.wasm_functype_new(&fs_params_vec, &fs_results_vec) orelse
            return error.FuncTypeNewFailed;
        defer c.wasm_functype_delete(fs_type);
        const link_err = c.wasmtime_linker_define_func(
            linker,
            "env",
            "env".len,
            "fs_read",
            "fs_read".len,
            fs_type,
            envFsReadCallback,
            null,
            null,
        );
        if (link_err) |e| {
            try printErrorAndDelete(io, e, "linker_define_func env.fs_read");
            std.process.exit(1);
        }
    }

    // -------------------------------------------------------------
    // env.kv_increment :: (delta) -> i64 (spec/env.md §`env.kv`,
    // `wasi:keyvalue/atomics.increment`). v0 floor: a single in-process counter
    // (no key), so a module that increments sees a monotonic shared total — the
    // shape qubepods backs with the project's key-value store. delta + result
    // are i64 regardless of address space. Defined unconditionally; modules that
    // don't import it are unaffected.
    // -------------------------------------------------------------
    {
        // (key_ptr, key_len, delta) -> i64. key ptr/len ride the address width
        // (i32 on wasm32, i64 on wasm64 — same introspection as env.out); delta
        // and the result are always i64.
        var kv_param_types = [_]?*c.wasm_valtype_t{
            c.wasm_valtype_new(arg_valkind),
            c.wasm_valtype_new(arg_valkind),
            c.wasm_valtype_new(c.WASM_I64),
        };
        var kv_params_vec: c.wasm_valtype_vec_t = undefined;
        c.wasm_valtype_vec_new(&kv_params_vec, kv_param_types.len, @ptrCast(&kv_param_types));
        var kv_result_types = [_]?*c.wasm_valtype_t{c.wasm_valtype_new(c.WASM_I64)};
        var kv_results_vec: c.wasm_valtype_vec_t = undefined;
        c.wasm_valtype_vec_new(&kv_results_vec, kv_result_types.len, @ptrCast(&kv_result_types));
        const kv_type = c.wasm_functype_new(&kv_params_vec, &kv_results_vec) orelse
            return error.FuncTypeNewFailed;
        defer c.wasm_functype_delete(kv_type);
        const link_err = c.wasmtime_linker_define_func(
            linker,
            "env",
            "env".len,
            "kv_increment",
            "kv_increment".len,
            kv_type,
            envKvIncrementCallback,
            null,
            null,
        );
        if (link_err) |e| {
            try printErrorAndDelete(io, e, "linker_define_func env.kv_increment");
            std.process.exit(1);
        }
    }

    // env.random_u64 :: () -> i64 — one word of host randomness
    // (spec/env.md `env.random`, `@random`). The HOST owns the policy:
    // Q64_SEED=<n> makes the stream a deterministic SplitMix64 sequence
    // (reproducible runs, capability-visible determinism); unset, the
    // stream seeds from OS entropy once per run.
    {
        var rnd_params_vec: c.wasm_valtype_vec_t = undefined;
        c.wasm_valtype_vec_new_empty(&rnd_params_vec);
        var rnd_result_types = [_]?*c.wasm_valtype_t{c.wasm_valtype_new(c.WASM_I64)};
        var rnd_results_vec: c.wasm_valtype_vec_t = undefined;
        c.wasm_valtype_vec_new(&rnd_results_vec, rnd_result_types.len, @ptrCast(&rnd_result_types));
        const rnd_type = c.wasm_functype_new(&rnd_params_vec, &rnd_results_vec) orelse
            return error.FuncTypeNewFailed;
        defer c.wasm_functype_delete(rnd_type);
        const link_err = c.wasmtime_linker_define_func(
            linker,
            "env",
            "env".len,
            "random_u64",
            "random_u64".len,
            rnd_type,
            envRandomU64Callback,
            null,
            null,
        );
        if (link_err) |e| {
            try printErrorAndDelete(io, e, "linker_define_func env.random_u64");
            std.process.exit(1);
        }
    }

    // env.time faces (spec/env.md `env.time`) — the local `qube run` ABI's
    // clock: monotonic_ns/resolution_ns/unix_ns are niladic i64 reads,
    // sleep_ns blocks the calling thread. Backed by libc clock_gettime/
    // clock_getres/nanosleep. (These were the missing imports that kept the
    // scheduler sections of link-roundtrip.sh from running on this host.)
    {
        var t_params_vec: c.wasm_valtype_vec_t = undefined;
        c.wasm_valtype_vec_new_empty(&t_params_vec);
        var t_result_types = [_]?*c.wasm_valtype_t{c.wasm_valtype_new(c.WASM_I64)};
        var t_results_vec: c.wasm_valtype_vec_t = undefined;
        c.wasm_valtype_vec_new(&t_results_vec, t_result_types.len, @ptrCast(&t_result_types));
        const t_type = c.wasm_functype_new(&t_params_vec, &t_results_vec) orelse
            return error.FuncTypeNewFailed;
        defer c.wasm_functype_delete(t_type);
        const clock_faces = [_]struct { name: []const u8, cb: c.wasmtime_func_callback_t }{
            .{ .name = "monotonic_ns", .cb = envMonotonicNsCallback },
            .{ .name = "resolution_ns", .cb = envResolutionNsCallback },
            .{ .name = "unix_ns", .cb = envUnixNsCallback },
        };
        for (clock_faces) |f| {
            const link_err2 = c.wasmtime_linker_define_func(
                linker,
                "env",
                "env".len,
                f.name.ptr,
                f.name.len,
                t_type,
                f.cb,
                null,
                null,
            );
            if (link_err2) |e| {
                try printErrorAndDelete(io, e, "linker_define_func env.time face");
                std.process.exit(1);
            }
        }
    }
    {
        var sl_param_types = [_]?*c.wasm_valtype_t{c.wasm_valtype_new(c.WASM_I64)};
        var sl_params_vec: c.wasm_valtype_vec_t = undefined;
        c.wasm_valtype_vec_new(&sl_params_vec, sl_param_types.len, @ptrCast(&sl_param_types));
        var sl_results_vec: c.wasm_valtype_vec_t = undefined;
        c.wasm_valtype_vec_new_empty(&sl_results_vec);
        const sl_type = c.wasm_functype_new(&sl_params_vec, &sl_results_vec) orelse
            return error.FuncTypeNewFailed;
        defer c.wasm_functype_delete(sl_type);
        const link_err2 = c.wasmtime_linker_define_func(
            linker,
            "env",
            "env".len,
            "sleep_ns",
            "sleep_ns".len,
            sl_type,
            envSleepNsCallback,
            null,
            null,
        );
        if (link_err2) |e| {
            try printErrorAndDelete(io, e, "linker_define_func env.sleep_ns");
            std.process.exit(1);
        }
    }

    // -------------------------------------------------------------
    // env.exit :: (code: i64) -> () (spec/env.md §`env.exit`,
    // `wasi:cli/exit`). The host terminates the process with the low byte of
    // `code` as its exit status (POSIX exit codes are 0–255). `code` is a value,
    // not an address, so it is i64 on either address space. Defined
    // unconditionally; modules that don't import it are unaffected.
    // -------------------------------------------------------------
    {
        var exit_param_types = [_]?*c.wasm_valtype_t{c.wasm_valtype_new(c.WASM_I64)};
        var exit_params_vec: c.wasm_valtype_vec_t = undefined;
        c.wasm_valtype_vec_new(&exit_params_vec, exit_param_types.len, @ptrCast(&exit_param_types));
        var exit_results_vec: c.wasm_valtype_vec_t = undefined;
        c.wasm_valtype_vec_new_empty(&exit_results_vec);
        const exit_type = c.wasm_functype_new(&exit_params_vec, &exit_results_vec) orelse
            return error.FuncTypeNewFailed;
        defer c.wasm_functype_delete(exit_type);
        const link_err = c.wasmtime_linker_define_func(
            linker,
            "env",
            "env".len,
            "exit",
            "exit".len,
            exit_type,
            envExitCallback,
            null,
            null,
        );
        if (link_err) |e| {
            try printErrorAndDelete(io, e, "linker_define_func env.exit");
            std.process.exit(1);
        }
    }

    // -------------------------------------------------------------
    // env.args :: (dest) -> i64 (spec/env.md §`env.args`,
    // `wasi:cli/environment.get-arguments`). The host writes
    // `[count][cells…][bytes…]` at `dest` and returns the total bytes. `dest` is
    // address-width (introspected, like env.out); the result is always i64.
    // -------------------------------------------------------------
    {
        var args_param_types = [_]?*c.wasm_valtype_t{c.wasm_valtype_new(arg_valkind)};
        var args_params_vec: c.wasm_valtype_vec_t = undefined;
        c.wasm_valtype_vec_new(&args_params_vec, args_param_types.len, @ptrCast(&args_param_types));
        var args_result_types = [_]?*c.wasm_valtype_t{c.wasm_valtype_new(c.WASM_I64)};
        var args_results_vec: c.wasm_valtype_vec_t = undefined;
        c.wasm_valtype_vec_new(&args_results_vec, args_result_types.len, @ptrCast(&args_result_types));
        const args_type = c.wasm_functype_new(&args_params_vec, &args_results_vec) orelse
            return error.FuncTypeNewFailed;
        defer c.wasm_functype_delete(args_type);
        const link_err = c.wasmtime_linker_define_func(
            linker,
            "env",
            "env".len,
            "args",
            "args".len,
            args_type,
            envArgsCallback,
            null,
            null,
        );
        if (link_err) |e| {
            try printErrorAndDelete(io, e, "linker_define_func env.args");
            std.process.exit(1);
        }
    }

    // -------------------------------------------------------------
    // env.envvar :: (dest, key_ptr, key_len) -> i64 (spec/env.md §`env.envvars`,
    // `wasi:cli/environment.get-environment`). The host writes the variable's
    // value at dest and returns its byte length (0 if unset). Same address-width
    // introspection as env.fs_read.
    // -------------------------------------------------------------
    {
        var ev_param_types = [_]?*c.wasm_valtype_t{
            c.wasm_valtype_new(arg_valkind),
            c.wasm_valtype_new(arg_valkind),
            c.wasm_valtype_new(arg_valkind),
        };
        var ev_params_vec: c.wasm_valtype_vec_t = undefined;
        c.wasm_valtype_vec_new(&ev_params_vec, ev_param_types.len, @ptrCast(&ev_param_types));
        var ev_result_types = [_]?*c.wasm_valtype_t{c.wasm_valtype_new(c.WASM_I64)};
        var ev_results_vec: c.wasm_valtype_vec_t = undefined;
        c.wasm_valtype_vec_new(&ev_results_vec, ev_result_types.len, @ptrCast(&ev_result_types));
        const ev_type = c.wasm_functype_new(&ev_params_vec, &ev_results_vec) orelse
            return error.FuncTypeNewFailed;
        defer c.wasm_functype_delete(ev_type);
        const link_err = c.wasmtime_linker_define_func(
            linker,
            "env",
            "env".len,
            "envvar",
            "envvar".len,
            ev_type,
            envEnvvarCallback,
            null,
            null,
        );
        if (link_err) |e| {
            try printErrorAndDelete(io, e, "linker_define_func env.envvar");
            std.process.exit(1);
        }
    }

    // -------------------------------------------------------------
    // Headless `qview.*` host face (spec/reactivity.md; the live web POC's
    // ABI). qview is an *open* face — any `qview.<op>(...)` a program invents
    // (`box`, `line`, `circle`, …) lowers to a host import. Rather than a fixed
    // list, enumerate the module's imports and define every `qview` one with a
    // generic trace callback that prints `@qview <op> <args…>` — a deterministic
    // display list a test asserts on and `scripts/qview-render.py` draws to PNG.
    // -------------------------------------------------------------
    {
        var imports: c.wasm_importtype_vec_t = undefined;
        c.wasmtime_module_imports(module, &imports);
        defer c.wasm_importtype_vec_delete(&imports);
        var i: usize = 0;
        while (i < imports.size) : (i += 1) {
            const imp = imports.data[i] orelse continue;
            if (!nameEql(c.wasm_importtype_module(imp), "qview")) continue;
            const nm = c.wasm_importtype_name(imp) orelse continue;
            const ft = c.wasm_externtype_as_functype(@constCast(c.wasm_importtype_type(imp))) orelse continue;
            const ps = c.wasm_functype_params(ft);
            const np = ps.*.size;
            // A process-lifetime, null-terminated op name for the callback's data.
            const op_z = std.heap.page_allocator.allocSentinel(u8, nm.*.size, 0) catch return error.OutOfMemory;
            @memcpy(op_z[0..nm.*.size], nm.*.data[0..nm.*.size]);
            // Match the import's own param kinds (i64 for ints; i32 for wasm32
            // str ptr/len). Results are void (drawing ops).
            const qptypes = try std.heap.page_allocator.alloc(?*c.wasm_valtype_t, np);
            var k: usize = 0;
            while (k < np) : (k += 1) qptypes[k] = c.wasm_valtype_new(c.wasm_valtype_kind(ps.*.data[k]));
            var qparams: c.wasm_valtype_vec_t = undefined;
            c.wasm_valtype_vec_new(&qparams, np, @ptrCast(qptypes.ptr));
            var qresults: c.wasm_valtype_vec_t = undefined;
            c.wasm_valtype_vec_new_empty(&qresults);
            const qtype = c.wasm_functype_new(&qparams, &qresults) orelse return error.FuncTypeNewFailed;
            defer c.wasm_functype_delete(qtype);
            const qerr = c.wasmtime_linker_define_func(
                linker,
                "qview",
                "qview".len,
                op_z.ptr,
                op_z.len,
                qtype,
                qviewCallback,
                @ptrCast(op_z.ptr),
                null,
            );
            if (qerr) |e| {
                try printErrorAndDelete(io, e, "linker_define_func qview");
                std.process.exit(1);
            }
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

    // -------------------------------------------------------------
    // Render-capture: rasterize the qview display list to a PNG (`--png`).
    // This is the headless half of `qube run`; the windowed half blits the
    // same framebuffer to an OS window.
    // -------------------------------------------------------------
    if (png_path) |pp| {
        const cv = render.render(gpa, g_display.items, cv_w, cv_h, cv_bg) catch |e| {
            try err_w.interface.print("q64-wasmtime-host: render failed: {s}\n", .{@errorName(e)});
            try err_w.interface.flush();
            std.process.exit(1);
        };
        defer gpa.free(cv.px);
        const png = render.toPng(gpa, cv) catch |e| {
            try err_w.interface.print("q64-wasmtime-host: png encode failed: {s}\n", .{@errorName(e)});
            try err_w.interface.flush();
            std.process.exit(1);
        };
        defer gpa.free(png);
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = pp, .data = png }) catch |e| {
            try err_w.interface.print("q64-wasmtime-host: cannot write {s}: {s}\n", .{ pp, @errorName(e) });
            try err_w.interface.flush();
            std.process.exit(1);
        };
        try err_w.interface.print("q64-wasmtime-host: rendered {d} ops -> {s} ({d}x{d})\n", .{ g_display.items.len, pp, cv_w, cv_h });
        try err_w.interface.flush();
    }

    // Contact sheet: split the display list into frames at each `present` and
    // tile them — a procedural animation shown as one image (`--contact`).
    if (contact_path) |cp| {
        var frames: std.ArrayListUnmanaged([]const render.Op) = .empty;
        defer frames.deinit(gpa);
        var start: usize = 0;
        for (g_display.items, 0..) |op, i| {
            if (std.mem.eql(u8, op.name, "present")) {
                try frames.append(gpa, g_display.items[start..i]);
                start = i + 1;
            }
        }
        if (start < g_display.items.len) try frames.append(gpa, g_display.items[start..]);
        const cv = render.renderContact(gpa, frames.items, cols, cell_w, cell_h, 8, cv_bg) catch |e| {
            try err_w.interface.print("q64-wasmtime-host: contact render failed: {s}\n", .{@errorName(e)});
            try err_w.interface.flush();
            std.process.exit(1);
        };
        defer gpa.free(cv.px);
        const png = render.toPng(gpa, cv) catch |e| {
            try err_w.interface.print("q64-wasmtime-host: png encode failed: {s}\n", .{@errorName(e)});
            try err_w.interface.flush();
            std.process.exit(1);
        };
        defer gpa.free(png);
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cp, .data = png }) catch |e| {
            try err_w.interface.print("q64-wasmtime-host: cannot write {s}: {s}\n", .{ cp, @errorName(e) });
            try err_w.interface.flush();
            std.process.exit(1);
        };
        try err_w.interface.print("q64-wasmtime-host: {d} frames -> {s} ({d} cols, {d}x{d} cells)\n", .{ frames.items.len, cp, cols, cell_w, cell_h });
        try err_w.interface.flush();
    }
}

// =====================================================================
// env.out host callback
// =====================================================================
//
// Called from C, so we can't accept an `Io` parameter. Reach for the
// process-wide single-threaded Io. Fine for v0 since the host is
// strictly single-threaded; revisit when we add concurrency.

const Timespec = extern struct { sec: i64, nsec: i64 };
extern "c" fn clock_gettime(clk: i32, tp: *Timespec) i32;
extern "c" fn clock_getres(clk: i32, tp: *Timespec) i32;
extern "c" fn nanosleep(req: *const Timespec, rem: ?*Timespec) i32;

fn clockNs(clk: i32, results: [*c]c.wasmtime_val_t) void {
    var ts = Timespec{ .sec = 0, .nsec = 0 };
    _ = clock_gettime(clk, &ts);
    results[0].kind = c.WASMTIME_I64;
    results[0].of.i64 = ts.sec *% 1_000_000_000 +% ts.nsec;
}

fn envMonotonicNsCallback(env_: ?*anyopaque, caller: ?*c.wasmtime_caller_t, args: [*c]const c.wasmtime_val_t, nargs: usize, results: [*c]c.wasmtime_val_t, nresults: usize) callconv(.c) ?*c.wasm_trap_t {
    _ = env_;
    _ = caller;
    _ = args;
    if (nargs != 0 or nresults != 1) return trap("env.monotonic_ns: expected () -> i64");
    clockNs(1, results); // CLOCK_MONOTONIC
    return null;
}

fn envUnixNsCallback(env_: ?*anyopaque, caller: ?*c.wasmtime_caller_t, args: [*c]const c.wasmtime_val_t, nargs: usize, results: [*c]c.wasmtime_val_t, nresults: usize) callconv(.c) ?*c.wasm_trap_t {
    _ = env_;
    _ = caller;
    _ = args;
    if (nargs != 0 or nresults != 1) return trap("env.unix_ns: expected () -> i64");
    clockNs(0, results); // CLOCK_REALTIME
    return null;
}

fn envResolutionNsCallback(env_: ?*anyopaque, caller: ?*c.wasmtime_caller_t, args: [*c]const c.wasmtime_val_t, nargs: usize, results: [*c]c.wasmtime_val_t, nresults: usize) callconv(.c) ?*c.wasm_trap_t {
    _ = env_;
    _ = caller;
    _ = args;
    if (nargs != 0 or nresults != 1) return trap("env.resolution_ns: expected () -> i64");
    var ts = Timespec{ .sec = 0, .nsec = 1 };
    _ = clock_getres(1, &ts);
    results[0].kind = c.WASMTIME_I64;
    results[0].of.i64 = if (ts.sec == 0 and ts.nsec > 0) ts.nsec else 1;
    return null;
}

fn envSleepNsCallback(env_: ?*anyopaque, caller: ?*c.wasmtime_caller_t, args: [*c]const c.wasmtime_val_t, nargs: usize, results: [*c]c.wasmtime_val_t, nresults: usize) callconv(.c) ?*c.wasm_trap_t {
    _ = env_;
    _ = caller;
    _ = results;
    if (nargs != 1 or nresults != 0) return trap("env.sleep_ns: expected (ns) -> ()");
    const ns = args[0].of.i64;
    if (ns > 0) {
        var req = Timespec{ .sec = @divTrunc(ns, 1_000_000_000), .nsec = @mod(ns, 1_000_000_000) };
        var rem = Timespec{ .sec = 0, .nsec = 0 };
        // Retry on EINTR so a signal doesn't shorten the parked wait.
        while (nanosleep(&req, &rem) != 0) req = rem;
    }
    return null;
}

// SplitMix64 state for `env.random_u64`. Seeded once per run: from
// Q64_SEED when set (deterministic, reproducible runs), else from the wall
// clock + ASLR. The local face is NOT crypto-grade — spec/env.md's secure
// randomness is the preview1/component `wasi:random` route, which wasmtime
// itself provides; this face exists for the local `qube run` ABI.
extern "c" fn time(tloc: ?*i64) i64;
var g_rng_state: u64 = 0;
var g_rng_seeded: bool = false;

fn envRandomU64Callback(
    env_: ?*anyopaque,
    caller: ?*c.wasmtime_caller_t,
    args: [*c]const c.wasmtime_val_t,
    nargs: usize,
    results: [*c]c.wasmtime_val_t,
    nresults: usize,
) callconv(.c) ?*c.wasm_trap_t {
    _ = env_;
    _ = caller;
    _ = args;
    if (nargs != 0 or nresults != 1) return trap("env.random_u64: expected () -> i64");
    if (!g_rng_seeded) {
        g_rng_seeded = true;
        if (std.c.getenv("Q64_SEED")) |sv| {
            g_rng_state = std.fmt.parseInt(u64, std.mem.span(sv), 10) catch 0;
        } else {
            g_rng_state = @as(u64, @bitCast(time(null))) ^ (@intFromPtr(&g_rng_seeded) *% 0x9E3779B97F4A7C15);
        }
    }
    g_rng_state +%= 0x9E3779B97F4A7C15;
    var z = g_rng_state;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    z ^= z >> 31;
    results[0].kind = c.WASMTIME_I64;
    results[0].of.i64 = @bitCast(z);
    return null;
}

fn envKvIncrementCallback(
    env_: ?*anyopaque,
    caller: ?*c.wasmtime_caller_t,
    args: [*c]const c.wasmtime_val_t,
    nargs: usize,
    results: [*c]c.wasmtime_val_t,
    nresults: usize,
) callconv(.c) ?*c.wasm_trap_t {
    _ = env_;
    if (nargs != 3 or nresults != 1) return trap("env.kv_increment: expected (key_ptr, key_len, delta) -> i64");
    const key_ptr = argAddr(args[0]);
    const key_len = argAddr(args[1]);
    const delta = args[2].of.i64;
    if (key_ptr < 0 or key_len < 0) return trap("env.kv_increment: negative key ptr/len");

    // Read the str key out of guest memory (len 0 → the empty keyless key).
    var memory_item: c.wasmtime_extern_t = undefined;
    if (!c.wasmtime_caller_export_get(caller, "memory", "memory".len, &memory_item)) {
        return trap("env.kv_increment: module has no `memory` export");
    }
    if (memory_item.kind != c.WASMTIME_EXTERN_MEMORY) {
        return trap("env.kv_increment: `memory` export is not a memory");
    }
    const ctx = c.wasmtime_caller_context(caller);
    const data = c.wasmtime_memory_data(ctx, &memory_item.of.memory);
    const data_size = c.wasmtime_memory_data_size(ctx, &memory_item.of.memory);
    const kp: usize = @intCast(key_ptr);
    const kl: usize = @intCast(key_len);
    if (kp + kl > data_size) return trap("env.kv_increment: key out of bounds");
    const key = data[kp .. kp + kl];

    // Increment the counter at `key`. New keys are duped into g_alloc — the
    // guest-memory slice doesn't outlive the call.
    const gop = g_kv_store.getOrPut(g_alloc, key) catch return trap("env.kv_increment: OOM");
    if (!gop.found_existing) {
        gop.key_ptr.* = g_alloc.dupe(u8, key) catch return trap("env.kv_increment: OOM");
        gop.value_ptr.* = 0;
    }
    gop.value_ptr.* += delta;
    results[0].kind = c.WASMTIME_I64;
    results[0].of.i64 = gop.value_ptr.*;
    return null;
}

/// `env.exit(code)` — terminate the runner with the low byte of `code` as its
/// exit status (the qube's exit code becomes the host's, matching
/// `wasi:cli/exit`). Does not return; instance `defer`s do not run, exactly as
/// `proc_exit` aborts the instance.
fn envExitCallback(
    env_: ?*anyopaque,
    caller: ?*c.wasmtime_caller_t,
    args: [*c]const c.wasmtime_val_t,
    nargs: usize,
    results: [*c]c.wasmtime_val_t,
    nresults: usize,
) callconv(.c) ?*c.wasm_trap_t {
    _ = env_;
    _ = caller;
    _ = results;
    _ = nresults;
    if (nargs != 1) return trap("env.exit: expected (code)");
    const code: u8 = @truncate(@as(u64, @bitCast(args[0].of.i64)));
    std.process.exit(code);
}

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
    return hostByteWrite(caller, args, nargs, false);
}

/// `env.err(ptr, len)` — the stderr twin of `env.out` (`wasi:cli/stderr`).
fn envErrCallback(
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
    return hostByteWrite(caller, args, nargs, true);
}

/// Shared body of `env.out` / `env.err`: read `(ptr, len)` from guest memory and
/// write the bytes verbatim to stdout (`to_stderr == false`) or stderr. ptr/len
/// are i32 (wasm32) or i64 (wasm64), read by runtime kind so one host binary
/// serves either address space.
fn hostByteWrite(caller: ?*c.wasmtime_caller_t, args: [*c]const c.wasmtime_val_t, nargs: usize, to_stderr: bool) ?*c.wasm_trap_t {
    if (nargs != 2) return trap(if (to_stderr) "env.err: expected (ptr, len)" else "env.out: expected (ptr, len)");

    const ptr_i64 = argAddr(args[0]);
    const len_i64 = argAddr(args[1]);
    if (ptr_i64 < 0 or len_i64 < 0) return trap(if (to_stderr) "env.err: negative ptr/len" else "env.out: negative ptr/len");

    var memory_item: c.wasmtime_extern_t = undefined;
    if (!c.wasmtime_caller_export_get(caller, "memory", "memory".len, &memory_item)) {
        return trap(if (to_stderr) "env.err: module has no `memory` export" else "env.out: module has no `memory` export");
    }
    if (memory_item.kind != c.WASMTIME_EXTERN_MEMORY) {
        return trap(if (to_stderr) "env.err: `memory` export is not a memory" else "env.out: `memory` export is not a memory");
    }

    const ctx = c.wasmtime_caller_context(caller);
    const data = c.wasmtime_memory_data(ctx, &memory_item.of.memory);
    const data_size = c.wasmtime_memory_data_size(ctx, &memory_item.of.memory);

    const ptr: usize = @intCast(ptr_i64);
    const len: usize = @intCast(len_i64);
    if (ptr + len > data_size) return trap(if (to_stderr) "env.err: out-of-bounds write" else "env.out: out-of-bounds write");

    const slice = data[ptr .. ptr + len];
    const io = std.Io.Threaded.global_single_threaded.io();
    var buf: [4096]u8 = undefined;
    var w = if (to_stderr) std.Io.File.stderr().writer(io, &buf) else std.Io.File.stdout().writer(io, &buf);
    w.interface.writeAll(slice) catch return trap(if (to_stderr) "env.err: stderr write failed" else "env.out: stdout write failed");
    w.interface.flush() catch return trap(if (to_stderr) "env.err: stderr flush failed" else "env.out: stdout flush failed");
    return null;
}

// =====================================================================
// env.fs_read host callback (spec/env.md §"Wire ABI: fs.read")
// =====================================================================
//
// (dest, path_ptr, path_len) -> i64: read the file named by the guest
// path, grow the guest memory if the contents don't fit, write them at
// `dest`, return the byte length. Negative = failure (the guest traps):
// -1 unopenable, -2 doesn't fit in growable memory.

fn envFsReadCallback(
    env_: ?*anyopaque,
    caller: ?*c.wasmtime_caller_t,
    args: [*c]const c.wasmtime_val_t,
    nargs: usize,
    results: [*c]c.wasmtime_val_t,
    nresults: usize,
) callconv(.c) ?*c.wasm_trap_t {
    _ = env_;
    if (nargs != 3 or nresults != 1) return trap("env.fs_read: expected (dest, ptr, len) -> i64");

    const dest_i64 = argAddr(args[0]);
    const path_ptr_i64 = argAddr(args[1]);
    const path_len_i64 = argAddr(args[2]);
    if (dest_i64 < 0 or path_ptr_i64 < 0 or path_len_i64 < 0) return trap("env.fs_read: negative ptr/len");

    var memory_item: c.wasmtime_extern_t = undefined;
    if (!c.wasmtime_caller_export_get(caller, "memory", "memory".len, &memory_item)) {
        return trap("env.fs_read: module has no `memory` export");
    }
    if (memory_item.kind != c.WASMTIME_EXTERN_MEMORY) {
        return trap("env.fs_read: `memory` export is not a memory");
    }
    const ctx = c.wasmtime_caller_context(caller);

    const fail = struct {
        fn ret(res: [*c]c.wasmtime_val_t, code: i64) ?*c.wasm_trap_t {
            res[0].kind = c.WASMTIME_I64;
            res[0].of.i64 = code;
            return null;
        }
    };

    // Read the path out of guest memory.
    var data = c.wasmtime_memory_data(ctx, &memory_item.of.memory);
    var data_size = c.wasmtime_memory_data_size(ctx, &memory_item.of.memory);
    const ppath: usize = @intCast(path_ptr_i64);
    const plen: usize = @intCast(path_len_i64);
    if (ppath + plen > data_size) return trap("env.fs_read: path out of bounds");
    var path_buf: [4096]u8 = undefined;
    if (plen > path_buf.len) return fail.ret(results, -1);
    @memcpy(path_buf[0..plen], data[ppath .. ppath + plen]);
    const path = path_buf[0..plen];

    const io = std.Io.Threaded.global_single_threaded.io();
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return fail.ret(results, -1);
    defer file.close(io);
    const size: usize = @intCast(file.length(io) catch return fail.ret(results, -1));

    // Grow the guest memory if the contents don't fit past `dest`.
    const dest: usize = @intCast(dest_i64);
    if (dest + size > data_size) {
        const page = 65536;
        const needed_pages: u64 = @intCast((dest + size - data_size + page - 1) / page);
        var prev: u64 = 0;
        const gerr = c.wasmtime_memory_grow(ctx, &memory_item.of.memory, needed_pages, &prev);
        if (gerr != null) return fail.ret(results, -2);
        data = c.wasmtime_memory_data(ctx, &memory_item.of.memory);
        data_size = c.wasmtime_memory_data_size(ctx, &memory_item.of.memory);
        if (dest + size > data_size) return fail.ret(results, -2);
    }

    var reader = file.reader(io, data[dest .. dest + size]);
    reader.interface.readSliceAll(data[dest .. dest + size]) catch return fail.ret(results, -1);

    results[0].kind = c.WASMTIME_I64;
    results[0].of.i64 = @intCast(size);
    return null;
}

/// `env.args(dest) -> i64` — materialize `g_args` as a `[str]` at `dest`:
/// `[count][cells…][bytes…]`, where each cell is `(guest_ptr, len)` at the
/// module's address width and `guest_ptr` is the absolute guest address of that
/// arg's bytes. Grows guest memory if needed; returns the total bytes written.
fn envArgsCallback(
    env_: ?*anyopaque,
    caller: ?*c.wasmtime_caller_t,
    args: [*c]const c.wasmtime_val_t,
    nargs: usize,
    results: [*c]c.wasmtime_val_t,
    nresults: usize,
) callconv(.c) ?*c.wasm_trap_t {
    _ = env_;
    if (nargs != 1 or nresults != 1) return trap("env.args: expected (dest) -> i64");
    const dest_i64 = argAddr(args[0]);
    if (dest_i64 < 0) return trap("env.args: negative dest");

    var memory_item: c.wasmtime_extern_t = undefined;
    if (!c.wasmtime_caller_export_get(caller, "memory", "memory".len, &memory_item)) {
        return trap("env.args: module has no `memory` export");
    }
    if (memory_item.kind != c.WASMTIME_EXTERN_MEMORY) {
        return trap("env.args: `memory` export is not a memory");
    }
    const ctx = c.wasmtime_caller_context(caller);

    const w = g_ptr_width;
    const count = g_args.items.len;
    var bytes_total: usize = 0;
    for (g_args.items) |a| bytes_total += a.len;
    const total = w + count * 2 * w + bytes_total;

    const dest: usize = @intCast(dest_i64);
    var data = c.wasmtime_memory_data(ctx, &memory_item.of.memory);
    var data_size = c.wasmtime_memory_data_size(ctx, &memory_item.of.memory);
    if (dest + total > data_size) {
        const page = 65536;
        const needed_pages: u64 = @intCast((dest + total - data_size + page - 1) / page);
        var prev: u64 = 0;
        if (c.wasmtime_memory_grow(ctx, &memory_item.of.memory, needed_pages, &prev) != null) return trap("env.args: out of memory");
        data = c.wasmtime_memory_data(ctx, &memory_item.of.memory);
        data_size = c.wasmtime_memory_data_size(ctx, &memory_item.of.memory);
        if (dest + total > data_size) return trap("env.args: out of memory");
    }

    // Write an address-width little-endian value at `data[off]`.
    const putW = struct {
        fn f(d: [*c]u8, off: usize, width: usize, v: usize) void {
            var i: usize = 0;
            while (i < width) : (i += 1) d[off + i] = @truncate(v >> @intCast(i * 8));
        }
    }.f;

    putW(data, dest, w, count); // count header
    const cells_base = dest + w;
    const bytes_base = dest + w + count * 2 * w;
    var byte_off: usize = 0;
    for (g_args.items, 0..) |a, i| {
        const guest_ptr = bytes_base + byte_off;
        putW(data, cells_base + i * 2 * w, w, guest_ptr); // cell[i].ptr
        putW(data, cells_base + i * 2 * w + w, w, a.len); // cell[i].len
        if (a.len > 0) @memcpy(data[guest_ptr .. guest_ptr + a.len], a);
        byte_off += a.len;
    }

    results[0].kind = c.WASMTIME_I64;
    results[0].of.i64 = @intCast(total);
    return null;
}

/// `env.envvar(dest, key_ptr, key_len) -> i64` — write the value of the env var
/// named by the guest key at `dest` and return its byte length (0 if unset).
/// Grows guest memory if needed.
fn envEnvvarCallback(
    env_: ?*anyopaque,
    caller: ?*c.wasmtime_caller_t,
    args: [*c]const c.wasmtime_val_t,
    nargs: usize,
    results: [*c]c.wasmtime_val_t,
    nresults: usize,
) callconv(.c) ?*c.wasm_trap_t {
    _ = env_;
    if (nargs != 3 or nresults != 1) return trap("env.envvar: expected (dest, key_ptr, key_len) -> i64");
    const dest_i64 = argAddr(args[0]);
    const key_ptr_i64 = argAddr(args[1]);
    const key_len_i64 = argAddr(args[2]);
    if (dest_i64 < 0 or key_ptr_i64 < 0 or key_len_i64 < 0) return trap("env.envvar: negative ptr/len");

    var memory_item: c.wasmtime_extern_t = undefined;
    if (!c.wasmtime_caller_export_get(caller, "memory", "memory".len, &memory_item)) {
        return trap("env.envvar: module has no `memory` export");
    }
    if (memory_item.kind != c.WASMTIME_EXTERN_MEMORY) {
        return trap("env.envvar: `memory` export is not a memory");
    }
    const ctx = c.wasmtime_caller_context(caller);

    const ret0 = struct {
        fn f(res: [*c]c.wasmtime_val_t, v: i64) ?*c.wasm_trap_t {
            res[0].kind = c.WASMTIME_I64;
            res[0].of.i64 = v;
            return null;
        }
    }.f;

    var data = c.wasmtime_memory_data(ctx, &memory_item.of.memory);
    var data_size = c.wasmtime_memory_data_size(ctx, &memory_item.of.memory);
    const kptr: usize = @intCast(key_ptr_i64);
    const klen: usize = @intCast(key_len_i64);
    if (kptr + klen > data_size) return trap("env.envvar: key out of bounds");
    var key_buf: [4096]u8 = undefined;
    if (klen + 1 > key_buf.len) return ret0(results, 0); // implausibly long key → unset
    @memcpy(key_buf[0..klen], data[kptr .. kptr + klen]);
    key_buf[klen] = 0; // NUL-terminate for libc getenv
    const val_c = std.c.getenv(@ptrCast(&key_buf)) orelse return ret0(results, 0);
    const val = std.mem.span(val_c);

    const dest: usize = @intCast(dest_i64);
    const size = val.len;
    if (dest + size > data_size) {
        const page = 65536;
        const needed_pages: u64 = @intCast((dest + size - data_size + page - 1) / page);
        var prev: u64 = 0;
        if (c.wasmtime_memory_grow(ctx, &memory_item.of.memory, needed_pages, &prev) != null) return trap("env.envvar: out of memory");
        data = c.wasmtime_memory_data(ctx, &memory_item.of.memory);
        data_size = c.wasmtime_memory_data_size(ctx, &memory_item.of.memory);
        if (dest + size > data_size) return trap("env.envvar: out of memory");
    }
    if (size > 0) @memcpy(data[dest .. dest + size], val);
    return ret0(results, @intCast(size));
}

/// `qview.*` callback: records the op into the global display list (for
/// PNG/window rendering) and prints a best-effort trace line `@qview <op>
/// <args…>`. The op name rides in `env_` (the import's data pointer); args are
/// read width-agnostically. The display list is what `qube run` draws.
fn qviewCallback(
    env_: ?*anyopaque,
    caller: ?*c.wasmtime_caller_t,
    args: [*c]const c.wasmtime_val_t,
    nargs: usize,
    results: [*c]c.wasmtime_val_t,
    nresults: usize,
) callconv(.c) ?*c.wasm_trap_t {
    _ = caller;
    _ = results;
    _ = nresults;
    const op = std.mem.span(@as([*:0]const u8, @ptrCast(env_.?)));
    // Record (for rendering).
    const argv = g_alloc.alloc(i64, nargs) catch return trap("qview: oom");
    var i: usize = 0;
    while (i < nargs) : (i += 1) argv[i] = argAddr(args[i]);
    g_display.append(g_alloc, .{ .name = op, .args = argv }) catch return trap("qview: oom");
    // Best-effort trace (a closed pipe must not abort the run).
    const io = std.Io.Threaded.global_single_threaded.io();
    var buf: [256]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    w.interface.print("@qview {s}", .{op}) catch return null;
    var j: usize = 0;
    while (j < nargs) : (j += 1) w.interface.print(" {d}", .{argv[j]}) catch return null;
    w.interface.print("\n", .{}) catch return null;
    w.interface.flush() catch {};
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
/// Detect the module's address width (wasm32 → i32, wasm64 → i64) from the
/// first parameter of any `env.*` face that takes an address-width argument —
/// `out`/`err` (ptr,len), `fs_read`/`args`/`envvar` (dest,…). Checking several
/// faces (not just `env.out`) means a module that imports only `env.err` (a
/// bare `panic`) or only `env.args` still detects the width correctly.
fn moduleAddrIsI32(module: ?*c.wasmtime_module_t) bool {
    var imports: c.wasm_importtype_vec_t = undefined;
    c.wasmtime_module_imports(module, &imports);
    defer c.wasm_importtype_vec_delete(&imports);
    var i: usize = 0;
    while (i < imports.size) : (i += 1) {
        const imp = imports.data[i] orelse continue;
        if (!nameEql(c.wasm_importtype_module(imp), "env")) continue;
        const nm = c.wasm_importtype_name(imp);
        const addr_face = nameEql(nm, "out") or nameEql(nm, "err") or
            nameEql(nm, "fs_read") or nameEql(nm, "args") or nameEql(nm, "envvar");
        if (!addr_face) continue;
        const ft = c.wasm_externtype_as_functype(@constCast(c.wasm_importtype_type(imp))) orelse continue;
        const ps = c.wasm_functype_params(ft);
        if (ps.*.size >= 1) return c.wasm_valtype_kind(ps.*.data[0]) == c.WASM_I32;
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
