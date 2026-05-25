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
//!     (import "env" "out" (func (param i64 i64)))
//!     (memory (export "memory") i64 1)
//!     (data (i64.const 0) "Hello, q64.\n")
//!     (func (export "_start")
//!       i64.const 0
//!       i64.const 12
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
    // Linking / const-evaluation (ladder steps 0, 3, 5, 6).
    UnknownModule, // an `import` names a module not supplied via --module (NAM001-ish)
    NameNotFound, // a selectively-imported name isn't defined in the module (NAM010-ish)
    UnsupportedImport, // import form codegen can't resolve yet (relative, stdlib)
    UnsupportedInterpolation, // `{expr}` whose value isn't a compile-time constant
    NotConstExpr, // an expression codegen cannot evaluate at compile time
    OutOfMemory,
};

/// A dependency module made available to codegen. `name` is the bare-
/// dotted module path (`dev.q64.hello_world`); `source` is the text of
/// that module's entry file (`src/lib.q`). The compiler resolves
/// `import <name>.{…}` against this set — it never reads `qube.json5`
/// or touches the filesystem itself (per spec/q64-cli.md §"--module").
pub const ModuleSource = struct {
    name: []const u8,
    source: []const u8,
};

/// Build the hello-world wasm module and return its bytes. Caller
/// owns the returned slice and must free it via `allocator`.
pub fn emitHelloWasm(allocator: std.mem.Allocator) ![]u8 {
    const module = c.BinaryenModuleCreate() orelse return error.ModuleCreate;
    defer c.BinaryenModuleDispose(module);

    // q64 targets Wasm Memory64 (spec/memory.md): 64-bit linear memory,
    // i64 pointers, so env.out is (i64, i64) -> ().
    c.BinaryenModuleSetFeatures(module, c.BinaryenFeatureMemory64());

    const i64_type = c.BinaryenTypeInt64();
    const none_type = c.BinaryenTypeNone();

    // env.out :: (i64, i64) -> () — imported from "env"."out".
    var env_out_params = [_]c.BinaryenType{ i64_type, i64_type };
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
        c.BinaryenConst(module, c.BinaryenLiteralInt64(0)),
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
        true, // memory64
        "0", // internal memory name
    );

    // _start body: call env.out(0, payload.len).
    const ptr_arg = c.BinaryenConst(module, c.BinaryenLiteralInt64(0));
    const len_arg = c.BinaryenConst(module, c.BinaryenLiteralInt64(@intCast(payload.len)));
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
    modules: []const ModuleSource,
) ![]u8 {
    const parse_result = try parse.parse(allocator, source, file);
    defer parse_result.deinit(allocator);

    const sf = ast.SourceFile.cast(parse_result.root) orelse return Error.NoMainFunction;

    // Build the link context: resolve every import against `modules`,
    // and index this file's own functions so a local `version()` works
    // too. An import codegen can't resolve is an error here, not a
    // silently-ignored line (ladder step 0).
    var resolver = Resolver.init(allocator, modules);
    defer resolver.deinit();
    try resolver.indexLocalFunctions(sf);
    try resolver.resolveImports(sf);

    var iter = sf.items();
    const main_fn = blk: while (iter.next()) |item| switch (item) {
        .fn_decl => |fd| {
            const name = fd.name() orelse continue;
            if (std.mem.eql(u8, name.text, "main")) break :blk fd;
        },
        else => {},
    } else return Error.NoMainFunction;

    return emitFn(allocator, &resolver, main_fn);
}

// A function codegen emits and calls at runtime (not const-folded).
//   const_str  — a nullary body that folds to a constant string in the
//                data segment; the function returns that fixed (ptr, len).
//   param_ref  — a passthrough body `{ s }` that returns the (ptr, len) of
//                str parameter #idx.
//   concat     — a body that builds its result in the scope arena from
//                `segments` [first..first+count] (const runs + `param`
//                refs), e.g. `{ "{s}!" }`, and returns it.
//   int_fn     — an i64-returning function `fn f(a: i64, …) -> i64 { expr }`
//                emitted as `(i64×params) -> i64` with `expr` lowered to
//                real wasm arithmetic (`emitIntExpr`).
// A `str` parameter is two i64 wasm params (ptr, len); an `i64` parameter
// is one. `n_params` is the source parameter count either way.
const Callee = struct {
    name: [:0]const u8,
    n_params: usize,
    body: union(enum) {
        const_str: struct { off: u32, len: u32 },
        param_ref: usize,
        concat: struct { first: usize, count: usize },
        int_fn: ast.FnDecl,
    },
};

// An argument passed at a call site: a string constant (in the data
// segment), a string runtime binding (its locals), or an integer value.
const ArgVal = union(enum) {
    constant: struct { off: u32, len: u32 },
    binding: RtBinding,
    int: i64,
};

// A runtime `let`/`var` binding holds a string value in two i64 `_start`
// locals (ptr, len). Binding locals come first in `_start`'s frame, so
// binding #k uses locals 2k, 2k+1.
const RtBinding = struct { ptr_local: u32, len_local: u32 };

// One piece of a runtime-concatenated string: a constant run in the static
// data segment, the (ptr, len) returned by a nullary callee, the (ptr, len)
// of a str parameter (only inside a callee body), or the (ptr, len) of a
// runtime binding (only inside `_start`).
const Segment = union(enum) {
    const_run: struct { off: u32, len: u32 },
    call: usize, // index into `callees`
    param: usize, // str parameter index (locals 2·idx, 2·idx+1)
    binding: RtBinding, // runtime binding locals
};

// One thing `main` does, in order.
//   print_const   — write a folded byte payload straight from the data segment.
//   print_callee  — call an emitted function (passing args[args_first..]),
//                   write its returned string.
//   print_concat  — build a string in the scope arena from `segments`
//                   [first..first+count] (const runs + call/binding results
//                   copied via memory.copy), then write it.
//   print_binding — write a runtime binding's current (ptr, len).
//   bind_call     — call an emitted function and store its (ptr, len) into a
//                   runtime binding's locals (a `let x = f(args)`).
//   print_int_callee — call an i64-returning function, format the result to
//                   decimal (`__fmt_i64`), and write it.
// The print_* actions append env.out's trailing "\n" (a shared byte at nl_off).
const Action = union(enum) {
    print_const: struct { off: u32, len: u32 },
    print_callee: struct { callee: usize, args_first: usize, args_count: usize, nl_off: u32 },
    print_concat: struct { first: usize, count: usize, nl_off: u32 },
    print_binding: struct { binding: RtBinding, nl_off: u32 },
    bind_call: struct { binding: RtBinding, callee: usize, args_first: usize, args_count: usize },
    print_int_callee: struct { callee: usize, args_first: usize, args_count: usize, nl_off: u32 },
};

fn emitFn(allocator: std.mem.Allocator, resolver: *Resolver, fd: ast.FnDecl) ![]u8 {
    const body = fd.body() orelse return Error.NoBody;

    // The module's linear-memory image, the ordered plan for `_start`,
    // the functions `_start` calls, and the segment store backing
    // `print_concat` actions.
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(allocator);
    var actions: std.ArrayList(Action) = .empty;
    defer actions.deinit(allocator);
    var callees: std.ArrayList(Callee) = .empty;
    defer {
        for (callees.items) |cl| allocator.free(cl.name);
        callees.deinit(allocator);
    }
    var segments: std.ArrayList(Segment) = .empty;
    defer segments.deinit(allocator);
    var call_args: std.ArrayList(ArgVal) = .empty;
    defer call_args.deinit(allocator);
    // Runtime `let` bindings: name → its (ptr, len) `_start` locals. Binding
    // locals occupy the first 2·N slots of the frame; `n_rt` counts them.
    var rt_bindings: std.StringHashMapUnmanaged(RtBinding) = .empty;
    defer rt_bindings.deinit(allocator);
    var n_rt: u32 = 0;

    // A single shared "\n" byte, materialized the first time env.out needs
    // its trailing newline.
    var nl_off: ?u32 = null;

    var stmts = body.statements();
    while (stmts.next()) |stmt| switch (stmt) {
        .expr_stmt => |es| {
            const expr = es.expression() orelse return Error.UnsupportedStatement;
            const call = switch (expr) {
                .call => |cc| cc,
                else => return Error.UnsupportedExpression,
            };
            const arg = try envOutArg(allocator, call);
            switch (arg) {
                // env.out(f(args…)) — a real runtime call to an emitted
                // function, passing string-literal arguments.
                .call => |inner| {
                    const idx = try ensureCallee(allocator, resolver, &data, &callees, &segments, inner);
                    const is_int = switch (callees.items[idx].body) {
                        .int_fn => true,
                        else => false,
                    };
                    const args_first = call_args.items.len;
                    try extractCallArgs(allocator, resolver, &data, &rt_bindings, &call_args, inner, is_int);
                    const args_count = call_args.items.len - args_first;
                    if (args_count != callees.items[idx].n_params) return Error.UnsupportedCall;
                    const nl = try ensureNewline(allocator, &data, &nl_off);
                    if (is_int) {
                        try actions.append(allocator, .{ .print_int_callee = .{
                            .callee = idx,
                            .args_first = args_first,
                            .args_count = args_count,
                            .nl_off = nl,
                        } });
                    } else {
                        try actions.append(allocator, .{ .print_callee = .{
                            .callee = idx,
                            .args_first = args_first,
                            .args_count = args_count,
                            .nl_off = nl,
                        } });
                    }
                },
                // env.out("…") — a string literal, possibly interpolated.
                .string_lit => |s| {
                    const raw = s.rawText() orelse return Error.BadStringLiteral;

                    var raws: std.ArrayList(RawSeg) = .empty;
                    defer {
                        for (raws.items) |rs| switch (rs) {
                            .lit => |b| allocator.free(b),
                            .call, .param, .binding => {},
                        };
                        raws.deinit(allocator);
                    }
                    const has_dyn = try splitInterpolation(allocator, resolver, raw, &data, &callees, &segments, &raws, null, &rt_bindings);

                    if (!has_dyn) {
                        // Pure-constant interpolation folds to one payload
                        // (preserves escapes, `{{`, numeric interpolation).
                        const value = try resolver.constEvalExpr(arg);
                        defer allocator.free(value);
                        const off: u32 = @intCast(data.items.len);
                        try data.appendSlice(allocator, value);
                        try data.append(allocator, '\n'); // env.out("X") writes "X\n"
                        try actions.append(allocator, .{ .print_const = .{ .off = off, .len = @intCast(value.len + 1) } });
                    } else {
                        // A call or runtime binding appears: build the
                        // string at runtime in the scope arena.
                        const seg_start = segments.items.len;
                        for (raws.items) |rs| switch (rs) {
                            .lit => |bytes| {
                                if (bytes.len == 0) continue;
                                const off: u32 = @intCast(data.items.len);
                                try data.appendSlice(allocator, bytes);
                                try segments.append(allocator, .{ .const_run = .{ .off = off, .len = @intCast(bytes.len) } });
                            },
                            .call => |idx| try segments.append(allocator, .{ .call = idx }),
                            .binding => |b| try segments.append(allocator, .{ .binding = b }),
                            // `_start` interpolation (params == null) yields no param pieces.
                            .param => unreachable,
                        };
                        const nl = try ensureNewline(allocator, &data, &nl_off);
                        try actions.append(allocator, .{ .print_concat = .{
                            .first = seg_start,
                            .count = segments.items.len - seg_start,
                            .nl_off = nl,
                        } });
                    }
                },
                // env.out(x) — a reference to a binding. A runtime binding
                // prints its (ptr, len) locals; a const binding folds.
                .path => |p| {
                    const ptext = try p.text(allocator);
                    defer allocator.free(ptext);
                    if (rt_bindings.get(ptext)) |rb| {
                        const nl = try ensureNewline(allocator, &data, &nl_off);
                        try actions.append(allocator, .{ .print_binding = .{ .binding = rb, .nl_off = nl } });
                    } else {
                        const value = try resolver.constEvalExpr(arg);
                        defer allocator.free(value);
                        const off: u32 = @intCast(data.items.len);
                        try data.appendSlice(allocator, value);
                        try data.append(allocator, '\n');
                        try actions.append(allocator, .{ .print_const = .{ .off = off, .len = @intCast(value.len + 1) } });
                    }
                },
                else => return Error.UnsupportedExpression,
            }
        },
        // `let`/`var` binds a string value usable by later statements via
        // `env.out(x)` or `"{x}"`. A const-foldable initializer becomes a
        // compile-time binding; a runtime call (`let g = f(args)`) binds the
        // call's (ptr, len) into `_start` locals.
        .let_stmt => |ls| {
            const pat = ls.pattern() orelse return Error.UnsupportedStatement;
            const name_tok = pat.bindingName() orelse return Error.UnsupportedStatement;
            const init_expr = ls.initializer() orelse return Error.UnsupportedStatement;

            if (resolver.constEvalExpr(init_expr)) |value| {
                errdefer allocator.free(value);
                try resolver.bind(name_tok.text, value);
            } else |err| switch (err) {
                // Not const-foldable: a runtime binding. v0 supports a
                // direct call initializer (`let g = f(args)`).
                error.NotConstExpr => {
                    const inner = switch (init_expr) {
                        .call => |cc| cc,
                        else => return err,
                    };
                    const idx = try ensureCallee(allocator, resolver, &data, &callees, &segments, inner);
                    // v0 runtime bindings hold strings; binding an i64
                    // result (`let x = double(21)`) isn't supported yet.
                    switch (callees.items[idx].body) {
                        .int_fn => return Error.UnsupportedCall,
                        else => {},
                    }
                    const args_first = call_args.items.len;
                    try extractCallArgs(allocator, resolver, &data, &rt_bindings, &call_args, inner, false);
                    const args_count = call_args.items.len - args_first;
                    if (args_count != callees.items[idx].n_params) return Error.UnsupportedCall;

                    const rb = RtBinding{ .ptr_local = n_rt * 2, .len_local = n_rt * 2 + 1 };
                    n_rt += 1;
                    try rt_bindings.put(allocator, name_tok.text, rb);
                    try actions.append(allocator, .{ .bind_call = .{
                        .binding = rb,
                        .callee = idx,
                        .args_first = args_first,
                        .args_count = args_count,
                    } });
                },
                else => return err,
            }
        },
        // Early `return` and control-flow statements aren't lowered yet.
        else => return Error.UnsupportedStatement,
    };

    return emitModule(allocator, data.items, actions.items, callees.items, segments.items, call_args.items, n_rt);
}

/// Reserve the shared newline byte env.out appends; idempotent.
fn ensureNewline(allocator: std.mem.Allocator, data: *std.ArrayList(u8), nl_off: *?u32) !u32 {
    if (nl_off.*) |off| return off;
    const off: u32 = @intCast(data.items.len);
    try data.append(allocator, '\n');
    nl_off.* = off;
    return off;
}

/// A raw concatenation piece produced while splitting an interpolated
/// literal: a decoded constant run (owned bytes), a resolved nullary call
/// (callee index), or a reference to str parameter #idx.
const RawSeg = union(enum) {
    lit: []u8,
    call: usize,
    param: usize,
    binding: RtBinding,
};

/// Split an interpolated string literal into runtime-concatenation pieces.
/// Constant runs (with escapes, `{{`/`}}`, and non-dynamic interpolations
/// const-evaluated) accumulate into `lit` pieces. A `{name}` matching a
/// parameter (callee-body context, `params`) becomes a `param` piece;
/// matching a runtime binding (`_start` context, `rt_bindings`) becomes a
/// `binding` piece. Otherwise a `{call()}` interpolation resolves its
/// nullary callee into a `call` piece (callee bodies may not nest calls in
/// v0). Returns whether any dynamic piece was produced — the caller folds
/// when none was. Caller owns the `.lit` byte slices in `out`.
fn splitInterpolation(
    allocator: std.mem.Allocator,
    resolver: *Resolver,
    raw: []const u8,
    data: *std.ArrayList(u8),
    callees: *std.ArrayList(Callee),
    segments: *std.ArrayList(Segment),
    out: *std.ArrayList(RawSeg),
    params: ?[]const []const u8,
    rt_bindings: ?*const std.StringHashMapUnmanaged(RtBinding),
) Error!bool {
    // Raw strings (`r"…"`) carry no interpolation — nothing to split.
    if (raw.len >= 1 and raw[0] == 'r') return false;
    if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') return Error.BadStringLiteral;
    const text = raw[1 .. raw.len - 1];

    var lit: std.ArrayList(u8) = .empty;
    errdefer lit.deinit(allocator);
    var has_dynamic = false;

    const flushLit = struct {
        fn call(a: std.mem.Allocator, buf: *std.ArrayList(u8), dst: *std.ArrayList(RawSeg)) !void {
            if (buf.items.len == 0) return;
            const owned = try buf.toOwnedSlice(a);
            errdefer a.free(owned);
            try dst.append(a, .{ .lit = owned });
        }
    }.call;

    var i: usize = 0;
    while (i < text.len) {
        const ch = text[i];
        if (ch == '\\' and i + 1 < text.len) {
            try lit.append(allocator, decodeEscape(text[i + 1]));
            i += 2;
            continue;
        }
        if (ch == '{') {
            if (i + 1 < text.len and text[i + 1] == '{') {
                try lit.append(allocator, '{');
                i += 2;
                continue;
            }
            const close = std.mem.indexOfScalarPos(u8, text, i + 1, '}') orelse
                return Error.UnsupportedInterpolation;
            const inner = text[i + 1 .. close];

            // Parse the interpolation. A nullary call becomes a runtime
            // call piece; anything else const-evaluates into the literal.
            const r = try parse.parseExpression(allocator, inner, "<interp>");
            defer r.deinit(allocator);
            const iexpr = ast.Expr.cast(r.root) orelse return Error.UnsupportedInterpolation;
            switch (iexpr) {
                .call => |cc| {
                    // v0: callee bodies don't nest calls; calls only
                    // appear at the top level, and only nullary.
                    if (params != null) return Error.UnsupportedCall;
                    var ca = cc.args();
                    if (ca.next() != null) return Error.UnsupportedCall;
                    try flushLit(allocator, &lit, out);
                    const idx = try ensureCallee(allocator, resolver, data, callees, segments, cc);
                    if (callees.items[idx].n_params != 0) return Error.UnsupportedCall;
                    try out.append(allocator, .{ .call = idx });
                    has_dynamic = true;
                },
                .path => |pp| {
                    const ptext = try pp.text(allocator);
                    defer allocator.free(ptext);
                    // `{name}` referencing a parameter (callee body) or a
                    // runtime binding (`_start`) becomes a dynamic piece.
                    if (params) |pnames| {
                        if (indexOfName(pnames, ptext)) |pidx| {
                            try flushLit(allocator, &lit, out);
                            try out.append(allocator, .{ .param = pidx });
                            has_dynamic = true;
                            i = close + 1;
                            continue;
                        }
                    }
                    if (rt_bindings) |rb_map| {
                        if (rb_map.get(ptext)) |rb| {
                            try flushLit(allocator, &lit, out);
                            try out.append(allocator, .{ .binding = rb });
                            has_dynamic = true;
                            i = close + 1;
                            continue;
                        }
                    }
                    const value = try resolver.constEvalExpr(iexpr);
                    defer allocator.free(value);
                    try lit.appendSlice(allocator, value);
                },
                else => {
                    const value = try resolver.constEvalExpr(iexpr);
                    defer allocator.free(value);
                    try lit.appendSlice(allocator, value);
                },
            }
            i = close + 1;
            continue;
        }
        if (ch == '}' and i + 1 < text.len and text[i + 1] == '}') {
            try lit.append(allocator, '}');
            i += 2;
            continue;
        }
        try lit.append(allocator, ch);
        i += 1;
    }
    try flushLit(allocator, &lit, out);
    lit.deinit(allocator);
    return has_dynamic;
}

/// The single argument of a well-formed `env.out(arg)` call.
fn envOutArg(allocator: std.mem.Allocator, call: ast.CallExpr) !ast.Expr {
    const callee_expr = call.callee() orelse return Error.UnsupportedCall;
    const path = switch (callee_expr) {
        .path => |p| p,
        else => return Error.UnsupportedCall,
    };
    const path_text = try path.text(allocator);
    defer allocator.free(path_text);
    if (!std.mem.eql(u8, path_text, "env.out")) return Error.UnsupportedCall;

    var arg_iter = call.args();
    return arg_iter.next() orelse return Error.UnsupportedCall;
}

/// Extract a call's arguments into `call_args`. With `int_args`, each
/// argument is const-evaluated to an `i64`. Otherwise it's a string: a
/// bare reference to a runtime binding is passed by its locals (a runtime
/// argument); anything else is const-evaluated into the data segment.
fn extractCallArgs(
    allocator: std.mem.Allocator,
    resolver: *Resolver,
    data: *std.ArrayList(u8),
    rt_bindings: *const std.StringHashMapUnmanaged(RtBinding),
    call_args: *std.ArrayList(ArgVal),
    inner: ast.CallExpr,
    int_args: bool,
) Error!void {
    var ait = inner.args();
    while (ait.next()) |a| {
        if (int_args) {
            try call_args.append(allocator, .{ .int = try resolver.constEvalInt(a) });
            continue;
        }
        switch (a) {
            .path => |p| {
                const ptext = try p.text(allocator);
                defer allocator.free(ptext);
                if (rt_bindings.get(ptext)) |rb| {
                    try call_args.append(allocator, .{ .binding = rb });
                    continue;
                }
            },
            else => {},
        }
        const v = try resolver.constEvalExpr(a);
        defer allocator.free(v);
        const off: u32 = @intCast(data.items.len);
        try data.appendSlice(allocator, v);
        try call_args.append(allocator, .{ .constant = .{ .off = off, .len = @intCast(v.len) } });
    }
}

/// Register the function a real `env.out(f())` invokes: resolve `f`,
/// const-evaluate its returned string into the data segment, and record
/// the callee so codegen emits it once. Returns the callee index;
/// deduplicates by name so repeated calls share one emitted function.
fn ensureCallee(
    allocator: std.mem.Allocator,
    resolver: *Resolver,
    data: *std.ArrayList(u8),
    callees: *std.ArrayList(Callee),
    segments: *std.ArrayList(Segment),
    call: ast.CallExpr,
) Error!usize {
    const callee_expr = call.callee() orelse return Error.UnsupportedCall;
    const path = switch (callee_expr) {
        .path => |p| p,
        else => return Error.UnsupportedCall,
    };
    const name = try path.text(allocator);
    defer allocator.free(name);

    for (callees.items, 0..) |cl, i| {
        if (std.mem.eql(u8, cl.name, name)) return i;
    }

    const fd = resolver.lookup(name) orelse return Error.NameNotFound;

    // Collect the callee's parameter names. v0 supports only `str`
    // parameters (each lowered to two i64 wasm params: ptr, len).
    var pnames: std.ArrayList([]const u8) = .empty;
    defer pnames.deinit(allocator);
    if (fd.params()) |ps| {
        var it = ps.iter();
        while (it.next()) |p| {
            const pn = p.name() orelse return Error.UnsupportedCall;
            try pnames.append(allocator, pn.text);
        }
    }

    const body: @FieldType(Callee, "body") = if (try returnsI64(allocator, fd)) blk: {
        // i64-returning function: emit real arithmetic (`emitIntExpr` at
        // emission time). v0 requires all parameters to be `i64`.
        if (fd.params()) |ps| {
            var it = ps.iter();
            while (it.next()) |p| {
                if (!try paramIsI64(allocator, p)) return Error.UnsupportedCall;
            }
        }
        break :blk .{ .int_fn = fd };
    } else if (pnames.items.len == 0) blk: {
        // Nullary: fold the body to a constant string in the data segment.
        const bytes = try resolver.constEvalFn(fd);
        defer allocator.free(bytes);
        const off: u32 = @intCast(data.items.len);
        try data.appendSlice(allocator, bytes);
        break :blk .{ .const_str = .{ .off = off, .len = @intCast(bytes.len) } };
    } else blk: {
        // Parameterized body. A bare `{ s }` is a passthrough (return the
        // parameter directly). A string literal `{ "…{s}…" }` builds its
        // result in the scope arena from segments (const runs + `param`
        // refs).
        const ve = bodyValueExpr(fd) orelse return Error.UnsupportedCall;
        switch (ve) {
            .path => |ppath| {
                const ptext = try ppath.text(allocator);
                defer allocator.free(ptext);
                const idx = indexOfName(pnames.items, ptext) orelse return Error.UnsupportedCall;
                break :blk .{ .param_ref = idx };
            },
            .string_lit => |s| {
                const raw = s.rawText() orelse return Error.BadStringLiteral;
                var raws: std.ArrayList(RawSeg) = .empty;
                defer {
                    for (raws.items) |rs| switch (rs) {
                        .lit => |b| allocator.free(b),
                        .call, .param, .binding => {},
                    };
                    raws.deinit(allocator);
                }
                const has_dyn = try splitInterpolation(allocator, resolver, raw, data, callees, segments, &raws, pnames.items, null);
                if (!has_dyn) {
                    // No parameter used: fold to a constant string.
                    const bytes = try resolver.constEvalExpr(ve);
                    defer allocator.free(bytes);
                    const off: u32 = @intCast(data.items.len);
                    try data.appendSlice(allocator, bytes);
                    break :blk .{ .const_str = .{ .off = off, .len = @intCast(bytes.len) } };
                }
                const first = segments.items.len;
                for (raws.items) |rs| switch (rs) {
                    .lit => |bytes| {
                        if (bytes.len == 0) continue;
                        const off: u32 = @intCast(data.items.len);
                        try data.appendSlice(allocator, bytes);
                        try segments.append(allocator, .{ .const_run = .{ .off = off, .len = @intCast(bytes.len) } });
                    },
                    .param => |idx| try segments.append(allocator, .{ .param = idx }),
                    .call => |idx| try segments.append(allocator, .{ .call = idx }),
                    // Callee bodies (params context) see no runtime bindings.
                    .binding => unreachable,
                };
                break :blk .{ .concat = .{ .first = first, .count = segments.items.len - first } };
            },
            else => return Error.UnsupportedCall,
        }
    };

    const owned = try allocator.dupeZ(u8, name);
    errdefer allocator.free(owned);
    try callees.append(allocator, .{
        .name = owned,
        .n_params = pnames.items.len,
        .body = body,
    });
    return callees.items.len - 1;
}

/// The tail value expression of a function body (mirrors `constEvalFn`'s
/// statement walk): the last expression statement or `return` value.
fn bodyValueExpr(fd: ast.FnDecl) ?ast.Expr {
    const body = fd.body() orelse return null;
    var stmts = body.statements();
    var last: ?ast.Expr = null;
    while (stmts.next()) |stmt| switch (stmt) {
        .expr_stmt => |es| last = es.expression(),
        .return_stmt => |rs| last = rs.value(),
        else => {},
    };
    return last;
}

fn indexOfName(names: []const []const u8, name: []const u8) ?usize {
    for (names, 0..) |n, i| {
        if (std.mem.eql(u8, n, name)) return i;
    }
    return null;
}

/// True if `te` is the named path type `name` (e.g. `i64`).
fn typeNamed(allocator: std.mem.Allocator, te: ast.TypeExpr, name: []const u8) !bool {
    const p = switch (te) {
        .path => |x| x,
        else => return false,
    };
    const nm = try p.name(allocator);
    defer allocator.free(nm);
    return std.mem.eql(u8, nm, name);
}

fn returnsI64(allocator: std.mem.Allocator, fd: ast.FnDecl) !bool {
    const rt = fd.returnType() orelse return false;
    const te = rt.type_() orelse return false;
    return typeNamed(allocator, te, "i64");
}

fn paramIsI64(allocator: std.mem.Allocator, p: ast.Param) !bool {
    const te = p.type_() orelse return false;
    return typeNamed(allocator, te, "i64");
}

// =====================================================================
// Resolver — imports, symbol table, and compile-time evaluation
// =====================================================================
//
// v0 linking is source-level and constant-folding: an imported function
// whose body is a compile-time constant (a string/number literal, or an
// interpolation of such) is evaluated at compile time and its value
// spliced into the caller. This is exactly enough to make
// `dev.q64.hello_app` print `0.1.0` by calling
// `dev.q64.hello_world.version()` (todo.md "Definition of done"), and it
// fails loudly on anything it cannot evaluate rather than emitting
// wrong code.

const Resolver = struct {
    allocator: std.mem.Allocator,
    modules: []const ModuleSource,
    /// Parsed dependency modules, kept alive so the `FnDecl` views below
    /// stay valid for the lifetime of the resolver.
    parsed: std.ArrayList(parse.Result),
    /// name → defining function. Keys are slices into a CST that outlives
    /// the resolver (the caller's parse result or a `parsed` entry).
    symbols: std.StringHashMapUnmanaged(ast.FnDecl),
    /// name → bound compile-time value. v0 `let`/`var` bindings hold a
    /// constant string; the resolver owns the value bytes. Keys are CST
    /// slices (the binding's identifier).
    bindings: std.StringHashMapUnmanaged([]u8),

    fn init(allocator: std.mem.Allocator, modules: []const ModuleSource) Resolver {
        return .{
            .allocator = allocator,
            .modules = modules,
            .parsed = .empty,
            .symbols = .empty,
            .bindings = .empty,
        };
    }

    fn deinit(self: *Resolver) void {
        for (self.parsed.items) |r| r.deinit(self.allocator);
        self.parsed.deinit(self.allocator);
        self.symbols.deinit(self.allocator);
        var it = self.bindings.valueIterator();
        while (it.next()) |v| self.allocator.free(v.*);
        self.bindings.deinit(self.allocator);
    }

    /// Bind `name` to a compile-time string value, taking ownership of
    /// `value`. A rebind (e.g. `var` reassignment) frees the prior value.
    fn bind(self: *Resolver, name: []const u8, value: []u8) !void {
        const gop = try self.bindings.getOrPut(self.allocator, name);
        if (gop.found_existing) self.allocator.free(gop.value_ptr.*);
        gop.value_ptr.* = value;
    }

    /// Index every top-level function in `sf` under its own name, so a
    /// program that defines and calls a local const function resolves
    /// without an import.
    fn indexLocalFunctions(self: *Resolver, sf: ast.SourceFile) !void {
        var it = sf.items();
        while (it.next()) |item| switch (item) {
            .fn_decl => |fd| {
                const name = fd.name() orelse continue;
                try self.symbols.put(self.allocator, name.text, fd);
            },
            else => {},
        };
    }

    /// Resolve each import statement against the `--module` set. Binds
    /// every selectively-imported name to its defining function. Errors
    /// on unresolvable imports (unknown module, missing name) and on
    /// import forms not yet supported (relative paths, stdlib).
    fn resolveImports(self: *Resolver, sf: ast.SourceFile) !void {
        var imports = sf.imports();
        while (imports.next()) |im| {
            if (im.isRelative()) return Error.UnsupportedImport;

            const module_path = (try im.path(self.allocator)) orelse return Error.UnsupportedImport;
            defer self.allocator.free(module_path);

            const src = self.moduleSource(module_path) orelse return Error.UnknownModule;

            const r = try parse.parse(self.allocator, src, module_path);
            try self.parsed.append(self.allocator, r);
            const dep_sf = ast.SourceFile.cast(r.root) orelse return Error.UnknownModule;

            var names = im.names();
            while (names.next()) |name_tok| {
                const fd = findPublicFn(dep_sf, name_tok.text) orelse return Error.NameNotFound;
                try self.symbols.put(self.allocator, name_tok.text, fd);
            }
        }
    }

    fn moduleSource(self: *Resolver, name: []const u8) ?[]const u8 {
        for (self.modules) |m| {
            if (std.mem.eql(u8, m.name, name)) return m.source;
        }
        return null;
    }

    fn lookup(self: *Resolver, name: []const u8) ?ast.FnDecl {
        return self.symbols.get(name);
    }

    /// Evaluate an expression to its compile-time string value. Caller
    /// owns the returned bytes.
    fn constEvalExpr(self: *Resolver, expr: ast.Expr) Error![]u8 {
        return switch (expr) {
            .string_lit => |s| self.renderStringLit(s),
            .num_lit => |n| self.allocator.dupe(u8, n.rawText() orelse return Error.BadStringLiteral),
            .call => |cc| self.constEvalCall(cc),
            // A bare identifier resolves to a `let`/`var` binding when one
            // is in scope; otherwise it isn't a constant we can fold.
            .path => |p| self.lookupBinding(p),
            // A parenthesized expression is transparent.
            .paren => |p| self.constEvalExpr(p.inner() orelse return Error.NotConstExpr),
            // Integer arithmetic folds to its decimal value.
            .bin, .unary => {
                const v = try self.constEvalInt(expr);
                return std.fmt.allocPrint(self.allocator, "{d}", .{v});
            },
            else => Error.NotConstExpr,
        };
    }

    /// Evaluate an integer-valued expression at compile time. Supports
    /// integer literals, the arithmetic / bitwise / shift binary operators,
    /// unary `-`/`~`, parentheses, and bindings holding an integer.
    fn constEvalInt(self: *Resolver, expr: ast.Expr) Error!i64 {
        switch (expr) {
            .num_lit => |n| return parseIntLit(n.rawText() orelse return Error.NotConstExpr),
            .paren => |p| return self.constEvalInt(p.inner() orelse return Error.NotConstExpr),
            .path => |p| {
                const bytes = try self.lookupBinding(p);
                defer self.allocator.free(bytes);
                return parseIntLit(bytes);
            },
            .unary => |u| {
                const x = try self.constEvalInt(u.operand() orelse return Error.NotConstExpr);
                const op = u.op() orelse return Error.NotConstExpr;
                return switch (op.kind) {
                    .MINUS => std.math.negate(x) catch return Error.NotConstExpr,
                    .TILDE => ~x,
                    else => Error.NotConstExpr, // `!` is boolean
                };
            },
            .bin => |b| {
                const l = try self.constEvalInt(b.lhs() orelse return Error.NotConstExpr);
                const r = try self.constEvalInt(b.rhs() orelse return Error.NotConstExpr);
                const op = b.op() orelse return Error.NotConstExpr;
                return switch (op.kind) {
                    .PLUS => std.math.add(i64, l, r) catch Error.NotConstExpr,
                    .MINUS => std.math.sub(i64, l, r) catch Error.NotConstExpr,
                    .STAR => std.math.mul(i64, l, r) catch Error.NotConstExpr,
                    .SLASH => if (r == 0) Error.NotConstExpr else @divTrunc(l, r),
                    .PERCENT => if (r == 0) Error.NotConstExpr else @rem(l, r),
                    .AMP => l & r,
                    .PIPE => l | r,
                    .CARET => l ^ r,
                    .SHL => if (r < 0 or r > 63) Error.NotConstExpr else l << @intCast(r),
                    .SHR => if (r < 0 or r > 63) Error.NotConstExpr else l >> @intCast(r),
                    else => Error.NotConstExpr, // comparisons / logical aren't integers
                };
            },
            else => return Error.NotConstExpr,
        }
    }

    /// Resolve a path expression against the binding table. Returns a copy
    /// of the bound value; `NotConstExpr` if the name isn't bound.
    fn lookupBinding(self: *Resolver, p: ast.PathExpr) Error![]u8 {
        const name = try p.text(self.allocator);
        defer self.allocator.free(name);
        const v = self.bindings.get(name) orelse return Error.NotConstExpr;
        return self.allocator.dupe(u8, v);
    }

    fn constEvalCall(self: *Resolver, call: ast.CallExpr) Error![]u8 {
        const callee = call.callee() orelse return Error.NotConstExpr;
        const path = switch (callee) {
            .path => |p| p,
            else => return Error.NotConstExpr,
        };
        const name = try path.text(self.allocator);
        defer self.allocator.free(name);

        // v0 evaluates only nullary calls: `version()`. Arguments would
        // require parameter substitution, which isn't supported yet.
        var args = call.args();
        if (args.next() != null) return Error.NotConstExpr;

        const fd = self.lookup(name) orelse return Error.NameNotFound;
        return self.constEvalFn(fd);
    }

    /// A function is a compile-time constant when its body is a single
    /// value expression (a tail expression with no preceding statements
    /// that matter). v0 evaluates that expression.
    fn constEvalFn(self: *Resolver, fd: ast.FnDecl) Error![]u8 {
        const body = fd.body() orelse return Error.NoBody;
        var stmts = body.statements();
        var last: ?ast.Expr = null;
        while (stmts.next()) |stmt| switch (stmt) {
            .expr_stmt => |es| last = es.expression(),
            // `return <expr>` names the function's value directly.
            .return_stmt => |rs| last = rs.value(),
            // `let`/`var` and other statements don't contribute the tail
            // value; a binding the tail depends on surfaces later as
            // `NotConstExpr` (honest), not as wrong output.
            else => {},
        };
        const value_expr = last orelse return Error.NotConstExpr;
        return self.constEvalExpr(value_expr);
    }

    /// Decode a string literal, evaluating any `{expr}` interpolations.
    /// `{{`/`}}` are literal braces; `\{`/`\}` escape a brace. An
    /// interpolation whose value isn't a compile-time constant is
    /// `UnsupportedInterpolation`.
    fn renderStringLit(self: *Resolver, s: ast.StringLit) Error![]u8 {
        const raw = s.rawText() orelse return Error.BadStringLiteral;

        // Raw string `r"…"` / `r#"…"#`: no escapes, no interpolation.
        if (raw.len >= 1 and raw[0] == 'r') {
            const open = std.mem.indexOfScalar(u8, raw, '"') orelse return Error.BadStringLiteral;
            const close = std.mem.lastIndexOfScalar(u8, raw, '"') orelse return Error.BadStringLiteral;
            if (close <= open) return Error.BadStringLiteral;
            return self.allocator.dupe(u8, raw[open + 1 .. close]);
        }

        if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') return Error.BadStringLiteral;
        const body = raw[1 .. raw.len - 1];

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);

        var i: usize = 0;
        while (i < body.len) {
            const ch = body[i];
            if (ch == '\\' and i + 1 < body.len) {
                try out.append(self.allocator, decodeEscape(body[i + 1]));
                i += 2;
                continue;
            }
            if (ch == '{') {
                if (i + 1 < body.len and body[i + 1] == '{') {
                    try out.append(self.allocator, '{');
                    i += 2;
                    continue;
                }
                // Interpolation: take everything up to the matching `}`.
                const close = std.mem.indexOfScalarPos(u8, body, i + 1, '}') orelse
                    return Error.UnsupportedInterpolation;
                const inner = body[i + 1 .. close];
                const value = try self.constEvalSource(inner);
                defer self.allocator.free(value);
                try out.appendSlice(self.allocator, value);
                i = close + 1;
                continue;
            }
            if (ch == '}' and i + 1 < body.len and body[i + 1] == '}') {
                try out.append(self.allocator, '}');
                i += 2;
                continue;
            }
            try out.append(self.allocator, ch);
            i += 1;
        }
        return out.toOwnedSlice(self.allocator);
    }

    /// Parse `source` as a single expression and const-evaluate it.
    fn constEvalSource(self: *Resolver, source: []const u8) Error![]u8 {
        const r = try parse.parseExpression(self.allocator, source, "<interp>");
        defer r.deinit(self.allocator);
        const expr = ast.Expr.cast(r.root) orelse return Error.UnsupportedInterpolation;
        return self.constEvalExpr(expr);
    }
};

fn decodeEscape(ch: u8) u8 {
    return switch (ch) {
        'n' => '\n',
        't' => '\t',
        'r' => '\r',
        '0' => 0,
        else => ch, // \\, \", \{, \} and unknowns pass the char through
    };
}

/// Parse an integer literal's text to an `i64`. Strips `_` digit
/// separators and honors `0x`/`0o`/`0b` prefixes. A float, a suffixed
/// unit literal (`48.kHz`), or anything unparseable is `NotConstExpr`.
fn parseIntLit(raw: []const u8) Error!i64 {
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    for (raw) |ch| {
        if (ch == '_') continue;
        if (n >= buf.len) return Error.NotConstExpr;
        buf[n] = ch;
        n += 1;
    }
    return std.fmt.parseInt(i64, buf[0..n], 0) catch Error.NotConstExpr;
}

fn findPublicFn(sf: ast.SourceFile, name: []const u8) ?ast.FnDecl {
    var it = sf.items();
    while (it.next()) |item| switch (item) {
        .fn_decl => |fd| {
            if (!fd.isPublic()) continue;
            const fn_name = fd.name() orelse continue;
            if (std.mem.eql(u8, fn_name.text, name)) return fd;
        },
        else => {},
    };
    return null;
}

// Locals used by an arena concatenation: `buf`/`off`/`len` are i64 scratch;
// `tuple_base` is the first tuple local for `call` segments.
const ConcatLocals = struct {
    buf: c.BinaryenIndex,
    off: c.BinaryenIndex,
    len: c.BinaryenIndex,
    tuple_base: c.BinaryenIndex,
};

/// Build a call's wasm operands: two i64 per str argument — `(off, len)`
/// consts for a constant arg, `(local.get ptr, local.get len)` for a
/// runtime binding. Caller owns the returned slice.
fn buildArgs(
    allocator: std.mem.Allocator,
    module: c.BinaryenModuleRef,
    call_args: []const ArgVal,
    first: usize,
    count: usize,
    i64_type: c.BinaryenType,
) ![]c.BinaryenExpressionRef {
    const argvals = try allocator.alloc(c.BinaryenExpressionRef, count * 2);
    errdefer allocator.free(argvals);
    for (0..count) |k| switch (call_args[first + k]) {
        .constant => |cv| {
            argvals[k * 2] = c.BinaryenConst(module, c.BinaryenLiteralInt64(@intCast(cv.off)));
            argvals[k * 2 + 1] = c.BinaryenConst(module, c.BinaryenLiteralInt64(@intCast(cv.len)));
        },
        .binding => |b| {
            argvals[k * 2] = c.BinaryenLocalGet(module, b.ptr_local, i64_type);
            argvals[k * 2 + 1] = c.BinaryenLocalGet(module, b.len_local, i64_type);
        },
        // String call sites never carry integer args (those go through
        // print_int_callee, which builds its own operands).
        .int => unreachable,
    };
    return argvals;
}

/// Lower an integer-valued expression to a wasm `i64`. A path resolving to
/// a parameter becomes `local.get`; literals, `+ - * / % & | ^ << >>`,
/// unary `-`/`~`, and parentheses lower to the matching i64 ops.
fn emitIntExpr(
    module: c.BinaryenModuleRef,
    expr: ast.Expr,
    param_names: []const []const u8,
    i64_type: c.BinaryenType,
    allocator: std.mem.Allocator,
) Error!c.BinaryenExpressionRef {
    switch (expr) {
        .num_lit => |n| {
            const v = try parseIntLit(n.rawText() orelse return Error.NotConstExpr);
            return c.BinaryenConst(module, c.BinaryenLiteralInt64(v));
        },
        .paren => |p| return emitIntExpr(module, p.inner() orelse return Error.NotConstExpr, param_names, i64_type, allocator),
        .path => |p| {
            const txt = try p.text(allocator);
            defer allocator.free(txt);
            const idx = indexOfName(param_names, txt) orelse return Error.NotConstExpr;
            return c.BinaryenLocalGet(module, @intCast(idx), i64_type);
        },
        .unary => |u| {
            const x = try emitIntExpr(module, u.operand() orelse return Error.NotConstExpr, param_names, i64_type, allocator);
            const op = u.op() orelse return Error.NotConstExpr;
            return switch (op.kind) {
                .MINUS => c.BinaryenBinary(module, c.BinaryenSubInt64(), c.BinaryenConst(module, c.BinaryenLiteralInt64(0)), x),
                .TILDE => c.BinaryenBinary(module, c.BinaryenXorInt64(), x, c.BinaryenConst(module, c.BinaryenLiteralInt64(-1))),
                else => Error.NotConstExpr,
            };
        },
        .bin => |b| {
            const l = try emitIntExpr(module, b.lhs() orelse return Error.NotConstExpr, param_names, i64_type, allocator);
            const r = try emitIntExpr(module, b.rhs() orelse return Error.NotConstExpr, param_names, i64_type, allocator);
            const op = b.op() orelse return Error.NotConstExpr;
            const binop: c.BinaryenOp = switch (op.kind) {
                .PLUS => c.BinaryenAddInt64(),
                .MINUS => c.BinaryenSubInt64(),
                .STAR => c.BinaryenMulInt64(),
                .SLASH => c.BinaryenDivSInt64(),
                .PERCENT => c.BinaryenRemSInt64(),
                .AMP => c.BinaryenAndInt64(),
                .PIPE => c.BinaryenOrInt64(),
                .CARET => c.BinaryenXorInt64(),
                .SHL => c.BinaryenShlInt64(),
                .SHR => c.BinaryenShrSInt64(),
                else => return Error.NotConstExpr,
            };
            return c.BinaryenBinary(module, binop, l, r);
        },
        else => return Error.NotConstExpr,
    }
}

/// Emit `__fmt_i64(n: i64) -> (i64, i64)`: format `n` to decimal in the
/// scope arena, returning (ptr, len). Writes digits backward into a 24-byte
/// bump allocation, then prepends `-` for negatives.
fn emitFmtI64(module: c.BinaryenModuleRef, allocator: std.mem.Allocator, i64_type: c.BinaryenType, pair_type: c.BinaryenType) !void {
    const i32_type = c.BinaryenTypeInt32();
    const none = c.BinaryenTypeNone();
    // Locals: 0=n (param), 1=mag, 2=p, 3=end (i64); 4=neg (i32).
    const N: c.BinaryenIndex = 0;
    const MAG: c.BinaryenIndex = 1;
    const P: c.BinaryenIndex = 2;
    const END: c.BinaryenIndex = 3;
    const NEG: c.BinaryenIndex = 4;
    const k = struct {
        fn i64c(m: c.BinaryenModuleRef, v: i64) c.BinaryenExpressionRef {
            return c.BinaryenConst(m, c.BinaryenLiteralInt64(v));
        }
        fn get(m: c.BinaryenModuleRef, idx: c.BinaryenIndex, t: c.BinaryenType) c.BinaryenExpressionRef {
            return c.BinaryenLocalGet(m, idx, t);
        }
    };

    var stmts: std.ArrayList(c.BinaryenExpressionRef) = .empty;
    defer stmts.deinit(allocator);

    // neg = n < 0
    try stmts.append(allocator, c.BinaryenLocalSet(module, NEG, c.BinaryenBinary(module, c.BinaryenLtSInt64(), k.get(module, N, i64_type), k.i64c(module, 0))));
    // mag = neg ? -n : n
    try stmts.append(allocator, c.BinaryenLocalSet(module, MAG, c.BinaryenSelect(
        module,
        k.get(module, NEG, i32_type),
        c.BinaryenBinary(module, c.BinaryenSubInt64(), k.i64c(module, 0), k.get(module, N, i64_type)),
        k.get(module, N, i64_type),
    )));
    // end = sp + 24; sp = end; p = end
    try stmts.append(allocator, c.BinaryenLocalSet(module, END, c.BinaryenBinary(module, c.BinaryenAddInt64(), c.BinaryenGlobalGet(module, "sp", i64_type), k.i64c(module, 24))));
    try stmts.append(allocator, c.BinaryenGlobalSet(module, "sp", k.get(module, END, i64_type)));
    try stmts.append(allocator, c.BinaryenLocalSet(module, P, k.get(module, END, i64_type)));

    // loop: p--; mem[p] = '0' + mag%10; mag /= 10; repeat while mag != 0.
    var loop_body: std.ArrayList(c.BinaryenExpressionRef) = .empty;
    defer loop_body.deinit(allocator);
    try loop_body.append(allocator, c.BinaryenLocalSet(module, P, c.BinaryenBinary(module, c.BinaryenSubInt64(), k.get(module, P, i64_type), k.i64c(module, 1))));
    try loop_body.append(allocator, c.BinaryenStore(
        module,
        1,
        0,
        0,
        k.get(module, P, i64_type),
        c.BinaryenBinary(module, c.BinaryenAddInt64(), k.i64c(module, '0'), c.BinaryenBinary(module, c.BinaryenRemUInt64(), k.get(module, MAG, i64_type), k.i64c(module, 10))),
        i64_type,
        "0",
    ));
    try loop_body.append(allocator, c.BinaryenLocalSet(module, MAG, c.BinaryenBinary(module, c.BinaryenDivUInt64(), k.get(module, MAG, i64_type), k.i64c(module, 10))));
    try loop_body.append(allocator, c.BinaryenBreak(module, "fmt", c.BinaryenBinary(module, c.BinaryenNeInt64(), k.get(module, MAG, i64_type), k.i64c(module, 0)), null));
    const loop_block = c.BinaryenBlock(module, null, @ptrCast(loop_body.items.ptr), @intCast(loop_body.items.len), none);
    try stmts.append(allocator, c.BinaryenLoop(module, "fmt", loop_block));

    // if neg: p--; mem[p] = '-'
    var sign_body = [_]c.BinaryenExpressionRef{
        c.BinaryenLocalSet(module, P, c.BinaryenBinary(module, c.BinaryenSubInt64(), k.get(module, P, i64_type), k.i64c(module, 1))),
        c.BinaryenStore(module, 1, 0, 0, k.get(module, P, i64_type), k.i64c(module, '-'), i64_type, "0"),
    };
    const sign_block = c.BinaryenBlock(module, null, @ptrCast(&sign_body), sign_body.len, none);
    try stmts.append(allocator, c.BinaryenIf(module, k.get(module, NEG, i32_type), sign_block, null));

    // result = (p, end - p)
    var ret = [_]c.BinaryenExpressionRef{
        k.get(module, P, i64_type),
        c.BinaryenBinary(module, c.BinaryenSubInt64(), k.get(module, END, i64_type), k.get(module, P, i64_type)),
    };
    try stmts.append(allocator, c.BinaryenTupleMake(module, @ptrCast(&ret), ret.len));

    const body = c.BinaryenBlock(module, null, @ptrCast(stmts.items.ptr), @intCast(stmts.items.len), pair_type);
    var var_types = [_]c.BinaryenType{ i64_type, i64_type, i64_type, i32_type };
    _ = c.BinaryenAddFunction(module, "__fmt_i64", i64_type, pair_type, @ptrCast(&var_types), var_types.len, body);
}

/// Append the arena-concatenation of `segs` to `exprs`, leaving the result
/// pointer in local `loc.buf` and its length in local `loc.len`.
/// Bump-allocates from the `sp` global. `call` segments are invoked into
/// tuple locals from `loc.tuple_base`; `param` segments read parameter
/// locals (2·idx, 2·idx+1); `const_run` segments come from static data.
fn appendConcat(
    allocator: std.mem.Allocator,
    module: c.BinaryenModuleRef,
    exprs: *std.ArrayList(c.BinaryenExpressionRef),
    segs: []const Segment,
    callees: []const Callee,
    pair_type: c.BinaryenType,
    i64_type: c.BinaryenType,
    loc: ConcatLocals,
) !void {
    // 1. Call each `call` segment into its tuple local.
    {
        var j: c.BinaryenIndex = 0;
        for (segs) |sg| switch (sg) {
            .call => |ci| {
                const result = c.BinaryenCall(module, callees[ci].name.ptr, null, 0, pair_type);
                try exprs.append(allocator, c.BinaryenLocalSet(module, loc.tuple_base + j, result));
                j += 1;
            },
            else => {},
        };
    }

    // 2. len = const total + dynamic (call / param) lengths.
    var const_total: u64 = 0;
    for (segs) |sg| switch (sg) {
        .const_run => |cr| const_total += cr.len,
        else => {},
    };
    var total = c.BinaryenConst(module, c.BinaryenLiteralInt64(@intCast(const_total)));
    {
        var j: c.BinaryenIndex = 0;
        for (segs) |sg| switch (sg) {
            .call => {
                const lenj = c.BinaryenTupleExtract(module, c.BinaryenLocalGet(module, loc.tuple_base + j, pair_type), 1);
                total = c.BinaryenBinary(module, c.BinaryenAddInt64(), total, lenj);
                j += 1;
            },
            .param => |idx| {
                const lenp = c.BinaryenLocalGet(module, @intCast(idx * 2 + 1), i64_type);
                total = c.BinaryenBinary(module, c.BinaryenAddInt64(), total, lenp);
            },
            .binding => |b| {
                const lenb = c.BinaryenLocalGet(module, b.len_local, i64_type);
                total = c.BinaryenBinary(module, c.BinaryenAddInt64(), total, lenb);
            },
            .const_run => {},
        };
    }
    try exprs.append(allocator, c.BinaryenLocalSet(module, loc.len, total));

    // 3. buf = sp; sp += len  (bump-allocate from the arena).
    try exprs.append(allocator, c.BinaryenLocalSet(module, loc.buf, c.BinaryenGlobalGet(module, "sp", i64_type)));
    try exprs.append(allocator, c.BinaryenGlobalSet(module, "sp", c.BinaryenBinary(
        module,
        c.BinaryenAddInt64(),
        c.BinaryenLocalGet(module, loc.buf, i64_type),
        c.BinaryenLocalGet(module, loc.len, i64_type),
    )));

    // 4. off = buf; memory.copy each segment, bumping off.
    try exprs.append(allocator, c.BinaryenLocalSet(module, loc.off, c.BinaryenLocalGet(module, loc.buf, i64_type)));
    {
        var j: c.BinaryenIndex = 0;
        for (segs) |sg| {
            var src: c.BinaryenExpressionRef = undefined;
            var ln: c.BinaryenExpressionRef = undefined;
            var ln_again: c.BinaryenExpressionRef = undefined;
            switch (sg) {
                .const_run => |cr| {
                    src = c.BinaryenConst(module, c.BinaryenLiteralInt64(@intCast(cr.off)));
                    ln = c.BinaryenConst(module, c.BinaryenLiteralInt64(@intCast(cr.len)));
                    ln_again = c.BinaryenConst(module, c.BinaryenLiteralInt64(@intCast(cr.len)));
                },
                .call => {
                    src = c.BinaryenTupleExtract(module, c.BinaryenLocalGet(module, loc.tuple_base + j, pair_type), 0);
                    ln = c.BinaryenTupleExtract(module, c.BinaryenLocalGet(module, loc.tuple_base + j, pair_type), 1);
                    ln_again = c.BinaryenTupleExtract(module, c.BinaryenLocalGet(module, loc.tuple_base + j, pair_type), 1);
                    j += 1;
                },
                .param => |idx| {
                    src = c.BinaryenLocalGet(module, @intCast(idx * 2), i64_type);
                    ln = c.BinaryenLocalGet(module, @intCast(idx * 2 + 1), i64_type);
                    ln_again = c.BinaryenLocalGet(module, @intCast(idx * 2 + 1), i64_type);
                },
                .binding => |b| {
                    src = c.BinaryenLocalGet(module, b.ptr_local, i64_type);
                    ln = c.BinaryenLocalGet(module, b.len_local, i64_type);
                    ln_again = c.BinaryenLocalGet(module, b.len_local, i64_type);
                },
            }
            try exprs.append(allocator, c.BinaryenMemoryCopy(
                module,
                c.BinaryenLocalGet(module, loc.off, i64_type),
                src,
                ln,
                "0",
                "0",
            ));
            try exprs.append(allocator, c.BinaryenLocalSet(module, loc.off, c.BinaryenBinary(
                module,
                c.BinaryenAddInt64(),
                c.BinaryenLocalGet(module, loc.off, i64_type),
                ln_again,
            )));
        }
    }
}

fn emitModule(
    allocator: std.mem.Allocator,
    data: []const u8,
    actions: []const Action,
    callees: []const Callee,
    segments: []const Segment,
    call_args: []const ArgVal,
    n_rt_bindings: u32,
) ![]u8 {
    const module = c.BinaryenModuleCreate() orelse return Error.ModuleCreate;
    defer c.BinaryenModuleDispose(module);

    // q64 is 64-bit: Memory64 linear memory with i64 pointers (spec/
    // memory.md §"The platform"). The string-return ABI is a `(i64, i64)`
    // (ptr, len) multi-value return with a tuple local at the call site
    // (Multivalue + Memory64); arena concatenation uses memory.copy
    // (BulkMemory).
    c.BinaryenModuleSetFeatures(
        module,
        c.BinaryenFeatureMultivalue() | c.BinaryenFeatureMemory64() |
            c.BinaryenFeatureBulkMemory() | c.BinaryenFeatureBulkMemoryOpt(),
    );

    const i64_type = c.BinaryenTypeInt64();
    const none_type = c.BinaryenTypeNone();
    var pair = [_]c.BinaryenType{ i64_type, i64_type };
    const pair_type = c.BinaryenTypeCreate(&pair, pair.len);

    var env_out_params = [_]c.BinaryenType{ i64_type, i64_type };
    const env_out_params_type = c.BinaryenTypeCreate(&env_out_params, env_out_params.len);
    c.BinaryenAddFunctionImport(module, "env_out", "env", "out", env_out_params_type, none_type);

    // One active data segment at offset 0 holds the whole memory image.
    // The offset is an i64 const because the memory is 64-bit.
    if (data.len == 0) {
        c.BinaryenSetMemory(module, 1, 1, "memory", null, null, null, null, null, 0, false, true, "0");
    } else {
        var seg_datas = [_][*c]const u8{data.ptr};
        var seg_passives = [_]bool{false};
        var seg_offsets = [_]c.BinaryenExpressionRef{
            c.BinaryenConst(module, c.BinaryenLiteralInt64(0)),
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
            true,
            "0",
        );
    }

    // Local layout for `_start`:
    //   [0 .. 2·nb-1]            : runtime-binding i64 locals (ptr, len).
    //   [tuple_base .. +nt-1]    : transient tuple locals (call results).
    //   buf / off / len          : i64 scratch, present only with a concat.
    const rt_locals: c.BinaryenIndex = @intCast(n_rt_bindings * 2);
    const tuple_base: c.BinaryenIndex = rt_locals;
    var n_tuples: usize = 0;
    var has_concat = false;
    var needs_fmt = false;
    for (actions) |a| switch (a) {
        .print_callee, .bind_call, .print_int_callee => {
            if (n_tuples < 1) n_tuples = 1;
            switch (a) {
                .print_int_callee => needs_fmt = true,
                else => {},
            }
        },
        .print_concat => |p| {
            has_concat = true;
            var calls: usize = 0;
            for (segments[p.first .. p.first + p.count]) |sg| switch (sg) {
                .call => calls += 1,
                .const_run, .param, .binding => {},
            };
            if (calls > n_tuples) n_tuples = calls;
        },
        .print_const, .print_binding => {},
    };
    // A concat body, or the int formatter (which bump-allocates), needs the
    // `sp` arena global.
    for (callees) |cl| switch (cl.body) {
        .concat => has_concat = true,
        .const_str, .param_ref, .int_fn => {},
    };
    if (needs_fmt) has_concat = true;

    const buf_idx: c.BinaryenIndex = @intCast(rt_locals + n_tuples);
    const off_idx: c.BinaryenIndex = @intCast(rt_locals + n_tuples + 1);
    const len_idx: c.BinaryenIndex = @intCast(rt_locals + n_tuples + 2);

    // The scope arena: a bump pointer (`sp`) starting just past the static
    // data. Each concat allocates from it; no reclamation in v0 (the
    // program is a single `_start` run). spec/memory.md §"Region kinds" —
    // the implicit `scope` Arena. Added before the callees so their concat
    // bodies can reference it.
    if (has_concat) {
        _ = c.BinaryenAddGlobal(
            module,
            "sp",
            i64_type,
            true, // mutable
            c.BinaryenConst(module, c.BinaryenLiteralInt64(@intCast(data.len))),
        );
    }

    // Emit each callee as `(i64×2·params) -> (i64, i64)`. A const body
    // returns its fixed (off, len); a passthrough body returns the
    // (ptr, len) of the parameter it names (locals 2·idx, 2·idx+1); a
    // concat body builds its result in the arena and returns (buf, len).
    for (callees) |callee| {
        // i64-returning functions: `(i64×params) -> i64`, body is real
        // arithmetic lowered from the source expression.
        switch (callee.body) {
            .int_fn => |fd| {
                var pnames: std.ArrayList([]const u8) = .empty;
                defer pnames.deinit(allocator);
                if (fd.params()) |ps| {
                    var it = ps.iter();
                    while (it.next()) |p| {
                        try pnames.append(allocator, (p.name() orelse return Error.UnsupportedCall).text);
                    }
                }
                var iparams: []c.BinaryenType = &.{};
                var iptype = none_type;
                if (pnames.items.len > 0) {
                    iparams = try allocator.alloc(c.BinaryenType, pnames.items.len);
                    for (iparams) |*x| x.* = i64_type;
                    iptype = c.BinaryenTypeCreate(iparams.ptr, @intCast(iparams.len));
                }
                defer if (iparams.len > 0) allocator.free(iparams);
                const ve = bodyValueExpr(fd) orelse return Error.UnsupportedCall;
                const ibody = try emitIntExpr(module, ve, pnames.items, i64_type, allocator);
                _ = c.BinaryenAddFunction(module, callee.name.ptr, iptype, i64_type, null, 0, ibody);
                continue;
            },
            else => {},
        }

        var params_type = none_type;
        var pbuf: []c.BinaryenType = &.{};
        if (callee.n_params > 0) {
            pbuf = try allocator.alloc(c.BinaryenType, callee.n_params * 2);
            for (pbuf) |*x| x.* = i64_type;
            params_type = c.BinaryenTypeCreate(pbuf.ptr, @intCast(pbuf.len));
        }
        defer if (pbuf.len > 0) allocator.free(pbuf);

        var body_expr: c.BinaryenExpressionRef = undefined;
        var n_vt: usize = 0;
        var scratch3 = [_]c.BinaryenType{ i64_type, i64_type, i64_type };
        switch (callee.body) {
            .const_str => |cs| {
                var elems = [_]c.BinaryenExpressionRef{
                    c.BinaryenConst(module, c.BinaryenLiteralInt64(@intCast(cs.off))),
                    c.BinaryenConst(module, c.BinaryenLiteralInt64(@intCast(cs.len))),
                };
                body_expr = c.BinaryenTupleMake(module, @ptrCast(&elems), elems.len);
            },
            .param_ref => |idx| {
                var elems = [_]c.BinaryenExpressionRef{
                    c.BinaryenLocalGet(module, @intCast(idx * 2), i64_type),
                    c.BinaryenLocalGet(module, @intCast(idx * 2 + 1), i64_type),
                };
                body_expr = c.BinaryenTupleMake(module, @ptrCast(&elems), elems.len);
            },
            .concat => |cc| {
                const np = callee.n_params;
                var body_exprs: std.ArrayList(c.BinaryenExpressionRef) = .empty;
                defer body_exprs.deinit(allocator);
                const loc = ConcatLocals{
                    .buf = @intCast(np * 2),
                    .off = @intCast(np * 2 + 1),
                    .len = @intCast(np * 2 + 2),
                    .tuple_base = 0, // callee bodies have no call segments in v0
                };
                try appendConcat(allocator, module, &body_exprs, segments[cc.first .. cc.first + cc.count], callees, pair_type, i64_type, loc);
                var ret_elems = [_]c.BinaryenExpressionRef{
                    c.BinaryenLocalGet(module, loc.buf, i64_type),
                    c.BinaryenLocalGet(module, loc.len, i64_type),
                };
                try body_exprs.append(allocator, c.BinaryenTupleMake(module, @ptrCast(&ret_elems), ret_elems.len));
                body_expr = c.BinaryenBlock(module, null, @ptrCast(body_exprs.items.ptr), @intCast(body_exprs.items.len), pair_type);
                n_vt = 3;
            },
            .int_fn => unreachable, // handled above
        }
        _ = c.BinaryenAddFunction(
            module,
            callee.name.ptr,
            params_type,
            pair_type,
            if (n_vt > 0) @ptrCast(&scratch3) else null,
            @intCast(n_vt),
            body_expr,
        );
    }

    if (needs_fmt) try emitFmtI64(module, allocator, i64_type, pair_type);

    var exprs: std.ArrayList(c.BinaryenExpressionRef) = .empty;
    defer exprs.deinit(allocator);

    for (actions) |action| switch (action) {
        .print_const => |p| {
            var cargs = [_]c.BinaryenExpressionRef{
                c.BinaryenConst(module, c.BinaryenLiteralInt64(@intCast(p.off))),
                c.BinaryenConst(module, c.BinaryenLiteralInt64(@intCast(p.len))),
            };
            try exprs.append(allocator, c.BinaryenCall(module, "env_out", @ptrCast(&cargs), cargs.len, none_type));
        },
        .print_callee => |p| {
            const argvals = try buildArgs(allocator, module, call_args, p.args_first, p.args_count, i64_type);
            defer allocator.free(argvals);
            const result = c.BinaryenCall(
                module,
                callees[p.callee].name.ptr,
                if (argvals.len > 0) argvals.ptr else null,
                @intCast(argvals.len),
                pair_type,
            );
            try exprs.append(allocator, c.BinaryenLocalSet(module, tuple_base, result));
            var cargs = [_]c.BinaryenExpressionRef{
                c.BinaryenTupleExtract(module, c.BinaryenLocalGet(module, tuple_base, pair_type), 0),
                c.BinaryenTupleExtract(module, c.BinaryenLocalGet(module, tuple_base, pair_type), 1),
            };
            try exprs.append(allocator, c.BinaryenCall(module, "env_out", @ptrCast(&cargs), cargs.len, none_type));
            var nargs = [_]c.BinaryenExpressionRef{
                c.BinaryenConst(module, c.BinaryenLiteralInt64(@intCast(p.nl_off))),
                c.BinaryenConst(module, c.BinaryenLiteralInt64(1)),
            };
            try exprs.append(allocator, c.BinaryenCall(module, "env_out", @ptrCast(&nargs), nargs.len, none_type));
        },
        .print_concat => |p| {
            const loc = ConcatLocals{ .buf = buf_idx, .off = off_idx, .len = len_idx, .tuple_base = tuple_base };
            try appendConcat(allocator, module, &exprs, segments[p.first .. p.first + p.count], callees, pair_type, i64_type, loc);
            // Write the assembled string, then the trailing newline.
            var cargs = [_]c.BinaryenExpressionRef{
                c.BinaryenLocalGet(module, buf_idx, i64_type),
                c.BinaryenLocalGet(module, len_idx, i64_type),
            };
            try exprs.append(allocator, c.BinaryenCall(module, "env_out", @ptrCast(&cargs), cargs.len, none_type));
            var nargs = [_]c.BinaryenExpressionRef{
                c.BinaryenConst(module, c.BinaryenLiteralInt64(@intCast(p.nl_off))),
                c.BinaryenConst(module, c.BinaryenLiteralInt64(1)),
            };
            try exprs.append(allocator, c.BinaryenCall(module, "env_out", @ptrCast(&nargs), nargs.len, none_type));
        },
        .print_binding => |p| {
            var cargs = [_]c.BinaryenExpressionRef{
                c.BinaryenLocalGet(module, p.binding.ptr_local, i64_type),
                c.BinaryenLocalGet(module, p.binding.len_local, i64_type),
            };
            try exprs.append(allocator, c.BinaryenCall(module, "env_out", @ptrCast(&cargs), cargs.len, none_type));
            var nargs = [_]c.BinaryenExpressionRef{
                c.BinaryenConst(module, c.BinaryenLiteralInt64(@intCast(p.nl_off))),
                c.BinaryenConst(module, c.BinaryenLiteralInt64(1)),
            };
            try exprs.append(allocator, c.BinaryenCall(module, "env_out", @ptrCast(&nargs), nargs.len, none_type));
        },
        .bind_call => |p| {
            const argvals = try buildArgs(allocator, module, call_args, p.args_first, p.args_count, i64_type);
            defer allocator.free(argvals);
            const result = c.BinaryenCall(
                module,
                callees[p.callee].name.ptr,
                if (argvals.len > 0) argvals.ptr else null,
                @intCast(argvals.len),
                pair_type,
            );
            try exprs.append(allocator, c.BinaryenLocalSet(module, tuple_base, result));
            try exprs.append(allocator, c.BinaryenLocalSet(module, p.binding.ptr_local, c.BinaryenTupleExtract(module, c.BinaryenLocalGet(module, tuple_base, pair_type), 0)));
            try exprs.append(allocator, c.BinaryenLocalSet(module, p.binding.len_local, c.BinaryenTupleExtract(module, c.BinaryenLocalGet(module, tuple_base, pair_type), 1)));
        },
        .print_int_callee => |p| {
            // Pass each i64 arg, call the function, format the result.
            const argvals = try allocator.alloc(c.BinaryenExpressionRef, p.args_count);
            defer allocator.free(argvals);
            for (0..p.args_count) |kk| {
                argvals[kk] = c.BinaryenConst(module, c.BinaryenLiteralInt64(call_args[p.args_first + kk].int));
            }
            var fmt_args = [_]c.BinaryenExpressionRef{c.BinaryenCall(
                module,
                callees[p.callee].name.ptr,
                if (argvals.len > 0) argvals.ptr else null,
                @intCast(argvals.len),
                i64_type,
            )};
            const fmt = c.BinaryenCall(module, "__fmt_i64", @ptrCast(&fmt_args), fmt_args.len, pair_type);
            try exprs.append(allocator, c.BinaryenLocalSet(module, tuple_base, fmt));
            var cargs = [_]c.BinaryenExpressionRef{
                c.BinaryenTupleExtract(module, c.BinaryenLocalGet(module, tuple_base, pair_type), 0),
                c.BinaryenTupleExtract(module, c.BinaryenLocalGet(module, tuple_base, pair_type), 1),
            };
            try exprs.append(allocator, c.BinaryenCall(module, "env_out", @ptrCast(&cargs), cargs.len, none_type));
            var nargs = [_]c.BinaryenExpressionRef{
                c.BinaryenConst(module, c.BinaryenLiteralInt64(@intCast(p.nl_off))),
                c.BinaryenConst(module, c.BinaryenLiteralInt64(1)),
            };
            try exprs.append(allocator, c.BinaryenCall(module, "env_out", @ptrCast(&nargs), nargs.len, none_type));
        },
    };

    const body_expr: c.BinaryenExpressionRef = if (exprs.items.len == 1)
        exprs.items[0]
    else
        c.BinaryenBlock(module, null, @ptrCast(exprs.items.ptr), @intCast(exprs.items.len), none_type);

    // Declare _start's locals, matching the layout above:
    //   2·nb i64 binding locals, then n_tuples tuple locals, then (with a
    //   concat) 3 i64 scratch.
    const nb: usize = n_rt_bindings * 2;
    const n_scratch: usize = if (has_concat) 3 else 0;
    const n_vars = nb + n_tuples + n_scratch;
    const var_types = try allocator.alloc(c.BinaryenType, n_vars);
    defer allocator.free(var_types);
    for (0..nb) |k| var_types[k] = i64_type;
    for (0..n_tuples) |k| var_types[nb + k] = pair_type;
    if (has_concat) {
        var_types[nb + n_tuples] = i64_type;
        var_types[nb + n_tuples + 1] = i64_type;
        var_types[nb + n_tuples + 2] = i64_type;
    }
    const vt: [*c]c.BinaryenType = if (n_vars > 0) var_types.ptr else null;
    _ = c.BinaryenAddFunction(
        module,
        "start",
        none_type,
        none_type,
        vt,
        @intCast(n_vars),
        body_expr,
    );
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
    const bytes = try emitFromSource(testing.allocator, src, "hello.q", &.{});
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
    const bytes = try emitFromSource(testing.allocator, src, "two.q", &.{});
    defer testing.allocator.free(bytes);

    try testing.expectEqualSlices(u8, "\x00asm", bytes[0..4]);
    try testing.expect(std.mem.indexOf(u8, bytes, "one\n") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "two\n") != null);
}

test "emitFromSource: missing main returns NoMainFunction" {
    const src = "fn helper { env.out(\"x\") }\n";
    try testing.expectError(
        Error.NoMainFunction,
        emitFromSource(testing.allocator, src, "no-main.q", &.{}),
    );
}

test "emitFromSource: non-env.out callee returns UnsupportedCall" {
    const src = "fn main { other.write(\"x\") }\n";
    try testing.expectError(
        Error.UnsupportedCall,
        emitFromSource(testing.allocator, src, "bad.q", &.{}),
    );
}

// ---------------------------------------------------------------------
// Linking: imports, const-evaluation, interpolation (ladder 0,3,5,6)
// ---------------------------------------------------------------------

test "emitFromSource: resolves a cross-module call inside interpolation" {
    // The definition of done: hello_app prints 0.1.0 by calling
    // hello_world.version().
    const lib = "//! dev.q64.hello_world\npub fn version() -> str { \"0.1.0\" }\n";
    const app =
        \\import dev.q64.hello_world.{version}
        \\
        \\fn main {
        \\    env.out("{version()}")
        \\}
        \\
    ;
    const modules = [_]ModuleSource{.{ .name = "dev.q64.hello_world", .source = lib }};
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &modules);
    defer testing.allocator.free(bytes);

    try testing.expectEqualSlices(u8, "\x00asm", bytes[0..4]);
    // A lone `{call}` interpolation is a single-segment concat: the
    // callee's "0.1.0" plus the shared newline are adjacent in the data
    // segment, assembled in the arena at runtime.
    try testing.expect(std.mem.indexOf(u8, bytes, "0.1.0\n") != null);
}

test "emitFromSource: interpolation with literal text concatenates at runtime" {
    // `"v{version()}!"` is built in the scope arena from three segments —
    // the assembled "v0.1.0!" exists only at runtime, so the binary holds
    // the pieces separately, not the joined string. Behavior is covered
    // end-to-end by scripts/link-roundtrip.sh.
    const lib = "pub fn version() -> str { \"0.1.0\" }\n";
    const app = "import dev.q64.hw.{version}\nfn main { env.out(\"v{version()}!\") }\n";
    const modules = [_]ModuleSource{.{ .name = "dev.q64.hw", .source = lib }};
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &modules);
    defer testing.allocator.free(bytes);

    try testing.expectEqualSlices(u8, "\x00asm", bytes[0..4]);
    // The pieces are present; the joined form is not baked in.
    try testing.expect(std.mem.indexOf(u8, bytes, "0.1.0") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "v0.1.0!") == null);
}

test "emitFromSource: a local function is callable inside interpolation" {
    const app = "fn version { \"9.9.9\" }\nfn main { env.out(\"{version()}\") }\n";
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &.{});
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "9.9.9\n") != null);
}

test "emitFromSource: a const fn bodied with `return` folds" {
    // `return <expr>` now surfaces through ast.Stmt, so the resolver
    // folds it the same as a tail-expression body.
    const lib = "pub fn version() -> str { return \"2.0.0\" }\n";
    const app = "import dev.q64.hw.{version}\nfn main { env.out(\"{version()}\") }\n";
    const modules = [_]ModuleSource{.{ .name = "dev.q64.hw", .source = lib }};
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &modules);
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "2.0.0\n") != null);
}

test "emitFromSource: env.out(version()) emits a real (non-folded) call" {
    // `env.out(version())` emits `version` as a real `() -> (i64, i64)`
    // function and calls it at runtime. Validation here proves the
    // multi-value module is well-formed (the ABI + Multivalue feature);
    // behavior is covered end-to-end by scripts/link-roundtrip.sh.
    const lib = "pub fn version() -> str { \"0.1.0\" }\n";
    const app =
        \\import dev.q64.hello_world.{version}
        \\
        \\fn main {
        \\    env.out(version())
        \\}
        \\
    ;
    const modules = [_]ModuleSource{.{ .name = "dev.q64.hello_world", .source = lib }};
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &modules);
    defer testing.allocator.free(bytes);

    try testing.expectEqualSlices(u8, "\x00asm", bytes[0..4]);
    try testing.expect(std.mem.indexOf(u8, bytes, "0.1.0") != null);
}

test "emitFromSource: env.out of an unknown function errors" {
    const app = "fn main { env.out(mystery()) }\n";
    try testing.expectError(
        Error.NameNotFound,
        emitFromSource(testing.allocator, app, "main.q", &.{}),
    );
}

test "emitFromSource: a string parameter is passed and returned (passthrough)" {
    // `id(s)` takes a str (lowered to two i64 params) and returns it; the
    // caller passes the literal "hi". Behavior is covered end-to-end by
    // scripts/link-roundtrip.sh.
    const lib = "pub fn id(s: str) -> str { s }\n";
    const app = "import dev.q64.s.{id}\nfn main { env.out(id(\"hi\")) }\n";
    const modules = [_]ModuleSource{.{ .name = "dev.q64.s", .source = lib }};
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &modules);
    defer testing.allocator.free(bytes);

    try testing.expectEqualSlices(u8, "\x00asm", bytes[0..4]);
    try testing.expect(std.mem.indexOf(u8, bytes, "hi") != null);
}

test "emitFromSource: wrong argument count errors" {
    const lib = "pub fn id(s: str) -> str { s }\n";
    const app = "import dev.q64.s.{id}\nfn main { env.out(id()) }\n";
    const modules = [_]ModuleSource{.{ .name = "dev.q64.s", .source = lib }};
    try testing.expectError(
        Error.UnsupportedCall,
        emitFromSource(testing.allocator, app, "main.q", &modules),
    );
}

test "emitFromSource: a parameterized body transforms its argument" {
    // `shout(s)` interpolates its parameter (`"{s}!"`); the body is built
    // in the arena from a param segment + the literal "!". The assembled
    // "hi!" exists only at runtime; behavior is covered by
    // scripts/link-roundtrip.sh.
    const lib = "pub fn shout(s: str) -> str { \"{s}!\" }\n";
    const app = "import dev.q64.s.{shout}\nfn main { env.out(shout(\"hi\")) }\n";
    const modules = [_]ModuleSource{.{ .name = "dev.q64.s", .source = lib }};
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &modules);
    defer testing.allocator.free(bytes);

    try testing.expectEqualSlices(u8, "\x00asm", bytes[0..4]);
    try testing.expect(std.mem.indexOf(u8, bytes, "hi") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "!") != null);
    // The joined result is assembled at runtime, not baked into the binary.
    try testing.expect(std.mem.indexOf(u8, bytes, "hi!") == null);
}

test "emitFromSource: a multi-parameter body joins its arguments" {
    // Two str params (four i64 wasm params); the body interpolates both.
    const lib = "pub fn join(a: str, b: str) -> str { \"{a}-{b}\" }\n";
    const app = "import dev.q64.s.{join}\nfn main { env.out(join(\"x\", \"y\")) }\n";
    const modules = [_]ModuleSource{.{ .name = "dev.q64.s", .source = lib }};
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &modules);
    defer testing.allocator.free(bytes);

    try testing.expectEqualSlices(u8, "\x00asm", bytes[0..4]);
    try testing.expect(std.mem.indexOf(u8, bytes, "x") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "y") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "-") != null);
    // "x-y" is assembled in the arena at runtime, not contiguous in data.
    try testing.expect(std.mem.indexOf(u8, bytes, "x-y") == null);
}

test "emitFromSource: a const-foldable call argument composes" {
    // `shout(version())`: version() folds to "0.1.0" (the argument), which
    // shout then transforms to "0.1.0!" in the arena.
    const lib = "pub fn version() -> str { \"0.1.0\" }\npub fn shout(s: str) -> str { \"{s}!\" }\n";
    const app = "import dev.q64.s.{version, shout}\nfn main { env.out(shout(version())) }\n";
    const modules = [_]ModuleSource{.{ .name = "dev.q64.s", .source = lib }};
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &modules);
    defer testing.allocator.free(bytes);

    try testing.expectEqualSlices(u8, "\x00asm", bytes[0..4]);
    try testing.expect(std.mem.indexOf(u8, bytes, "0.1.0") != null);
}

test "emitFromSource: a let binding folds into interpolation" {
    const app = "fn main {\n    let name = \"world\"\n    env.out(\"Hello, {name}!\")\n}\n";
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &.{});
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "Hello, world!\n") != null);
}

test "emitFromSource: integer arithmetic folds at compile time" {
    const app = "fn main {\n    env.out(\"{2 + 3}\")\n    env.out(\"{(1 + 2) * 3}\")\n    env.out(\"{-5 + 8}\")\n}\n";
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &.{});
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "5\n") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "9\n") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "3\n") != null);
}

test "emitFromSource: an integer binding folds in arithmetic" {
    const app = "fn main {\n    let n = 6 * 7\n    env.out(\"{n + 1}\")\n}\n";
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &.{});
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "43\n") != null);
}

test "emitFromSource: division by zero isn't const-foldable" {
    const app = "fn main { env.out(\"{1 / 0}\") }\n";
    try testing.expectError(
        Error.NotConstExpr,
        emitFromSource(testing.allocator, app, "main.q", &.{}),
    );
}

test "emitFromSource: a runtime i64 function is called and formatted" {
    // `double(n) { n + n }` references a parameter, so it can't const-fold:
    // it's emitted as `(i64) -> i64`, called at runtime, and the result is
    // formatted by __fmt_i64. The value "42" never appears in the binary.
    const lib = "pub fn double(n: i64) -> i64 { n + n }\n";
    const app = "import dev.q64.m.{double}\nfn main { env.out(double(21)) }\n";
    const modules = [_]ModuleSource{.{ .name = "dev.q64.m", .source = lib }};
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &modules);
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, "\x00asm", bytes[0..4]);
    try testing.expect(std.mem.indexOf(u8, bytes, "42") == null);
}

test "emitFromSource: a multi-parameter i64 function" {
    const lib = "pub fn add(a: i64, b: i64) -> i64 { a + b }\n";
    const app = "import dev.q64.m.{add}\nfn main { env.out(add(40, 2)) }\n";
    const modules = [_]ModuleSource{.{ .name = "dev.q64.m", .source = lib }};
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &modules);
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, "\x00asm", bytes[0..4]);
}

test "emitFromSource: a binding can name a const call result, referenced directly" {
    const lib = "pub fn version() -> str { \"0.1.0\" }\n";
    const app = "import dev.q64.s.{version}\nfn main {\n    let v = version()\n    env.out(v)\n}\n";
    const modules = [_]ModuleSource{.{ .name = "dev.q64.s", .source = lib }};
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &modules);
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "0.1.0\n") != null);
}

test "emitFromSource: a runtime binding holds a call result, used in interpolation" {
    // `let g = shout("hi")` isn't const-foldable, so g binds the call's
    // (ptr, len) into `_start` locals; `"[{g}]"` then concatenates it at
    // runtime. The assembled string exists only at runtime.
    const lib = "pub fn shout(s: str) -> str { \"{s}!\" }\n";
    const app =
        \\import dev.q64.s.{shout}
        \\
        \\fn main {
        \\    let g = shout("hi")
        \\    env.out(g)
        \\    env.out("[{g}]")
        \\}
        \\
    ;
    const modules = [_]ModuleSource{.{ .name = "dev.q64.s", .source = lib }};
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &modules);
    defer testing.allocator.free(bytes);

    try testing.expectEqualSlices(u8, "\x00asm", bytes[0..4]);
    try testing.expect(std.mem.indexOf(u8, bytes, "hi") != null);
    // Neither the call result nor the `[…]`-wrapped form is baked in.
    try testing.expect(std.mem.indexOf(u8, bytes, "hi!") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "[hi!]") == null);
}

test "emitFromSource: a runtime binding can be passed as an argument" {
    // `wrap(g)` passes g's (ptr, len) locals as the argument — a runtime
    // argument, not a const-folded one.
    const lib = "pub fn shout(s: str) -> str { \"{s}!\" }\npub fn wrap(s: str) -> str { \"[{s}]\" }\n";
    const app =
        \\import dev.q64.s.{shout, wrap}
        \\
        \\fn main {
        \\    let g = shout("hi")
        \\    env.out(wrap(g))
        \\}
        \\
    ;
    const modules = [_]ModuleSource{.{ .name = "dev.q64.s", .source = lib }};
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &modules);
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, "\x00asm", bytes[0..4]);
    try testing.expect(std.mem.indexOf(u8, bytes, "[hi!]") == null); // built at runtime
}

test "emitFromSource: a nested runtime call argument is unsupported" {
    // `wrap(shout("yo"))` — the argument is itself a non-const call, not a
    // binding; bind it first (`let t = shout("yo"); wrap(t)`).
    const lib = "pub fn shout(s: str) -> str { \"{s}!\" }\npub fn wrap(s: str) -> str { \"[{s}]\" }\n";
    const app = "import dev.q64.s.{shout, wrap}\nfn main { env.out(wrap(shout(\"yo\"))) }\n";
    const modules = [_]ModuleSource{.{ .name = "dev.q64.s", .source = lib }};
    try testing.expectError(
        Error.NotConstExpr,
        emitFromSource(testing.allocator, app, "main.q", &modules),
    );
}

test "emitFromSource: doubled braces are literal, not interpolation" {
    const app = "fn main { env.out(\"{{not interp}}\") }\n";
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &.{});
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "{not interp}\n") != null);
}

test "emitFromSource: interpolating an unknown name errors (honest baseline)" {
    const app = "fn main { env.out(\"{mystery()}\") }\n";
    try testing.expectError(
        Error.NameNotFound,
        emitFromSource(testing.allocator, app, "main.q", &.{}),
    );
}

test "emitFromSource: an unresolved import errors (honest baseline)" {
    const app = "import dev.q64.absent.{version}\nfn main { env.out(\"hi\") }\n";
    try testing.expectError(
        Error.UnknownModule,
        emitFromSource(testing.allocator, app, "main.q", &.{}),
    );
}

test "emitFromSource: importing a name the module lacks errors" {
    const lib = "pub fn version() -> str { \"1.0\" }\n";
    const app = "import dev.q64.hw.{missing}\nfn main { env.out(\"hi\") }\n";
    const modules = [_]ModuleSource{.{ .name = "dev.q64.hw", .source = lib }};
    try testing.expectError(
        Error.NameNotFound,
        emitFromSource(testing.allocator, app, "main.q", &modules),
    );
}

test "emitFromSource: a relative import is unsupported in v0" {
    const app = "import \"./util.q\".{helper}\nfn main { env.out(\"hi\") }\n";
    try testing.expectError(
        Error.UnsupportedImport,
        emitFromSource(testing.allocator, app, "main.q", &.{}),
    );
}
