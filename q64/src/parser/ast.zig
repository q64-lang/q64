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

/// The file-level `//!` doc block — the run of `DOC_COMMENT` tokens at the top
/// of the file, before the first item or import. License/test banner `//`
/// comments above it are skipped. Each line's `//!` prefix is stripped and
/// lines are joined with `\n`. `null` when the file has no header doc. Caller
/// owns the slice. Used by `q64 doc --json` for a qube's module documentation.
pub fn fileHeaderDoc(allocator: std.mem.Allocator, sf: SourceFile) !?[]u8 {
    const children = sf.cst.children;
    var end: usize = 0;
    var has_doc = false;
    var started = false;
    var blanks: usize = 0; // consecutive newlines since the last doc line
    for (children, 0..) |c, i| switch (c) {
        .token => |t| switch (t.kind) {
            .WHITESPACE => {},
            .NEWLINE => {
                // A blank line (2+ newlines) ends the contiguous header block,
                // separating it from a following item's own doc comment.
                if (started) {
                    blanks += 1;
                    if (blanks >= 2) break;
                }
            },
            // Banner `//` comments may precede the header doc, but one inside
            // the block (after it starts) ends it.
            .LINE_COMMENT => if (started) break,
            .DOC_COMMENT => {
                has_doc = true;
                started = true;
                blanks = 0;
                end = i + 1;
            },
            else => break,
        },
        .node => break,
    };
    if (!has_doc) return null;
    return joinDocComments(allocator, children[0..end]);
}

/// The `//!` doc block immediately preceding `item_node` among `sf`'s direct
/// children. Walking backward from the item, whitespace and newlines are
/// skipped and contiguous `DOC_COMMENT` tokens are collected; any other token
/// (including a plain `//` comment) or node ends the run. Each line's `//!`
/// prefix is stripped and lines are joined with `\n`. `null` when no doc leads
/// the item. Caller owns the slice. `item_node` must be a direct child of `sf`.
pub fn leadingDoc(
    allocator: std.mem.Allocator,
    sf: SourceFile,
    item_node: *const cst.Node,
) !?[]u8 {
    const children = sf.cst.children;
    var idx: ?usize = null;
    for (children, 0..) |c, i| switch (c) {
        .node => |n| if (n == item_node) {
            idx = i;
            break;
        },
        .token => {},
    };
    const start = idx orelse return null;

    var first: usize = start;
    var has_doc = false;
    var blanks: usize = 0; // consecutive newlines since the last doc line seen
    var i: usize = start;
    while (i > 0) {
        i -= 1;
        switch (children[i]) {
            .token => |t| switch (t.kind) {
                .WHITESPACE => {},
                .NEWLINE => {
                    // A blank line ends the run, separating an item's own doc
                    // from a preceding item's doc or the file header.
                    blanks += 1;
                    if (blanks >= 2) break;
                },
                .DOC_COMMENT => {
                    first = i;
                    has_doc = true;
                    blanks = 0;
                },
                else => break,
            },
            .node => break,
        }
    }
    if (!has_doc) return null;
    return joinDocComments(allocator, children[first..start]);
}

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
    state_decl: StateDecl,
    face_decl: FaceDecl,
    fit_decl: FitDecl,
    screen_decl: ScreenDecl,

    pub fn cast(node: *const cst.Node) ?Item {
        return switch (node.kind) {
            .FN_DECL => .{ .fn_decl = .{ .cst = node } },
            .STRUCT_DECL => .{ .struct_decl = .{ .cst = node } },
            .ENUM_DECL => .{ .enum_decl = .{ .cst = node } },
            .TYPE_DECL => .{ .type_decl = .{ .cst = node } },
            .CONST_DECL => .{ .const_decl = .{ .cst = node } },
            .STATE_DECL => .{ .state_decl = .{ .cst = node } },
            .FACE_DECL => .{ .face_decl = .{ .cst = node } },
            .FIT_DECL => .{ .fit_decl = .{ .cst = node } },
            .SCREEN_DECL => .{ .screen_decl = .{ .cst = node } },
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

    /// The alias identifier of an `import foo as bar` binding, or `null`
    /// when the import has no alias clause.
    pub fn alias(self: ImportStmt) ?cst.Token {
        const ab = firstChildRawNode(self.cst, .ALIAS_BINDING) orelse return null;
        for (ab.children) |c| switch (c) {
            .token => |t| if (t.kind == .IDENT) return t,
            .node => {},
        };
        return null;
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

    /// The raw `<…>` generic-parameter span (`<T: Display>`), or null
    /// for a non-generic function. Internals are tokens pending the
    /// generics grammar; B5 monomorphization reads them directly.
    pub fn genericParams(self: FnDecl) ?*const cst.Node {
        return firstChildRawNode(self.cst, .GENERIC_PARAMS);
    }

    pub fn isGeneric(self: FnDecl) bool {
        return self.genericParams() != null;
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

    /// The field's declared type as source text, or `null` when absent.
    /// Caller owns the returned slice.
    pub fn typeText(self: Field, allocator: std.mem.Allocator) !?[]u8 {
        return joinTokensAfter(allocator, self.cst, .COLON);
    }

    /// The structured field type.
    pub fn type_(self: Field) ?TypeExpr {
        return firstChildType(self.cst);
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

    /// The raw `<…>` generic-parameter span (`<T>`), or null for a
    /// non-generic enum. Internals are tokens pending the generics
    /// grammar, like `FnDecl.genericParams`.
    pub fn genericParams(self: EnumDecl) ?*const cst.Node {
        return firstChildRawNode(self.cst, .GENERIC_PARAMS);
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
/// `None` lexes as `KW_NONE` but names a variant (the prelude `Option`).
pub const Variant = struct {
    cst: *const cst.Node,

    pub fn name(self: Variant) ?cst.Token {
        for (self.cst.children) |c| switch (c) {
            .token => |t| if (t.kind == .IDENT or t.kind == .KW_NONE) return t,
            .node => {},
        };
        return null;
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

    /// The structured aliased type.
    pub fn type_(self: TypeDecl) ?TypeExpr {
        return firstChildType(self.cst);
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

/// `StateDecl := "state" IDENT (":" TypeExpr)? "=" Expr` — module-level
/// reactive state (a mutable instance binding).
pub const StateDecl = struct {
    cst: *const cst.Node,

    pub fn visibility(self: StateDecl) ?Visibility {
        return itemVisibility(self.cst);
    }
    pub fn name(self: StateDecl) ?cst.Token {
        return itemName(self.cst);
    }
    /// The initializer expression after `=`, if present.
    pub fn value(self: StateDecl) ?Expr {
        for (self.cst.children) |c| switch (c) {
            .node => |n| if (Expr.cast(n)) |e| return e,
            .token => {},
        };
        return null;
    }
};

/// `ScreenDecl := "screen" IDENT? "{" (StateDecl | DrawBlock | OnHandler)* "}"`
/// — the QView frontend DSL (spec/reactivity.md, agent-ui.md). Groups reactive
/// `state`, a declarative `draw` block, and `on <event>` handlers. The shell is
/// structured; codegen lowers it to the `qview.*` mutation ops (a follow-up).
pub const ScreenDecl = struct {
    cst: *const cst.Node,

    pub fn visibility(self: ScreenDecl) ?Visibility {
        return itemVisibility(self.cst);
    }
    /// The optional screen name (`screen login { … }`).
    pub fn name(self: ScreenDecl) ?cst.Token {
        return itemName(self.cst);
    }
    /// The `state` / `@state` declarations, in order.
    pub fn states(self: ScreenDecl) ChildIter(StateDecl, .STATE_DECL) {
        return .{ .children = self.cst.children };
    }
    /// The `draw { … }` block, if present (a screen has at most one).
    pub fn draw(self: ScreenDecl) ?DrawBlock {
        return firstChildNode(self.cst, .DRAW_BLOCK, DrawBlock);
    }
    /// The `on <event>(…) { … }` handlers, in order.
    pub fn handlers(self: ScreenDecl) ChildIter(OnHandler, .ON_HANDLER) {
        return .{ .children = self.cst.children };
    }
};

/// `DrawBlock := "draw" Block` — the declarative view body. Its statements are
/// widget calls (e.g. `text(40, 56, 0)`, `button(1, …)`).
pub const DrawBlock = struct {
    cst: *const cst.Node,

    pub fn body(self: DrawBlock) ?Block {
        return firstChildNode(self.cst, .BLOCK, Block);
    }
};

/// `OnHandler := "on" IDENT Params? Block` — an event handler bound to an
/// event name (`on press(id: i64) { … }`).
pub const OnHandler = struct {
    cst: *const cst.Node,

    /// The event name token (`press`, `drag`, …).
    pub fn event(self: OnHandler) ?cst.Token {
        return itemName(self.cst);
    }
    pub fn params(self: OnHandler) ?Params {
        return firstChildNode(self.cst, .PARAMS, Params);
    }
    pub fn body(self: OnHandler) ?Block {
        return firstChildNode(self.cst, .BLOCK, Block);
    }
};

/// A typed iterator over a parent's direct child nodes of one CST `kind`,
/// wrapping each as `View`. (`View` must have a `cst: *const cst.Node` field.)
pub fn ChildIter(comptime View: type, comptime kind: cst.SyntaxKind) type {
    return struct {
        children: []const cst.Element,
        i: usize = 0,

        pub fn next(self: *@This()) ?View {
            while (self.i < self.children.len) : (self.i += 1) {
                switch (self.children[self.i]) {
                    .node => |n| if (n.kind == kind) {
                        self.i += 1;
                        return .{ .cst = n };
                    },
                    .token => {},
                }
            }
            return null;
        }
    };
}

/// `FaceDecl := "face" IDENT GenericParams? FaceSuperList? FaceBody`
/// (B3: the body's method signatures are structured; `type` aliases and
/// `law`s stay raw token runs).
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

    /// The structured method signatures in the face body.
    pub fn methods(self: FaceDecl) MethodIter {
        const body = firstChildRawNode(self.cst, .FACE_BODY) orelse
            return .{ .children = &.{} };
        return .{ .children = body.children };
    }
};

/// `FitDecl := "fit" FitSpec WhereClause? FitBody` (B3: the spec and the
/// body's method signatures are structured; the where clause is raw).
pub const FitDecl = struct {
    cst: *const cst.Node,

    pub fn visibility(self: FitDecl) ?Visibility {
        return itemVisibility(self.cst);
    }
    pub fn isPublic(self: FitDecl) bool {
        return self.visibility() != null;
    }

    /// The first name in the `fit` header (`fit Name : Face` → `Name`,
    /// `fit Eq<Point>` → `Eq`) — the spec's first path's head token.
    pub fn name(self: FitDecl) ?cst.Token {
        const sp = self.spec() orelse return null;
        const te = firstChildType(sp.cst) orelse return null;
        return switch (te) {
            .path => |pt| itemName(pt.cst),
            else => null,
        };
    }

    pub fn spec(self: FitDecl) ?FitSpec {
        const node = firstChildRawNode(self.cst, .FIT_SPEC) orelse return null;
        return .{ .cst = node };
    }

    /// The structured method declarations in the fit body.
    pub fn methods(self: FitDecl) MethodIter {
        const body = firstChildRawNode(self.cst, .FIT_BODY) orelse
            return .{ .children = &.{} };
        return .{ .children = body.children };
    }
};

/// `FitSpec := TypeExpr ":" FaceRef | FaceRef` — which form was written.
/// The single-param form names a target type and a face
/// (`Color : Display`); the multi-param form is one generic face path
/// (`Convert<A, B>`). Whether the written form matches the face's arity
/// is sema's check (TYP201 / TYP202 — the B4 fit registry).
pub const FitSpec = struct {
    cst: *const cst.Node,

    /// True for the `Type : Face` form (a COLON token is present).
    pub fn isColonForm(self: FitSpec) bool {
        for (self.cst.children) |c| switch (c) {
            .token => |t| if (t.kind == .COLON) return true,
            .node => {},
        };
        return false;
    }

    /// The target type before the `:` (`fit Color : Display` → `Color`),
    /// or null in the bare multi-param form.
    pub fn target(self: FitSpec) ?TypeExpr {
        if (!self.isColonForm()) return null;
        return firstChildType(self.cst);
    }

    /// The face reference: the FACE_REF after `:` in the colon form, or
    /// the bare type itself in the multi-param form.
    pub fn face(self: FitSpec) ?TypeExpr {
        if (firstChildRawNode(self.cst, .FACE_REF)) |ref| {
            return firstChildType(ref);
        }
        if (self.isColonForm()) return null; // `:` with a missing/degraded ref
        return firstChildType(self.cst);
    }
};

/// Iterates the METHOD_SIG children of a FACE_BODY / FIT_BODY.
pub const MethodIter = struct {
    children: []const cst.Element,
    i: usize = 0,

    pub fn next(self: *MethodIter) ?MethodSig {
        while (self.i < self.children.len) : (self.i += 1) {
            switch (self.children[self.i]) {
                .node => |n| if (n.kind == .METHOD_SIG) {
                    self.i += 1;
                    return .{ .cst = n };
                },
                .token => {},
            }
        }
        return null;
    }
};

/// `MethodSig := "fn" IDENT GenericParams? "(" Params? ")"
/// ("->" TypeExpr)? EffectSpec? WhereClause? Block?` — a face/fit body
/// item. Effects and where clauses are raw tokens in v0. A body present
/// means a default impl (in a face) or the impl itself (in a fit) —
/// whether one is required is sema's call.
pub const MethodSig = struct {
    cst: *const cst.Node,

    pub fn name(self: MethodSig) ?cst.Token {
        return itemName(self.cst);
    }

    pub fn params(self: MethodSig) ?Params {
        const node = firstChildRawNode(self.cst, .PARAMS) orelse return null;
        return .{ .cst = node };
    }

    pub fn returnType(self: MethodSig) ?ReturnType {
        const node = firstChildRawNode(self.cst, .RETURN_TYPE) orelse return null;
        return .{ .cst = node };
    }

    pub fn body(self: MethodSig) ?Block {
        const node = firstChildRawNode(self.cst, .BLOCK) orelse return null;
        return .{ .cst = node };
    }

    pub fn hasBody(self: MethodSig) bool {
        return self.body() != null;
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

    /// The parameter's binding name — the first `IDENT` (or the `self`
    /// receiver keyword) before the `:`. `null` for ill-formed input
    /// with no name token.
    pub fn name(self: Param) ?cst.Token {
        for (self.cst.children) |c| switch (c) {
            .token => |t| {
                if (t.kind == .COLON) return null;
                if (t.kind == .IDENT or t.kind == .KW_SELF) return t;
            },
            .node => {},
        };
        return null;
    }

    /// True for the `self` receiver parameter of a face/fit method.
    pub fn isSelf(self: Param) bool {
        const nm = self.name() orelse return false;
        return nm.kind == .KW_SELF;
    }

    /// The declared type as source text, trivia-trimmed. `null` when the
    /// parameter has no `: Type` annotation (e.g. a receiver `self`).
    /// Caller owns the returned slice.
    pub fn typeText(self: Param, allocator: std.mem.Allocator) !?[]u8 {
        return joinTokensAfter(allocator, self.cst, .COLON);
    }

    /// The structured parameter type.
    pub fn type_(self: Param) ?TypeExpr {
        return firstChildType(self.cst);
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

    /// The structured return type (`-> Vec<i64>` → a `PathType`).
    pub fn type_(self: ReturnType) ?TypeExpr {
        return firstChildType(self.cst);
    }
};

// =====================================================================
// Type expressions (spec/grammar.md §"Type expressions", v0 floor)
//
// Structured: path (dotted name + raw generic args), ref, slice, array,
// tuple, optional. fn / dyn / union types arrive as a `raw` TYPE_EXPR
// whose `.text()` is the source span. Generic arguments within a path are
// a raw span (`GenericArgs.text()`).
// =====================================================================

pub const TypeExpr = union(enum) {
    path: PathType,
    ref: RefType,
    slice: SliceType,
    array: ArrayType,
    tuple: TupleType,
    optional: OptionalType,
    raw: RawType,

    pub fn cast(node: *const cst.Node) ?TypeExpr {
        return switch (node.kind) {
            .PATH_TYPE => .{ .path = .{ .cst = node } },
            .REF_TYPE => .{ .ref = .{ .cst = node } },
            .SLICE_TYPE => .{ .slice = .{ .cst = node } },
            .ARRAY_TYPE => .{ .array = .{ .cst = node } },
            .TUPLE_TYPE => .{ .tuple = .{ .cst = node } },
            .OPTIONAL_TYPE => .{ .optional = .{ .cst = node } },
            .TYPE_EXPR => .{ .raw = .{ .cst = node } },
            else => null,
        };
    }

    pub fn isTypeKind(k: cst.SyntaxKind) bool {
        return switch (k) {
            .PATH_TYPE, .REF_TYPE, .SLICE_TYPE, .ARRAY_TYPE, .TUPLE_TYPE, .OPTIONAL_TYPE, .TYPE_EXPR => true,
            else => false,
        };
    }

    /// The full type as source text, trivia-trimmed. Caller owns the slice.
    pub fn text(self: TypeExpr, allocator: std.mem.Allocator) ![]u8 {
        return renderNodeText(allocator, self.cstNode());
    }

    pub fn cstNode(self: TypeExpr) *const cst.Node {
        return switch (self) {
            inline else => |v| v.cst,
        };
    }
};

/// `PathType := IDENT ("." IDENT)* GenericArgs?` — `i64`, `Vec<T>`,
/// `q64.net.Url`.
pub const PathType = struct {
    cst: *const cst.Node,

    /// The dotted name preceding any generic arguments (`Vec`, `q64.net.Url`).
    /// Caller owns the returned slice.
    pub fn name(self: PathType, allocator: std.mem.Allocator) ![]u8 {
        var total: usize = 0;
        for (self.cst.children) |c| switch (c) {
            .token => |t| if (!t.kind.isTrivia()) {
                total += t.text.len;
            },
            .node => {}, // GENERIC_ARGS — excluded from the name
        };
        const buf = try allocator.alloc(u8, total);
        var i: usize = 0;
        for (self.cst.children) |c| switch (c) {
            .token => |t| if (!t.kind.isTrivia()) {
                @memcpy(buf[i .. i + t.text.len], t.text);
                i += t.text.len;
            },
            .node => {},
        };
        return buf;
    }

    pub fn hasGenericArgs(self: PathType) bool {
        return firstChildRawNode(self.cst, .GENERIC_ARGS) != null;
    }

    /// The generic-argument list as source text (`<K, V>`), or `null`.
    pub fn genericArgsText(self: PathType, allocator: std.mem.Allocator) !?[]u8 {
        const ga = firstChildRawNode(self.cst, .GENERIC_ARGS) orelse return null;
        return try renderNodeText(allocator, ga);
    }
};

/// `RefType := "ref" TypeExpr`.
pub const RefType = struct {
    cst: *const cst.Node,
    pub fn inner(self: RefType) ?TypeExpr {
        return firstChildType(self.cst);
    }
};

/// `SliceType := "[" TypeExpr "]"`.
pub const SliceType = struct {
    cst: *const cst.Node,
    pub fn element(self: SliceType) ?TypeExpr {
        return firstChildType(self.cst);
    }
};

/// `ArrayType := "[" TypeExpr ";" Count "]"` (count is a raw span).
pub const ArrayType = struct {
    cst: *const cst.Node,
    pub fn element(self: ArrayType) ?TypeExpr {
        return firstChildType(self.cst);
    }
};

/// `TupleType := "(" TypeExpr ("," TypeExpr)* ")"` (also `()`).
pub const TupleType = struct {
    cst: *const cst.Node,
    pub fn elements(self: TupleType) TypeIter {
        return .{ .children = self.cst.children };
    }
};

/// `OptionalType := TypeExpr "?"`.
pub const OptionalType = struct {
    cst: *const cst.Node,
    pub fn inner(self: OptionalType) ?TypeExpr {
        return firstChildType(self.cst);
    }
};

/// A type form the v0 parser leaves unstructured (fn / dyn / union).
pub const RawType = struct {
    cst: *const cst.Node,
    pub fn text(self: RawType, allocator: std.mem.Allocator) ![]u8 {
        return renderNodeText(allocator, self.cst);
    }
};

pub const TypeIter = struct {
    children: []const cst.Element,
    i: usize = 0,

    pub fn next(self: *TypeIter) ?TypeExpr {
        while (self.i < self.children.len) : (self.i += 1) {
            switch (self.children[self.i]) {
                .node => |n| if (TypeExpr.cast(n)) |t| {
                    self.i += 1;
                    return t;
                },
                .token => {},
            }
        }
        return null;
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
    assign_stmt: AssignStmt,
    if_stmt: IfStmt,
    while_stmt: WhileStmt,
    loop_stmt: LoopStmt,
    for_stmt: ForStmt,
    match_stmt: MatchStmt,
    break_stmt: BreakStmt,
    continue_stmt: ContinueStmt,
    panic_stmt: PanicStmt,

    pub fn cast(node: *const cst.Node) ?Stmt {
        return switch (node.kind) {
            .EXPR_STMT => .{ .expr_stmt = .{ .cst = node } },
            .LET_STMT, .VAR_STMT => .{ .let_stmt = .{ .cst = node } },
            .RETURN_STMT => .{ .return_stmt = .{ .cst = node } },
            .ASSIGN_STMT => .{ .assign_stmt = .{ .cst = node } },
            .IF_STMT => .{ .if_stmt = .{ .cst = node } },
            .WHILE_STMT => .{ .while_stmt = .{ .cst = node } },
            .LOOP_STMT => .{ .loop_stmt = .{ .cst = node } },
            .FOR_STMT => .{ .for_stmt = .{ .cst = node } },
            .MATCH_STMT => .{ .match_stmt = .{ .cst = node } },
            .BREAK_STMT => .{ .break_stmt = .{ .cst = node } },
            .CONTINUE_STMT => .{ .continue_stmt = .{ .cst = node } },
            .PANIC_STMT => .{ .panic_stmt = .{ .cst = node } },
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
    /// The `: TypeExpr` annotation between the pattern and `=` is a
    /// type node (never `Expr`-shaped), so the first `Expr` child is
    /// the value.
    pub fn initializer(self: LetStmt) ?Expr {
        for (self.cst.children) |c| switch (c) {
            .node => |n| if (Expr.cast(n)) |e| return e,
            .token => {},
        };
        return null;
    }

    /// The structured `: TypeExpr` annotation, or `null` when the binding
    /// is unannotated.
    pub fn type_(self: LetStmt) ?TypeExpr {
        return firstChildType(self.cst);
    }
};

/// `ReturnStmt := "return" Expr?` (spec/grammar.md §Statements).
pub const ReturnStmt = struct {
    cst: *const cst.Node,

    /// The returned expression, or `null` for a bare `return`.
    pub fn value(self: ReturnStmt) ?Expr {
        return firstChildExpr(self.cst);
    }
};

// =====================================================================
// Control-flow and assignment statements
//
// Bodies are `Block`s, conditions/scrutinees are `Expr`s, and for/match
// patterns reuse `Pattern`. Guards, `if let` condition bindings, and
// `for`/`match` pattern *internals* beyond a simple binding stay raw
// spans pending the pattern grammar.
// =====================================================================

/// `AssignStmt := LValue AssignOp Expr` (spec/grammar.md §Statements).
pub const AssignStmt = struct {
    cst: *const cst.Node,

    /// The assignment target (l-value) — the first expression.
    pub fn target(self: AssignStmt) ?Expr {
        return nthChildExpr(self.cst, 0);
    }
    /// The assigned value — the second expression.
    pub fn value(self: AssignStmt) ?Expr {
        return nthChildExpr(self.cst, 1);
    }
    /// The assignment operator token (`=`, `+=`, …).
    pub fn op(self: AssignStmt) ?cst.Token {
        for (self.cst.children) |c| switch (c) {
            .token => |t| switch (t.kind) {
                .EQ, .PLUS_EQ, .MINUS_EQ, .STAR_EQ, .SLASH_EQ, .PERCENT_EQ => return t,
                else => {},
            },
            .node => {},
        };
        return null;
    }
};

/// `IfStmt := "if" (Expr | IfCondLet) Block ("else" (IfStmt | Block))?`.
pub const IfStmt = struct {
    cst: *const cst.Node,

    /// The condition expression; `null` for an `if let …` binding form.
    pub fn condition(self: IfStmt) ?Expr {
        return nthChildExpr(self.cst, 0);
    }
    /// The `then` block.
    pub fn thenBody(self: IfStmt) ?Block {
        return nthChildBlock(self.cst, 0);
    }
    /// The `else { … }` block, if the else branch is a plain block.
    pub fn elseBody(self: IfStmt) ?Block {
        return nthChildBlock(self.cst, 1);
    }
    /// The `else if …` branch, if the else branch is another `if`.
    pub fn elseIf(self: IfStmt) ?IfStmt {
        return firstChildNode(self.cst, .IF_STMT, IfStmt);
    }
    /// The `if let …` binding head, if this is the binding form.
    pub fn ifLet(self: IfStmt) ?IfCondLet {
        return firstChildNode(self.cst, .IF_COND_LET, IfCondLet);
    }
};

/// `IfCondLet := "let" Pattern "=" Expr` — the `if let` binding head.
pub const IfCondLet = struct {
    cst: *const cst.Node,

    pub fn pattern(self: IfCondLet) ?Pattern {
        for (self.cst.children) |c| switch (c) {
            .node => |n| if (Pattern.cast(n)) |p| return p,
            .token => {},
        };
        return null;
    }
    /// The scrutinee expression (after the `=`).
    pub fn scrutinee(self: IfCondLet) ?Expr {
        return nthChildExpr(self.cst, 0);
    }
};

/// `WhileStmt := "while" Expr Block`.
pub const WhileStmt = struct {
    cst: *const cst.Node,

    pub fn condition(self: WhileStmt) ?Expr {
        return firstChildExpr(self.cst);
    }
    pub fn body(self: WhileStmt) ?Block {
        return firstChildNode(self.cst, .BLOCK, Block);
    }
};

/// `LoopStmt := "loop" Block`.
pub const LoopStmt = struct {
    cst: *const cst.Node,

    pub fn body(self: LoopStmt) ?Block {
        return firstChildNode(self.cst, .BLOCK, Block);
    }
};

/// `ForStmt := "for" Pattern "in" Expr Block`.
pub const ForStmt = struct {
    cst: *const cst.Node,

    pub fn pattern(self: ForStmt) ?Pattern {
        return firstChildPattern(self.cst);
    }
    pub fn iterable(self: ForStmt) ?Expr {
        return firstChildExpr(self.cst);
    }
    pub fn body(self: ForStmt) ?Block {
        return firstChildNode(self.cst, .BLOCK, Block);
    }
};

/// `MatchStmt := "match" Expr "{" MatchArm,* "}"`.
pub const MatchStmt = struct {
    cst: *const cst.Node,

    pub fn scrutinee(self: MatchStmt) ?Expr {
        return firstChildExpr(self.cst);
    }
    pub fn arms(self: MatchStmt) MatchArmIter {
        return .{ .children = self.cst.children };
    }
};

/// `match` in expression position (`let x = match l { … }`) — the
/// same scrutinee/arms shape as `MatchStmt`, yielding a value.
pub const MatchExpr = struct {
    cst: *const cst.Node,

    pub fn scrutinee(self: MatchExpr) ?Expr {
        return firstChildExpr(self.cst);
    }

    pub fn arms(self: MatchExpr) MatchArmIter {
        return .{ .children = self.cst.children };
    }
};

pub const MatchArmIter = struct {
    children: []const cst.Element,
    i: usize = 0,

    pub fn next(self: *MatchArmIter) ?MatchArm {
        while (self.i < self.children.len) : (self.i += 1) {
            switch (self.children[self.i]) {
                .node => |n| if (n.kind == .MATCH_ARM) {
                    self.i += 1;
                    return .{ .cst = n };
                },
                .token => {},
            }
        }
        return null;
    }
};

/// `MatchArm := Pattern ("if" Expr)? "->" (Block | Expr)` (guard raw).
pub const MatchArm = struct {
    cst: *const cst.Node,

    pub fn pattern(self: MatchArm) ?Pattern {
        return firstChildPattern(self.cst);
    }
    /// The arm body when it is a block (`-> { … }`).
    pub fn block(self: MatchArm) ?Block {
        return firstChildNode(self.cst, .BLOCK, Block);
    }
    /// The arm body when it is an expression (`-> expr`).
    pub fn expression(self: MatchArm) ?Expr {
        return firstChildExpr(self.cst);
    }
};

/// `BreakStmt := "break" Expr?`.
pub const BreakStmt = struct {
    cst: *const cst.Node,

    pub fn value(self: BreakStmt) ?Expr {
        return firstChildExpr(self.cst);
    }
};

/// `ContinueStmt := "continue"`.
pub const ContinueStmt = struct { cst: *const cst.Node };

/// `PanicStmt := "panic" Expr?`.
pub const PanicStmt = struct {
    cst: *const cst.Node,

    pub fn value(self: PanicStmt) ?Expr {
        return firstChildExpr(self.cst);
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

/// Sum of the expression forms the parser produces. `record`/`range`/
/// `lambda`/`spawn`/`channel`/`graph` have CST kinds reserved but no
/// parser productions yet; they join here when those land. Adding a kind:
/// add a CST kind in `cst.zig`, a parse function in `parse.zig`, and a
/// variant here whose `cast` recognizes it.
pub const Expr = union(enum) {
    call: CallExpr,
    path: PathExpr,
    string_lit: StringLit,
    num_lit: NumLit,
    literal: LiteralExpr,
    bin: BinExpr,
    pipe: BinExpr,
    unary: UnaryExpr,
    @"try": TryExpr,
    index: IndexExpr,
    field: FieldExpr,
    method: MethodExpr,
    tuple_field: TupleFieldExpr,
    question_dot: QuestionDotExpr,
    tuple: TupleExpr,
    paren: ParenExpr,
    array: ArrayExpr,
    record: RecordExpr,
    match: MatchExpr,

    pub fn cast(node: *const cst.Node) ?Expr {
        return switch (node.kind) {
            .CALL_EXPR => .{ .call = .{ .cst = node } },
            .RECORD_EXPR => .{ .record = .{ .cst = node } },
            .MATCH_EXPR => .{ .match = .{ .cst = node } },
            .PATH_EXPR => .{ .path = .{ .cst = node } },
            .STR_LITERAL => .{ .string_lit = .{ .cst = node } },
            .NUM_LITERAL => .{ .num_lit = .{ .cst = node } },
            .LITERAL_EXPR => .{ .literal = .{ .cst = node } },
            .BIN_EXPR => .{ .bin = .{ .cst = node } },
            .PIPE_EXPR => .{ .pipe = .{ .cst = node } },
            .UNARY_EXPR => .{ .unary = .{ .cst = node } },
            .TRY_EXPR => .{ .@"try" = .{ .cst = node } },
            .INDEX_EXPR => .{ .index = .{ .cst = node } },
            .FIELD_EXPR => .{ .field = .{ .cst = node } },
            .METHOD_EXPR => .{ .method = .{ .cst = node } },
            .TUPLE_FIELD_EXPR => .{ .tuple_field = .{ .cst = node } },
            .QUESTION_DOT_EXPR => .{ .question_dot = .{ .cst = node } },
            .TUPLE_EXPR => .{ .tuple = .{ .cst = node } },
            .PAREN_EXPR => .{ .paren = .{ .cst = node } },
            .ARRAY_EXPR => .{ .array = .{ .cst = node } },
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
            // Keep in sync with Parser.isPathStart: keywords admissible as a
            // path/field segment. `on` is needed so the host-face op
            // `qview.on(...)` (spec/qview-protocol.md) reconstructs its dotted
            // name including the `on` segment; `self` so a method body's
            // receiver access (`self.w`) reconstructs whole.
            .IDENT, .DOT, .KW_IN, .KW_OUT, .KW_REF, .KW_MOVE, .KW_ON, .KW_SELF => true,
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
        const t = self.token() orelse return null;
        return t.text;
    }

    /// The numeric token itself (its kind tells INT_LIT from FLOAT_LIT).
    pub fn token(self: NumLit) ?cst.Token {
        for (self.cst.children) |c| switch (c) {
            .token => |t| if (t.kind == .INT_LIT or t.kind == .FLOAT_LIT) return t,
            .node => {},
        };
        return null;
    }
};

pub const LiteralExpr = struct {
    cst: *const cst.Node,

    /// The literal's keyword token (`true` / `false` / `none`), if it is one
    /// of those forms. Other literals (numbers, strings) have their own
    /// `Expr` variants, so a `LiteralExpr` only ever holds a keyword token.
    pub fn token(self: LiteralExpr) ?cst.Token {
        for (self.cst.children) |c| switch (c) {
            .token => |t| if (t.kind == .KW_TRUE or t.kind == .KW_FALSE or t.kind == .KW_NONE) return t,
            .node => {},
        };
        return null;
    }
};

// =====================================================================
// Operator and postfix expressions
// =====================================================================

/// `BinExpr := Expr BinOp Expr` (also used for the `|>` pipe form, which
/// has the same shape). `op` is the operator token between the operands.
pub const BinExpr = struct {
    cst: *const cst.Node,

    pub fn lhs(self: BinExpr) ?Expr {
        return nthChildExpr(self.cst, 0);
    }
    pub fn rhs(self: BinExpr) ?Expr {
        return nthChildExpr(self.cst, 1);
    }
    pub fn op(self: BinExpr) ?cst.Token {
        return firstNonTriviaToken(self.cst);
    }
};

/// `UnaryExpr := UnaryOp Expr` (`!`, `-`, `~`, `ref`, `move`).
pub const UnaryExpr = struct {
    cst: *const cst.Node,

    pub fn op(self: UnaryExpr) ?cst.Token {
        return firstNonTriviaToken(self.cst);
    }
    pub fn operand(self: UnaryExpr) ?Expr {
        return firstChildExpr(self.cst);
    }
};

/// `TryExpr := "try" Expr`.
pub const TryExpr = struct {
    cst: *const cst.Node,

    pub fn operand(self: TryExpr) ?Expr {
        return firstChildExpr(self.cst);
    }
};

/// `IndexExpr := Expr "[" Expr "]"`.
pub const IndexExpr = struct {
    cst: *const cst.Node,

    pub fn base(self: IndexExpr) ?Expr {
        return nthChildExpr(self.cst, 0);
    }
    pub fn index(self: IndexExpr) ?Expr {
        return nthChildExpr(self.cst, 1);
    }
};

/// `FieldExpr := Expr "." IDENT`.
pub const FieldExpr = struct {
    cst: *const cst.Node,

    pub fn base(self: FieldExpr) ?Expr {
        return firstChildExpr(self.cst);
    }
    /// The accessed field name (the token after `.`).
    pub fn field(self: FieldExpr) ?cst.Token {
        return lastNonTriviaToken(self.cst);
    }
};

/// `MethodExpr := Expr "." IDENT "(" Args? ")"`.
pub const MethodExpr = struct {
    cst: *const cst.Node,

    pub fn receiver(self: MethodExpr) ?Expr {
        return firstChildExpr(self.cst);
    }
    /// The method name (the token between `.` and `(`).
    pub fn method(self: MethodExpr) ?cst.Token {
        // The last token before the CALL_ARGS node is the method name.
        var name: ?cst.Token = null;
        for (self.cst.children) |c| switch (c) {
            .token => |t| if (!t.kind.isTrivia() and t.kind != .DOT) {
                name = t;
            },
            .node => |n| if (n.kind == .CALL_ARGS) break,
        };
        return name;
    }
    pub fn args(self: MethodExpr) ArgIter {
        for (self.cst.children) |c| switch (c) {
            .node => |n| if (n.kind == .CALL_ARGS) return .{ .children = n.children },
            .token => {},
        };
        return .{ .children = &.{} };
    }
};

/// `TupleFieldExpr := Expr "." INT` (e.g. `pair.0`).
pub const TupleFieldExpr = struct {
    cst: *const cst.Node,

    pub fn base(self: TupleFieldExpr) ?Expr {
        return firstChildExpr(self.cst);
    }
    /// The tuple-index token (`0`, `1`, …).
    pub fn index(self: TupleFieldExpr) ?cst.Token {
        return lastNonTriviaToken(self.cst);
    }
};

/// `QuestionDotExpr := Expr "?." IDENT` (Option chaining).
pub const QuestionDotExpr = struct {
    cst: *const cst.Node,

    pub fn base(self: QuestionDotExpr) ?Expr {
        return firstChildExpr(self.cst);
    }
    pub fn field(self: QuestionDotExpr) ?cst.Token {
        return lastNonTriviaToken(self.cst);
    }
};

/// `TupleExpr := "(" Expr ("," Expr)+ ")"`.
pub const TupleExpr = struct {
    cst: *const cst.Node,

    pub fn elements(self: TupleExpr) ExprIter {
        return .{ .children = self.cst.children };
    }
};

/// `ParenExpr := "(" Expr ")"`.
pub const ParenExpr = struct {
    cst: *const cst.Node,

    pub fn inner(self: ParenExpr) ?Expr {
        return firstChildExpr(self.cst);
    }
};

/// `ArrayExpr := "[" Expr,* "]"` (or `[Expr ";" Count]`).
pub const ArrayExpr = struct {
    cst: *const cst.Node,

    pub fn elements(self: ArrayExpr) ExprIter {
        return .{ .children = self.cst.children };
    }
};

/// `RecordExpr := PathExpr "{" (RecordInit ("," RecordInit)* ","?)? "}"`
/// (spec/grammar.md §"Record literals") — `Point { x: 1, y: 2 }`.
pub const RecordExpr = struct {
    cst: *const cst.Node,

    /// The type path before the brace (`Point`, `q64.math.Vec3`).
    pub fn path(self: RecordExpr) ?PathExpr {
        for (self.cst.children) |c| switch (c) {
            .node => |n| if (n.kind == .PATH_EXPR) return .{ .cst = n },
            .token => {},
        };
        return null;
    }

    pub fn inits(self: RecordExpr) RecordInitIter {
        return .{ .children = self.cst.children };
    }
};

pub const RecordInitIter = struct {
    children: []const cst.Element,
    i: usize = 0,

    pub fn next(self: *RecordInitIter) ?RecordInit {
        while (self.i < self.children.len) : (self.i += 1) {
            switch (self.children[self.i]) {
                .node => |n| if (n.kind == .RECORD_INIT) {
                    self.i += 1;
                    return .{ .cst = n };
                },
                .token => {},
            }
        }
        return null;
    }
};

/// One `field: value` (or shorthand `field`) initializer.
pub const RecordInit = struct {
    cst: *const cst.Node,

    pub fn name(self: RecordInit) ?cst.Token {
        for (self.cst.children) |c| switch (c) {
            .token => |t| if (t.kind == .IDENT) return t,
            .node => {},
        };
        return null;
    }

    /// The initializer value; `null` for the shorthand form.
    pub fn value(self: RecordInit) ?Expr {
        return firstChildExpr(self.cst);
    }
};

/// Iterates the `Expr`-shaped child nodes of a node (tuple/array elements).
pub const ExprIter = struct {
    children: []const cst.Element,
    i: usize = 0,

    pub fn next(self: *ExprIter) ?Expr {
        while (self.i < self.children.len) : (self.i += 1) {
            switch (self.children[self.i]) {
                .node => |n| if (Expr.cast(n)) |e| {
                    self.i += 1;
                    return e;
                },
                .token => {},
            }
        }
        return null;
    }
};

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

fn firstChildExpr(parent: *const cst.Node) ?Expr {
    return nthChildExpr(parent, 0);
}

/// The `n`-th `Expr`-shaped child node (0-based), skipping non-expression
/// nodes (patterns, blocks, …) and tokens.
fn nthChildExpr(parent: *const cst.Node, n: usize) ?Expr {
    var seen: usize = 0;
    for (parent.children) |c| switch (c) {
        .node => |node| if (Expr.cast(node)) |e| {
            if (seen == n) return e;
            seen += 1;
        },
        .token => {},
    };
    return null;
}

/// The `n`-th `BLOCK` child (0-based).
fn nthChildBlock(parent: *const cst.Node, n: usize) ?Block {
    var seen: usize = 0;
    for (parent.children) |c| switch (c) {
        .node => |node| if (node.kind == .BLOCK) {
            if (seen == n) return .{ .cst = node };
            seen += 1;
        },
        .token => {},
    };
    return null;
}

fn firstChildPattern(parent: *const cst.Node) ?Pattern {
    for (parent.children) |c| switch (c) {
        .node => |n| if (Pattern.cast(n)) |p| return p,
        .token => {},
    };
    return null;
}

fn firstChildType(parent: *const cst.Node) ?TypeExpr {
    for (parent.children) |c| switch (c) {
        .node => |n| if (TypeExpr.cast(n)) |t| return t,
        .token => {},
    };
    return null;
}

/// Join the text of every `DOC_COMMENT` token in `elems`, stripping each
/// line's `//!` prefix (and one optional following space) and separating lines
/// with `\n`. Non-doc elements are ignored. `null` if none are present. Caller
/// owns the slice.
fn joinDocComments(allocator: std.mem.Allocator, elems: []const cst.Element) !?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var n: usize = 0;
    for (elems) |c| switch (c) {
        .token => |t| if (t.kind == .DOC_COMMENT) {
            if (n > 0) try out.append(allocator, '\n');
            try out.appendSlice(allocator, stripDocPrefix(t.text));
            n += 1;
        },
        .node => {},
    };
    if (n == 0) {
        out.deinit(allocator);
        return null;
    }
    return try out.toOwnedSlice(allocator);
}

/// Strip the `//!` lead (and one following space) from a doc-comment token's
/// text, plus any trailing CR left by a CRLF line ending.
fn stripDocPrefix(text: []const u8) []const u8 {
    var s = text;
    if (std.mem.startsWith(u8, s, "//!")) s = s[3..];
    if (s.len > 0 and s[0] == ' ') s = s[1..];
    if (s.len > 0 and s[s.len - 1] == '\r') s = s[0 .. s.len - 1];
    return s;
}

/// Render all of `node`'s leaf tokens as source text, trivia-trimmed.
/// Caller owns the slice.
fn renderNodeText(allocator: std.mem.Allocator, node: *const cst.Node) ![]u8 {
    const total = nodeTokenLen(node);
    const buf = try allocator.alloc(u8, total);
    var i: usize = 0;
    appendNodeTokens(node, buf, &i);
    const trimmed = std.mem.trim(u8, buf, " \t\r\n");
    if (trimmed.len == buf.len) return buf;
    const out = try allocator.dupe(u8, trimmed);
    allocator.free(buf);
    return out;
}

fn firstNonTriviaToken(parent: *const cst.Node) ?cst.Token {
    for (parent.children) |c| switch (c) {
        .token => |t| if (!t.kind.isTrivia()) return t,
        .node => {},
    };
    return null;
}

fn lastNonTriviaToken(parent: *const cst.Node) ?cst.Token {
    var last: ?cst.Token = null;
    for (parent.children) |c| switch (c) {
        .token => |t| if (!t.kind.isTrivia()) {
            last = t;
        },
        .node => {},
    };
    return last;
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
        // A structured child (e.g. a TypeExpr node after `->`/`:`)
        // contributes all of its leaf tokens.
        .node => |n| if (seen) {
            total += nodeTokenLen(n);
        },
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
        .node => |n| if (seen) appendNodeTokens(n, buf, &i),
    };

    const trimmed = std.mem.trim(u8, buf, " \t\r\n");
    if (trimmed.len == buf.len) return buf;
    const out = try allocator.dupe(u8, trimmed);
    allocator.free(buf);
    return out;
}

/// Total byte length of all leaf tokens under `node` (recursive).
fn nodeTokenLen(node: *const cst.Node) usize {
    var total: usize = 0;
    for (node.children) |c| switch (c) {
        .token => |t| total += t.text.len,
        .node => |n| total += nodeTokenLen(n),
    };
    return total;
}

/// Append every leaf token's text under `node` into `buf` at `*i`.
fn appendNodeTokens(node: *const cst.Node, buf: []u8, i: *usize) void {
    for (node.children) |c| switch (c) {
        .token => |t| {
            @memcpy(buf[i.* .. i.* + t.text.len], t.text);
            i.* += t.text.len;
        },
        .node => |n| appendNodeTokens(n, buf, i),
    };
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
    const if_node = try cst.makeNode(a, .IF_STMT, &.{});
    const other = try cst.makeNode(a, .BLOCK, &.{}); // not a statement node

    const tag = std.meta.activeTag;
    try testing.expectEqual(tag(Stmt.cast(let_node).?), .let_stmt);
    try testing.expectEqual(tag(Stmt.cast(var_node).?), .let_stmt);
    try testing.expectEqual(tag(Stmt.cast(ret_node).?), .return_stmt);
    try testing.expectEqual(tag(Stmt.cast(expr_node).?), .expr_stmt);
    try testing.expectEqual(tag(Stmt.cast(if_node).?), .if_stmt);
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

test "fileHeaderDoc: collects the header block, stops at a blank line" {
    const parse = @import("parse.zig");
    // Banner `//` comments precede the header; a blank line separates it from
    // the item's own doc, which must NOT be folded into the header.
    const src =
        \\// banner
        \\//! line one.
        \\//! line two.
        \\
        \\//! item doc.
        \\fn main {}
        \\
    ;
    var r = try parse.parse(testing.allocator, src, "h.q");
    defer r.deinit(testing.allocator);
    const sf = SourceFile.cast(r.root).?;

    const hdr = (try fileHeaderDoc(testing.allocator, sf)) orelse return error.TestExpectedNonNull;
    defer testing.allocator.free(hdr);
    try testing.expectEqualStrings("line one.\nline two.", hdr);
}

test "fileHeaderDoc: null when the file opens with an item" {
    const parse = @import("parse.zig");
    var r = try parse.parse(testing.allocator, "fn main {}\n", "h.q");
    defer r.deinit(testing.allocator);
    const sf = SourceFile.cast(r.root).?;
    try testing.expect((try fileHeaderDoc(testing.allocator, sf)) == null);
}

test "leadingDoc: the contiguous block directly above an item, not the header" {
    const parse = @import("parse.zig");
    const src =
        \\//! header.
        \\
        \\//! Adds.
        \\pub fn add(a: i64, b: i64) -> i64 { a + b }
        \\
    ;
    var r = try parse.parse(testing.allocator, src, "lib.q");
    defer r.deinit(testing.allocator);
    const sf = SourceFile.cast(r.root).?;

    var items = sf.items();
    const item = items.next() orelse return error.TestExpectedNonNull;
    const doc = (try leadingDoc(testing.allocator, sf, item.fn_decl.cst)) orelse return error.TestExpectedNonNull;
    defer testing.allocator.free(doc);
    try testing.expectEqualStrings("Adds.", doc);
}

test "leadingDoc: null when a blank line separates doc from item" {
    const parse = @import("parse.zig");
    const src =
        \\//! detached.
        \\
        \\fn main {}
        \\
    ;
    var r = try parse.parse(testing.allocator, src, "m.q");
    defer r.deinit(testing.allocator);
    const sf = SourceFile.cast(r.root).?;
    var items = sf.items();
    const item = items.next() orelse return error.TestExpectedNonNull;
    // The lone doc is the file header, separated by a blank line — not the
    // item's leading doc.
    try testing.expect((try leadingDoc(testing.allocator, sf, item.fn_decl.cst)) == null);
}
