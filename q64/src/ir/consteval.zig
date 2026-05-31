//! Compile-time constant evaluation for the AST→HIR builder.
//!
//! Folds expressions to their constant string/integer value: string literals
//! (with `{expr}` interpolation), integer arithmetic, `let` bindings that name
//! a constant, and nullary calls to const-bodied functions (e.g.
//! `version() { "0.1.0" }`). Returns `error.NotConst` for anything that needs
//! a runtime value, so the builder can choose another lowering (an i64 call,
//! or a fall-back to the legacy emitter).
//!
//! Pure Zig (imports `parser` only). All results are allocated in the
//! builder's arena, so there is nothing to free.

const std = @import("std");
const parser = @import("parser");
const ast = parser.ast;
const parse = parser.parse;
const hir = @import("hir.zig");

/// `NotConst` — the expression needs a runtime value (a parameter, a runtime
/// binding, a real call), so the builder should pick another lowering.
/// `ConstArith` — the expression is *entirely constant* but arithmetically
/// invalid (divide/modulo by zero, overflow, out-of-range shift); it can never
/// have a value, so the builder surfaces it as an honest `NotConstExpr` error
/// rather than falling back.
pub const Error = error{ NotConst, ConstArith } || std.mem.Allocator.Error;

pub const Evaluator = struct {
    a: std.mem.Allocator, // arena
    resolver: hir.ModuleResolver,
    /// `let`/`var` bindings that hold a compile-time value (name → bytes).
    bindings: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Whether a (nullary, const-bodied) function call may be folded. Only a
    /// `let`-initializer enables this; a direct `env.out(f())` or a `{f()}`
    /// interpolation keeps `f()` a real runtime call (matching the existing
    /// "cross-module calls are real, not folded" behavior).
    fold_calls: bool = false,

    /// Bind `name` to a constant value (a later rebind just overwrites; the
    /// old value is left to the arena).
    pub fn bind(self: *Evaluator, name: []const u8, value: []const u8) std.mem.Allocator.Error!void {
        try self.bindings.put(self.a, name, value);
    }

    /// Evaluate `expr` to its constant string bytes (arena-owned).
    pub fn evalExpr(self: *Evaluator, expr: ast.Expr) Error![]const u8 {
        return switch (expr) {
            .string_lit => |s| self.renderStringLit(s),
            .num_lit => |n| self.a.dupe(u8, n.rawText() orelse return error.NotConst),
            .call => |cc| self.evalCall(cc),
            .path => |p| self.lookupBinding(p),
            .paren => |p| self.evalExpr(p.inner() orelse return error.NotConst),
            .bin, .unary => {
                const v = try self.evalInt(expr);
                return std.fmt.allocPrint(self.a, "{d}", .{v});
            },
            else => error.NotConst,
        };
    }

    pub fn evalInt(self: *Evaluator, expr: ast.Expr) Error!i64 {
        switch (expr) {
            .num_lit => |n| return parseIntLit(n.rawText() orelse return error.NotConst),
            .paren => |p| return self.evalInt(p.inner() orelse return error.NotConst),
            .path => |p| {
                const bytes = try self.lookupBinding(p);
                return parseIntLit(bytes);
            },
            .unary => |u| {
                const x = try self.evalInt(u.operand() orelse return error.NotConst);
                const op = u.op() orelse return error.NotConst;
                return switch (op.kind) {
                    .MINUS => std.math.negate(x) catch return error.ConstArith,
                    .TILDE => ~x,
                    .BANG => @as(i64, @intFromBool(x == 0)),
                    else => error.NotConst,
                };
            },
            .bin => |b| {
                const l = try self.evalInt(b.lhs() orelse return error.NotConst);
                const r = try self.evalInt(b.rhs() orelse return error.NotConst);
                const op = b.op() orelse return error.NotConst;
                return switch (op.kind) {
                    .PLUS => std.math.add(i64, l, r) catch error.ConstArith,
                    .MINUS => std.math.sub(i64, l, r) catch error.ConstArith,
                    .STAR => std.math.mul(i64, l, r) catch error.ConstArith,
                    .SLASH => if (r == 0) error.ConstArith else @divTrunc(l, r),
                    .PERCENT => if (r == 0) error.ConstArith else @rem(l, r),
                    .AMP => l & r,
                    .PIPE => l | r,
                    .CARET => l ^ r,
                    .SHL => if (r < 0 or r > 63) error.ConstArith else l << @intCast(r),
                    .SHR => if (r < 0 or r > 63) error.ConstArith else l >> @intCast(r),
                    else => error.NotConst,
                };
            },
            else => return error.NotConst,
        }
    }

    fn lookupBinding(self: *Evaluator, p: ast.PathExpr) Error![]const u8 {
        const name = try p.text(self.a);
        return self.bindings.get(name) orelse error.NotConst;
    }

    fn evalCall(self: *Evaluator, call: ast.CallExpr) Error![]const u8 {
        if (!self.fold_calls) return error.NotConst; // a real runtime call here
        const callee = call.callee() orelse return error.NotConst;
        const path = switch (callee) {
            .path => |p| p,
            else => return error.NotConst,
        };
        const name = try path.text(self.a);

        // v0 folds only nullary calls; arguments would need substitution.
        var args = call.args();
        if (args.next() != null) return error.NotConst;

        const fd = self.resolver.lookup(name) orelse return error.NotConst;
        return self.evalFn(fd);
    }

    fn evalFn(self: *Evaluator, fd: ast.FnDecl) Error![]const u8 {
        const body = fd.body() orelse return error.NotConst;
        var stmts = body.statements();
        var last: ?ast.Expr = null;
        while (stmts.next()) |stmt| switch (stmt) {
            .expr_stmt => |es| last = es.expression(),
            .return_stmt => |rs| last = rs.value(),
            else => {},
        };
        return self.evalExpr(last orelse return error.NotConst);
    }

    /// Decode a string literal, folding `{expr}` interpolations. `{{`/`}}` are
    /// literal braces; `\{`/`\}` escape a brace. A non-constant interpolation
    /// is `error.NotConst`.
    pub fn renderStringLit(self: *Evaluator, s: ast.StringLit) Error![]const u8 {
        const raw = s.rawText() orelse return error.NotConst;

        if (raw.len >= 1 and raw[0] == 'r') {
            const open = std.mem.indexOfScalar(u8, raw, '"') orelse return error.NotConst;
            const close = std.mem.lastIndexOfScalar(u8, raw, '"') orelse return error.NotConst;
            if (close <= open) return error.NotConst;
            return self.a.dupe(u8, raw[open + 1 .. close]);
        }

        if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') return error.NotConst;
        const inner = raw[1 .. raw.len - 1];

        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < inner.len) {
            const ch = inner[i];
            if (ch == '\\' and i + 1 < inner.len) {
                try out.append(self.a, decodeEscape(inner[i + 1]));
                i += 2;
                continue;
            }
            if (ch == '{') {
                if (i + 1 < inner.len and inner[i + 1] == '{') {
                    try out.append(self.a, '{');
                    i += 2;
                    continue;
                }
                const close = std.mem.indexOfScalarPos(u8, inner, i + 1, '}') orelse return error.NotConst;
                const value = try self.evalSource(inner[i + 1 .. close]);
                try out.appendSlice(self.a, value);
                i = close + 1;
                continue;
            }
            if (ch == '}' and i + 1 < inner.len and inner[i + 1] == '}') {
                try out.append(self.a, '}');
                i += 2;
                continue;
            }
            try out.append(self.a, ch);
            i += 1;
        }
        return out.toOwnedSlice(self.a);
    }

    fn evalSource(self: *Evaluator, source: []const u8) Error![]const u8 {
        const r = parse.parseExpression(self.a, source, "<interp>") catch return error.NotConst;
        const expr = ast.Expr.cast(r.root) orelse return error.NotConst;
        return self.evalExpr(expr);
    }
};

pub fn parseIntLit(raw: []const u8) Error!i64 {
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    for (raw) |ch| {
        if (ch == '_') continue;
        if (n >= buf.len) return error.NotConst;
        buf[n] = ch;
        n += 1;
    }
    return std.fmt.parseInt(i64, buf[0..n], 0) catch error.NotConst;
}

pub fn decodeEscape(ch: u8) u8 {
    return switch (ch) {
        'n' => '\n',
        't' => '\t',
        'r' => '\r',
        '0' => 0,
        else => ch,
    };
}
