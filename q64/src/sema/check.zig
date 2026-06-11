//! The sema check pass (ladder rung A4) — the first sema layer that
//! *emits* rather than records. Walks every function body with sema's
//! own typed scopes (params from the lowered signatures, `let` bindings
//! from their annotations or inferred initializers) and reports the
//! first two TYP diagnostics:
//!
//! - **TYP051** — an `if`/`while` condition whose type is provably an
//!   integer (`if 1`, `if n` with `n: i64`). Conditions require `bool`
//!   (spec/types.md §bool).
//! - **TYP042** — an arithmetic site mixing two *different* known
//!   numeric types (`i32 + i64`). No implicit conversion
//!   (spec/types.md §arithmetic).
//!
//! Honesty rules, in keeping with the floor: a check fires only on
//! *provable* types. Unknown stays silent — bare integer literals are
//! flexible (they adapt to context, so `a + 1` never mismatches),
//! unannotated bindings inherit their initializer's type or unknown,
//! calls resolve through this file's signatures only, and anything the
//! parser leaves unstructured types as unknown. NAM010 (unknown name)
//! stays *recorded-only* in resolve.zig: the corpus survey shows
//! systematic false positives until lambdas, `graph`/`channel` exprs,
//! named arguments, record-pattern fields, and the auto-prelude table
//! land.

const std = @import("std");
const parser = @import("parser");
const ast = parser.ast;
const cst = parser.cst;
const symbols = @import("symbols.zig");
const types = @import("types.zig");
const exprtype = @import("exprtype.zig");

pub const Diag = struct {
    code: []const u8,
    offset: u32,
};

/// What the body typer knows about a value.
const Info = union(enum) {
    /// A known type in the store.
    id: types.TypeId,
    /// A bare integer literal — flexible, adapts to context: counts as
    /// an integer for TYP051, never mismatches for TYP042.
    int_literal,
    unknown,
};

const Scope = struct {
    gpa: std.mem.Allocator,
    levels: std.ArrayList(std.StringHashMapUnmanaged(Info)) = .empty,

    fn push(self: *Scope) !void {
        try self.levels.append(self.gpa, .empty);
    }
    fn pop(self: *Scope) void {
        var lvl = &self.levels.items[self.levels.items.len - 1];
        var it = lvl.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        lvl.deinit(self.gpa);
        self.levels.items.len -= 1;
    }
    fn bind(self: *Scope, name: []const u8, info: Info) !void {
        var lvl = &self.levels.items[self.levels.items.len - 1];
        const gop = try lvl.getOrPut(self.gpa, name);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.gpa.dupe(u8, name);
        }
        gop.value_ptr.* = info; // rebind within a level: latest wins
    }
    fn find(self: *const Scope, name: []const u8) ?Info {
        var i = self.levels.items.len;
        while (i > 0) {
            i -= 1;
            if (self.levels.items[i].get(name)) |info| return info;
        }
        return null;
    }
    fn deinit(self: *Scope) void {
        while (self.levels.items.len > 0) self.pop();
        self.levels.deinit(self.gpa);
    }
};

const Checker = struct {
    gpa: std.mem.Allocator,
    store: *types.TypeStore,
    sigs: *const types.Signatures,
    scope: Scope,
    diags: *std.ArrayList(Diag),

    // -- typing ------------------------------------------------------

    fn builtinOf(c: *Checker, info: Info) ?types.Builtin {
        return switch (info) {
            .id => |id| switch (c.store.get(id)) {
                .builtin => |b| b,
                else => null,
            },
            else => null,
        };
    }

    fn isNumeric(b: types.Builtin) bool {
        return switch (b) {
            .bool, .str, .void => false,
            else => true,
        };
    }

    fn isInteger(b: types.Builtin) bool {
        return switch (b) {
            .f16, .f32, .f64, .bool, .str, .void => false,
            else => true,
        };
    }

    fn boolInfo(c: *Checker) !Info {
        return .{ .id = try c.store.intern(.{ .builtin = .bool }) };
    }

    /// Type `expr`, emitting TYP042 for mixed-numeric arithmetic found
    /// anywhere inside it.
    fn typeOf(c: *Checker, expr: ast.Expr) std.mem.Allocator.Error!Info {
        switch (expr) {
            .num_lit => return .int_literal,
            .string_lit => return .{ .id = try c.store.intern(.{ .builtin = .str }) },
            .literal => |lit| {
                const t = lit.token() orelse return .unknown;
                return switch (t.kind) {
                    .KW_TRUE, .KW_FALSE => try c.boolInfo(),
                    else => .unknown,
                };
            },
            .paren => |p| return c.typeOf(p.inner() orelse return .unknown),
            .unary => |u| {
                const inner = try c.typeOf(u.operand() orelse return .unknown);
                const op = u.op() orelse return .unknown;
                return switch (op.kind) {
                    .BANG => try c.boolInfo(),
                    .MINUS, .TILDE => inner,
                    else => .unknown,
                };
            },
            .bin => |bx| {
                const lhs = try c.typeOf(bx.lhs() orelse return .unknown);
                const rhs = try c.typeOf(bx.rhs() orelse return .unknown);
                const op = bx.op() orelse return .unknown;
                if (exprtype.boolOp(op.kind)) return try c.boolInfo();
                if (exprtype.intOp(op.kind)) {
                    // TYP042: both sides provably numeric and different.
                    if (c.builtinOf(lhs)) |lb| if (c.builtinOf(rhs)) |rb| {
                        if (isNumeric(lb) and isNumeric(rb) and lb != rb) {
                            try c.diags.append(c.gpa, .{ .code = "TYP042", .offset = op.offset });
                        }
                    };
                    // Result: a known side wins; two literals stay flexible.
                    if (c.builtinOf(lhs) != null) return lhs;
                    if (c.builtinOf(rhs) != null) return rhs;
                    if (lhs == .int_literal and rhs == .int_literal) return .int_literal;
                    return .unknown;
                }
                return .unknown;
            },
            .call => |cc| {
                // Type the arguments (a mismatch can hide inside).
                var args = cc.args();
                while (args.next()) |a| _ = try c.typeOf(a);
                const callee = cc.callee() orelse return .unknown;
                const cpath = switch (callee) {
                    .path => |p| p,
                    else => return .unknown,
                };
                const name = cpath.text(c.gpa) catch return .unknown;
                defer c.gpa.free(name);
                const sig = c.sigs.find(name) orelse return .unknown;
                return switch (c.store.get(sig.ret)) {
                    .unparsed, .unresolved => .unknown,
                    else => .{ .id = sig.ret },
                };
            },
            .path => |p| {
                const name = p.text(c.gpa) catch return .unknown;
                defer c.gpa.free(name);
                return c.scope.find(name) orelse .unknown;
            },
            else => return .unknown,
        }
    }

    // -- checks ------------------------------------------------------

    /// TYP051: a condition whose type is provably an integer.
    fn checkCondition(c: *Checker, cond: ast.Expr) !void {
        const info = try c.typeOf(cond);
        const is_int = switch (info) {
            .int_literal => true,
            .id => if (c.builtinOf(info)) |b| isInteger(b) else false,
            .unknown => false,
        };
        if (is_int) {
            try c.diags.append(c.gpa, .{
                .code = "TYP051",
                .offset = firstTokenOffset(exprNode(cond)),
            });
        }
    }

    // -- walking -----------------------------------------------------

    fn walkBlock(c: *Checker, block: ast.Block) std.mem.Allocator.Error!void {
        try c.scope.push();
        defer c.scope.pop();
        var it = block.statements();
        while (it.next()) |s| try c.walkStmt(s);
    }

    fn walkStmt(c: *Checker, s: ast.Stmt) std.mem.Allocator.Error!void {
        switch (s) {
            .expr_stmt => |es| _ = try c.typeOfOpt(es.expression()),
            .let_stmt => |ls| {
                const init_info = try c.typeOfOpt(ls.initializer());
                // Annotation wins; a missing/unlowerable one infers.
                var info = init_info;
                if (ls.type_()) |te| {
                    const id = try types.lower(c.store, null, te);
                    info = switch (c.store.get(id)) {
                        .unparsed, .unresolved => init_info,
                        else => .{ .id = id },
                    };
                }
                if (ls.pattern()) |p| {
                    if (p.bindingName()) |tok| try c.scope.bind(tok.text, info);
                }
            },
            .return_stmt => |rs| _ = try c.typeOfOpt(rs.value()),
            .panic_stmt => |ps| _ = try c.typeOfOpt(ps.value()),
            .break_stmt => |bs| _ = try c.typeOfOpt(bs.value()),
            .continue_stmt => {},
            .assign_stmt => |as_| {
                _ = try c.typeOfOpt(as_.target());
                _ = try c.typeOfOpt(as_.value());
            },
            .if_stmt => |is| try c.walkIf(is),
            .while_stmt => |ws| {
                if (ws.condition()) |cond| try c.checkCondition(cond);
                if (ws.body()) |b| try c.walkBlock(b);
            },
            .loop_stmt => |ls| if (ls.body()) |b| try c.walkBlock(b),
            .for_stmt => |fs| {
                _ = try c.typeOfOpt(fs.iterable());
                try c.scope.push();
                defer c.scope.pop();
                if (fs.pattern()) |p| {
                    if (p.bindingName()) |tok| try c.scope.bind(tok.text, .unknown);
                }
                if (fs.body()) |b| try c.walkBlock(b);
            },
            .match_stmt => |ms| {
                _ = try c.typeOfOpt(ms.scrutinee());
                var arms = ms.arms();
                while (arms.next()) |arm| {
                    try c.scope.push();
                    defer c.scope.pop();
                    if (arm.pattern()) |p| {
                        if (p.bindingName()) |tok| try c.scope.bind(tok.text, .unknown);
                    }
                    if (arm.block()) |b| {
                        try c.walkBlock(b);
                    } else {
                        _ = try c.typeOfOpt(arm.expression());
                    }
                }
            },
        }
    }

    fn walkIf(c: *Checker, is: ast.IfStmt) std.mem.Allocator.Error!void {
        if (is.condition()) |cond| try c.checkCondition(cond);
        // `if let` patterns bind in the then-branch; their type is the
        // scrutinee's payload — unknown at this floor.
        try c.scope.push();
        defer c.scope.pop();
        if (is.condition() == null) {
            if (firstChildPattern(is.cst)) |p| {
                if (p.bindingName()) |tok| try c.scope.bind(tok.text, .unknown);
            }
        }
        if (is.thenBody()) |b| try c.walkBlock(b);
        if (is.elseBody()) |b| try c.walkBlock(b);
        if (is.elseIf()) |ei| try c.walkIf(ei);
    }

    fn typeOfOpt(c: *Checker, e: ?ast.Expr) std.mem.Allocator.Error!Info {
        const expr = e orelse return .unknown;
        return c.typeOf(expr);
    }
};

fn exprNode(e: ast.Expr) *const cst.Node {
    return switch (e) {
        inline else => |v| v.cst,
    };
}

fn firstChildPattern(node: *const cst.Node) ?ast.Pattern {
    for (node.children) |c| switch (c) {
        .node => |n| if (ast.Pattern.cast(n)) |p| return p,
        .token => {},
    };
    return null;
}

fn firstTokenOffset(node: *const cst.Node) u32 {
    for (node.children) |c| switch (c) {
        .token => |t| if (!t.kind.isTrivia()) return t.offset,
        .node => |n| {
            const o = firstTokenOffset(n);
            if (o != 0) return o;
        },
    };
    return 0;
}

/// Check every function body in `sf`. Caller frees the returned slice.
pub fn checkFile(
    gpa: std.mem.Allocator,
    sf: ast.SourceFile,
    table: *const symbols.SymbolTable,
    store: *types.TypeStore,
    sigs: *const types.Signatures,
) ![]Diag {
    _ = table; // named-type checks join when struct shapes land (B2)
    var diags: std.ArrayList(Diag) = .empty;
    errdefer diags.deinit(gpa);

    var it = sf.items();
    while (it.next()) |item| switch (item) {
        .fn_decl => |fd| {
            const name_tok = fd.name() orelse continue;
            const body = fd.body() orelse continue;

            var c = Checker{
                .gpa = gpa,
                .store = store,
                .sigs = sigs,
                .scope = .{ .gpa = gpa },
                .diags = &diags,
            };
            defer c.scope.deinit();

            // Param scope, typed from the lowered signature.
            try c.scope.push();
            if (sigs.find(name_tok.text)) |sig| {
                if (fd.params()) |ps| {
                    var pit = ps.iter();
                    var i: usize = 0;
                    while (pit.next()) |p| : (i += 1) {
                        const pn = p.name() orelse continue;
                        if (i < sig.params.len) {
                            const info: Info = switch (store.get(sig.params[i])) {
                                .unparsed, .unresolved => .unknown,
                                else => .{ .id = sig.params[i] },
                            };
                            try c.scope.bind(pn.text, info);
                        }
                    }
                }
            }
            try c.walkBlock(body);
            c.scope.pop();
        },
        else => {},
    };

    return diags.toOwnedSlice(gpa);
}

// =====================================================================
// Tests
// =====================================================================

const t_alloc = std.testing.allocator;
const parse = parser.parse;

fn checkSource(src: []const u8) ![]Diag {
    const pr = try parse.parse(t_alloc, src, "t.q");
    defer pr.deinit(t_alloc);
    const sf = ast.SourceFile.cast(pr.root).?;
    var table = try symbols.build(t_alloc, sf);
    defer table.deinit();
    var store = try types.TypeStore.init(t_alloc);
    defer store.deinit();
    var sigs = try types.collectSignatures(&store, &table, sf);
    defer sigs.deinit();
    return checkFile(t_alloc, sf, &table, &store, &sigs);
}

fn expectCodes(src: []const u8, expected: []const []const u8) !void {
    const ds = try checkSource(src);
    defer t_alloc.free(ds);
    try std.testing.expectEqual(expected.len, ds.len);
    for (expected, 0..) |code, i| {
        try std.testing.expectEqualStrings(code, ds[i].code);
    }
}

test "check: TYP051 — integer conditions in if and while" {
    try expectCodes("fn main { if 1 { env.out(\"y\") } }\n", &.{"TYP051"});
    try expectCodes("fn f(n: i64) { while n { env.out(\"t\") } }\n", &.{"TYP051"});
    try expectCodes("fn f(n: i64) { if n + 1 { env.out(\"t\") } }\n", &.{"TYP051"});
}

test "check: bool and unknown conditions stay silent" {
    try expectCodes("fn f(n: i64) { if n > 0 { env.out(\"y\") } }\n", &.{});
    try expectCodes("fn f(b: bool) { while b { env.out(\"y\") } }\n", &.{});
    try expectCodes("fn main { if mystery() { env.out(\"y\") } }\n", &.{});
    try expectCodes("fn main { if let Some(x) = opt() { env.out(x) } }\n", &.{});
}

test "check: TYP042 — mixed numeric arithmetic on annotated bindings" {
    try expectCodes(
        \\fn main {
        \\    let a: i32 = 1
        \\    let b: i64 = 2
        \\    let c = a + b
        \\    env.out("{c}")
        \\}
        \\
    , &.{"TYP042"});
    try expectCodes(
        \\fn f(x: i32, y: f64) -> f64 { x + y }
        \\
    , &.{"TYP042"});
}

test "check: literals are flexible; same types and unknowns are clean" {
    try expectCodes("fn main { let a: i32 = 1\n let c = a + 1 }\n", &.{});
    try expectCodes("fn f(a: i64, b: i64) -> i64 { a + b }\n", &.{});
    try expectCodes("fn main { let c = ghost() + 1 }\n", &.{});
}

test "check: call returns type through this file's signature" {
    // narrow() -> i32 mixed with an i64 param: provable through the sig.
    try expectCodes(
        \\fn narrow() -> i32 { 0 }
        \\fn f(b: i64) -> i64 { narrow() + b }
        \\
    , &.{"TYP042"});
}
