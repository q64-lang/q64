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
    } else return Error.NoMainFunction;

    return emitFn(allocator, &resolver, main_fn);
}

fn emitFn(allocator: std.mem.Allocator, resolver: *Resolver, fd: ast.FnDecl) ![]u8 {
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
            try collectEnvOutPayload(allocator, resolver, call, &payloads);
        },
    };

    return emitModuleWithPayloads(allocator, payloads.items);
}

fn collectEnvOutPayload(
    allocator: std.mem.Allocator,
    resolver: *Resolver,
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

    // The argument is evaluated to its compile-time string value. For a
    // plain literal that is just the decoded bytes; for an interpolated
    // literal (`"{version()}"`) each `{expr}` is const-evaluated and
    // spliced in (ladder steps 5–6).
    const value = try resolver.constEvalExpr(first);
    defer allocator.free(value);

    // env.out("X") semantically writes "X\n" (spec/env.md §"Capability faces").
    var payload = try allocator.alloc(u8, value.len + 1);
    @memcpy(payload[0..value.len], value);
    payload[value.len] = '\n';
    try out_payloads.append(allocator, payload);
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

    fn init(allocator: std.mem.Allocator, modules: []const ModuleSource) Resolver {
        return .{
            .allocator = allocator,
            .modules = modules,
            .parsed = .empty,
            .symbols = .empty,
        };
    }

    fn deinit(self: *Resolver) void {
        for (self.parsed.items) |r| r.deinit(self.allocator);
        self.parsed.deinit(self.allocator);
        self.symbols.deinit(self.allocator);
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
            // A bare identifier or anything else isn't a constant we can
            // fold in v0.
            else => Error.NotConstExpr,
        };
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

fn findPublicFn(sf: ast.SourceFile, name: []const u8) ?ast.FnDecl {
    var it = sf.items();
    while (it.next()) |item| switch (item) {
        .fn_decl => |fd| {
            if (!fd.isPublic()) continue;
            const fn_name = fd.name() orelse continue;
            if (std.mem.eql(u8, fn_name.text, name)) return fd;
        },
    };
    return null;
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
    // The folded value lands in the data segment as "0.1.0\n".
    try testing.expect(std.mem.indexOf(u8, bytes, "0.1.0\n") != null);
}

test "emitFromSource: literal text around an interpolation is preserved" {
    const lib = "pub fn version() -> str { \"0.1.0\" }\n";
    const app = "import dev.q64.hw.{version}\nfn main { env.out(\"v{version()}!\") }\n";
    const modules = [_]ModuleSource{.{ .name = "dev.q64.hw", .source = lib }};
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &modules);
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "v0.1.0!\n") != null);
}

test "emitFromSource: a local const function folds without an import" {
    const app = "fn version { \"9.9.9\" }\nfn main { env.out(\"{version()}\") }\n";
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &.{});
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "9.9.9\n") != null);
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
