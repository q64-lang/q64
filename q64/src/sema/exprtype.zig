//! Expression typing at the scalar floor (sema rung A3, slice 2). Owns
//! the rules `ir/build_hir` previously hard-coded in `exprIsBool`:
//! literal typing, the boolean/arithmetic operator tables, paren/unary
//! recursion, call-return and local-binding lookups.
//!
//! The caller injects its environment (local types, callee return
//! types) through `Env` — the same callback pattern as
//! `hir.ModuleResolver` — because today the local scope lives in
//! `build_hir` (it is interwoven with wasm local-slot allocation).
//! When A3's final slice moves name lookup into sema, the callbacks
//! collapse into sema's own tables; the typing rules here don't change.
//!
//! Like the rest of sema's recording layers: this module decides types,
//! it does not emit diagnostics — A4's TYP wiring reads it.

const std = @import("std");
const parser = @import("parser");
const ast = parser.ast;
const cst = parser.cst;

/// The scalar floor (mirrors what codegen can represent today).
/// `unknown` is "not provable at this floor" — callers treat it as
/// not-bool / not-str rather than an error.
pub const ScalarType = enum {
    i64,
    f32,
    f64,
    bool,
    str,
    /// A provably sub-i64 integer (a `u8`…`i32` field read): storage-only
    /// in v0 — formattable and castable, but arithmetic on it is rejected
    /// until the spec pins narrow-overflow semantics.
    narrow_int,
    unknown,
};

/// Caller-injected lookups. Both return `null` for "not found / not
/// scalar"; `callRet` may allocate (signature lowering), hence the
/// error union.
pub const Env = struct {
    ctx: *anyopaque,
    /// Type of a bare name (local binding or parameter) in the current
    /// body scope.
    localType: *const fn (ctx: *anyopaque, name: []const u8) ?ScalarType,
    /// Scalar return type of a named callee. The call expression rides
    /// along so a generic callee (`fn twice<T>(x: T) -> T`) can type
    /// its return from the deciding argument.
    callRet: *const fn (ctx: *anyopaque, name: []const u8, call: ast.CallExpr) std.mem.Allocator.Error!?ScalarType,
    /// Type of a field/tuple-slot of a record-or-tuple-valued `base`
    /// expression (`expr.field`, `t.0`). `null` when `base` isn't a record
    /// the caller can resolve, or the field/slot isn't a scalar.
    fieldType: *const fn (ctx: *anyopaque, base: ast.Expr, field: []const u8) std.mem.Allocator.Error!?ScalarType,
};

/// Scalar type of `expr` under `env`. Total: anything outside the floor
/// is `.unknown`, never an error (allocation aside).
pub fn scalarOf(gpa: std.mem.Allocator, expr: ast.Expr, env: Env) std.mem.Allocator.Error!ScalarType {
    switch (expr) {
        .literal => |lit| {
            const t = lit.token() orelse return .unknown;
            return switch (t.kind) {
                .KW_TRUE, .KW_FALSE => .bool,
                else => .unknown, // `none` — optionals are beyond the floor
            };
        },
        .num_lit => |n| {
            // A FLOAT_LIT (`3.14`, `1e9`) is f64 at the floor; ints stay
            // the flexible i64 they were.
            const tok = n.token() orelse return .i64;
            return if (tok.kind == .FLOAT_LIT) .f64 else .i64;
        },
        .string_lit => return .str,
        .paren => |p| return scalarOf(gpa, p.inner() orelse return .unknown, env),
        .unary => |u| {
            const op = u.op() orelse return .unknown;
            return switch (op.kind) {
                .BANG => .bool,
                // `-x` keeps its operand's numeric type (f64 stays f64).
                .MINUS => switch (try scalarOf(gpa, u.operand() orelse return .i64, env)) {
                    .f64 => .f64,
                    .f32 => .f32,
                    else => .i64,
                },
                .TILDE => .i64,
                else => .unknown,
            };
        },
        .bin => |bx| {
            const op = bx.op() orelse return .unknown;
            if (boolOp(op.kind)) return .bool;
            if (intOp(op.kind)) {
                // Arithmetic keeps the operands' numeric type: either side
                // provably float makes the result that float (mixing is
                // rejected at the emit/check layers — typing stays total).
                const l = try scalarOf(gpa, bx.lhs() orelse return .i64, env);
                if (l == .f64 or l == .f32) return l;
                const r = try scalarOf(gpa, bx.rhs() orelse return .i64, env);
                if (r == .f64 or r == .f32) return r;
                return .i64;
            }
            return .unknown;
        },
        .call => |cc| {
            const callee = cc.callee() orelse return .unknown;
            const cpath = switch (callee) {
                .path => |p| p,
                else => return .unknown,
            };
            const name = cpath.text(gpa) catch return .unknown;
            defer gpa.free(name);
            return (try env.callRet(env.ctx, name, cc)) orelse .unknown;
        },
        .path => |p| {
            const name = p.text(gpa) catch return .unknown;
            defer gpa.free(name);
            return env.localType(env.ctx, name) orelse .unknown;
        },
        .index => |ix| {
            // `s[i]` — the unsigned byte of a str, an i64. Array element
            // typing lives with the caller's slot scope (its bridge).
            const base = ix.base() orelse return .unknown;
            if ((try scalarOf(gpa, base, env)) == .str) return .i64;
            return .unknown;
        },
        .method => |me| {
            // The str method floor (spec/types.md §Strings): contains /
            // starts_with → bool, index_of → i64, slice → str. Non-str
            // receivers (fit methods) are typed by the caller's bridge.
            const recv = me.receiver() orelse return .unknown;
            if ((try scalarOf(gpa, recv, env)) != .str) return .unknown;
            const mname = (me.method() orelse return .unknown).text;
            return strMethodType(mname) orelse .unknown;
        },
        .field => |fe| {
            // `expr.field` — a field of a record-valued expression. (`p.x` on a
            // bare binding parses as a dotted path, typed via `localType`.)
            const base = fe.base() orelse return .unknown;
            const f = fe.field() orelse return .unknown;
            return (try env.fieldType(env.ctx, base, f.text)) orelse .unknown;
        },
        .tuple_field => |tf| {
            // `t.0` — a tuple slot. The tuple is an anonymous record whose
            // fields are named by their index.
            const base = tf.base() orelse return .unknown;
            const idx = tf.index() orelse return .unknown;
            return (try env.fieldType(env.ctx, base, idx.text)) orelse .unknown;
        },
        else => return .unknown,
    }
}

/// The result type of a str method by name, or null for an unknown one.
pub fn strMethodType(name: []const u8) ?ScalarType {
    if (std.mem.eql(u8, name, "contains") or std.mem.eql(u8, name, "starts_with")) return .bool;
    if (std.mem.eql(u8, name, "index_of")) return .i64;
    if (std.mem.eql(u8, name, "slice")) return .str;
    return null;
}

/// Operators that produce a `bool` (comparisons + short-circuit logic),
/// per spec/types.md. Moved verbatim from build_hir's `isBoolOp`.
pub fn boolOp(k: cst.SyntaxKind) bool {
    return switch (k) {
        .EQ_EQ, .BANG_EQ, .L_ANGLE, .R_ANGLE, .LT_EQ, .GT_EQ, .AMP_AMP, .PIPE_PIPE => true,
        else => false,
    };
}

/// Operators that produce an integer at the floor.
pub fn intOp(k: cst.SyntaxKind) bool {
    return switch (k) {
        .PLUS, .MINUS, .STAR, .SLASH, .PERCENT, .AMP, .PIPE, .CARET, .SHL, .SHR => true,
        else => false,
    };
}

// =====================================================================
// Tests
// =====================================================================

const t_alloc = std.testing.allocator;
const parse = parser.parse;

/// Test env: `flag`/`n`/`s` are a bool/i64/str local; `pred`/`count`/
/// `greet` are bool/i64/str-returning callees.
const TestEnv = struct {
    fn localType(_: *anyopaque, name: []const u8) ?ScalarType {
        if (std.mem.eql(u8, name, "flag")) return .bool;
        if (std.mem.eql(u8, name, "n")) return .i64;
        if (std.mem.eql(u8, name, "s")) return .str;
        return null;
    }
    fn callRet(_: *anyopaque, name: []const u8, _: ast.CallExpr) std.mem.Allocator.Error!?ScalarType {
        if (std.mem.eql(u8, name, "pred")) return .bool;
        if (std.mem.eql(u8, name, "count")) return .i64;
        if (std.mem.eql(u8, name, "greet")) return .str;
        return null;
    }
    fn fieldType(_: *anyopaque, _: ast.Expr, _: []const u8) std.mem.Allocator.Error!?ScalarType {
        return null;
    }
    var dummy: u8 = 0;
    fn env() Env {
        return .{ .ctx = @ptrCast(&dummy), .localType = localType, .callRet = callRet, .fieldType = fieldType };
    }
};

/// Parse `src` as `fn t { env.out(<expr>) }` and type the call's argument.
fn typeOf(expr_src: []const u8) !ScalarType {
    const src = try std.fmt.allocPrint(t_alloc, "fn t {{ env.out({s}) }}\n", .{expr_src});
    defer t_alloc.free(src);
    const pr = try parse.parse(t_alloc, src, "t.q");
    defer pr.deinit(t_alloc);
    const sf = ast.SourceFile.cast(pr.root).?;
    var items = sf.items();
    const fd = while (items.next()) |item| switch (item) {
        .fn_decl => |f| break f,
        else => {},
    } else return error.TestExpectedItem;
    var stmts = (fd.body() orelse return error.TestExpectedItem).statements();
    const st = stmts.next() orelse return error.TestExpectedItem;
    const call = switch (switch (st) {
        .expr_stmt => |es| es.expression() orelse return error.TestExpectedItem,
        else => return error.TestExpectedItem,
    }) {
        .call => |c| c,
        else => return error.TestExpectedItem,
    };
    var args = call.args();
    const arg = args.next() orelse return error.TestExpectedItem;
    return scalarOf(t_alloc, arg, TestEnv.env());
}

test "scalarOf: literals, operators, unary" {
    try std.testing.expectEqual(ScalarType.bool, try typeOf("true"));
    try std.testing.expectEqual(ScalarType.bool, try typeOf("1 == 2"));
    try std.testing.expectEqual(ScalarType.bool, try typeOf("n > 0 && flag"));
    try std.testing.expectEqual(ScalarType.bool, try typeOf("!flag"));
    try std.testing.expectEqual(ScalarType.bool, try typeOf("(n < 3)"));
    try std.testing.expectEqual(ScalarType.i64, try typeOf("1 + 2"));
    try std.testing.expectEqual(ScalarType.i64, try typeOf("-n"));
    try std.testing.expectEqual(ScalarType.i64, try typeOf("42"));
    try std.testing.expectEqual(ScalarType.str, try typeOf("\"hi\""));
}

test "scalarOf: locals and callee returns through the env" {
    try std.testing.expectEqual(ScalarType.bool, try typeOf("flag"));
    try std.testing.expectEqual(ScalarType.i64, try typeOf("n"));
    try std.testing.expectEqual(ScalarType.str, try typeOf("s"));
    try std.testing.expectEqual(ScalarType.bool, try typeOf("pred(1)"));
    try std.testing.expectEqual(ScalarType.i64, try typeOf("count()"));
    try std.testing.expectEqual(ScalarType.str, try typeOf("greet(s)"));
    try std.testing.expectEqual(ScalarType.unknown, try typeOf("mystery(1)"));
    try std.testing.expectEqual(ScalarType.unknown, try typeOf("ghost"));
}
