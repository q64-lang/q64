//! Typed AST views over the CST.
//!
//! Each view is a thin, allocation-free wrapper around a `*const cst.Node`
//! that exposes the structured accessors downstream passes (typeck,
//! codegen, `q64 show`) walk. Views skip trivia, return `?T` for
//! optional spec positions, and never copy data.
//!
//! Construction is `<View>.cast(node)`: a kind check that returns
//! `null` when the node isn't the right production. Callers
//! pattern-match on the result.
//!
//! See parser/README.md §"AST views" for the design and
//! spec/grammar.md for the productions each view corresponds to.

const std = @import("std");
const cst = @import("cst.zig");

// =====================================================================
// SourceFile
// =====================================================================

/// `SourceFile := DocComment? ImportStmt* Item*` (spec/grammar.md §"Source files and items").
pub const SourceFile = struct {
    cst: *const cst.Node,

    pub fn cast(node: *const cst.Node) ?SourceFile {
        if (node.kind == .SOURCE_FILE) return .{ .cst = node };
        return null;
    }

    pub fn items(self: SourceFile) ItemIter {
        return .{ .children = self.cst.children };
    }

    pub fn imports(self: SourceFile) ImportIter {
        return .{ .children = self.cst.children };
    }
};

// =====================================================================
// Items
// =====================================================================

/// `Item := Visibility? ItemKind` (spec/grammar.md §"Source files and
/// items"). Every item kind the parser produces is surfaced; leaf
/// internals that depend on the (unwritten) type-expression grammar —
/// field/variant/const/alias types — remain raw spans rendered as text.
pub const Item = union(enum) {
    fn_decl: FnDecl,
    struct_decl: StructDecl,
    enum_decl: EnumDecl,
    type_decl: TypeDecl,
    const_decl: ConstDecl,
    face_decl: FaceDecl,
    fit_decl: FitDecl,

    pub fn cast(node: *const cst.Node) ?Item {
        return switch (node.kind) {
            .FN_DECL => .{ .fn_decl = .{ .cst = node } },
            .STRUCT_DECL => .{ .struct_decl = .{ .cst = node } },
            .ENUM_DECL => .{ .enum_decl = .{ .cst = node } },
            .TYPE_DECL => .{ .type_decl = .{ .cst = node } },
            .CONST_DECL => .{ .const_decl = .{ .cst = node } },
            .FACE_DECL => .{ .face_decl = .{ .cst = node } },
            .FIT_DECL => .{ .fit_decl = .{ .cst = node } },
            else => null,
        };
    }
};

pub const ItemIter = struct {
    children: []const cst.Element,
    i: usize = 0,

    pub fn next(self: *ItemIter) ?Item {
        while (self.i < self.children.len) : (self.i += 1) {
            switch (self.children[self.i]) {
                .node => |n| if (Item.cast(n)) |it| {
                    self.i += 1;
                    return it;
                },
                .token => {},
            }
        }
        return null;
    }
};

// =====================================================================
// ImportStmt
// =====================================================================

/// `ImportStmt := "import" ImportPath ImportBinding?` (spec/modules.md
/// §"Import grammar"). Exposes the module path, whether it is a quoted
/// relative path, and the selectively-imported names.
pub const ImportStmt = struct {
    cst: *const cst.Node,

    pub fn cast(node: *const cst.Node) ?ImportStmt {
        if (node.kind == .IMPORT_STMT) return .{ .cst = node };
        return null;
    }

    fn importPath(self: ImportStmt) ?*const cst.Node {
        return firstChildRawNode(self.cst, .IMPORT_PATH);
    }

    /// True for `import "./util.q"` forms; false for bare-dotted module
    /// paths like `import dev.q64.foo`.
    pub fn isRelative(self: ImportStmt) bool {
        const p = self.importPath() orelse return false;
        return firstChildRawNode(p, .QUOTED_RELATIVE) != null;
    }

    /// The dotted module path text (`dev.q64.hello_world`) for a
    /// bare-dotted import, or the decoded relative path (`./util.q`)
    /// for a quoted import. Caller owns the returned slice.
    pub fn path(self: ImportStmt, allocator: std.mem.Allocator) !?[]u8 {
        const p = self.importPath() orelse return null;
        if (firstChildRawNode(p, .BARE_DOTTED)) |bare| {
            var len: usize = 0;
            for (bare.children) |c| switch (c) {
                .token => |t| if (t.kind == .IDENT or t.kind == .DOT) {
                    len += t.text.len;
                },
                .node => {},
            };
            const out = try allocator.alloc(u8, len);
            var i: usize = 0;
            for (bare.children) |c| switch (c) {
                .token => |t| if (t.kind == .IDENT or t.kind == .DOT) {
                    @memcpy(out[i .. i + t.text.len], t.text);
                    i += t.text.len;
                },
                .node => {},
            };
            return out;
        }
        if (firstChildRawNode(p, .QUOTED_RELATIVE)) |q| {
            for (q.children) |c| switch (c) {
                .token => |t| if (t.kind == .STR_PLAIN or t.kind == .STR_RAW) {
                    // Strip the surrounding quotes; relative paths use no escapes in v0.
                    if (t.text.len >= 2 and t.text[0] == '"') {
                        return try allocator.dupe(u8, t.text[1 .. t.text.len - 1]);
                    }
                    return try allocator.dupe(u8, t.text);
                },
                .node => {},
            };
        }
        return null;
    }

    /// Iterator over the selectively-imported names (`.{a, b}`). Empty
    /// for namespace and alias imports.
    pub fn names(self: ImportStmt) NameIter {
        const sel = firstChildRawNode(self.cst, .SELECTIVE_LIST) orelse
            return .{ .children = &.{} };
        return .{ .children = sel.children };
    }
};

pub const NameIter = struct {
    children: []const cst.Element,
    i: usize = 0,

    pub fn next(self: *NameIter) ?cst.Token {
        while (self.i < self.children.len) : (self.i += 1) {
            switch (self.children[self.i]) {
                .token => |t| if (t.kind == .IDENT) {
                    self.i += 1;
                    return t;
                },
                .node => {},
            }
        }
        return null;
    }
};

pub const ImportIter = struct {
    children: []const cst.Element,
    i: usize = 0,

    pub fn next(self: *ImportIter) ?ImportStmt {
        while (self.i < self.children.len) : (self.i += 1) {
            switch (self.children[self.i]) {
                .node => |n| if (ImportStmt.cast(n)) |im| {
                    self.i += 1;
                    return im;
                },
                .token => {},
            }
        }
        return null;
    }
};

// =====================================================================
// FnDecl
// =====================================================================

/// `FnDecl := "fn" IDENT GenericParams? "(" Params? ")" ("->" TypeExpr)?
///             EffectSpec? WhereClause? Block` (spec/grammar.md §"Functions").
///
/// v0 surfaces the four positions the parser already populates:
/// visibility, name, params, return type, body. Generic params,
/// effect spec, and where clause appear as the corresponding
/// accessors land.
pub const FnDecl = struct {
    cst: *const cst.Node,

    pub fn cast(node: *const cst.Node) ?FnDecl {
        if (node.kind == .FN_DECL) return .{ .cst = node };
        return null;
    }

    pub fn visibility(self: FnDecl) ?Visibility {
        return firstChildNode(self.cst, .VISIBILITY, Visibility);
    }

    pub fn isPublic(self: FnDecl) bool {
        return self.visibility() != null;
    }

    /// The function's name token. `null` for ill-formed input where
    /// the parser didn't find an `IDENT` after `fn`.
    pub fn name(self: FnDecl) ?cst.Token {
        var seen_fn = false;
        for (self.cst.children) |c| switch (c) {
            .token => |t| {
                if (t.kind == .KW_FN) {
                    seen_fn = true;
                    continue;
                }
                if (!seen_fn) continue;
                if (t.kind.isTrivia()) continue;
                if (t.kind == .IDENT) return t;
                return null;
            },
            .node => {},
        };
        return null;
    }

    pub fn params(self: FnDecl) ?Params {
        return firstChildNode(self.cst, .PARAMS, Params);
    }

    pub fn returnType(self: FnDecl) ?ReturnType {
        return firstChildNode(self.cst, .RETURN_TYPE, ReturnType);
    }

    pub fn body(self: FnDecl) ?Block {
        return firstChildNode(self.cst, .BLOCK, Block);
    }
};

// =====================================================================
// Other item declarations
//
// Each shares the item shell: an optional `VISIBILITY` node, the keyword
// token, the name `IDENT`, and optional `GENERIC_PARAMS`. `itemName`
// returns the first `IDENT` token child (the name), since visibility and
// generics are nodes, not direct token children.
// =====================================================================

fn itemVisibility(node: *const cst.Node) ?Visibility {
    return firstChildNode(node, .VISIBILITY, Visibility);
}

fn itemName(node: *const cst.Node) ?cst.Token {
    for (node.children) |c| switch (c) {
        .token => |t| if (t.kind == .IDENT) return t,
        .node => {},
    };
    return null;
}

/// `StructDecl := "struct" IDENT GenericParams? StructBody`
/// (spec/grammar.md §"Type declarations").
pub const StructDecl = struct {
    cst: *const cst.Node,

    pub fn visibility(self: StructDecl) ?Visibility {
        return itemVisibility(self.cst);
    }
    pub fn isPublic(self: StructDecl) bool {
        return self.visibility() != null;
    }
    pub fn name(self: StructDecl) ?cst.Token {
        return itemName(self.cst);
    }

    /// Record-struct fields (`struct S { a: T, … }`). Empty for tuple
    /// structs (`struct S(T, …)`) and unit structs (`struct S`).
    pub fn fields(self: StructDecl) FieldIter {
        const body = firstChildRawNode(self.cst, .RECORD_BODY) orelse
            return .{ .children = &.{} };
        return .{ .children = body.children };
    }
};

pub const FieldIter = struct {
    children: []const cst.Element,
    i: usize = 0,

    pub fn next(self: *FieldIter) ?Field {
        while (self.i < self.children.len) : (self.i += 1) {
            switch (self.children[self.i]) {
                .node => |n| if (n.kind == .FIELD) {
                    self.i += 1;
                    return .{ .cst = n };
                },
                .token => {},
            }
        }
        return null;
    }
};

/// `Field := IDENT ":" TypeExpr` (the type is a raw span in v0).
pub const Field = struct {
    cst: *const cst.Node,

    pub fn name(self: Field) ?cst.Token {
        return itemName(self.cst);
    }

    /// The field's declared type as source text (raw span), or `null`
    /// when absent. Caller owns the returned slice.
    pub fn typeText(self: Field, allocator: std.mem.Allocator) !?[]u8 {
        return joinTokensAfter(allocator, self.cst, .COLON);
    }
};

/// `EnumDecl := "enum" IDENT GenericParams? "{" Variant,* "}"`.
pub const EnumDecl = struct {
    cst: *const cst.Node,

    pub fn visibility(self: EnumDecl) ?Visibility {
        return itemVisibility(self.cst);
    }
    pub fn isPublic(self: EnumDecl) bool {
        return self.visibility() != null;
    }
    pub fn name(self: EnumDecl) ?cst.Token {
        return itemName(self.cst);
    }

    pub fn variants(self: EnumDecl) VariantIter {
        return .{ .children = self.cst.children };
    }
};

pub const VariantIter = struct {
    children: []const cst.Element,
    i: usize = 0,

    pub fn next(self: *VariantIter) ?Variant {
        while (self.i < self.children.len) : (self.i += 1) {
            switch (self.children[self.i]) {
                .node => |n| if (n.kind == .VARIANT) {
                    self.i += 1;
                    return .{ .cst = n };
                },
                .token => {},
            }
        }
        return null;
    }
};

/// `Variant := IDENT VariantPayload?` (payload is a raw span in v0).
pub const Variant = struct {
    cst: *const cst.Node,

    pub fn name(self: Variant) ?cst.Token {
        return itemName(self.cst);
    }
};

/// `TypeDecl := "type" IDENT GenericParams? "=" TypeExpr`.
pub const TypeDecl = struct {
    cst: *const cst.Node,

    pub fn visibility(self: TypeDecl) ?Visibility {
        return itemVisibility(self.cst);
    }
    pub fn isPublic(self: TypeDecl) bool {
        return self.visibility() != null;
    }
    pub fn name(self: TypeDecl) ?cst.Token {
        return itemName(self.cst);
    }

    /// The aliased type as source text (raw span after `=`). Caller owns
    /// the returned slice.
    pub fn aliasedText(self: TypeDecl, allocator: std.mem.Allocator) !?[]u8 {
        return joinTokensAfter(allocator, self.cst, .EQ);
    }
};

/// `ConstDecl := "const" IDENT ":" TypeExpr "=" Expr`.
pub const ConstDecl = struct {
    cst: *const cst.Node,

    pub fn visibility(self: ConstDecl) ?Visibility {
        return itemVisibility(self.cst);
    }
    pub fn isPublic(self: ConstDecl) bool {
        return self.visibility() != null;
    }
    pub fn name(self: ConstDecl) ?cst.Token {
        return itemName(self.cst);
    }

    /// The initializer expression after `=`, if present.
    pub fn value(self: ConstDecl) ?Expr {
        for (self.cst.children) |c| switch (c) {
            .node => |n| if (Expr.cast(n)) |e| return e,
            .token => {},
        };
        return null;
    }
};

/// `FaceDecl := "face" IDENT … FaceBody`. The header (super-faces,
/// generics) and method signatures are raw spans in v0.
pub const FaceDecl = struct {
    cst: *const cst.Node,

    pub fn visibility(self: FaceDecl) ?Visibility {
        return itemVisibility(self.cst);
    }
    pub fn isPublic(self: FaceDecl) bool {
        return self.visibility() != null;
    }
    pub fn name(self: FaceDecl) ?cst.Token {
        return itemName(self.cst);
    }
};

/// `FitDecl := "fit" … FitBody`. Header and method bodies are raw spans
/// in v0.
pub const FitDecl = struct {
    cst: *const cst.Node,

    pub fn visibility(self: FitDecl) ?Visibility {
        return itemVisibility(self.cst);
    }
    pub fn isPublic(self: FitDecl) bool {
        return self.visibility() != null;
    }

    /// The first name in the `fit` header (`fit Name : Face` → `Name`).
    pub fn name(self: FitDecl) ?cst.Token {
        return itemName(self.cst);
    }
};

// =====================================================================
// Leaf views
//
// Thin wrappers today; structured accessors land as the corresponding
// productions get a real parser. Keeping them as named types lets the
// AST surface evolve without renaming call sites.
// =====================================================================

pub const Visibility = struct { cst: *const cst.Node };

/// `Params := "(" Param ("," Param)* ","? ")"`. Iterates the structured
/// `PARAM` children; commas and trivia are skipped.
pub const Params = struct {
    cst: *const cst.Node,

    /// True for `()` — no `PARAM` children.
    pub fn isEmpty(self: Params) bool {
        var it = self.iter();
        return it.next() == null;
    }

    pub fn iter(self: Params) ParamIter {
        return .{ .children = self.cst.children };
    }
};

pub const ParamIter = struct {
    children: []const cst.Element,
    i: usize = 0,

    pub fn next(self: *ParamIter) ?Param {
        while (self.i < self.children.len) : (self.i += 1) {
            switch (self.children[self.i]) {
                .node => |n| if (n.kind == .PARAM) {
                    self.i += 1;
                    return .{ .cst = n };
                },
                .token => {},
            }
        }
        return null;
    }
};

/// `Param := ParamMode? IDENT ":" TypeExpr` (spec/grammar.md §Functions).
/// Surfaces the mode, the binding name, and the declared type text; the
/// type stays a raw span pending the type-expression grammar.
pub const Param = struct {
    cst: *const cst.Node,

    /// The parameter mode token (`in` / `ref` / `out` / `move`), or
    /// `null` for the default (by-value) mode.
    pub fn mode(self: Param) ?cst.Token {
        for (self.cst.children) |c| switch (c) {
            .node => |n| if (n.kind == .PARAM_MODE) {
                for (n.children) |cc| switch (cc) {
                    .token => |t| if (!t.kind.isTrivia()) return t,
                    .node => {},
                };
            },
            .token => {},
        };
        return null;
    }

    /// The parameter's binding name — the first `IDENT` before the `:`.
    /// `null` for ill-formed input with no name token.
    pub fn name(self: Param) ?cst.Token {
        for (self.cst.children) |c| switch (c) {
            .token => |t| {
                if (t.kind == .COLON) return null;
                if (t.kind == .IDENT) return t;
            },
            .node => {},
        };
        return null;
    }

    /// The declared type as source text (raw span in v0), trivia-trimmed.
    /// `null` when the parameter has no `: Type` annotation (e.g. a
    /// receiver `self`). Caller owns the returned slice.
    pub fn typeText(self: Param, allocator: std.mem.Allocator) !?[]u8 {
        return joinTokensAfter(allocator, self.cst, .COLON);
    }
};

/// `ReturnType := "->" TypeExpr`. The type expression is a raw token
/// span in v0 (pending the type grammar); `text` renders it back to
/// source so codegen / `q64 show` can read the declared type.
pub const ReturnType = struct {
    cst: *const cst.Node,

    /// The declared return type as source text — the tokens after `->`
    /// with surrounding trivia trimmed (`-> str` → `str`,
    /// `-> Signal<PCM<f32>>` → `Signal<PCM<f32>>`). Internal spacing is
    /// preserved as written. Caller owns the returned slice; `null` when
    /// the node carries no type tokens after the arrow.
    pub fn text(self: ReturnType, allocator: std.mem.Allocator) !?[]u8 {
        return joinTokensAfter(allocator, self.cst, .ARROW);
    }
};

/// `Block := "{" Stmt* "}"`. v0 surfaces structured `ExprStmt`s; any
/// unparsed tokens between statements live as direct token children
/// and are skipped by the iterator.
pub const Block = struct {
    cst: *const cst.Node,

    pub fn cast(node: *const cst.Node) ?Block {
        if (node.kind == .BLOCK) return .{ .cst = node };
        return null;
    }

    pub fn statements(self: Block) StmtIter {
        return .{ .children = self.cst.children };
    }
};

pub const Stmt = union(enum) {
    expr_stmt: ExprStmt,
    let_stmt: LetStmt,
    return_stmt: ReturnStmt,

    pub fn cast(node: *const cst.Node) ?Stmt {
        return switch (node.kind) {
            .EXPR_STMT => .{ .expr_stmt = .{ .cst = node } },
            .LET_STMT, .VAR_STMT => .{ .let_stmt = .{ .cst = node } },
            .RETURN_STMT => .{ .return_stmt = .{ .cst = node } },
            else => null,
        };
    }
};

pub const StmtIter = struct {
    children: []const cst.Element,
    i: usize = 0,

    pub fn next(self: *StmtIter) ?Stmt {
        while (self.i < self.children.len) : (self.i += 1) {
            switch (self.children[self.i]) {
                .node => |n| if (Stmt.cast(n)) |s| {
                    self.i += 1;
                    return s;
                },
                .token => {},
            }
        }
        return null;
    }
};

pub const ExprStmt = struct {
    cst: *const cst.Node,

    pub fn expression(self: ExprStmt) ?Expr {
        for (self.cst.children) |c| switch (c) {
            .node => |n| if (Expr.cast(n)) |e| return e,
            .token => {},
        };
        return null;
    }
};

/// `LetStmt := ("let" | "var") Pattern (":" TypeExpr)? ("=" Expr)?`
/// (spec/grammar.md §Statements). The binding pattern and initializer
/// are surfaced; the type annotation stays a raw token span in v0.
pub const LetStmt = struct {
    cst: *const cst.Node,

    /// True for `var`, false for `let`. The two share this view since
    /// they differ only in mutability, which downstream passes read off
    /// the CST kind.
    pub fn isVar(self: LetStmt) bool {
        return self.cst.kind == .VAR_STMT;
    }

    /// The binding pattern (`x`, `(a, b)`, `Point { x }`). `null` only
    /// for ill-formed input the parser recovered without a pattern node.
    pub fn pattern(self: LetStmt) ?Pattern {
        for (self.cst.children) |c| switch (c) {
            .node => |n| if (Pattern.cast(n)) |p| return p,
            .token => {},
        };
        return null;
    }

    /// The initializer expression after `=`, if the binding has one.
    /// The type annotation between the pattern and `=` is a raw token
    /// span (no node), so the first `Expr`-shaped child is the value.
    pub fn initializer(self: LetStmt) ?Expr {
        for (self.cst.children) |c| switch (c) {
            .node => |n| if (Expr.cast(n)) |e| return e,
            .token => {},
        };
        return null;
    }
};

/// `ReturnStmt := "return" Expr?` (spec/grammar.md §Statements).
pub const ReturnStmt = struct {
    cst: *const cst.Node,

    /// The returned expression, or `null` for a bare `return`.
    pub fn value(self: ReturnStmt) ?Expr {
        for (self.cst.children) |c| switch (c) {
            .node => |n| if (Expr.cast(n)) |e| return e,
            .token => {},
        };
        return null;
    }
};

/// A binding/match pattern. The parser emits a family of pattern node
/// kinds (`IDENT_PATTERN`, `WILD_PATTERN`, `TUPLE_PATTERN`, …) rather
/// than one `PATTERN` kind; this view wraps any of them and exposes the
/// accessors codegen consumes today.
pub const Pattern = struct {
    cst: *const cst.Node,

    pub fn cast(node: *const cst.Node) ?Pattern {
        return if (isPatternKind(node.kind)) .{ .cst = node } else null;
    }

    pub fn kind(self: Pattern) cst.SyntaxKind {
        return self.cst.kind;
    }

    /// The bound identifier for a simple `let x` binding
    /// (`IDENT_PATTERN`). `null` for wildcards and structured patterns
    /// whose binding shape codegen doesn't consume yet.
    pub fn bindingName(self: Pattern) ?cst.Token {
        if (self.cst.kind != .IDENT_PATTERN) return null;
        for (self.cst.children) |c| switch (c) {
            .token => |t| if (t.kind == .IDENT) return t,
            .node => {},
        };
        return null;
    }

    pub fn isPatternKind(k: cst.SyntaxKind) bool {
        return switch (k) {
            .WILD_PATTERN,
            .IDENT_PATTERN,
            .LITERAL_PATTERN,
            .ENUM_VARIANT_PATTERN,
            .TUPLE_PATTERN,
            .TUPLE_STRUCT_PATTERN,
            .RECORD_STRUCT_PATTERN,
            => true,
            else => false,
        };
    }
};

/// Sum of v0 expression forms. Adding a new expression kind: add a
/// CST kind in `cst.zig`, a parse function in `parse.zig`, and a
/// variant here whose `cast` recognizes the new kind.
pub const Expr = union(enum) {
    call: CallExpr,
    path: PathExpr,
    string_lit: StringLit,
    num_lit: NumLit,
    literal: LiteralExpr,

    pub fn cast(node: *const cst.Node) ?Expr {
        return switch (node.kind) {
            .CALL_EXPR => .{ .call = .{ .cst = node } },
            .PATH_EXPR => .{ .path = .{ .cst = node } },
            .STR_LITERAL => .{ .string_lit = .{ .cst = node } },
            .NUM_LITERAL => .{ .num_lit = .{ .cst = node } },
            .LITERAL_EXPR => .{ .literal = .{ .cst = node } },
            else => null,
        };
    }
};

pub const CallExpr = struct {
    cst: *const cst.Node,

    /// The callee expression — the node immediately before the
    /// CALL_ARGS child.
    pub fn callee(self: CallExpr) ?Expr {
        for (self.cst.children) |c| switch (c) {
            .node => |n| {
                if (n.kind == .CALL_ARGS) continue;
                if (Expr.cast(n)) |e| return e;
            },
            .token => {},
        };
        return null;
    }

    pub fn args(self: CallExpr) ArgIter {
        for (self.cst.children) |c| switch (c) {
            .node => |n| if (n.kind == .CALL_ARGS) {
                return .{ .children = n.children };
            },
            .token => {},
        };
        return .{ .children = &.{} };
    }
};

pub const ArgIter = struct {
    children: []const cst.Element,
    i: usize = 0,

    pub fn next(self: *ArgIter) ?Expr {
        while (self.i < self.children.len) : (self.i += 1) {
            switch (self.children[self.i]) {
                .node => |n| if (n.kind == .CALL_ARG) {
                    self.i += 1;
                    for (n.children) |cc| switch (cc) {
                        .node => |cn| if (Expr.cast(cn)) |e| return e,
                        .token => {},
                    };
                    return null;
                },
                .token => {},
            }
        }
        return null;
    }
};

pub const PathExpr = struct {
    cst: *const cst.Node,

    /// Joined source text of the path (segments + dots), e.g.
    /// `"env.out"` for `PATH_EXPR[IDENT("env"), DOT, KW_OUT("out")]`.
    /// Caller owns the returned slice. Param-mode soft keywords
    /// (`in`, `out`, `ref`, `move`) appear as path segments via their
    /// keyword tokens, mirroring `parse.parsePath`.
    pub fn text(self: PathExpr, allocator: std.mem.Allocator) ![]u8 {
        var len: usize = 0;
        for (self.cst.children) |c| switch (c) {
            .token => |t| if (isPathToken(t.kind)) {
                len += t.text.len;
            },
            .node => {},
        };
        const out = try allocator.alloc(u8, len);
        var i: usize = 0;
        for (self.cst.children) |c| switch (c) {
            .token => |t| if (isPathToken(t.kind)) {
                @memcpy(out[i .. i + t.text.len], t.text);
                i += t.text.len;
            },
            .node => {},
        };
        return out;
    }

    fn isPathToken(k: cst.SyntaxKind) bool {
        return switch (k) {
            .IDENT, .DOT, .KW_IN, .KW_OUT, .KW_REF, .KW_MOVE => true,
            else => false,
        };
    }
};

pub const StringLit = struct {
    cst: *const cst.Node,

    pub fn rawText(self: StringLit) ?[]const u8 {
        for (self.cst.children) |c| switch (c) {
            .token => |t| if (t.kind == .STR_PLAIN or t.kind == .STR_RAW) return t.text,
            .node => {},
        };
        return null;
    }

    /// Decode the literal — strip the surrounding `"…"` and
    /// interpret a small set of escape sequences (`\n`, `\t`, `\r`,
    /// `\\`, `\"`, `\0`). Unknown escapes pass through as-is. v0
    /// scope; full escape grammar lands with the typed-string spec.
    pub fn value(self: StringLit, allocator: std.mem.Allocator) !?[]u8 {
        const raw = self.rawText() orelse return null;
        if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') return null;
        const body = raw[1 .. raw.len - 1];

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        var i: usize = 0;
        while (i < body.len) : (i += 1) {
            if (body[i] != '\\' or i + 1 >= body.len) {
                try out.append(allocator, body[i]);
                continue;
            }
            i += 1;
            switch (body[i]) {
                'n' => try out.append(allocator, '\n'),
                't' => try out.append(allocator, '\t'),
                'r' => try out.append(allocator, '\r'),
                '\\' => try out.append(allocator, '\\'),
                '"' => try out.append(allocator, '"'),
                '0' => try out.append(allocator, 0),
                else => {
                    try out.append(allocator, '\\');
                    try out.append(allocator, body[i]);
                },
            }
        }
        return try out.toOwnedSlice(allocator);
    }
};

pub const NumLit = struct {
    cst: *const cst.Node,

    /// The numeric token's raw text (e.g. `"42"`, `"3.14"`, `"0xFF"`).
    pub fn rawText(self: NumLit) ?[]const u8 {
        for (self.cst.children) |c| switch (c) {
            .token => |t| if (t.kind == .INT_LIT or t.kind == .FLOAT_LIT) return t.text,
            .node => {},
        };
        return null;
    }
};

pub const LiteralExpr = struct { cst: *const cst.Node };

// =====================================================================
// Internal helpers
// =====================================================================

fn firstChildNode(
    parent: *const cst.Node,
    kind: cst.SyntaxKind,
    comptime View: type,
) ?View {
    for (parent.children) |c| switch (c) {
        .node => |n| if (n.kind == kind) return View{ .cst = n },
        .token => {},
    };
    return null;
}

fn firstChildRawNode(parent: *const cst.Node, kind: cst.SyntaxKind) ?*const cst.Node {
    for (parent.children) |c| switch (c) {
        .node => |n| if (n.kind == kind) return n,
        .token => {},
    };
    return null;
}

/// Join the source text of every token after the first `after`-kind
/// token in `node`'s direct children, with surrounding trivia trimmed.
/// Returns `null` if `after` never appears or no tokens follow it.
/// Caller owns the returned slice. Used to render the raw type spans
/// that follow `->` (return types) and `:` (param types) until the
/// type-expression grammar makes them structured.
fn joinTokensAfter(
    allocator: std.mem.Allocator,
    node: *const cst.Node,
    after: cst.SyntaxKind,
) !?[]u8 {
    var seen = false;
    var total: usize = 0;
    for (node.children) |c| switch (c) {
        .token => |t| {
            if (!seen) {
                if (t.kind == after) seen = true;
                continue;
            }
            total += t.text.len;
        },
        .node => {},
    };
    if (!seen or total == 0) return null;

    const buf = try allocator.alloc(u8, total);
    var i: usize = 0;
    seen = false;
    for (node.children) |c| switch (c) {
        .token => |t| {
            if (!seen) {
                if (t.kind == after) seen = true;
                continue;
            }
            @memcpy(buf[i .. i + t.text.len], t.text);
            i += t.text.len;
        },
        .node => {},
    };

    const trimmed = std.mem.trim(u8, buf, " \t\r\n");
    if (trimmed.len == buf.len) return buf;
    const out = try allocator.dupe(u8, trimmed);
    allocator.free(buf);
    return out;
}

// =====================================================================
// Tests
// =====================================================================

const testing = std.testing;

test "FnDecl.cast: kind check" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const not_fn = try cst.makeNode(a, .SOURCE_FILE, &.{});
    try testing.expect(FnDecl.cast(not_fn) == null);

    const fn_node = try cst.makeNode(a, .FN_DECL, &.{});
    try testing.expect(FnDecl.cast(fn_node) != null);
}

test "FnDecl.name: simple `fn main`" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const children = [_]cst.Element{
        cst.makeToken(.KW_FN, "fn", 0),
        cst.makeToken(.WHITESPACE, " ", 2),
        cst.makeToken(.IDENT, "main", 3),
    };
    const node = try cst.makeNode(a, .FN_DECL, &children);
    const fn_decl = FnDecl.cast(node) orelse return error.TestExpectedNonNull;

    const got = fn_decl.name() orelse return error.TestExpectedNonNull;
    try testing.expectEqualStrings("main", got.text);
}

test "FnDecl.name: returns null if first non-trivia after `fn` isn't IDENT" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `fn { ... }` — no name. The parser still wraps this in FN_DECL
    // for recovery; the view reports the missing name.
    const children = [_]cst.Element{
        cst.makeToken(.KW_FN, "fn", 0),
        cst.makeToken(.WHITESPACE, " ", 2),
        cst.makeToken(.L_BRACE, "{", 3),
    };
    const node = try cst.makeNode(a, .FN_DECL, &children);
    try testing.expect(FnDecl.cast(node).?.name() == null);
}

test "FnDecl.isPublic: with and without VISIBILITY child" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const vis_children = [_]cst.Element{cst.makeToken(.KW_PUB, "pub", 0)};
    const vis_node = try cst.makeNode(a, .VISIBILITY, &vis_children);

    const with_pub = [_]cst.Element{
        .{ .node = vis_node },
        cst.makeToken(.WHITESPACE, " ", 3),
        cst.makeToken(.KW_FN, "fn", 4),
        cst.makeToken(.WHITESPACE, " ", 6),
        cst.makeToken(.IDENT, "f", 7),
    };
    const with_pub_node = try cst.makeNode(a, .FN_DECL, &with_pub);
    try testing.expect(FnDecl.cast(with_pub_node).?.isPublic());

    const no_pub = [_]cst.Element{
        cst.makeToken(.KW_FN, "fn", 0),
        cst.makeToken(.WHITESPACE, " ", 2),
        cst.makeToken(.IDENT, "f", 3),
    };
    const no_pub_node = try cst.makeNode(a, .FN_DECL, &no_pub);
    try testing.expect(!FnDecl.cast(no_pub_node).?.isPublic());
}

test "FnDecl.params / .returnType / .body: present or absent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const params_node = try cst.makeNode(a, .PARAMS, &[_]cst.Element{
        cst.makeToken(.L_PAREN, "(", 0),
        cst.makeToken(.R_PAREN, ")", 1),
    });
    const block_node = try cst.makeNode(a, .BLOCK, &[_]cst.Element{
        cst.makeToken(.L_BRACE, "{", 0),
        cst.makeToken(.R_BRACE, "}", 1),
    });

    const with_all = [_]cst.Element{
        cst.makeToken(.KW_FN, "fn", 0),
        cst.makeToken(.IDENT, "f", 0),
        .{ .node = params_node },
        .{ .node = block_node },
    };
    const all_node = try cst.makeNode(a, .FN_DECL, &with_all);
    const fd = FnDecl.cast(all_node).?;
    try testing.expect(fd.params() != null);
    try testing.expect(fd.returnType() == null);
    try testing.expect(fd.body() != null);

    const just_fn = [_]cst.Element{
        cst.makeToken(.KW_FN, "fn", 0),
        cst.makeToken(.IDENT, "f", 0),
    };
    const just_fn_node = try cst.makeNode(a, .FN_DECL, &just_fn);
    const fd2 = FnDecl.cast(just_fn_node).?;
    try testing.expect(fd2.params() == null);
    try testing.expect(fd2.returnType() == null);
    try testing.expect(fd2.body() == null);
}

test "SourceFile.items: iterates FnDecls, skips stray tokens" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const fn1 = try cst.makeNode(a, .FN_DECL, &[_]cst.Element{
        cst.makeToken(.KW_FN, "fn", 0),
        cst.makeToken(.WHITESPACE, " ", 2),
        cst.makeToken(.IDENT, "a", 3),
    });
    const fn2 = try cst.makeNode(a, .FN_DECL, &[_]cst.Element{
        cst.makeToken(.KW_FN, "fn", 0),
        cst.makeToken(.WHITESPACE, " ", 2),
        cst.makeToken(.IDENT, "b", 3),
    });

    const root_children = [_]cst.Element{
        cst.makeToken(.WHITESPACE, "  ", 0),
        .{ .node = fn1 },
        cst.makeToken(.NEWLINE, "\n", 2),
        .{ .node = fn2 },
    };
    const root = try cst.makeNode(a, .SOURCE_FILE, &root_children);
    const sf = SourceFile.cast(root) orelse return error.TestExpectedNonNull;

    var iter = sf.items();
    const first = iter.next() orelse return error.TestExpectedNonNull;
    try testing.expectEqualStrings("a", first.fn_decl.name().?.text);
    const second = iter.next() orelse return error.TestExpectedNonNull;
    try testing.expectEqualStrings("b", second.fn_decl.name().?.text);
    try testing.expect(iter.next() == null);
}

test "Stmt.cast: recognizes let/var/return alongside expr" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const let_node = try cst.makeNode(a, .LET_STMT, &.{});
    const var_node = try cst.makeNode(a, .VAR_STMT, &.{});
    const ret_node = try cst.makeNode(a, .RETURN_STMT, &.{});
    const expr_node = try cst.makeNode(a, .EXPR_STMT, &.{});
    const other = try cst.makeNode(a, .IF_STMT, &.{});

    const tag = std.meta.activeTag;
    try testing.expectEqual(tag(Stmt.cast(let_node).?), .let_stmt);
    try testing.expectEqual(tag(Stmt.cast(var_node).?), .let_stmt);
    try testing.expectEqual(tag(Stmt.cast(ret_node).?), .return_stmt);
    try testing.expectEqual(tag(Stmt.cast(expr_node).?), .expr_stmt);
    try testing.expect(Stmt.cast(other) == null);
}

test "LetStmt: isVar, pattern binding name, initializer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `let x = "hi"`
    const pat = try cst.makeNode(a, .IDENT_PATTERN, &[_]cst.Element{
        cst.makeToken(.IDENT, "x", 4),
    });
    const init_expr = try cst.makeNode(a, .STR_LITERAL, &[_]cst.Element{
        cst.makeToken(.STR_PLAIN, "\"hi\"", 8),
    });
    const let_node = try cst.makeNode(a, .LET_STMT, &[_]cst.Element{
        cst.makeToken(.KW_LET, "let", 0),
        cst.makeToken(.WHITESPACE, " ", 3),
        .{ .node = pat },
        cst.makeToken(.WHITESPACE, " ", 5),
        cst.makeToken(.EQ, "=", 6),
        cst.makeToken(.WHITESPACE, " ", 7),
        .{ .node = init_expr },
    });

    const ls = switch (Stmt.cast(let_node) orelse return error.TestExpectedNonNull) {
        .let_stmt => |x| x,
        else => return error.TestUnexpectedResult,
    };
    try testing.expect(!ls.isVar());

    const p = ls.pattern() orelse return error.TestExpectedNonNull;
    try testing.expectEqualStrings("x", p.bindingName().?.text);

    const e = ls.initializer() orelse return error.TestExpectedNonNull;
    const lit = switch (e) {
        .string_lit => |s| s,
        else => return error.TestUnexpectedResult,
    };
    const sval = (try lit.value(a)) orelse return error.TestExpectedNonNull;
    try testing.expectEqualStrings("hi", sval);
}

test "LetStmt: var binding reports isVar" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const var_node = try cst.makeNode(a, .VAR_STMT, &[_]cst.Element{
        cst.makeToken(.KW_VAR, "var", 0),
    });
    const ls = switch (Stmt.cast(var_node).?) {
        .let_stmt => |x| x,
        else => return error.TestUnexpectedResult,
    };
    try testing.expect(ls.isVar());
}

test "ReturnStmt.value: present and bare" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const val = try cst.makeNode(a, .STR_LITERAL, &[_]cst.Element{
        cst.makeToken(.STR_PLAIN, "\"0.1.0\"", 7),
    });
    const ret = try cst.makeNode(a, .RETURN_STMT, &[_]cst.Element{
        cst.makeToken(.KW_RETURN, "return", 0),
        cst.makeToken(.WHITESPACE, " ", 6),
        .{ .node = val },
    });
    const rs = switch (Stmt.cast(ret).?) {
        .return_stmt => |x| x,
        else => return error.TestUnexpectedResult,
    };
    try testing.expect(rs.value() != null);

    const bare = try cst.makeNode(a, .RETURN_STMT, &[_]cst.Element{
        cst.makeToken(.KW_RETURN, "return", 0),
    });
    const rs2 = switch (Stmt.cast(bare).?) {
        .return_stmt => |x| x,
        else => return error.TestUnexpectedResult,
    };
    try testing.expect(rs2.value() == null);
}

test "ReturnType.text: strips the arrow and trims trivia" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `-> str`
    const rt = try cst.makeNode(a, .RETURN_TYPE, &[_]cst.Element{
        cst.makeToken(.ARROW, "->", 0),
        cst.makeToken(.WHITESPACE, " ", 2),
        cst.makeToken(.IDENT, "str", 3),
    });
    const txt = (try (ReturnType{ .cst = rt }).text(a)) orelse return error.TestExpectedNonNull;
    try testing.expectEqualStrings("str", txt);

    // `->` with no type tokens yields null.
    const empty = try cst.makeNode(a, .RETURN_TYPE, &[_]cst.Element{
        cst.makeToken(.ARROW, "->", 0),
    });
    try testing.expect((try (ReturnType{ .cst = empty }).text(a)) == null);
}

test "Pattern.bindingName: ident binds, wildcard does not" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ident = try cst.makeNode(a, .IDENT_PATTERN, &[_]cst.Element{
        cst.makeToken(.IDENT, "count", 0),
    });
    try testing.expectEqualStrings("count", Pattern.cast(ident).?.bindingName().?.text);

    const wild = try cst.makeNode(a, .WILD_PATTERN, &[_]cst.Element{
        cst.makeToken(.IDENT, "_", 0),
    });
    try testing.expect(Pattern.cast(wild).?.bindingName() == null);

    // A non-pattern node doesn't cast.
    const not_pat = try cst.makeNode(a, .BLOCK, &.{});
    try testing.expect(Pattern.cast(not_pat) == null);
}

test "Params: empty parens, iteration, and Param accessors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const empty = try cst.makeNode(a, .PARAMS, &[_]cst.Element{
        cst.makeToken(.L_PAREN, "(", 0),
        cst.makeToken(.R_PAREN, ")", 1),
    });
    try testing.expect((Params{ .cst = empty }).isEmpty());

    // `(ref count: i32, name: str)`
    const mode = try cst.makeNode(a, .PARAM_MODE, &[_]cst.Element{
        cst.makeToken(.KW_REF, "ref", 1),
    });
    const p0 = try cst.makeNode(a, .PARAM, &[_]cst.Element{
        .{ .node = mode },
        cst.makeToken(.WHITESPACE, " ", 4),
        cst.makeToken(.IDENT, "count", 5),
        cst.makeToken(.COLON, ":", 10),
        cst.makeToken(.WHITESPACE, " ", 11),
        cst.makeToken(.IDENT, "i32", 12),
    });
    const p1 = try cst.makeNode(a, .PARAM, &[_]cst.Element{
        cst.makeToken(.IDENT, "name", 17),
        cst.makeToken(.COLON, ":", 21),
        cst.makeToken(.WHITESPACE, " ", 22),
        cst.makeToken(.IDENT, "str", 23),
    });
    const params = try cst.makeNode(a, .PARAMS, &[_]cst.Element{
        cst.makeToken(.L_PAREN, "(", 0),
        .{ .node = p0 },
        cst.makeToken(.COMMA, ",", 15),
        cst.makeToken(.WHITESPACE, " ", 16),
        .{ .node = p1 },
        cst.makeToken(.R_PAREN, ")", 26),
    });

    const pv = Params{ .cst = params };
    try testing.expect(!pv.isEmpty());

    var it = pv.iter();
    const first = it.next() orelse return error.TestExpectedNonNull;
    try testing.expectEqualStrings("ref", first.mode().?.text);
    try testing.expectEqualStrings("count", first.name().?.text);
    try testing.expectEqualStrings("i32", (try first.typeText(a)).?);

    const second = it.next() orelse return error.TestExpectedNonNull;
    try testing.expect(second.mode() == null);
    try testing.expectEqualStrings("name", second.name().?.text);
    try testing.expectEqualStrings("str", (try second.typeText(a)).?);

    try testing.expect(it.next() == null);
}
