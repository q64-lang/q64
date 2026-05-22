//! Concrete Syntax Tree (CST) for q64.
//!
//! The tree is lossless: walking it and concatenating every token's
//! text reproduces the original source byte-for-byte. Trivia
//! (whitespace, newlines, comments) appears as token kinds; it is
//! not a separate field.
//!
//! Shape: Roslyn-lite, single-tree. Every position is either a Token
//! (leaf) or a Node (composite with an ordered child list). The
//! same `SyntaxKind` enum names both — token kinds and non-terminal
//! kinds share the namespace, distinguished by which payload they
//! attach to.
//!
//! See spec/grammar.md for the productions each non-terminal kind
//! corresponds to. See spec/tests/ for the golden positives that
//! the lossless invariant `serialize(parse(s)) == s` is checked
//! against.

const std = @import("std");

/// Every grammar-relevant token kind and non-terminal kind. Names
/// match grammar.md's production names where possible (PascalCase
/// → SCREAMING_SNAKE here, in line with Zig enum convention).
pub const SyntaxKind = enum {
    // ---------------------------------------------------------------
    // Lexical: trivia
    // ---------------------------------------------------------------
    WHITESPACE, // spaces and tabs
    NEWLINE, // \n or \r\n
    LINE_COMMENT, // `// …`
    DOC_COMMENT, // `//! …`

    // ---------------------------------------------------------------
    // Lexical: literals
    // ---------------------------------------------------------------
    INT_LIT, // 42, 0xff, 0b1010
    FLOAT_LIT, // 3.14, 1e9
    NUM_SUFFIX, // .i32 / .u8 / .kHz tail of a NUM_LITERAL
    STR_PLAIN, // "..."
    STR_RAW, // r"..." / r#"..."#
    STR_PREFIX, // typed-prefix identifier (url, re, …) before a string
    CHAR_ESCAPE, // not strictly a separate token; reserved for sub-token spans

    // ---------------------------------------------------------------
    // Lexical: identifiers and keywords
    // ---------------------------------------------------------------
    IDENT,

    KW_ACTOR,
    KW_AS,
    KW_BREAK,
    KW_CATCH,
    KW_CONST,
    KW_CONTINUE,
    KW_DYN,
    KW_ELSE,
    KW_ENUM,
    KW_EFFECT,
    KW_FACE,
    KW_FALSE,
    KW_FIT,
    KW_FN,
    KW_FOR,
    KW_FORALL,
    KW_FROM,
    KW_GRAPH,
    KW_HANDLE,
    KW_IF,
    KW_IMPORT,
    KW_IN,
    KW_LAW,
    KW_LET,
    KW_LOOP,
    KW_MATCH,
    KW_MOVE,
    KW_NONE, // capitalized; the prelude None value used in patterns
    KW_OUT,
    KW_PANIC,
    KW_PUB,
    KW_REF,
    KW_REGION,
    KW_RETURN,
    KW_SCOPE,
    KW_SELECT,
    KW_SELF, // lowercase `self`
    KW_SELF_TYPE, // capitalized `Self`
    KW_SPAWN,
    KW_STATE,
    KW_STRUCT,
    KW_TELL,
    KW_TRAP,
    KW_TRUE,
    KW_TRY,
    KW_TYPE,
    KW_USE,
    KW_VAR,
    KW_WHERE,
    KW_WHILE,
    KW_WITH_CAPABILITIES,

    // ---------------------------------------------------------------
    // Lexical: punctuators and operators
    // ---------------------------------------------------------------
    L_PAREN, // (
    R_PAREN, // )
    L_BRACE, // {
    R_BRACE, // }
    L_BRACK, // [
    R_BRACK, // ]
    L_ANGLE, // <  (also less-than; context disambiguates)
    R_ANGLE, // >
    COMMA,
    SEMICOLON,
    COLON,
    COLON_COLON,
    DOT,
    DOT_DOT, // ..
    DOT_DOT_EQ, // ..=
    ARROW, // ->
    FAT_ARROW, // =>
    EQ, // =
    PIPE, // |
    AT, // @
    QUESTION, // ?
    QUESTION_DOT, // ?.
    PIPE_GT, // |>

    // Arithmetic / bitwise / logical
    PLUS,
    MINUS,
    STAR,
    SLASH,
    PERCENT,
    BANG,
    AMP,
    CARET,
    TILDE,
    SHL, // <<
    SHR, // >>
    AMP_AMP, // &&
    PIPE_PIPE, // ||

    // Comparison
    EQ_EQ,
    BANG_EQ,
    LT_EQ,
    GT_EQ,

    // Compound assignment
    PLUS_EQ,
    MINUS_EQ,
    STAR_EQ,
    SLASH_EQ,
    PERCENT_EQ,

    // Sentinels
    EOF,
    ERROR, // lexical error placeholder; carries the offending bytes

    // ===============================================================
    // Composite (non-terminal) nodes — names mirror grammar.md
    // ===============================================================

    SOURCE_FILE,

    // Imports & re-exports
    IMPORT_STMT,
    IMPORT_PATH,
    BARE_DOTTED,
    QUOTED_RELATIVE,
    IMPORT_BINDING,
    SELECTIVE_LIST,
    ALIAS_BINDING,
    RE_EXPORT,
    RE_EXPORT_SPEC,

    // Top-level items
    VISIBILITY,
    FN_DECL,
    STRUCT_DECL,
    ENUM_DECL,
    TYPE_DECL,
    FACE_DECL,
    FIT_DECL,
    CONST_DECL,
    ACTOR_DECL,
    EFFECT_DECL,
    GRAPH_DECL,

    // Function parts
    PARAMS,
    PARAM,
    PARAM_MODE,
    RETURN_TYPE,
    EFFECT_SPEC,
    EFFECT_MARKER,
    WHERE_CLAUSE,
    BOUND,
    BOUND_LIST,

    // Generics
    GENERIC_PARAMS,
    TYPE_PARAM,
    CONST_PARAM,
    REGION_PARAM,
    EFFECT_PARAM,
    GENERIC_ARGS,

    // Type expressions
    PATH_TYPE,
    REF_TYPE,
    DYN_TYPE,
    FN_TYPE,
    FN_TYPE_PARAMS,
    FN_TYPE_PARAM,
    UNION_TYPE,
    ARRAY_TYPE,
    SLICE_TYPE,
    OPTIONAL_TYPE,
    TUPLE_TYPE,
    FACE_REF,

    // Struct / enum bodies
    RECORD_BODY,
    TUPLE_BODY,
    UNIT_BODY,
    FIELD,
    VARIANT,
    VARIANT_PAYLOAD,

    // Face / fit
    FACE_SUPER_LIST,
    FACE_BODY,
    FIT_SPEC,
    FIT_BODY,
    TYPE_ALIAS,
    METHOD_SIG,
    METHOD_DECL,
    METHOD_BODY,
    LAW_DECL,
    QUANT_LIST,
    QUANT_BIND,

    // Actor body
    ACTOR_BODY,
    STATE_DECL,
    HANDLE_DECL,

    // Bindings
    LET_STMT,
    VAR_STMT,
    ASSIGN_STMT,

    // Control flow / statements
    EXPR_STMT,
    IF_STMT,
    IF_COND_LET, // `let Pattern = expr` form of an if condition
    MATCH_STMT,
    MATCH_ARM,
    FOR_STMT,
    LOOP_STMT,
    WHILE_STMT,
    BREAK_STMT,
    CONTINUE_STMT,
    RETURN_STMT,
    REGION_STMT,
    SCOPE_STMT,
    PANIC_STMT,

    // Concurrency
    SPAWN_EXPR,
    CATCH_ARM,
    CHANNEL_EXPR,
    CHAN_ARGS,
    NAMED_ARG,
    SELECT_STMT,
    SELECT_ARM,

    // Capabilities
    WITH_CAPS_STMT,
    CAPS_USE,
    CAPS_DENY,
    CAP_FIELD,

    // Graphs
    GRAPH_EXPR,

    // Annotations
    ANNOTATION,
    ANNOTATION_ARGS,
    ANNOTATION_ARG,

    // Patterns
    WILD_PATTERN,
    LITERAL_PATTERN,
    IDENT_PATTERN,
    TUPLE_PATTERN,
    TUPLE_STRUCT_PATTERN,
    RECORD_STRUCT_PATTERN,
    FIELD_PATTERN,
    ENUM_VARIANT_PATTERN,

    // Expressions
    BLOCK,
    PAREN_EXPR,
    PIPE_EXPR,
    BIN_EXPR,
    UNARY_EXPR,
    TRY_EXPR,
    CALL_EXPR,
    CALL_ARGS,
    CALL_ARG,
    INDEX_EXPR,
    FIELD_EXPR, // expr.name
    TUPLE_FIELD_EXPR, // expr.0
    QUESTION_DOT_EXPR, // expr?.name (Option chain)
    METHOD_EXPR, // expr.name(args)
    PATH_EXPR,
    LITERAL_EXPR,
    NUM_LITERAL,
    STR_LITERAL,
    TUPLE_EXPR,
    ARRAY_EXPR,
    RECORD_EXPR,
    RECORD_INIT,
    RANGE_EXPR,
    LAMBDA_EXPR,
    LAMBDA_PARAMS,

    pub fn isTrivia(self: SyntaxKind) bool {
        return switch (self) {
            .WHITESPACE, .NEWLINE, .LINE_COMMENT, .DOC_COMMENT => true,
            else => false,
        };
    }

    pub fn isToken(self: SyntaxKind) bool {
        // Composite kinds start at SOURCE_FILE; everything before is
        // a token kind. Keep this in sync with the enum order above.
        return @intFromEnum(self) < @intFromEnum(SyntaxKind.SOURCE_FILE);
    }

    pub fn isKeyword(self: SyntaxKind) bool {
        const v = @intFromEnum(self);
        return v >= @intFromEnum(SyntaxKind.KW_ACTOR) and
            v <= @intFromEnum(SyntaxKind.KW_WITH_CAPABILITIES);
    }
};

/// A leaf in the CST. `text` is a slice into the original source
/// buffer (the parser does not copy bytes). `offset` is the absolute
/// byte offset of the first byte of `text` in that buffer.
pub const Token = struct {
    kind: SyntaxKind,
    text: []const u8,
    offset: u32,
};

/// A composite node. `children` is an ordered list of CST elements
/// (tokens and nested nodes) in source order. Trivia tokens appear
/// in this list interleaved with the structural children — the CST
/// is lossless.
pub const Node = struct {
    kind: SyntaxKind,
    children: []const Element,
};

/// Sum of leaf and composite. The CST is built out of these.
pub const Element = union(enum) {
    token: Token,
    node: *const Node,

    pub fn kind(self: Element) SyntaxKind {
        return switch (self) {
            .token => |t| t.kind,
            .node => |n| n.kind,
        };
    }

    pub fn textLen(self: Element) usize {
        return switch (self) {
            .token => |t| t.text.len,
            .node => |n| blk: {
                var sum: usize = 0;
                for (n.children) |c| sum += c.textLen();
                break :blk sum;
            },
        };
    }
};

pub const SerializeError = error{OutOfMemory};

/// Append every token's text to `out` in order. The result equals
/// the original source iff the CST was constructed losslessly. Used
/// by `q64 fmt --check` and by the conformance test runner.
pub fn serialize(root: *const Node, allocator: std.mem.Allocator, out: *std.ArrayList(u8)) SerializeError!void {
    for (root.children) |child| try serializeElement(child, allocator, out);
}

fn serializeElement(elem: Element, allocator: std.mem.Allocator, out: *std.ArrayList(u8)) SerializeError!void {
    switch (elem) {
        .token => |t| try out.appendSlice(allocator, t.text),
        .node => |n| try serialize(n, allocator, out),
    }
}

/// Construct a Node in the supplied arena. The arena owns the
/// children slice; element ordering is the caller's responsibility.
pub fn makeNode(
    arena: std.mem.Allocator,
    kind_: SyntaxKind,
    children: []const Element,
) !*const Node {
    std.debug.assert(!kind_.isToken());
    const node = try arena.create(Node);
    const owned = try arena.dupe(Element, children);
    node.* = .{ .kind = kind_, .children = owned };
    return node;
}

/// Construct a token Element. No allocation — Tokens are stored
/// by value in their parent's children slice.
pub fn makeToken(kind_: SyntaxKind, text: []const u8, offset: u32) Element {
    std.debug.assert(kind_.isToken());
    return .{ .token = .{ .kind = kind_, .text = text, .offset = offset } };
}

/// Tree-walking helpers used by AST views and the formatter.
pub const Walk = struct {
    /// Return the first child whose kind matches. Trivia tokens are
    /// skipped by default; pass `include_trivia = true` to include
    /// them (the formatter does).
    pub fn firstChild(
        node: *const Node,
        kind_: SyntaxKind,
        include_trivia: bool,
    ) ?Element {
        for (node.children) |c| {
            if (!include_trivia and c.kind().isTrivia()) continue;
            if (c.kind() == kind_) return c;
        }
        return null;
    }

    /// Iterator that yields children matching the predicate. Caller
    /// drives via `.next()`.
    pub fn ChildIter(comptime predicate: fn (SyntaxKind) bool) type {
        return struct {
            children: []const Element,
            i: usize = 0,

            pub fn next(self: *@This()) ?Element {
                while (self.i < self.children.len) : (self.i += 1) {
                    const c = self.children[self.i];
                    if (predicate(c.kind())) {
                        self.i += 1;
                        return c;
                    }
                }
                return null;
            }
        };
    }
};

// ===================================================================
// Tests
// ===================================================================

test "kind classification" {
    try std.testing.expect(SyntaxKind.WHITESPACE.isTrivia());
    try std.testing.expect(SyntaxKind.LINE_COMMENT.isTrivia());
    try std.testing.expect(!SyntaxKind.IDENT.isTrivia());

    try std.testing.expect(SyntaxKind.IDENT.isToken());
    try std.testing.expect(SyntaxKind.KW_FN.isToken());
    try std.testing.expect(!SyntaxKind.FN_DECL.isToken());
    try std.testing.expect(!SyntaxKind.SOURCE_FILE.isToken());

    try std.testing.expect(SyntaxKind.KW_FN.isKeyword());
    try std.testing.expect(SyntaxKind.KW_WITH_CAPABILITIES.isKeyword());
    try std.testing.expect(!SyntaxKind.IDENT.isKeyword());
    try std.testing.expect(!SyntaxKind.PLUS.isKeyword());
}

test "lossless serialize: token-only tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Build the CST for: `fn main { }` (roughly).
    const children = [_]Element{
        makeToken(.KW_FN, "fn", 0),
        makeToken(.WHITESPACE, " ", 2),
        makeToken(.IDENT, "main", 3),
        makeToken(.WHITESPACE, " ", 7),
        makeToken(.L_BRACE, "{", 8),
        makeToken(.WHITESPACE, " ", 9),
        makeToken(.R_BRACE, "}", 10),
    };
    const root = try makeNode(a, .SOURCE_FILE, &children);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try serialize(root, std.testing.allocator, &out);

    try std.testing.expectEqualStrings("fn main { }", out.items);
}

test "lossless serialize: nested tree preserves all bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Build the CST for: `fn main {\n    let x = 1\n}`
    //
    //   SOURCE_FILE
    //     FN_DECL
    //       KW_FN  WHITESPACE  IDENT  WHITESPACE
    //       BLOCK
    //         L_BRACE  NEWLINE  WHITESPACE
    //         LET_STMT
    //           KW_LET  WHITESPACE  IDENT  WHITESPACE  EQ  WHITESPACE  INT_LIT
    //         NEWLINE
    //         R_BRACE

    const let_children = [_]Element{
        makeToken(.KW_LET, "let", 14),
        makeToken(.WHITESPACE, " ", 17),
        makeToken(.IDENT, "x", 18),
        makeToken(.WHITESPACE, " ", 19),
        makeToken(.EQ, "=", 20),
        makeToken(.WHITESPACE, " ", 21),
        makeToken(.INT_LIT, "1", 22),
    };
    const let_node = try makeNode(a, .LET_STMT, &let_children);

    const block_children = [_]Element{
        makeToken(.L_BRACE, "{", 8),
        makeToken(.NEWLINE, "\n", 9),
        makeToken(.WHITESPACE, "    ", 10),
        .{ .node = let_node },
        makeToken(.NEWLINE, "\n", 23),
        makeToken(.R_BRACE, "}", 24),
    };
    const block_node = try makeNode(a, .BLOCK, &block_children);

    const fn_children = [_]Element{
        makeToken(.KW_FN, "fn", 0),
        makeToken(.WHITESPACE, " ", 2),
        makeToken(.IDENT, "main", 3),
        makeToken(.WHITESPACE, " ", 7),
        .{ .node = block_node },
    };
    const fn_node = try makeNode(a, .FN_DECL, &fn_children);

    const root_children = [_]Element{.{ .node = fn_node }};
    const root = try makeNode(a, .SOURCE_FILE, &root_children);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try serialize(root, std.testing.allocator, &out);

    const expected = "fn main {\n    let x = 1\n}";
    try std.testing.expectEqualStrings(expected, out.items);
}

test "Walk.firstChild skips trivia by default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const children = [_]Element{
        makeToken(.WHITESPACE, "  ", 0),
        makeToken(.LINE_COMMENT, "// hi\n", 2),
        makeToken(.KW_FN, "fn", 8),
        makeToken(.WHITESPACE, " ", 10),
        makeToken(.IDENT, "main", 11),
    };
    const node = try makeNode(a, .FN_DECL, &children);

    const found = Walk.firstChild(node, .IDENT, false) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("main", found.token.text);
}
