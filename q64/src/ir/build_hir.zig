//! AST → HIR builder (front boundary of the Q64 IR).
//!
//! Imports `parser` only — NEVER the Binaryen C API. Owns the semantic-but-
//! not-executable work: name resolution, (eventual) typing, const-folding,
//! and desugaring. The HIR→MIR `lower` pass takes it from here.
//!
//! Migration status: `tryBuild` returns `null` for any function shape it
//! cannot yet represent, so `codegen/emit.zig`'s router falls back to the
//! legacy AST→Binaryen path. v0 handles `fn main` whose body is a sequence
//! of `env.out("<constant string>")` calls (no interpolation). Each
//! migration phase teaches `tryBuild` one more construct and shrinks the
//! fallback surface, keeping the build green throughout.

const std = @import("std");
const parser = @import("parser");
const ast = parser.ast;
const hir = @import("hir.zig");

/// Build HIR for `sf`'s `fn main`, or return `null` if the function uses any
/// construct the IR path does not yet handle (the caller then uses the
/// legacy emitter). Errors are reserved for allocation failure.
pub fn tryBuild(gpa: std.mem.Allocator, sf: ast.SourceFile) std.mem.Allocator.Error!?hir.Module {
    const main_fn = findMain(sf) orelse return null;
    const body = main_fn.body() orelse return null;

    var mod = hir.Module.init(gpa);
    const a = mod.alloc();

    var stmts: std.ArrayList(*hir.Stmt) = .empty;
    // (no deinit: arena-owned)

    var it = body.statements();
    const ok = while (it.next()) |stmt| {
        const es = switch (stmt) {
            .expr_stmt => |x| x,
            else => break false,
        };
        const expr = es.expression() orelse break false;
        const call = switch (expr) {
            .call => |cc| cc,
            else => break false,
        };
        if (!isEnvOut(a, call)) break false;
        const arg = firstArg(call) orelse break false;
        const slit = switch (arg) {
            .string_lit => |sl| sl,
            else => break false,
        };
        const bytes = (try renderConstLiteral(a, slit)) orelse break false;

        const e = try a.create(hir.Expr);
        e.* = .{ .str_const = bytes };
        const st = try a.create(hir.Stmt);
        st.* = .{ .host_out = e };
        try stmts.append(a, st);
    } else true;

    if (!ok) {
        mod.deinit();
        return null;
    }

    const block = try a.create(hir.Stmt);
    block.* = .{ .block = try stmts.toOwnedSlice(a) };

    const fns = try a.alloc(hir.Func, 1);
    fns[0] = .{ .name = "main", .ret = .void, .body = block, .visibility = .public };
    mod.funcs = fns;
    mod.entry = 0;
    return mod;
}

fn findMain(sf: ast.SourceFile) ?ast.FnDecl {
    var it = sf.items();
    while (it.next()) |item| switch (item) {
        .fn_decl => |fd| {
            const name = fd.name() orelse continue;
            if (std.mem.eql(u8, name.text, "main")) return fd;
        },
        else => {},
    };
    return null;
}

/// True when `call`'s callee is exactly the `env.out` capability face.
fn isEnvOut(a: std.mem.Allocator, call: ast.CallExpr) bool {
    const callee = call.callee() orelse return false;
    const path = switch (callee) {
        .path => |p| p,
        else => return false,
    };
    const txt = path.text(a) catch return false;
    defer a.free(txt);
    return std.mem.eql(u8, txt, "env.out");
}

fn firstArg(call: ast.CallExpr) ?ast.Expr {
    var args = call.args();
    return args.next();
}

/// Decode a string literal to its constant bytes, mirroring the legacy
/// `Resolver.renderStringLit` for everything *except* interpolation: a `{`
/// that isn't `{{` means a dynamic value, so we return `null` to defer the
/// whole function to the legacy path. Raw strings, escapes, and `{{`/`}}`
/// literal braces are handled here. Returns `null` on a malformed literal
/// too, so the legacy path produces the diagnostic.
fn renderConstLiteral(a: std.mem.Allocator, s: ast.StringLit) std.mem.Allocator.Error!?[]u8 {
    const raw = s.rawText() orelse return null;

    // Raw string `r"…"` / `r#"…"#`: no escapes, no interpolation.
    if (raw.len >= 1 and raw[0] == 'r') {
        const open = std.mem.indexOfScalar(u8, raw, '"') orelse return null;
        const close = std.mem.lastIndexOfScalar(u8, raw, '"') orelse return null;
        if (close <= open) return null;
        return try a.dupe(u8, raw[open + 1 .. close]);
    }

    if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') return null;
    const inner = raw[1 .. raw.len - 1];

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);

    var i: usize = 0;
    while (i < inner.len) {
        const ch = inner[i];
        if (ch == '\\' and i + 1 < inner.len) {
            try out.append(a, decodeEscape(inner[i + 1]));
            i += 2;
            continue;
        }
        if (ch == '{') {
            if (i + 1 < inner.len and inner[i + 1] == '{') {
                try out.append(a, '{');
                i += 2;
                continue;
            }
            // A real interpolation — dynamic value, defer to legacy.
            out.deinit(a);
            return null;
        }
        if (ch == '}' and i + 1 < inner.len and inner[i + 1] == '}') {
            try out.append(a, '}');
            i += 2;
            continue;
        }
        try out.append(a, ch);
        i += 1;
    }
    return try out.toOwnedSlice(a);
}

fn decodeEscape(ch: u8) u8 {
    return switch (ch) {
        'n' => '\n',
        't' => '\t',
        'r' => '\r',
        '0' => 0,
        else => ch, // \\, \", \{, \} and unknowns pass through
    };
}

// ---------------------------------------------------------------------
// Tests (pure Zig — no Binaryen). Run via the `ir_tests` target.
// ---------------------------------------------------------------------
const testing = std.testing;
const print = @import("print.zig");

fn buildFromSource(gpa: std.mem.Allocator, source: []const u8) !?hir.Module {
    const pr = try parser.parse.parse(gpa, source, "<test>");
    defer pr.deinit(gpa);
    const sf = ast.SourceFile.cast(pr.root) orelse return null;
    return tryBuild(gpa, sf);
}

test "tryBuild: a main of env.out string literals builds HIR" {
    var mod = (try buildFromSource(testing.allocator, "fn main {\n env.out(\"one\")\n env.out(\"two\")\n}\n")) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();

    try testing.expect(mod.entry != null);
    try testing.expectEqual(@as(usize, 1), mod.funcs.len);
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "host_out \"one\"") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "host_out \"two\"") != null);
}

test "tryBuild: escapes are decoded into the constant" {
    var mod = (try buildFromSource(testing.allocator, "fn main {\n env.out(\"a\\tb\")\n}\n")) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "a\tb") != null);
}

test "tryBuild: interpolation defers to legacy (returns null)" {
    const r = try buildFromSource(testing.allocator, "fn main {\n env.out(\"v{x}\")\n}\n");
    try testing.expect(r == null);
}

test "tryBuild: a non-env.out call defers to legacy (returns null)" {
    const r = try buildFromSource(testing.allocator, "fn main {\n other.write(\"x\")\n}\n");
    try testing.expect(r == null);
}

test "tryBuild: a non-string argument defers to legacy (returns null)" {
    const r = try buildFromSource(testing.allocator, "fn main {\n env.out(version())\n}\n");
    try testing.expect(r == null);
}
