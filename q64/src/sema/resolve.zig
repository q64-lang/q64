//! Body-level name resolution (sema rung A1). Walks every function body
//! with a lexical scope stack — params, `let`/`var` bindings, block
//! nesting, `for`/`match`/`if let` pattern bindings — and classifies the
//! head segment of each path expression: a local, a file-level symbol, an
//! import binding, an ambient host face, or **unresolved**.
//!
//! Unresolved references are *recorded, not emitted*: `build_hir` still
//! owns the rejection for the constructs it compiles (`NameNotFound`),
//! and emitting NAM010 here would double-diagnose until rung A3 makes
//! sema the single source of truth. `q64 show symbols` surfaces the list.
//!
//! Resolved *local* references (a use → its binding site) are likewise
//! recorded, in `Resolution.locals`, so the language server can answer
//! hover and go-to-definition for params and `let`/pattern bindings.
//!
//! v0 boundaries (documented, not bugs):
//! - References inside string interpolation (`"{name}"`) live in raw
//!   string tokens, not CST nodes — invisible here until interpolation
//!   gets parse-level structure.
//! - `screen` bodies (draw/handlers) are skipped; they join when the
//!   screen lowering lands (todo.md §QView).
//! - Pattern bindings collect `IDENT_PATTERN` leaves recursively, which
//!   deliberately excludes enum-variant/struct heads (raw tokens).

const std = @import("std");
const parser = @import("parser");
const ast = parser.ast;
const cst = parser.cst;
const symbols = @import("symbols.zig");
const prelude = @import("prelude.zig");

/// Ambient host-face names usable without declaration (spec/env.md's
/// `env`, the QView host face, and the implicit `ctx: Cancel` that
/// `main`/`spawn`/`scope` introduce per spec/concurrency.md). The
/// auto-prelude proper lives in prelude.zig.
const ambient = [_][]const u8{ "env", "qview", "ctx" };

pub const Ref = struct {
    /// Owned by the Resolution.
    name: []const u8,
    /// Owned by the Resolution: the function whose body references it.
    in_fn: []const u8,
    offset: u32,
};

/// A resolved reference to a local binding (param, `let`/`var`, or a
/// pattern binding from `for`/`match`/`if let`/`scope`). Recorded so the
/// language server can answer hover / go-to-definition for locals: `offset`
/// is the use site, `def_offset` the binding's declaration. Both are byte
/// offsets into the source.
pub const Local = struct {
    /// Owned by the Resolution.
    name: []const u8,
    offset: u32,
    def_offset: u32,
};

pub const Resolution = struct {
    gpa: std.mem.Allocator,
    unresolved: std.ArrayList(Ref) = .empty,
    locals: std.ArrayList(Local) = .empty,

    pub fn deinit(self: *Resolution) void {
        for (self.unresolved.items) |r| {
            self.gpa.free(r.name);
            self.gpa.free(r.in_fn);
        }
        self.unresolved.deinit(self.gpa);
        for (self.locals.items) |l| self.gpa.free(l.name);
        self.locals.deinit(self.gpa);
    }
};

const Scopes = struct {
    gpa: std.mem.Allocator,
    /// Innermost last. Each level maps a bound name to its declaration's byte
    /// offset (so a use can point back at the binding site).
    levels: std.ArrayList(std.StringHashMapUnmanaged(u32)) = .empty,

    fn push(self: *Scopes) !void {
        try self.levels.append(self.gpa, .empty);
    }
    fn pop(self: *Scopes) void {
        var lvl = &self.levels.items[self.levels.items.len - 1];
        var it = lvl.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        lvl.deinit(self.gpa);
        self.levels.items.len -= 1;
    }
    fn bind(self: *Scopes, name: []const u8, offset: u32) !void {
        var lvl = &self.levels.items[self.levels.items.len - 1];
        if (lvl.contains(name)) return; // shadow within one level: keep first
        try lvl.put(self.gpa, try self.gpa.dupe(u8, name), offset);
    }
    /// The declaration offset of `name`'s nearest enclosing binding, or null.
    fn lookup(self: *const Scopes, name: []const u8) ?u32 {
        var i = self.levels.items.len;
        while (i > 0) {
            i -= 1;
            if (self.levels.items[i].get(name)) |off| return off;
        }
        return null;
    }
    fn contains(self: *const Scopes, name: []const u8) bool {
        return self.lookup(name) != null;
    }
    fn deinit(self: *Scopes) void {
        while (self.levels.items.len > 0) self.pop();
        self.levels.deinit(self.gpa);
    }
};

const Walker = struct {
    gpa: std.mem.Allocator,
    table: *const symbols.SymbolTable,
    scopes: Scopes,
    res: *Resolution,
    fn_name: []const u8,

    fn resolveHead(w: *Walker, tok: cst.Token) !void {
        for (ambient) |a| if (std.mem.eql(u8, tok.text, a)) return;
        if (prelude.contains(tok.text)) return;
        if (w.scopes.lookup(tok.text)) |def_offset| {
            // A local: record the use → declaration link for the LSP.
            try w.res.locals.append(w.res.gpa, .{
                .name = try w.res.gpa.dupe(u8, tok.text),
                .offset = tok.offset,
                .def_offset = def_offset,
            });
            return;
        }
        if (w.table.lookup(tok.text) != null) return;
        try w.res.unresolved.append(w.res.gpa, .{
            .name = try w.res.gpa.dupe(u8, tok.text),
            .in_fn = try w.res.gpa.dupe(u8, w.fn_name),
            .offset = tok.offset,
        });
    }

    /// Generic expression walk: resolve PATH_EXPR heads; recurse
    /// everything else. A nested BLOCK gets proper scoping.
    fn walkNode(w: *Walker, node: *const cst.Node) !void {
        switch (node.kind) {
            .PATH_EXPR => {
                // Head segment only: `env.out` resolves `env`; the rest
                // is member access, owned by the (future) type checker.
                for (node.children) |c| switch (c) {
                    .token => |t| if (t.kind == .IDENT) {
                        try w.resolveHead(t);
                        return;
                    } else if (t.kind != .DOT) {
                        return; // keyword-headed path (`in`, `ref`, …)
                    },
                    .node => {},
                };
            },
            .BLOCK => try w.walkBlock(node),
            else => for (node.children) |c| switch (c) {
                .node => |n| try w.walkNode(n),
                .token => {},
            },
        }
    }

    fn walkExprOpt(w: *Walker, e: ?ast.Expr) !void {
        const expr = e orelse return;
        try w.walkNode(exprNode(expr));
    }

    /// Bind every `IDENT_PATTERN` leaf under `p` into the current scope.
    fn bindPattern(w: *Walker, p: ast.Pattern) !void {
        try w.bindPatternNode(p.cst);
    }
    fn bindPatternNode(w: *Walker, node: *const cst.Node) !void {
        if (node.kind == .IDENT_PATTERN) {
            for (node.children) |c| switch (c) {
                .token => |t| if (t.kind == .IDENT) {
                    try w.scopes.bind(t.text, t.offset);
                    return;
                },
                .node => {},
            };
            return;
        }
        for (node.children) |c| switch (c) {
            .node => |n| try w.bindPatternNode(n),
            .token => {},
        };
    }

    fn walkBlock(w: *Walker, block_node: *const cst.Node) (std.mem.Allocator.Error)!void {
        try w.scopes.push();
        defer w.scopes.pop();
        for (block_node.children) |c| switch (c) {
            .node => |n| {
                if (ast.Stmt.cast(n)) |s| {
                    try w.walkStmt(s);
                } else {
                    try w.walkNode(n);
                }
            },
            .token => {},
        };
    }

    fn walkStmt(w: *Walker, s: ast.Stmt) !void {
        switch (s) {
            .expr_stmt => |es| try w.walkExprOpt(es.expression()),
            .let_stmt => |ls| {
                // Initializer sees the scope BEFORE the binding
                // (`let x = x` references an outer x, or is unresolved).
                try w.walkExprOpt(ls.initializer());
                if (ls.pattern()) |p| try w.bindPattern(p);
            },
            .return_stmt => |rs| try w.walkExprOpt(rs.value()),
            .panic_stmt => |ps| try w.walkExprOpt(ps.value()),
            .break_stmt => |bs| try w.walkExprOpt(bs.value()),
            .continue_stmt => {},
            .assign_stmt => |as_| {
                try w.walkExprOpt(as_.target());
                try w.walkExprOpt(as_.value());
            },
            .if_stmt => |is| try w.walkIf(is),
            .while_stmt => |ws| {
                try w.walkExprOpt(ws.condition());
                if (ws.body()) |b| try w.walkBlock(b.cst);
            },
            .loop_stmt => |ls| if (ls.body()) |b| try w.walkBlock(b.cst),
            .for_stmt => |fs| {
                try w.walkExprOpt(fs.iterable());
                try w.scopes.push();
                defer w.scopes.pop();
                if (fs.pattern()) |p| try w.bindPattern(p);
                if (fs.body()) |b| try w.walkBlock(b.cst);
            },
            .match_stmt => |ms| {
                try w.walkExprOpt(ms.scrutinee());
                var arms = ms.arms();
                while (arms.next()) |arm| {
                    try w.scopes.push();
                    defer w.scopes.pop();
                    if (arm.pattern()) |p| try w.bindPattern(p);
                    if (arm.block()) |b| {
                        try w.walkBlock(b.cst);
                    } else {
                        try w.walkExprOpt(arm.expression());
                    }
                }
            },
            .scope_stmt => |ss| {
                if (ss.block()) |b| try w.walkBlock(b.cst);
                var arms = ss.catchArms();
                while (arms.next()) |arm| {
                    try w.scopes.push();
                    defer w.scopes.pop();
                    if (arm.binding()) |tok| try w.scopes.bind(tok.text, tok.offset);
                    if (arm.block()) |b| try w.walkBlock(b.cst);
                }
            },
            .select_stmt => |sel| {
                var arms = sel.arms();
                while (arms.next()) |arm| {
                    try w.scopes.push();
                    defer w.scopes.pop();
                    try w.walkExprOpt(arm.operation());
                    if (arm.binding()) |p| try w.bindPattern(p);
                    if (arm.block()) |b| try w.walkBlock(b.cst);
                }
            },
        }
    }

    fn walkIf(w: *Walker, is: ast.IfStmt) (std.mem.Allocator.Error)!void {
        try w.walkExprOpt(is.condition());
        // `if let PAT = …`: the pattern binds in the then-branch only.
        try w.scopes.push();
        defer w.scopes.pop();
        if (is.condition() == null) {
            if (firstChildPattern(is.cst)) |p| try w.bindPattern(p);
        }
        if (is.thenBody()) |b| try w.walkBlock(b.cst);
        if (is.elseBody()) |b| try w.walkBlock(b.cst);
        if (is.elseIf()) |ei| try w.walkIf(ei);
    }
};

fn firstChildPattern(node: *const cst.Node) ?ast.Pattern {
    for (node.children) |c| switch (c) {
        .node => |n| if (ast.Pattern.cast(n)) |p| return p,
        .token => {},
    };
    return null;
}

/// The CST node behind any `ast.Expr` variant.
fn exprNode(e: ast.Expr) *const cst.Node {
    return switch (e) {
        inline else => |v| v.cst,
    };
}

/// Resolve every function body in `sf` against `table`. Caller deinits
/// the Resolution.
pub fn resolveBodies(
    gpa: std.mem.Allocator,
    sf: ast.SourceFile,
    table: *const symbols.SymbolTable,
) !Resolution {
    var res = Resolution{ .gpa = gpa };
    errdefer res.deinit();

    var it = sf.items();
    while (it.next()) |item| switch (item) {
        .fn_decl => |fd| {
            const name_tok = fd.name() orelse continue;
            const body = fd.body() orelse continue;

            var w = Walker{
                .gpa = gpa,
                .table = table,
                .scopes = .{ .gpa = gpa },
                .res = &res,
                .fn_name = name_tok.text,
            };
            defer w.scopes.deinit();

            // Param scope.
            try w.scopes.push();
            if (fd.params()) |ps| {
                var pit = ps.iter();
                while (pit.next()) |p| {
                    if (p.name()) |t| try w.scopes.bind(t.text, t.offset);
                }
            }
            try w.walkBlock(body.cst);
            w.scopes.pop();
        },
        else => {}, // screens/faces/fits: later rungs
    };

    return res;
}

// =====================================================================
// Tests
// =====================================================================

const t_alloc = std.testing.allocator;
const parse = parser.parse;

const Built = struct {
    pr: parse.Result,
    table: symbols.SymbolTable,
    res: Resolution,

    fn deinit(self: *Built) void {
        self.res.deinit();
        self.table.deinit();
        self.pr.deinit(t_alloc);
    }
};

fn resolveSource(source: []const u8) !Built {
    const pr = try parse.parse(t_alloc, source, "test.q");
    errdefer pr.deinit(t_alloc);
    const sf = ast.SourceFile.cast(pr.root) orelse return error.NoSourceFile;
    var table = try symbols.build(t_alloc, sf);
    errdefer table.deinit();
    const res = try resolveBodies(t_alloc, sf, &table);
    return .{ .pr = pr, .table = table, .res = res };
}

fn expectUnresolved(b: *const Built, names: []const []const u8) !void {
    try std.testing.expectEqual(names.len, b.res.unresolved.items.len);
    for (names, 0..) |n, i| {
        try std.testing.expectEqualStrings(n, b.res.unresolved.items[i].name);
    }
}

test "resolve: params, locals, file symbols, imports, and ambient hosts all resolve" {
    var b = try resolveSource(
        \\import dev.q64.util.{helper}
        \\
        \\fn add(a: i64, b: i64) -> i64 { a + b }
        \\fn main {
        \\    let x = add(1, 2)
        \\    var y = x + helper(x)
        \\    y = y + 1
        \\    env.out(y)
        \\}
        \\
    );
    defer b.deinit();
    try expectUnresolved(&b, &.{});
}

test "resolve: an unknown head is recorded with its function" {
    var b = try resolveSource(
        \\fn main { env.out(mystery(2)) }
        \\
    );
    defer b.deinit();
    try expectUnresolved(&b, &.{"mystery"});
    try std.testing.expectEqualStrings("main", b.res.unresolved.items[0].in_fn);
}

test "resolve: a let initializer does not see its own binding" {
    var b = try resolveSource(
        \\fn main { let x = x + 1 }
        \\
    );
    defer b.deinit();
    try expectUnresolved(&b, &.{"x"});
}

test "resolve: block scoping — an inner binding does not leak out" {
    var b = try resolveSource(
        \\fn f(n: i64) -> i64 {
        \\    while n > 0 {
        \\        let inner = n
        \\    }
        \\    inner
        \\}
        \\
    );
    defer b.deinit();
    try expectUnresolved(&b, &.{"inner"});
}

test "resolve: for/match patterns bind in their bodies" {
    var b = try resolveSource(
        \\fn f(xs: i64) {
        \\    for item in xs {
        \\        env.out(item)
        \\    }
        \\    match xs {
        \\        n -> env.out(n),
        \\    }
        \\}
        \\
    );
    defer b.deinit();
    try expectUnresolved(&b, &.{});
}
