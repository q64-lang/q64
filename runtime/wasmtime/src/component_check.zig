//! q64-component-check — validates a WebAssembly **component** binary with
//! wasmtime's component-model compiler (`wasmtime_component_new`), and
//! optionally instantiates it and calls a nullary-or-scalar export to confirm
//! it is callable. Used by the q64 build pipeline's tests to prove that
//! `q64 build --component` emits a component wasmtime accepts.
//!
//! Usage:
//!   q64-component-check <file.component.wasm>              # validate only
//!   q64-component-check <file.component.wasm> add 2 3 5    # call add(2,3), expect 5
//!
//! Exits 0 on success; non-zero (with a diagnostic on stderr) otherwise.

const std = @import("std");

const c = @cImport({
    @cInclude("wasm.h");
    @cInclude("wasi.h");
    @cInclude("wasmtime.h");
    @cInclude("wasmtime/component/component.h");
    @cInclude("wasmtime/component/instance.h");
    @cInclude("wasmtime/component/func.h");
    @cInclude("wasmtime/component/linker.h");
    @cInclude("wasmtime/component/val.h");
});

/// The WASI interface-version suffix the vendored adapter (`vendor/wasi/`)
/// produces — see `vendor/wasi/` and `wasm-tools component wit`. The `run`
/// export lives in the instance `wasi:cli/run@<this>`.
const wasi_version = "0.2.6";

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var err_buf: [4096]u8 = undefined;
    var err_w = std.Io.File.stderr().writer(io, &err_buf);

    var it = init.minimal.args.iterate();
    _ = it.next(); // argv0
    const path = it.next() orelse {
        try err_w.interface.writeAll("usage: q64-component-check <file.component.wasm> [<fn> <a> <b> <expected>]\n");
        try err_w.interface.flush();
        std.process.exit(2);
    };

    // `--run`: instantiate a WASI command component, wire WASI with stdout
    // captured, call its `wasi:cli/run` export, and print what it wrote to
    // stdout (the program's env.out output, now via `fd_write` → the adapter).
    const second = it.next();
    const run_mode = second != null and std.mem.eql(u8, second.?, "--run");

    // Optional call check: <fn> <a> <b> <expected> (two s64 args, one s64 result).
    const call_fn = if (run_mode) null else second;
    const call_a = it.next();
    const call_b = it.next();
    const call_expected = it.next();

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024 * 1024)) catch |e| {
        try err_w.interface.print("q64-component-check: cannot read {s}: {s}\n", .{ path, @errorName(e) });
        try err_w.interface.flush();
        std.process.exit(2);
    };
    defer gpa.free(bytes);

    const config = c.wasm_config_new() orelse return error.ConfigNewFailed;
    c.wasmtime_config_wasm_component_model_set(config, true);
    c.wasmtime_config_wasm_memory64_set(config, true);
    const engine = c.wasm_engine_new_with_config(config) orelse return error.EngineNewFailed;
    defer c.wasm_engine_delete(engine);

    // The validation step: compile the component. A malformed component (bad
    // section, bad canon lift, type mismatch) fails here with a precise message.
    var component: ?*c.wasmtime_component_t = null;
    if (c.wasmtime_component_new(engine, bytes.ptr, bytes.len, &component)) |e| {
        try printErr(io, e, "component_new (validation)");
        std.process.exit(1);
    }
    defer c.wasmtime_component_delete(component);

    if (!run_mode and call_fn == null) {
        var w = std.Io.File.stdout().writer(io, &.{});
        try w.interface.print("ok: {s} is a valid component\n", .{path});
        try w.interface.flush();
        return;
    }

    if (run_mode) {
        try runApp(io, engine, component);
        return;
    }

    // Optional: instantiate and call <fn>(a, b) -> expected (all s64).
    const store = c.wasmtime_store_new(engine, null, null) orelse return error.StoreNewFailed;
    defer c.wasmtime_store_delete(store);
    const ctx = c.wasmtime_store_context(store);

    const linker = c.wasmtime_component_linker_new(engine) orelse return error.LinkerNewFailed;
    defer c.wasmtime_component_linker_delete(linker);

    var instance: c.wasmtime_component_instance_t = undefined;
    if (c.wasmtime_component_linker_instantiate(linker, ctx, component, &instance)) |e| {
        try printErr(io, e, "instantiate");
        std.process.exit(1);
    }

    const idx = c.wasmtime_component_instance_get_export_index(&instance, ctx, null, call_fn.?.ptr, call_fn.?.len) orelse {
        try err_w.interface.print("q64-component-check: export '{s}' not found\n", .{call_fn.?});
        try err_w.interface.flush();
        std.process.exit(1);
    };
    defer c.wasmtime_component_export_index_delete(idx);
    var func_export: c.wasmtime_component_func_t = undefined;
    if (!c.wasmtime_component_instance_get_func(&instance, ctx, idx, &func_export)) {
        try err_w.interface.print("q64-component-check: export '{s}' is not a func\n", .{call_fn.?});
        try err_w.interface.flush();
        std.process.exit(1);
    }

    const a_val = std.fmt.parseInt(i64, call_a.?, 10) catch 0;
    const b_val = std.fmt.parseInt(i64, call_b.?, 10) catch 0;
    const expected = std.fmt.parseInt(i64, call_expected.?, 10) catch 0;

    var args = [_]c.wasmtime_component_val_t{
        .{ .kind = c.WASMTIME_COMPONENT_S64, .of = .{ .s64 = a_val } },
        .{ .kind = c.WASMTIME_COMPONENT_S64, .of = .{ .s64 = b_val } },
    };
    var result: c.wasmtime_component_val_t = .{ .kind = c.WASMTIME_COMPONENT_S64, .of = .{ .s64 = 0 } };
    if (c.wasmtime_component_func_call(&func_export, ctx, &args, args.len, &result, 1)) |e| {
        try printErr(io, e, "func_call");
        std.process.exit(1);
    }

    if (result.of.s64 != expected) {
        try err_w.interface.print("q64-component-check: {s}({d},{d}) = {d}, expected {d}\n", .{ call_fn.?, a_val, b_val, result.of.s64, expected });
        try err_w.interface.flush();
        std.process.exit(1);
    }

    var w = std.Io.File.stdout().writer(io, &.{});
    try w.interface.print("ok: {s}({d},{d}) = {d}\n", .{ call_fn.?, a_val, b_val, result.of.s64 });
    try w.interface.flush();
}

/// Captures the bytes the component writes to stdout — i.e. the program's
/// `env.out` output, now flowing through `fd_write` → the WASI adapter →
/// `wasi:cli/stdout`, which we direct here via `wasi_config_set_stdout_custom`.
const Capture = struct { buf: [64 * 1024]u8 = undefined, len: usize = 0 };

/// WASI stdout sink: append the written bytes and report them all consumed.
fn stdoutCallback(env: ?*anyopaque, buf: [*c]const u8, len: usize) callconv(.c) isize {
    const cap: *Capture = @ptrCast(@alignCast(env.?));
    const n = @min(len, cap.buf.len - cap.len);
    if (n > 0) @memcpy(cap.buf[cap.len..][0..n], buf[0..n]);
    cap.len += n;
    return @intCast(len);
}

/// Instantiate a WASI command component: configure WASI with stdout captured,
/// add the WASI host implementation to the linker, call the lifted
/// `wasi:cli/run`, and write the captured stdout out. Proves the preview1 core
/// + WASI adapter run end-to-end, not just validate.
fn runApp(io: std.Io, engine: ?*c.wasm_engine_t, component: ?*c.wasmtime_component_t) !void {
    const store = c.wasmtime_store_new(engine, null, null) orelse return error.StoreNewFailed;
    defer c.wasmtime_store_delete(store);
    const ctx = c.wasmtime_store_context(store);

    // WASI context: capture stdout into `cap`; everything else is empty/denied.
    var cap = Capture{};
    const wasi_config = c.wasi_config_new() orelse return error.WasiConfigNewFailed;
    c.wasi_config_set_stdout_custom(wasi_config, stdoutCallback, &cap, null);
    if (c.wasmtime_context_set_wasi(ctx, wasi_config)) |e| {
        try printErr(io, e, "context_set_wasi");
        std.process.exit(1);
    }

    const linker = c.wasmtime_component_linker_new(engine) orelse return error.LinkerNewFailed;
    defer c.wasmtime_component_linker_delete(linker);

    // Provide the WASI interfaces the adapter imports (wasi:cli/stdout, …).
    if (c.wasmtime_component_linker_add_wasip2(linker)) |e| {
        try printErr(io, e, "add_wasip2");
        std.process.exit(1);
    }

    var instance: c.wasmtime_component_instance_t = undefined;
    if (c.wasmtime_component_linker_instantiate(linker, ctx, component, &instance)) |e| {
        try printErr(io, e, "instantiate");
        std.process.exit(1);
    }

    // The command's entry is `run` inside the `wasi:cli/run@<ver>` instance:
    // resolve the instance export, then the `run` func within it.
    const run_iface = "wasi:cli/run@" ++ wasi_version;
    const iface_idx = c.wasmtime_component_instance_get_export_index(&instance, ctx, null, run_iface.ptr, run_iface.len) orelse {
        var buf: [256]u8 = undefined;
        var w = std.Io.File.stderr().writer(io, &buf);
        try w.interface.print("q64-component-check: instance '{s}' not found\n", .{run_iface});
        try w.interface.flush();
        std.process.exit(1);
    };
    defer c.wasmtime_component_export_index_delete(iface_idx);
    const idx = c.wasmtime_component_instance_get_export_index(&instance, ctx, iface_idx, "run", "run".len) orelse {
        var buf: [256]u8 = undefined;
        var w = std.Io.File.stderr().writer(io, &buf);
        try w.interface.writeAll("q64-component-check: export 'run' not found\n");
        try w.interface.flush();
        std.process.exit(1);
    };
    defer c.wasmtime_component_export_index_delete(idx);
    var func: c.wasmtime_component_func_t = undefined;
    if (!c.wasmtime_component_instance_get_func(&instance, ctx, idx, &func)) {
        std.process.exit(1);
    }

    // `run: func() -> result` — one result value; a trap or an `err` return
    // surfaces as a call error.
    var run_result: c.wasmtime_component_val_t = .{ .kind = c.WASMTIME_COMPONENT_BOOL, .of = .{ .boolean = false } };
    if (c.wasmtime_component_func_call(&func, ctx, null, 0, &run_result, 1)) |e| {
        try printErr(io, e, "call run");
        std.process.exit(1);
    }

    var w = std.Io.File.stdout().writer(io, &.{});
    try w.interface.writeAll(cap.buf[0..cap.len]);
    try w.interface.flush();
}

fn printErr(io: std.Io, err: *c.wasmtime_error_t, ctx_label: []const u8) !void {
    var msg: c.wasm_byte_vec_t = undefined;
    c.wasmtime_error_message(err, &msg);
    defer c.wasm_byte_vec_delete(&msg);
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    try w.interface.print("q64-component-check: {s}: {s}\n", .{ ctx_label, msg.data[0..msg.size] });
    try w.interface.flush();
    c.wasmtime_error_delete(err);
}
