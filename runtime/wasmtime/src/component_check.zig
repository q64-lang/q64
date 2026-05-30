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
    @cInclude("wasmtime.h");
    @cInclude("wasmtime/component/component.h");
    @cInclude("wasmtime/component/instance.h");
    @cInclude("wasmtime/component/func.h");
    @cInclude("wasmtime/component/linker.h");
    @cInclude("wasmtime/component/val.h");
});

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

    // Optional call check: <fn> <a> <b> <expected> (two s64 args, one s64 result).
    const call_fn = it.next();
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

    if (call_fn == null) {
        var w = std.Io.File.stdout().writer(io, &.{});
        try w.interface.print("ok: {s} is a valid component\n", .{path});
        try w.interface.flush();
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
