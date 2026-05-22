//! q64/src/codegen — AST → Wasm 3.0 via Binaryen.
//!
//! v0 surface: a single entry point `emitHelloWasm` that builds the
//! hand-equivalent of `runtime/wasmtime/hello.wat` directly via the
//! Binaryen C API. This proves the Binaryen integration and gives
//! us a byte-level shape codegen will later produce from a typed AST.
//!
//! Module shape produced:
//!
//!   (module
//!     (import "env" "out" (func (param i32 i32)))
//!     (memory (export "memory") 1)
//!     (data (i32.const 0) "Hello, q64.\n")
//!     (func (export "_start")
//!       i32.const 0
//!       i32.const 12
//!       call $env_out))
//!
//! The result instantiates against `runtime/wasmtime/q64-wasmtime-host`
//! and prints `Hello, q64.\n` to stdout, matching the hand-written
//! hello.wat byte-for-byte in behavior (the exact byte stream may
//! differ in section ordering / type-index layout — Binaryen and
//! wabt make different but equally valid choices).

const std = @import("std");
const parser = @import("parser");
const parse = parser.parse;
const ast = parser.ast;

const c = @cImport({
    @cInclude("binaryen-c.h");
});

pub const Error = error{
    ModuleCreate,
    ModuleInvalid,
    SerializeEmpty,
    NoMainFunction,
    NoBody,
    UnsupportedStatement,
    UnsupportedExpression,
    UnsupportedCall,
    BadStringLiteral,
    OutOfMemory,
};

/// Build the hello-world wasm module and return its bytes. Caller
/// owns the returned slice and must free it via `allocator`.
pub fn emitHelloWasm(allocator: std.mem.Allocator) ![]u8 {
    const module = c.BinaryenModuleCreate() orelse return error.ModuleCreate;
    defer c.BinaryenModuleDispose(module);

    const i32_type = c.BinaryenTypeInt32();
    const none_type = c.BinaryenTypeNone();

    // env.out :: (i32, i32) -> () — imported from "env"."out".
    var env_out_params = [_]c.BinaryenType{ i32_type, i32_type };
    const env_out_params_type = c.BinaryenTypeCreate(&env_out_params, env_out_params.len);
    c.BinaryenAddFunctionImport(
        module,
        "env_out", // internal name
        "env", // external module
        "out", // external field
        env_out_params_type,
        none_type,
    );

    // Memory: 1 page, exported as "memory", with one active data
    // segment at offset 0 holding "Hello, q64.\n".
    const payload = "Hello, q64.\n";
    var seg_datas = [_][*c]const u8{payload.ptr};
    var seg_passives = [_]bool{false};
    var seg_offsets = [_]c.BinaryenExpressionRef{
        c.BinaryenConst(module, c.BinaryenLiteralInt32(0)),
    };
    var seg_sizes = [_]c.BinaryenIndex{@intCast(payload.len)};

    c.BinaryenSetMemory(
        module,
        1, // initial pages
        1, // maximum pages
        "memory", // export name
        null, // segmentNames — Binaryen auto-generates from indices
        @ptrCast(&seg_datas),
        @ptrCast(&seg_passives),
        @ptrCast(&seg_offsets),
        @ptrCast(&seg_sizes),
        seg_sizes.len,
        false, // shared
        false, // memory64
        "0", // internal memory name
    );

    // _start body: call env.out(0, payload.len).
    const ptr_arg = c.BinaryenConst(module, c.BinaryenLiteralInt32(0));
    const len_arg = c.BinaryenConst(module, c.BinaryenLiteralInt32(@intCast(payload.len)));
    var call_args = [_]c.BinaryenExpressionRef{ ptr_arg, len_arg };
    const body = c.BinaryenCall(
        module,
        "env_out",
        @ptrCast(&call_args),
        call_args.len,
        none_type,
    );

    _ = c.BinaryenAddFunction(
        module,
        "start", // internal name
        none_type, // params
        none_type, // results
        null, // varTypes
        0,
        body,
    );

    _ = c.BinaryenAddFunctionExport(module, "start", "_start");

    if (!c.BinaryenModuleValidate(module)) {
        return error.ModuleInvalid;
    }

    const result = c.BinaryenModuleAllocateAndWrite(module, null);
    defer if (result.binary) |b| std.c.free(b);
    defer if (result.sourceMap) |s| std.c.free(s);

    const binary_ptr = result.binary orelse return error.SerializeEmpty;
    if (result.binaryBytes == 0) return error.SerializeEmpty;

    const src: [*]const u8 = @ptrCast(binary_ptr);
    const out = try allocator.alloc(u8, result.binaryBytes);
    @memcpy(out, src[0..result.binaryBytes]);
    return out;
}

// =====================================================================
// AST-driven emission
// =====================================================================
//
// `emitFromSource` parses a source string, finds `fn main`, walks
// its body, and emits a wasm module. v0 only supports bodies that
// are a sequence of `env.out("…")` calls — any other expression
// shape returns `Error.UnsupportedExpression`. Newline-appending
// follows spec/env.md §"Capability faces": each `env.out("X")` lands
// in the data segment as `"X\n"`.

pub fn emitFromSource(
    allocator: std.mem.Allocator,
    source: []const u8,
    file: []const u8,
) ![]u8 {
    const parse_result = try parse.parse(allocator, source, file);
    defer parse_result.deinit(allocator);

    const sf = ast.SourceFile.cast(parse_result.root) orelse return Error.NoMainFunction;

    var iter = sf.items();
    const main_fn = blk: while (iter.next()) |item| switch (item) {
        .fn_decl => |fd| {
            const name = fd.name() orelse continue;
            if (std.mem.eql(u8, name.text, "main")) break :blk fd;
        },
    } else return Error.NoMainFunction;

    return emitFn(allocator, main_fn);
}

fn emitFn(allocator: std.mem.Allocator, fd: ast.FnDecl) ![]u8 {
    const body = fd.body() orelse return Error.NoBody;

    // Collect each env.out call's payload bytes ("text" + "\n").
    var payloads: std.ArrayList([]u8) = .empty;
    defer {
        for (payloads.items) |p| allocator.free(p);
        payloads.deinit(allocator);
    }

    var stmts = body.statements();
    while (stmts.next()) |stmt| switch (stmt) {
        .expr_stmt => |es| {
            const expr = es.expression() orelse return Error.UnsupportedStatement;
            const call = switch (expr) {
                .call => |cc| cc,
                else => return Error.UnsupportedExpression,
            };
            try collectEnvOutPayload(allocator, call, &payloads);
        },
    };

    return emitModuleWithPayloads(allocator, payloads.items);
}

fn collectEnvOutPayload(
    allocator: std.mem.Allocator,
    call: ast.CallExpr,
    out_payloads: *std.ArrayList([]u8),
) !void {
    const callee_expr = call.callee() orelse return Error.UnsupportedCall;
    const path = switch (callee_expr) {
        .path => |p| p,
        else => return Error.UnsupportedCall,
    };
    const path_text = try path.text(allocator);
    defer allocator.free(path_text);
    if (!std.mem.eql(u8, path_text, "env.out")) return Error.UnsupportedCall;

    var arg_iter = call.args();
    const first = arg_iter.next() orelse return Error.UnsupportedCall;
    const str_lit = switch (first) {
        .string_lit => |s| s,
        else => return Error.UnsupportedCall,
    };
    const value = (try str_lit.value(allocator)) orelse return Error.BadStringLiteral;
    defer allocator.free(value);

    // env.out("X") semantically writes "X\n" (spec/env.md §"Capability faces").
    var payload = try allocator.alloc(u8, value.len + 1);
    @memcpy(payload[0..value.len], value);
    payload[value.len] = '\n';
    try out_payloads.append(allocator, payload);
}

fn emitModuleWithPayloads(allocator: std.mem.Allocator, payloads: []const []u8) ![]u8 {
    var total: usize = 0;
    for (payloads) |p| total += p.len;

    const data = try allocator.alloc(u8, total);
    defer allocator.free(data);

    const offsets = try allocator.alloc(usize, payloads.len);
    defer allocator.free(offsets);

    {
        var off: usize = 0;
        for (payloads, 0..) |p, i| {
            @memcpy(data[off .. off + p.len], p);
            offsets[i] = off;
            off += p.len;
        }
    }

    const module = c.BinaryenModuleCreate() orelse return Error.ModuleCreate;
    defer c.BinaryenModuleDispose(module);

    const i32_type = c.BinaryenTypeInt32();
    const none_type = c.BinaryenTypeNone();

    var env_out_params = [_]c.BinaryenType{ i32_type, i32_type };
    const env_out_params_type = c.BinaryenTypeCreate(&env_out_params, env_out_params.len);
    c.BinaryenAddFunctionImport(
        module,
        "env_out",
        "env",
        "out",
        env_out_params_type,
        none_type,
    );

    if (payloads.len == 0) {
        c.BinaryenSetMemory(module, 1, 1, "memory", null, null, null, null, null, 0, false, false, "0");
    } else {
        var seg_datas = [_][*c]const u8{data.ptr};
        var seg_passives = [_]bool{false};
        var seg_offsets = [_]c.BinaryenExpressionRef{
            c.BinaryenConst(module, c.BinaryenLiteralInt32(0)),
        };
        var seg_sizes = [_]c.BinaryenIndex{@intCast(data.len)};
        c.BinaryenSetMemory(
            module,
            1,
            1,
            "memory",
            null,
            @ptrCast(&seg_datas),
            @ptrCast(&seg_passives),
            @ptrCast(&seg_offsets),
            @ptrCast(&seg_sizes),
            seg_sizes.len,
            false,
            false,
            "0",
        );
    }

    // Body: a sequence of `call $env_out(offset, len)`.
    var call_exprs: std.ArrayList(c.BinaryenExpressionRef) = try .initCapacity(allocator, payloads.len);
    defer call_exprs.deinit(allocator);
    for (payloads, 0..) |p, i| {
        const ptr_arg = c.BinaryenConst(module, c.BinaryenLiteralInt32(@intCast(offsets[i])));
        const len_arg = c.BinaryenConst(module, c.BinaryenLiteralInt32(@intCast(p.len)));
        var cargs = [_]c.BinaryenExpressionRef{ ptr_arg, len_arg };
        const call = c.BinaryenCall(
            module,
            "env_out",
            @ptrCast(&cargs),
            cargs.len,
            none_type,
        );
        try call_exprs.append(allocator, call);
    }

    const body_expr: c.BinaryenExpressionRef = if (call_exprs.items.len == 1)
        call_exprs.items[0]
    else
        c.BinaryenBlock(
            module,
            null,
            @ptrCast(call_exprs.items.ptr),
            @intCast(call_exprs.items.len),
            none_type,
        );

    _ = c.BinaryenAddFunction(module, "start", none_type, none_type, null, 0, body_expr);
    _ = c.BinaryenAddFunctionExport(module, "start", "_start");

    if (!c.BinaryenModuleValidate(module)) return Error.ModuleInvalid;

    const result = c.BinaryenModuleAllocateAndWrite(module, null);
    defer if (result.binary) |b| std.c.free(b);
    defer if (result.sourceMap) |s| std.c.free(s);

    const binary_ptr = result.binary orelse return Error.SerializeEmpty;
    if (result.binaryBytes == 0) return Error.SerializeEmpty;

    const src: [*]const u8 = @ptrCast(binary_ptr);
    const out = try allocator.alloc(u8, result.binaryBytes);
    @memcpy(out, src[0..result.binaryBytes]);
    return out;
}

// =====================================================================
// Tests
// =====================================================================

const testing = std.testing;

test "emitHelloWasm: produces a non-empty Wasm module starting with the magic" {
    const bytes = try emitHelloWasm(testing.allocator);
    defer testing.allocator.free(bytes);

    // Every valid wasm binary starts with `\x00asm` followed by the
    // 4-byte version (currently `\x01\x00\x00\x00`).
    try testing.expect(bytes.len >= 8);
    try testing.expectEqualSlices(u8, "\x00asm", bytes[0..4]);
    try testing.expectEqualSlices(u8, "\x01\x00\x00\x00", bytes[4..8]);
}

test "emitHelloWasm: contains the expected import + export names" {
    // Cheap structural sanity check: the import/export name strings
    // should appear verbatim in the binary. Avoids parsing wasm here
    // — that's the host's job in the end-to-end test.
    const bytes = try emitHelloWasm(testing.allocator);
    defer testing.allocator.free(bytes);

    try testing.expect(std.mem.indexOf(u8, bytes, "env") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "out") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "memory") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "_start") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "Hello, q64.\n") != null);
}

test "emitFromSource: parses fn main { env.out(\"Hello, q64.\") } and emits a valid module" {
    const src =
        \\fn main {
        \\    env.out("Hello, q64.")
        \\}
        \\
    ;
    const bytes = try emitFromSource(testing.allocator, src, "hello.q");
    defer testing.allocator.free(bytes);

    // Valid wasm magic + version.
    try testing.expect(bytes.len >= 8);
    try testing.expectEqualSlices(u8, "\x00asm", bytes[0..4]);

    // Payload appears verbatim in the data segment.
    try testing.expect(std.mem.indexOf(u8, bytes, "Hello, q64.\n") != null);
    // Import + export names land in their string tables.
    try testing.expect(std.mem.indexOf(u8, bytes, "env") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "out") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "_start") != null);
}

test "emitFromSource: supports multiple env.out calls" {
    const src =
        \\fn main {
        \\    env.out("one")
        \\    env.out("two")
        \\}
        \\
    ;
    const bytes = try emitFromSource(testing.allocator, src, "two.q");
    defer testing.allocator.free(bytes);

    try testing.expectEqualSlices(u8, "\x00asm", bytes[0..4]);
    try testing.expect(std.mem.indexOf(u8, bytes, "one\n") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "two\n") != null);
}

test "emitFromSource: missing main returns NoMainFunction" {
    const src = "fn helper { env.out(\"x\") }\n";
    try testing.expectError(
        Error.NoMainFunction,
        emitFromSource(testing.allocator, src, "no-main.q"),
    );
}

test "emitFromSource: non-env.out callee returns UnsupportedCall" {
    const src = "fn main { other.write(\"x\") }\n";
    try testing.expectError(
        Error.UnsupportedCall,
        emitFromSource(testing.allocator, src, "bad.q"),
    );
}
