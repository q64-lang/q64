//! Parser — tokens to CST.
//!
//! Recursive-descent, error-tolerant, lossless. Tokens consumed
//! left-to-right; every token (including trivia) lands somewhere in
//! the tree, so `serialize(parse(s)) == s` holds end-to-end.
//!
//! v0 productions implemented:
//!   - SourceFile pass-through (trivia / unknown items appear as
//!     direct token children).
//!   - `Visibility` (`pub`).
//!   - `FnDecl` — `fn IDENT (Params?) (-> TypeExpr)? Block`, with
//!     Params, ReturnType, and Block parsed as balanced groups.
//!     Internals (parameter list, statement structure inside the
//!     block, full type expressions) appear as raw tokens for now;
//!     the AST views in `ast.zig` ignore them.
//!
//! Productions still to land: `struct`, `enum`, `face`, `fit`,
//! `const`, `import` (todo.md). Until those exist, their leading
//! keywords pass through `parseSourceFile` as direct token children
//! so losslessness still holds — they just don't get structured
//! into items yet.

const std = @import("std");
const Allocator = std.mem.Allocator;
const cst = @import("cst.zig");
const lex = @import("lex.zig");
const diag = @import("diag.zig");

pub const Result = struct {
    /// Arena that owns every CST allocation. Caller frees by
    /// calling `Result.deinit`.
    arena: *std.heap.ArenaAllocator,
    root: *const cst.Node,
    diagnostics: []const diag.Diagnostic,

    pub fn deinit(self: Result, allocator: Allocator) void {
        self.arena.deinit();
        allocator.destroy(self.arena);
        allocator.free(self.diagnostics);
    }
};

/// Parse `source` and return the CST + diagnostics. The returned
/// arena owns every CST node and every slice referenced from
/// `root`; callers must keep it alive while walking the tree.
pub fn parse(allocator: Allocator, source: []const u8, file: []const u8) !Result {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }

    const a = arena.allocator();

    const lex_result = try lex.tokenize(a, source);

    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    errdefer diags.deinit(allocator);
    for (lex_result.diagnostics) |d| {
        try diags.append(allocator, .{
            .code = d.code,
            .severity = .err,
            .message = diag.messageFor(d.code),
            .file = file,
            .offset = d.offset,
        });
    }

    var parser = Parser{
        .tokens = lex_result.tokens,
        .pos = 0,
        .arena = a,
        .gpa = allocator,
        .file = file,
        .diags = &diags,
    };
    const root = try parser.parseSourceFile();

    return .{
        .arena = arena,
        .root = root,
        .diagnostics = try diags.toOwnedSlice(allocator),
    };
}

/// Parse a single expression from `source`. Used by codegen to evaluate
/// string-interpolation bodies (`{version()}`) without standing up a
/// whole file. The returned `Result.root` is the expression node
/// (castable via `ast.Expr.cast`); losslessness is not a goal here, so
/// leading trivia is discarded.
pub fn parseExpression(allocator: Allocator, source: []const u8, file: []const u8) !Result {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }

    const a = arena.allocator();
    const lex_result = try lex.tokenize(a, source);

    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    errdefer diags.deinit(allocator);
    for (lex_result.diagnostics) |d| {
        try diags.append(allocator, .{
            .code = d.code,
            .severity = .err,
            .message = diag.messageFor(d.code),
            .file = file,
            .offset = d.offset,
        });
    }

    var parser = Parser{
        .tokens = lex_result.tokens,
        .pos = 0,
        .arena = a,
        .gpa = allocator,
        .file = file,
        .diags = &diags,
    };
    while (!parser.isEof() and parser.peek().isTrivia()) _ = parser.advance();
    const root = if (parser.isEof())
        try cst.makeNode(a, .LITERAL_EXPR, &.{})
    else
        try parser.parseExpr();

    return .{
        .arena = arena,
        .root = root,
        .diagnostics = try diags.toOwnedSlice(allocator),
    };
}

// =====================================================================
// Parser
// =====================================================================

const Parser = struct {
    tokens: []const cst.Token,
    pos: usize,
    arena: Allocator,
    /// Diagnostics emitted during parsing live in the *outer* allocator
    /// (they outlive the CST arena), so the parser keeps a handle to it.
    gpa: Allocator,
    file: []const u8,
    diags: *std.ArrayList(diag.Diagnostic),
    /// Record-literal restriction depth (spec/grammar.md §"Record
    /// literals"). While > 0 — inside the bare condition/scrutinee/
    /// iterable of `if`/`while`/`for`/`match` — `Path {` parses as an
    /// expression followed by the statement's block, not as a record
    /// literal. Parenthesized/bracketed/argument positions reset it to
    /// 0 (the brace is unambiguous again inside delimiters).
    no_record_depth: u32 = 0,

    fn peek(self: *const Parser) cst.SyntaxKind {
        if (self.pos >= self.tokens.len) return .EOF;
        return self.tokens[self.pos].kind;
    }

    fn isEof(self: *const Parser) bool {
        return self.peek() == .EOF;
    }

    fn advance(self: *Parser) cst.Token {
        const t = self.tokens[self.pos];
        self.pos += 1;
        return t;
    }

    fn offsetHere(self: *const Parser) u32 {
        if (self.pos >= self.tokens.len) return 0;
        return self.tokens[self.pos].offset;
    }

    /// Emit a parse-time diagnostic. Used for the syntactic checks the
    /// parser can resolve without a name-resolution pass (the `NAM00x`
    /// import/visibility codes from spec/modules.md §"Forbidden").
    fn emitDiag(self: *Parser, code: []const u8, offset: u32) !void {
        try self.diags.append(self.gpa, .{
            .code = code,
            .severity = .err,
            .message = diag.messageFor(code),
            .file = self.file,
            .offset = offset,
        });
    }

    /// Kind of the next non-trivia token at or after the cursor.
    fn nextNonTrivia(self: *const Parser) cst.SyntaxKind {
        var i = self.pos;
        while (i < self.tokens.len and self.tokens[i].kind.isTrivia()) : (i += 1) {}
        if (i >= self.tokens.len) return .EOF;
        return self.tokens[i].kind;
    }

    /// Kind of the next non-trivia token *after* the current one.
    fn peekSecond(self: *const Parser) cst.SyntaxKind {
        var i = self.pos + 1;
        while (i < self.tokens.len and self.tokens[i].kind.isTrivia()) : (i += 1) {}
        if (i >= self.tokens.len) return .EOF;
        return self.tokens[i].kind;
    }

    /// Parse an expression with the record-literal restriction lifted —
    /// inside parens/brackets/argument lists the `{` is unambiguous.
    fn parseExprUnrestricted(self: *Parser) std.mem.Allocator.Error!*const cst.Node {
        const saved = self.no_record_depth;
        self.no_record_depth = 0;
        defer self.no_record_depth = saved;
        return self.parseExpr();
    }

    /// Kind of the first non-trivia token after the upcoming `.`, or
    /// `.EOF` if the cursor isn't on a `.`. Distinguishes `foo.{a}`
    /// (selective list) and `foo.*` (wildcard) from `foo.bar`.
    fn kindAfterDot(self: *const Parser) cst.SyntaxKind {
        var i = self.pos;
        if (i >= self.tokens.len or self.tokens[i].kind != .DOT) return .EOF;
        i += 1;
        while (i < self.tokens.len and self.tokens[i].kind.isTrivia()) : (i += 1) {}
        if (i >= self.tokens.len) return .EOF;
        return self.tokens[i].kind;
    }

    /// Lookahead used for the block-`pub` check: is the next non-trivia
    /// token after `pub` an opening brace?
    fn pubFollowedByBrace(self: *const Parser) bool {
        var i = self.pos + 1;
        while (i < self.tokens.len and self.tokens[i].kind.isTrivia()) : (i += 1) {}
        return i < self.tokens.len and self.tokens[i].kind == .L_BRACE;
    }

    /// Consume any leading trivia tokens into `out`. Trivia at the
    /// boundary between productions ends up at the *outer* level —
    /// this helper is what places it there.
    fn eatTrivia(self: *Parser, out: *std.ArrayList(cst.Element)) !void {
        while (!self.isEof() and self.peek().isTrivia()) {
            try out.append(self.arena, .{ .token = self.advance() });
        }
    }

    /// The item keyword introducing the upcoming item, skipping an
    /// optional leading `pub`. Returns `.EOF` if there's no item keyword
    /// there (so a stray `pub {` doesn't read as an item).
    fn itemKeyword(self: *const Parser) cst.SyntaxKind {
        var i = self.pos;
        if (i < self.tokens.len and self.tokens[i].kind == .KW_PUB) {
            i += 1;
            while (i < self.tokens.len and self.tokens[i].kind.isTrivia()) : (i += 1) {}
        }
        if (i >= self.tokens.len) return .EOF;
        const k = self.tokens[i].kind;
        return if (isItemKeyword(k)) k else .EOF;
    }

    fn isItemKeyword(k: cst.SyntaxKind) bool {
        return switch (k) {
            .KW_FN, .KW_STRUCT, .KW_ENUM, .KW_TYPE, .KW_CONST, .KW_STATE, .KW_FACE, .KW_FIT, .KW_SCREEN => true,
            else => false,
        };
    }

    /// Consume an optional `pub` visibility prefix (plus trailing trivia)
    /// into `children`. Shared by every item parser.
    fn consumeVisibility(self: *Parser, children: *std.ArrayList(cst.Element)) !void {
        if (self.peek() == .KW_PUB) {
            try children.append(self.arena, .{ .node = try self.parseVisibility() });
            try self.eatTrivia(children);
        }
    }

    // -----------------------------------------------------------------
    // SourceFile
    // -----------------------------------------------------------------

    fn parseSourceFile(self: *Parser) !*const cst.Node {
        var children: std.ArrayList(cst.Element) = .empty;

        while (!self.isEof()) {
            if (self.peek() == .KW_IMPORT) {
                const import_node = try self.parseImportStmt();
                try children.append(self.arena, .{ .node = import_node });
                continue;
            }
            const ik = self.itemKeyword();
            if (ik != .EOF) {
                try children.append(self.arena, .{ .node = try self.parseItem(ik) });
                continue;
            }
            // Block `pub { … }` is forbidden (spec/modules.md). Flag it,
            // then let the `pub` and the block pass through so the inner
            // items still parse and losslessness holds.
            if (self.peek() == .KW_PUB and self.pubFollowedByBrace()) {
                try self.emitDiag("NAM009", self.offsetHere());
                try children.append(self.arena, .{ .token = self.advance() });
                continue;
            }
            // Anything we don't recognize — trivia, unimplemented
            // items, stray tokens — passes through as a direct
            // token child of SOURCE_FILE. Lossless by construction.
            try children.append(self.arena, .{ .token = self.advance() });
        }

        return try cst.makeNode(self.arena, .SOURCE_FILE, children.items);
    }

    // -----------------------------------------------------------------
    // FnDecl
    // -----------------------------------------------------------------

    /// Dispatch to the parser for the item introduced by `kw` (the
    /// keyword `itemKeyword` already peeked past any `pub`).
    fn parseItem(self: *Parser, kw: cst.SyntaxKind) std.mem.Allocator.Error!*const cst.Node {
        return switch (kw) {
            .KW_FN => self.parseFnDecl(),
            .KW_STRUCT => self.parseStructDecl(),
            .KW_ENUM => self.parseEnumDecl(),
            .KW_TYPE => self.parseTypeDecl(),
            .KW_CONST => self.parseConstDecl(),
            .KW_STATE => self.parseStateDecl(),
            .KW_FACE => self.parseFaceDecl(),
            .KW_FIT => self.parseFitDecl(),
            .KW_SCREEN => self.parseScreenDecl(),
            else => unreachable,
        };
    }

    // -----------------------------------------------------------------
    // ScreenDecl — the QView frontend DSL (spec/reactivity.md, agent-ui.md)
    // -----------------------------------------------------------------
    //
    //   ScreenDecl  := "pub"? "screen" IDENT? "{" ScreenMember* "}"
    //   ScreenMember := StateDecl | DrawBlock | OnHandler
    //   DrawBlock   := "draw" Block
    //   OnHandler   := "on" IDENT Params? Block
    //
    // A `screen` groups reactive `state`, a declarative `draw` block of widget
    // calls, and `on <event>` handlers — the view is written once in `draw` and
    // a handler just mutates state (the compiler re-emits the view). Widget
    // calls inside `draw` and statements inside `on` reuse the ordinary block /
    // expression grammar, so this production is the shell; codegen lowers it to
    // the `qview.*` mutation ops (a follow-up). Unrecognized tokens inside the
    // body pass through as direct children, preserving the lossless invariant.
    fn parseScreenDecl(self: *Parser) !*const cst.Node {
        var children: std.ArrayList(cst.Element) = .empty;
        try self.consumeVisibility(&children);
        try children.append(self.arena, .{ .token = self.advance() }); // KW_SCREEN
        try self.eatTrivia(&children);
        if (self.peek() == .IDENT) {
            try children.append(self.arena, .{ .token = self.advance() });
        }
        try self.eatTrivia(&children);
        if (self.peek() == .L_BRACE) {
            try children.append(self.arena, .{ .token = self.advance() }); // {
            while (!self.isEof() and self.peek() != .R_BRACE) {
                if (self.peek().isTrivia()) {
                    try children.append(self.arena, .{ .token = self.advance() });
                    continue;
                }
                switch (self.peek()) {
                    .KW_STATE => try children.append(self.arena, .{ .node = try self.parseStateDecl() }),
                    .KW_DRAW => try children.append(self.arena, .{ .node = try self.parseDrawBlock() }),
                    .KW_ON => try children.append(self.arena, .{ .node = try self.parseOnHandler() }),
                    // Recovery: anything else passes through losslessly.
                    else => try children.append(self.arena, .{ .token = self.advance() }),
                }
            }
            if (self.peek() == .R_BRACE) {
                try children.append(self.arena, .{ .token = self.advance() }); // }
            }
        }
        return try cst.makeNode(self.arena, .SCREEN_DECL, children.items);
    }

    /// `DrawBlock := "draw" Block` — the declarative view body (widget calls).
    fn parseDrawBlock(self: *Parser) !*const cst.Node {
        var children: std.ArrayList(cst.Element) = .empty;
        try children.append(self.arena, .{ .token = self.advance() }); // KW_DRAW
        try self.eatTrivia(&children);
        if (self.peek() == .L_BRACE) {
            try children.append(self.arena, .{ .node = try self.parseBlock() });
        }
        return try cst.makeNode(self.arena, .DRAW_BLOCK, children.items);
    }

    /// `OnHandler := "on" IDENT Params? Block` — an event handler (`on press(id) { … }`).
    fn parseOnHandler(self: *Parser) !*const cst.Node {
        var children: std.ArrayList(cst.Element) = .empty;
        try children.append(self.arena, .{ .token = self.advance() }); // KW_ON
        try self.eatTrivia(&children);
        if (self.peek() == .IDENT) {
            try children.append(self.arena, .{ .token = self.advance() }); // event name
        }
        try self.eatTrivia(&children);
        if (self.peek() == .L_PAREN) {
            try children.append(self.arena, .{ .node = try self.parseParams() });
            try self.eatTrivia(&children);
        }
        if (self.peek() == .L_BRACE) {
            try children.append(self.arena, .{ .node = try self.parseBlock() });
        }
        return try cst.makeNode(self.arena, .ON_HANDLER, children.items);
    }

    fn parseFnDecl(self: *Parser) !*const cst.Node {
        var children: std.ArrayList(cst.Element) = .empty;

        try self.consumeVisibility(&children);

        std.debug.assert(self.peek() == .KW_FN);
        try children.append(self.arena, .{ .token = self.advance() }); // KW_FN
        try self.eatTrivia(&children);

        if (self.peek() == .IDENT) {
            try children.append(self.arena, .{ .token = self.advance() });
        }
        try self.eatTrivia(&children);

        // Generic params (`<T: Display>`) are captured as a raw-span
        // GENERIC_PARAMS node (internals pending the generics grammar),
        // so the parameter list after them still parses structured.
        if (self.peek() == .L_ANGLE) {
            try children.append(self.arena, .{ .node = try self.parseGenericParams() });
            try self.eatTrivia(&children);
        }

        if (self.peek() == .L_PAREN) {
            const params_node = try self.parseParams();
            try children.append(self.arena, .{ .node = params_node });
            try self.eatTrivia(&children);
        }

        if (self.peek() == .ARROW) {
            const ret_node = try self.parseReturnType();
            try children.append(self.arena, .{ .node = ret_node });
            try self.eatTrivia(&children);
        }

        // EffectSpec / WhereClause aren't parsed yet. Anything
        // between the return type and the body's `{` collects here
        // so the lossless invariant holds.
        while (!self.isEof() and self.peek() != .L_BRACE) {
            try children.append(self.arena, .{ .token = self.advance() });
        }

        if (self.peek() == .L_BRACE) {
            const block_node = try self.parseBlock();
            try children.append(self.arena, .{ .node = block_node });
        }

        return try cst.makeNode(self.arena, .FN_DECL, children.items);
    }

    fn parseVisibility(self: *Parser) !*const cst.Node {
        std.debug.assert(self.peek() == .KW_PUB);
        const kw = self.advance();
        return try cst.makeNode(self.arena, .VISIBILITY, &[_]cst.Element{
            .{ .token = kw },
        });
    }

    // -----------------------------------------------------------------
    // Item productions: struct / enum / type / const / face / fit
    // -----------------------------------------------------------------
    //
    // v0 structures the item shell — visibility, keyword, name, generic
    // params, and body — enough for `SourceFile` iteration and lossless
    // round-tripping. Field/variant *types*, fit/face method bodies, and
    // generic-parameter internals are captured as raw token spans for
    // now; they gain structure alongside the type-expression and pattern
    // grammars. These nodes are not yet surfaced through `ast.Item`
    // (only `FnDecl` is), so codegen is unaffected.

    /// Balanced `<…>` generic parameter list, captured raw. `>>` (a
    /// single `SHR` token) closes two levels so nested args terminate.
    fn parseGenericParams(self: *Parser) !*const cst.Node {
        var children: std.ArrayList(cst.Element) = .empty;
        var depth: i32 = 0;
        while (!self.isEof()) {
            const k = self.peek();
            try children.append(self.arena, .{ .token = self.advance() });
            switch (k) {
                .L_ANGLE => depth += 1,
                .R_ANGLE => depth -= 1,
                .SHR => depth -= 2,
                else => {},
            }
            if (depth <= 0) break;
        }
        return try cst.makeNode(self.arena, .GENERIC_PARAMS, children.items);
    }

    /// Balanced `{ … }` group captured raw, tagged `kind` (used for face
    /// / fit bodies whose internals aren't structured yet).
    fn parseBalancedBraces(self: *Parser, kind: cst.SyntaxKind) !*const cst.Node {
        std.debug.assert(self.peek() == .L_BRACE);
        var children: std.ArrayList(cst.Element) = .empty;
        var depth: i32 = 0;
        while (!self.isEof()) {
            const k = self.peek();
            try children.append(self.arena, .{ .token = self.advance() });
            if (k == .L_BRACE) depth += 1;
            if (k == .R_BRACE) {
                depth -= 1;
                if (depth == 0) break;
            }
        }
        return try cst.makeNode(self.arena, kind, children.items);
    }

    /// Capture the item header (everything up to the body's `{`) as raw
    /// tokens, tracking `()`/`[]`/`<>` nesting so a `{` inside them isn't
    /// mistaken for the body.
    fn captureHeaderUntilBrace(self: *Parser, children: *std.ArrayList(cst.Element)) !void {
        var depth: i32 = 0;
        while (!self.isEof()) {
            const k = self.peek();
            if (depth <= 0 and (k == .L_BRACE or k == .NEWLINE)) return;
            switch (k) {
                .L_PAREN, .L_BRACK, .L_ANGLE => depth += 1,
                .R_PAREN, .R_BRACK, .R_ANGLE => depth -= 1,
                .SHR => depth -= 2,
                else => {},
            }
            try children.append(self.arena, .{ .token = self.advance() });
        }
    }

    /// Optional name + generic params shared by struct/enum/type.
    fn consumeNameAndGenerics(self: *Parser, children: *std.ArrayList(cst.Element)) !void {
        if (self.peek() == .IDENT) {
            try children.append(self.arena, .{ .token = self.advance() });
        }
        try self.eatTrivia(children);
        if (self.peek() == .L_ANGLE) {
            try children.append(self.arena, .{ .node = try self.parseGenericParams() });
            try self.eatTrivia(children);
        }
    }

    fn parseStructDecl(self: *Parser) !*const cst.Node {
        var children: std.ArrayList(cst.Element) = .empty;
        try self.consumeVisibility(&children);
        try children.append(self.arena, .{ .token = self.advance() }); // struct
        try self.eatTrivia(&children);
        try self.consumeNameAndGenerics(&children);
        switch (self.peek()) {
            .L_BRACE => try children.append(self.arena, .{ .node = try self.parseRecordBody() }),
            .L_PAREN => try children.append(self.arena, .{ .node = try self.parseBalancedParen(.TUPLE_BODY) }),
            else => {}, // unit struct
        }
        return try cst.makeNode(self.arena, .STRUCT_DECL, children.items);
    }

    /// `{ Field ("," Field)* ","? }` — `Field := IDENT ":" TypeExpr`,
    /// the type captured raw until the next `,`/`}`.
    fn parseRecordBody(self: *Parser) !*const cst.Node {
        var children: std.ArrayList(cst.Element) = .empty;
        try children.append(self.arena, .{ .token = self.advance() }); // {
        while (!self.isEof()) {
            try self.eatTrivia(&children);
            if (self.peek() == .R_BRACE) break;
            const before = self.pos;
            try children.append(self.arena, .{ .node = try self.parseField() });
            try self.eatTrivia(&children);
            if (self.peek() == .COMMA) {
                try children.append(self.arena, .{ .token = self.advance() });
            } else if (self.pos == before) {
                // parseField consumed nothing (e.g. a keyword-shaped field
                // name like `on`): eat one token so the loop must progress.
                try children.append(self.arena, .{ .token = self.advance() });
            }
        }
        if (self.peek() == .R_BRACE) {
            try children.append(self.arena, .{ .token = self.advance() });
        }
        return try cst.makeNode(self.arena, .RECORD_BODY, children.items);
    }

    fn parseField(self: *Parser) !*const cst.Node {
        var children: std.ArrayList(cst.Element) = .empty;
        if (self.peek() == .IDENT) {
            try children.append(self.arena, .{ .token = self.advance() });
        }
        try self.eatTrivia(&children);
        if (self.peek() == .COLON) {
            try children.append(self.arena, .{ .token = self.advance() });
            try self.eatTrivia(&children);
            try children.append(self.arena, .{ .node = try self.parseType() });
        }
        return try cst.makeNode(self.arena, .FIELD, children.items);
    }

    /// Balanced `( … )` captured raw, tagged `kind`.
    fn parseBalancedParen(self: *Parser, kind: cst.SyntaxKind) !*const cst.Node {
        std.debug.assert(self.peek() == .L_PAREN);
        var children: std.ArrayList(cst.Element) = .empty;
        var depth: i32 = 0;
        while (!self.isEof()) {
            const k = self.peek();
            try children.append(self.arena, .{ .token = self.advance() });
            if (k == .L_PAREN) depth += 1;
            if (k == .R_PAREN) {
                depth -= 1;
                if (depth == 0) break;
            }
        }
        return try cst.makeNode(self.arena, kind, children.items);
    }

    fn parseEnumDecl(self: *Parser) !*const cst.Node {
        var children: std.ArrayList(cst.Element) = .empty;
        try self.consumeVisibility(&children);
        try children.append(self.arena, .{ .token = self.advance() }); // enum
        try self.eatTrivia(&children);
        try self.consumeNameAndGenerics(&children);
        if (self.peek() == .L_BRACE) {
            try children.append(self.arena, .{ .token = self.advance() }); // {
            while (!self.isEof()) {
                try self.eatTrivia(&children);
                if (self.peek() == .R_BRACE) break;
                const before = self.pos;
                try children.append(self.arena, .{ .node = try self.parseVariant() });
                try self.eatTrivia(&children);
                if (self.peek() == .COMMA) {
                    try children.append(self.arena, .{ .token = self.advance() });
                } else if (self.pos == before) {
                    // parseVariant consumed nothing (a keyword-shaped
                    // name): eat one token so the loop must progress.
                    try children.append(self.arena, .{ .token = self.advance() });
                }
            }
            if (self.peek() == .R_BRACE) {
                try children.append(self.arena, .{ .token = self.advance() });
            }
        }
        return try cst.makeNode(self.arena, .ENUM_DECL, children.items);
    }

    /// `Variant := IDENT VariantPayload?` — payload is a raw balanced
    /// `(…)` (tuple-like) or `{…}` (record-like). A payload may sit after
    /// inline whitespace (`C { … }`); a newline ends the variant, so the
    /// lookahead won't grab the next variant's tokens. `None` lexes as
    /// `KW_NONE` but is a valid variant name (the prelude `Option`
    /// declares it).
    fn parseVariant(self: *Parser) !*const cst.Node {
        var children: std.ArrayList(cst.Element) = .empty;
        if (self.peek() == .IDENT or self.peek() == .KW_NONE) {
            try children.append(self.arena, .{ .token = self.advance() });
        }
        const save = self.pos;
        var lead: std.ArrayList(cst.Element) = .empty;
        try self.eatTrivia(&lead);
        const crossed_newline = for (lead.items) |e| {
            if (e.kind() == .NEWLINE) break true;
        } else false;
        const payload_kind: ?cst.SyntaxKind = switch (self.peek()) {
            .L_PAREN => .L_PAREN,
            .L_BRACE => .L_BRACE,
            else => null,
        };
        if (payload_kind != null and !crossed_newline) {
            try children.appendSlice(self.arena, lead.items);
            if (payload_kind.? == .L_PAREN) {
                try children.append(self.arena, .{ .node = try self.parseBalancedParen(.VARIANT_PAYLOAD) });
            } else {
                try children.append(self.arena, .{ .node = try self.parseBalancedBraces(.VARIANT_PAYLOAD) });
            }
        } else {
            self.pos = save;
        }
        return try cst.makeNode(self.arena, .VARIANT, children.items);
    }

    /// `TypeDecl := "type" IDENT GenericParams? "=" TypeExpr` (the type
    /// captured raw to end of line).
    fn parseTypeDecl(self: *Parser) !*const cst.Node {
        var children: std.ArrayList(cst.Element) = .empty;
        try self.consumeVisibility(&children);
        try children.append(self.arena, .{ .token = self.advance() }); // type
        try self.eatTrivia(&children);
        try self.consumeNameAndGenerics(&children);
        if (self.peek() == .EQ) {
            try children.append(self.arena, .{ .token = self.advance() });
            try self.eatTrivia(&children);
            try children.append(self.arena, .{ .node = try self.parseType() });
        }
        return try cst.makeNode(self.arena, .TYPE_DECL, children.items);
    }

    /// `ConstDecl := "const" IDENT ":" TypeExpr "=" Expr`.
    fn parseConstDecl(self: *Parser) !*const cst.Node {
        var children: std.ArrayList(cst.Element) = .empty;
        try self.consumeVisibility(&children);
        try children.append(self.arena, .{ .token = self.advance() }); // const
        try self.eatTrivia(&children);
        if (self.peek() == .IDENT) {
            try children.append(self.arena, .{ .token = self.advance() });
        }
        try self.eatTrivia(&children);
        if (self.peek() == .COLON) {
            try children.append(self.arena, .{ .token = self.advance() });
            try self.eatTrivia(&children);
            try children.append(self.arena, .{ .node = try self.parseType() });
            try self.eatTrivia(&children);
        }
        if (self.peek() == .EQ) {
            try children.append(self.arena, .{ .token = self.advance() });
            try self.eatTrivia(&children);
            try children.append(self.arena, .{ .node = try self.parseExpr() });
        }
        return try cst.makeNode(self.arena, .CONST_DECL, children.items);
    }

    /// `StateDecl := "state" IDENT (":" TypeExpr)? "=" Expr` — module-level
    /// reactive state (a mutable instance binding). Same shape as a const decl;
    /// the type is optional (inferred from the initializer in v0).
    fn parseStateDecl(self: *Parser) !*const cst.Node {
        var children: std.ArrayList(cst.Element) = .empty;
        try self.consumeVisibility(&children);
        try children.append(self.arena, .{ .token = self.advance() }); // state
        try self.eatTrivia(&children);
        if (self.peek() == .IDENT) {
            try children.append(self.arena, .{ .token = self.advance() });
        }
        try self.eatTrivia(&children);
        if (self.peek() == .COLON) {
            try children.append(self.arena, .{ .token = self.advance() });
            try self.eatTrivia(&children);
            try children.append(self.arena, .{ .node = try self.parseType() });
            try self.eatTrivia(&children);
        }
        if (self.peek() == .EQ) {
            try children.append(self.arena, .{ .token = self.advance() });
            try self.eatTrivia(&children);
            try children.append(self.arena, .{ .node = try self.parseExpr() });
        }
        return try cst.makeNode(self.arena, .STATE_DECL, children.items);
    }

    /// `FaceDecl := "face" IDENT GenericParams? FaceSuperList? FaceBody`
    /// (spec/grammar.md §"Faces and fits"). B3: the super list's refs and
    /// the body's method signatures parse structured; `type` aliases and
    /// `law`s inside the body stay raw token runs (pending their grammars).
    fn parseFaceDecl(self: *Parser) !*const cst.Node {
        var children: std.ArrayList(cst.Element) = .empty;
        try self.consumeVisibility(&children);
        try children.append(self.arena, .{ .token = self.advance() }); // face
        try self.eatTrivia(&children);
        try self.consumeNameAndGenerics(&children);
        // FaceSuperList := ":" FaceRef ("+" FaceRef)*
        if (self.peek() == .COLON) {
            try children.append(self.arena, .{ .token = self.advance() });
            try self.eatTrivia(&children);
            while (self.peek() == .IDENT) {
                try children.append(self.arena, .{ .node = try self.parseFaceRef() });
                try self.eatTrivia(&children);
                if (self.peek() != .PLUS) break;
                try children.append(self.arena, .{ .token = self.advance() });
                try self.eatTrivia(&children);
            }
        }
        if (self.peek() == .L_BRACE) {
            try children.append(self.arena, .{ .node = try self.parseFaceFitBody(.FACE_BODY) });
        }
        return try cst.makeNode(self.arena, .FACE_DECL, children.items);
    }

    /// `FitDecl := "fit" FitSpec WhereClause? FitBody`;
    /// `FitSpec := TypeExpr ":" FaceRef | FaceRef` (single- vs multi-param
    /// face forms). Both forms *parse*; which one is correct for the
    /// face's arity is sema's call (TYP201 / TYP202 — the B4 fit registry
    /// reads the structured spec). The where clause stays a raw span.
    fn parseFitDecl(self: *Parser) !*const cst.Node {
        var children: std.ArrayList(cst.Element) = .empty;
        try self.consumeVisibility(&children);
        try children.append(self.arena, .{ .token = self.advance() }); // fit
        try self.eatTrivia(&children);
        if (self.peek() != .L_BRACE and !self.isEof()) {
            var spec: std.ArrayList(cst.Element) = .empty;
            try spec.append(self.arena, .{ .node = try self.parseType() });
            try self.eatTrivia(&spec);
            if (self.peek() == .COLON) {
                try spec.append(self.arena, .{ .token = self.advance() });
                try self.eatTrivia(&spec);
                if (self.peek() == .IDENT) {
                    try spec.append(self.arena, .{ .node = try self.parseFaceRef() });
                }
            }
            try children.append(self.arena, .{ .node = try cst.makeNode(self.arena, .FIT_SPEC, spec.items) });
        }
        try self.eatTrivia(&children);
        // WhereClause isn't structured yet; anything before the body's `{`
        // collects raw so the lossless invariant holds.
        try self.captureHeaderUntilBrace(&children);
        if (self.peek() == .L_BRACE) {
            try children.append(self.arena, .{ .node = try self.parseFaceFitBody(.FIT_BODY) });
        }
        return try cst.makeNode(self.arena, .FIT_DECL, children.items);
    }

    /// `FaceRef` — a face reference (`Display`, `Convert<A, B>`): a path
    /// type wrapped in a FACE_REF node.
    fn parseFaceRef(self: *Parser) !*const cst.Node {
        std.debug.assert(self.peek() == .IDENT);
        const path = try self.parsePathType();
        return try cst.makeNode(self.arena, .FACE_REF, &[_]cst.Element{.{ .node = path }});
    }

    /// The shared face/fit body: `{ (MethodSig | raw run)* }`. A `fn`
    /// item parses as a structured METHOD_SIG; anything else (a `type`
    /// alias, a `law`, junk) is captured as a raw token run with bracket
    /// tracking, so a `{ … }` inside it can't be mistaken for the body's
    /// close and the run can't swallow a following `fn`.
    fn parseFaceFitBody(self: *Parser, kind: cst.SyntaxKind) !*const cst.Node {
        std.debug.assert(self.peek() == .L_BRACE);
        var children: std.ArrayList(cst.Element) = .empty;
        try children.append(self.arena, .{ .token = self.advance() }); // {
        while (!self.isEof()) {
            try self.eatTrivia(&children);
            if (self.peek() == .R_BRACE) break;
            if (self.peek() == .KW_FN) {
                try children.append(self.arena, .{ .node = try self.parseMethodSig() });
                continue;
            }
            // Raw run. eatTrivia just ran, so the first token is real —
            // the run always makes progress.
            var depth: i32 = 0;
            while (!self.isEof()) {
                const k = self.peek();
                if (depth <= 0 and (k == .R_BRACE or k == .KW_FN or k == .NEWLINE)) break;
                switch (k) {
                    .L_BRACE, .L_PAREN, .L_BRACK => depth += 1,
                    .R_BRACE, .R_PAREN, .R_BRACK => depth -= 1,
                    else => {},
                }
                try children.append(self.arena, .{ .token = self.advance() });
            }
        }
        if (self.peek() == .R_BRACE) {
            try children.append(self.arena, .{ .token = self.advance() }); // }
        }
        return try cst.makeNode(self.arena, kind, children.items);
    }

    /// `MethodSig := "fn" IDENT GenericParams? "(" Params? ")"
    /// ("->" TypeExpr)? EffectSpec? WhereClause? Block?` — a face/fit
    /// body item. A body makes it a default impl (face) or the impl
    /// itself (fit); whether one is *required* is sema's call, not the
    /// grammar's. Inline trivia only between header pieces: a line break
    /// ends a bodyless signature, so the parse can't swallow the next
    /// `fn`. Effects (`@pure`) and where clauses stay raw tokens.
    fn parseMethodSig(self: *Parser) !*const cst.Node {
        std.debug.assert(self.peek() == .KW_FN);
        var children: std.ArrayList(cst.Element) = .empty;
        try children.append(self.arena, .{ .token = self.advance() }); // fn
        try self.eatInlineTrivia(&children);
        if (self.peek() == .IDENT) {
            try children.append(self.arena, .{ .token = self.advance() });
        }
        try self.eatInlineTrivia(&children);
        if (self.peek() == .L_ANGLE) {
            try children.append(self.arena, .{ .node = try self.parseGenericParams() });
            try self.eatInlineTrivia(&children);
        }
        if (self.peek() == .L_PAREN) {
            try children.append(self.arena, .{ .node = try self.parseParams() });
            try self.eatInlineTrivia(&children);
        }
        if (self.peek() == .ARROW) {
            try children.append(self.arena, .{ .node = try self.parseReturnType() });
        }
        // EffectSpec / WhereClause: raw up to the body's `{`, the end of
        // the line, or the enclosing body's `}` (a one-line face like
        // `face G { fn hi() -> str }`) — any of which closes a bodyless
        // signature.
        var depth: i32 = 0;
        while (!self.isEof()) {
            const k = self.peek();
            if (depth <= 0 and (k == .L_BRACE or k == .R_BRACE or k == .NEWLINE)) break;
            switch (k) {
                .L_PAREN, .L_BRACK, .L_ANGLE => depth += 1,
                .R_PAREN, .R_BRACK, .R_ANGLE => depth -= 1,
                .SHR => depth -= 2,
                else => {},
            }
            try children.append(self.arena, .{ .token = self.advance() });
        }
        if (self.peek() == .L_BRACE) {
            try children.append(self.arena, .{ .node = try self.parseBlock() });
        }
        return try cst.makeNode(self.arena, .METHOD_SIG, children.items);
    }

    /// Trivia except NEWLINE — for header seams where a line break ends
    /// the production (a bodyless method signature must not eat into the
    /// next line's item).
    fn eatInlineTrivia(self: *Parser, out: *std.ArrayList(cst.Element)) !void {
        while (!self.isEof()) {
            const k = self.peek();
            if (k != .WHITESPACE and k != .LINE_COMMENT) break;
            try out.append(self.arena, .{ .token = self.advance() });
        }
    }

    // -----------------------------------------------------------------
    // ImportStmt
    // -----------------------------------------------------------------
    //
    // `ImportStmt := "import" ImportPath ImportBinding?` per
    // spec/modules.md §"Import grammar" and spec/grammar.md §Imports.
    // The path is either a bare dotted module path (`dev.q64.foo`) or
    // a quoted relative path (`"./util.q"`); the optional binding is a
    // selective list (`.{a, b}`) or an alias (`as x`). The pieces the
    // parser doesn't recognize still pass through as raw tokens so the
    // lossless invariant holds.

    fn parseImportStmt(self: *Parser) !*const cst.Node {
        std.debug.assert(self.peek() == .KW_IMPORT);
        var children: std.ArrayList(cst.Element) = .empty;

        try children.append(self.arena, .{ .token = self.advance() }); // KW_IMPORT
        try self.eatTrivia(&children);

        // ImportPath: quoted-relative or bare-dotted.
        if (self.peek() == .STR_PLAIN or self.peek() == .STR_RAW) {
            const path_node = try self.parseQuotedRelative();
            try children.append(self.arena, .{ .node = path_node });
        } else if (self.peek() == .IDENT) {
            const path_node = try self.parseBareDotted();
            try children.append(self.arena, .{ .node = path_node });
        }
        try self.eatTrivia(&children);

        // A `-` immediately after the path means a dash leaked into a bare
        // module path (`audio-filters`) — it lexed as the minus operator
        // (spec/modules.md NAM011). Leave the stray tokens for passthrough.
        if (self.peek() == .MINUS) {
            try self.emitDiag("NAM011", self.offsetHere());
            return try cst.makeNode(self.arena, .IMPORT_STMT, children.items);
        }

        // ImportBinding: wildcard (`.*`, forbidden), selective list
        // (`.{...}`), or alias (`as x`).
        if (self.peek() == .DOT and self.kindAfterDot() == .STAR) {
            try self.emitDiag("NAM003", self.offsetHere());
            try children.append(self.arena, .{ .token = self.advance() }); // DOT
            try self.eatTrivia(&children);
            try children.append(self.arena, .{ .token = self.advance() }); // STAR
        } else if (self.peek() == .DOT and self.kindAfterDot() == .L_BRACE) {
            const sel = try self.parseSelectiveList();
            try children.append(self.arena, .{ .node = sel });
            try self.eatTrivia(&children);
            // Selective list combined with an alias is forbidden (NAM004).
            if (self.peek() == .KW_AS) {
                try self.emitDiag("NAM004", self.offsetHere());
                const alias = try self.parseAliasBinding();
                try children.append(self.arena, .{ .node = alias });
            }
        } else if (self.peek() == .KW_AS) {
            const alias = try self.parseAliasBinding();
            try children.append(self.arena, .{ .node = alias });
        }

        return try cst.makeNode(self.arena, .IMPORT_STMT, children.items);
    }

    fn parseQuotedRelative(self: *Parser) !*const cst.Node {
        const str = self.advance(); // STR_PLAIN / STR_RAW
        const inner = try cst.makeNode(self.arena, .QUOTED_RELATIVE, &[_]cst.Element{
            .{ .token = str },
        });
        return try cst.makeNode(self.arena, .IMPORT_PATH, &[_]cst.Element{
            .{ .node = inner },
        });
    }

    /// `BareDotted := IDENT ("." IDENT)*`, wrapped in IMPORT_PATH. Stops
    /// at a `.` that introduces a selective list (`.{`), leaving that dot
    /// for `parseSelectiveList`.
    fn parseBareDotted(self: *Parser) !*const cst.Node {
        var children: std.ArrayList(cst.Element) = .empty;
        try children.append(self.arena, .{ .token = self.advance() }); // first IDENT

        while (self.peek() == .DOT and !self.nonTriviaAfterDotIsBrace()) {
            const save = self.pos;
            const dot = self.advance();
            // Only continue the path if the dot is followed by an IDENT.
            if (self.peek() == .IDENT) {
                try children.append(self.arena, .{ .token = dot });
                try children.append(self.arena, .{ .token = self.advance() });
                continue;
            }
            self.pos = save;
            break;
        }

        const inner = try cst.makeNode(self.arena, .BARE_DOTTED, children.items);
        return try cst.makeNode(self.arena, .IMPORT_PATH, &[_]cst.Element{
            .{ .node = inner },
        });
    }

    /// `SelectiveList := "." "{" IDENT ("," IDENT)* "}"`.
    fn parseSelectiveList(self: *Parser) !*const cst.Node {
        var children: std.ArrayList(cst.Element) = .empty;
        try children.append(self.arena, .{ .token = self.advance() }); // DOT
        try self.eatTrivia(&children);
        if (self.peek() == .L_BRACE) {
            try children.append(self.arena, .{ .token = self.advance() });
        }
        try self.eatTrivia(&children);
        while (!self.isEof() and self.peek() != .R_BRACE) {
            if (self.peek() == .IDENT) {
                try children.append(self.arena, .{ .token = self.advance() });
            } else {
                // Recovery: absorb anything unexpected so we make progress.
                try children.append(self.arena, .{ .token = self.advance() });
            }
            try self.eatTrivia(&children);
            if (self.peek() == .COMMA) {
                try children.append(self.arena, .{ .token = self.advance() });
                try self.eatTrivia(&children);
            }
        }
        if (self.peek() == .R_BRACE) {
            try children.append(self.arena, .{ .token = self.advance() });
        }
        return try cst.makeNode(self.arena, .SELECTIVE_LIST, children.items);
    }

    /// `AliasBinding := "as" IDENT`.
    fn parseAliasBinding(self: *Parser) !*const cst.Node {
        var children: std.ArrayList(cst.Element) = .empty;
        try children.append(self.arena, .{ .token = self.advance() }); // KW_AS
        try self.eatTrivia(&children);
        if (self.peek() == .IDENT) {
            try children.append(self.arena, .{ .token = self.advance() });
        }
        return try cst.makeNode(self.arena, .ALIAS_BINDING, children.items);
    }

    /// Lookahead: is the token after the upcoming `.` (skipping trivia)
    /// an `{`? Distinguishes a selective list (`foo.{a}`) from a path
    /// continuation (`foo.bar`).
    fn nonTriviaAfterDotIsBrace(self: *const Parser) bool {
        return self.kindAfterDot() == .L_BRACE;
    }

    /// Collect everything from the opening `(` to its matching `)`,
    /// inclusive. v0 carries the contents as raw tokens; the
    /// `Param` production fills in once todo.md "Parser: items
    /// productions" lands.
    /// `Params := Param ("," Param)* ","?` between the parens
    /// (spec/grammar.md §Functions). Each `Param` becomes a structured
    /// `PARAM` child; commas and trivia stay as direct token children so
    /// the round-trip is lossless.
    fn parseParams(self: *Parser) !*const cst.Node {
        var children: std.ArrayList(cst.Element) = .empty;
        std.debug.assert(self.peek() == .L_PAREN);
        try children.append(self.arena, .{ .token = self.advance() }); // (

        while (!self.isEof()) {
            try self.eatTrivia(&children);
            if (self.peek() == .R_PAREN) break;

            const before = self.pos;
            try children.append(self.arena, .{ .node = try self.parseParam() });
            try self.eatTrivia(&children);
            if (self.peek() == .COMMA) {
                try children.append(self.arena, .{ .token = self.advance() });
            } else if (self.pos == before) {
                // Defensive: parseParam made no progress on unexpected
                // input. Consume one token so the loop terminates.
                if (!self.isEof()) try children.append(self.arena, .{ .token = self.advance() });
            }
        }

        if (self.peek() == .R_PAREN) {
            try children.append(self.arena, .{ .token = self.advance() }); // )
        }
        return try cst.makeNode(self.arena, .PARAMS, children.items);
    }

    /// `Param := ParamMode? (IDENT | "self") (":" TypeExpr)?`. The mode
    /// (if any) is a `PARAM_MODE` node. `self` (KW_SELF) is a valid
    /// receiver parameter in face/fit method signatures — bare or with
    /// an explicit `: Self` type. Always consumes at least one token
    /// when the caller guarantees a non-`)` start, so the params loop
    /// makes progress.
    fn parseParam(self: *Parser) !*const cst.Node {
        var children: std.ArrayList(cst.Element) = .empty;

        if (isParamMode(self.peek())) {
            const mode = try cst.makeNode(self.arena, .PARAM_MODE, &[_]cst.Element{
                .{ .token = self.advance() },
            });
            try children.append(self.arena, .{ .node = mode });
            try self.eatTrivia(&children);
        }

        if (self.peek() == .IDENT or self.peek() == .KW_SELF) {
            try children.append(self.arena, .{ .token = self.advance() }); // name
        }
        try self.eatTrivia(&children);

        if (self.peek() == .COLON) {
            try children.append(self.arena, .{ .token = self.advance() }); // :
            try self.eatTrivia(&children);
            try children.append(self.arena, .{ .node = try self.parseType() });
        }

        // Progress guarantee: if nothing matched (unexpected token), take
        // one token so `parseParams` can't spin.
        if (children.items.len == 0 and !self.isEof() and
            self.peek() != .R_PAREN and self.peek() != .COMMA)
        {
            try children.append(self.arena, .{ .token = self.advance() });
        }

        return try cst.makeNode(self.arena, .PARAM, children.items);
    }

    fn isParamMode(k: cst.SyntaxKind) bool {
        return k == .KW_IN or k == .KW_OUT or k == .KW_REF or k == .KW_MOVE;
    }

    /// Consume `->` followed by a `TypeExpr`. The type parser stops at
    /// the body's opening `{` on its own.
    fn parseReturnType(self: *Parser) !*const cst.Node {
        std.debug.assert(self.peek() == .ARROW);
        var children: std.ArrayList(cst.Element) = .empty;
        try children.append(self.arena, .{ .token = self.advance() }); // ARROW
        try self.eatTrivia(&children);
        if (!self.isEof() and self.peek() != .L_BRACE) {
            try children.append(self.arena, .{ .node = try self.parseType() });
        }
        return try cst.makeNode(self.arena, .RETURN_TYPE, children.items);
    }

    // -----------------------------------------------------------------
    // Type expressions (spec/grammar.md §"Type expressions", v0 floor)
    // -----------------------------------------------------------------
    //
    // Structured: PathType (dotted name + raw GenericArgs), RefType,
    // Slice/Array, Tuple, Optional. fn / dyn / union types and anything
    // unrecognized fall to a raw `TYPE_EXPR` span. Generic arguments stay
    // a raw balanced `GENERIC_ARGS` span (sidesteps `>>` splitting). The
    // parser stops at the first token that can't extend the type, leaving
    // boundary tokens (`,`, `)`, `]`, `{`, `=`, `;`, newline) for callers.

    fn parseType(self: *Parser) std.mem.Allocator.Error!*const cst.Node {
        var base = try self.parseTypePrimary();
        // Postfix `?` → OptionalType (stacks: `T??`).
        while (self.peek() == .QUESTION) {
            var children: std.ArrayList(cst.Element) = .empty;
            try children.append(self.arena, .{ .node = base });
            try children.append(self.arena, .{ .token = self.advance() }); // ?
            base = try cst.makeNode(self.arena, .OPTIONAL_TYPE, children.items);
        }
        return base;
    }

    fn parseTypePrimary(self: *Parser) std.mem.Allocator.Error!*const cst.Node {
        switch (self.peek()) {
            .KW_REF => {
                var children: std.ArrayList(cst.Element) = .empty;
                try children.append(self.arena, .{ .token = self.advance() }); // ref
                try self.eatTrivia(&children);
                try children.append(self.arena, .{ .node = try self.parseType() });
                return try cst.makeNode(self.arena, .REF_TYPE, children.items);
            },
            .L_BRACK => return self.parseBracketType(),
            .L_PAREN => return self.parseTupleType(),
            .IDENT => return self.parsePathType(),
            else => return self.parseRawType(),
        }
    }

    /// `PathType := IDENT ("." IDENT)* GenericArgs?`. Generic args are a
    /// raw balanced `<…>` span.
    fn parsePathType(self: *Parser) std.mem.Allocator.Error!*const cst.Node {
        var children: std.ArrayList(cst.Element) = .empty;
        try children.append(self.arena, .{ .token = self.advance() }); // IDENT
        while (self.peek() == .DOT and self.kindAfterDot() == .IDENT) {
            try children.append(self.arena, .{ .token = self.advance() }); // DOT
            try children.append(self.arena, .{ .token = self.advance() }); // segment
        }
        if (self.peek() == .L_ANGLE) {
            try children.append(self.arena, .{ .node = try self.parseGenericArgs() });
        }
        return try cst.makeNode(self.arena, .PATH_TYPE, children.items);
    }

    /// Balanced `<…>` generic-argument list captured raw; `>>` (SHR) closes
    /// two levels (mirrors `parseGenericParams`).
    fn parseGenericArgs(self: *Parser) !*const cst.Node {
        var children: std.ArrayList(cst.Element) = .empty;
        var depth: i32 = 0;
        while (!self.isEof()) {
            const k = self.peek();
            try children.append(self.arena, .{ .token = self.advance() });
            switch (k) {
                .L_ANGLE => depth += 1,
                .R_ANGLE => depth -= 1,
                .SHR => depth -= 2,
                else => {},
            }
            if (depth <= 0) break;
        }
        return try cst.makeNode(self.arena, .GENERIC_ARGS, children.items);
    }

    /// `[ TypeExpr ]` (slice) or `[ TypeExpr ";" Count ]` (array).
    fn parseBracketType(self: *Parser) std.mem.Allocator.Error!*const cst.Node {
        var children: std.ArrayList(cst.Element) = .empty;
        try children.append(self.arena, .{ .token = self.advance() }); // [
        try self.eatTrivia(&children);
        if (self.peek() != .R_BRACK and !self.isEof()) {
            try children.append(self.arena, .{ .node = try self.parseType() });
        }
        try self.eatTrivia(&children);
        var kind: cst.SyntaxKind = .SLICE_TYPE;
        if (self.peek() == .SEMICOLON) {
            kind = .ARRAY_TYPE;
            try children.append(self.arena, .{ .token = self.advance() }); // ;
            // Length is a raw token span up to `]`.
            while (!self.isEof() and self.peek() != .R_BRACK and self.peek() != .NEWLINE) {
                try children.append(self.arena, .{ .token = self.advance() });
            }
        }
        if (self.peek() == .R_BRACK) {
            try children.append(self.arena, .{ .token = self.advance() }); // ]
        }
        return try cst.makeNode(self.arena, kind, children.items);
    }

    /// `( TypeExpr ("," TypeExpr)* ")"` — also covers `()` (unit) and a
    /// parenthesized type (treated as a one-element tuple in v0).
    fn parseTupleType(self: *Parser) std.mem.Allocator.Error!*const cst.Node {
        var children: std.ArrayList(cst.Element) = .empty;
        try children.append(self.arena, .{ .token = self.advance() }); // (
        while (!self.isEof()) {
            try self.eatTrivia(&children);
            if (self.peek() == .R_PAREN) break;
            const before = self.pos;
            try children.append(self.arena, .{ .node = try self.parseType() });
            try self.eatTrivia(&children);
            if (self.peek() == .COMMA) {
                try children.append(self.arena, .{ .token = self.advance() });
            } else if (self.pos == before) {
                if (!self.isEof()) try children.append(self.arena, .{ .token = self.advance() });
            }
        }
        if (self.peek() == .R_PAREN) {
            try children.append(self.arena, .{ .token = self.advance() }); // )
        }
        return try cst.makeNode(self.arena, .TUPLE_TYPE, children.items);
    }

    /// Fallback: capture an unstructured type (fn / dyn / union, or
    /// malformed) as a raw `TYPE_EXPR` span up to a depth-0 boundary.
    fn parseRawType(self: *Parser) std.mem.Allocator.Error!*const cst.Node {
        var children: std.ArrayList(cst.Element) = .empty;
        var depth: i32 = 0;
        while (!self.isEof()) {
            const k = self.peek();
            if (depth <= 0) switch (k) {
                .COMMA, .R_PAREN, .R_BRACK, .R_ANGLE, .SHR, .L_BRACE, .R_BRACE, .EQ, .SEMICOLON, .NEWLINE => break,
                else => {},
            };
            switch (k) {
                .L_PAREN, .L_BRACK, .L_ANGLE => depth += 1,
                .R_PAREN, .R_BRACK, .R_ANGLE => depth -= 1,
                else => {},
            }
            try children.append(self.arena, .{ .token = self.advance() });
        }
        return try cst.makeNode(self.arena, .TYPE_EXPR, children.items);
    }

    /// Parse a block: `{ Stmt* }`. Statement parsing is best-effort
    /// in v0 — `ExprStmt` is the only structured form; unknown
    /// trailing tokens within a statement are collected as raw
    /// children so the lossless invariant still holds.
    fn parseBlock(self: *Parser) !*const cst.Node {
        std.debug.assert(self.peek() == .L_BRACE);
        var children: std.ArrayList(cst.Element) = .empty;

        try children.append(self.arena, .{ .token = self.advance() }); // L_BRACE

        while (!self.isEof()) {
            try self.eatTrivia(&children);
            // Explicit `;` separators between statements.
            while (self.peek() == .SEMICOLON) {
                try children.append(self.arena, .{ .token = self.advance() });
                try self.eatTrivia(&children);
            }
            if (self.peek() == .R_BRACE or self.isEof()) break;

            const stmt = try self.parseStmt();
            try children.append(self.arena, .{ .node = stmt });
        }

        if (self.peek() == .R_BRACE) {
            try children.append(self.arena, .{ .token = self.advance() });
        }
        return try cst.makeNode(self.arena, .BLOCK, children.items);
    }

    // -----------------------------------------------------------------
    // Statements
    // -----------------------------------------------------------------
    //
    // Dispatch per spec/grammar.md §Statements. The common forms are
    // structured here; scope / select / region / with_capabilities and
    // item-level `const` are not yet handled and fall through to the
    // expr/assign fallback (still lossless). Patterns and let-bindings
    // are captured as raw token spans for now — the structured pattern
    // grammar lands next (todo.md). Only `ExprStmt` is surfaced to the
    // AST (`ast.Stmt`); the other statement nodes are skipped by
    // `StmtIter`, so codegen is unaffected.

    fn parseStmt(self: *Parser) std.mem.Allocator.Error!*const cst.Node {
        return switch (self.peek()) {
            .KW_LET => self.parseLetOrVarStmt(.LET_STMT),
            .KW_VAR => self.parseLetOrVarStmt(.VAR_STMT),
            .KW_RETURN => self.parseReturnLike(.RETURN_STMT),
            .KW_BREAK => self.parseReturnLike(.BREAK_STMT),
            .KW_CONTINUE => self.parseBareKeywordStmt(.CONTINUE_STMT),
            .KW_PANIC => self.parsePanicStmt(),
            .KW_IF => self.parseIfStmt(),
            .KW_WHILE => self.parseWhileStmt(),
            .KW_LOOP => self.parseLoopStmt(),
            .KW_FOR => self.parseForStmt(),
            .KW_MATCH => self.parseMatchStmt(),
            else => self.parseExprOrAssignStmt(),
        };
    }

    fn isAssignOp(k: cst.SyntaxKind) bool {
        return switch (k) {
            .EQ, .PLUS_EQ, .MINUS_EQ, .STAR_EQ, .SLASH_EQ, .PERCENT_EQ => true,
            else => false,
        };
    }

    /// Append raw tokens until a depth-0 token in `stops` (or a closing
    /// `}`/newline/EOF). Bracket nesting is tracked so a stop token
    /// inside `(...)`, `[...]`, `{...}`, or `<...>` is ignored. Used for
    /// the not-yet-structured spans (let bindings, types, patterns).
    fn captureRawUntil(self: *Parser, children: *std.ArrayList(cst.Element), stops: []const cst.SyntaxKind) !void {
        var depth: i32 = 0;
        while (!self.isEof()) {
            const k = self.peek();
            if (depth <= 0) {
                if (k == .R_BRACE or k == .NEWLINE) return;
                for (stops) |s| if (k == s) return;
            }
            switch (k) {
                .L_PAREN, .L_BRACK, .L_BRACE, .L_ANGLE => depth += 1,
                .R_PAREN, .R_BRACK, .R_ANGLE, .R_BRACE => depth -= 1,
                else => {},
            }
            try children.append(self.arena, .{ .token = self.advance() });
        }
    }

    /// Is there a real token before the end of this statement (newline /
    /// `;` / `}` / EOF)? Used for the optional expression in
    /// `return` / `break`.
    fn nextIsExprOnLine(self: *const Parser) bool {
        var i = self.pos;
        while (i < self.tokens.len) : (i += 1) {
            const k = self.tokens[i].kind;
            if (k == .NEWLINE or k == .SEMICOLON or k == .R_BRACE or k == .EOF) return false;
            if (k.isTrivia()) continue;
            return true;
        }
        return false;
    }

    /// `LetStmt`/`VarStmt`: `(let|var) <binding> (":" <type>)? ("=" Expr)?`.
    /// Binding and type are raw spans pending the pattern grammar.
    fn parseLetOrVarStmt(self: *Parser, kind: cst.SyntaxKind) !*const cst.Node {
        var children: std.ArrayList(cst.Element) = .empty;
        try children.append(self.arena, .{ .token = self.advance() }); // let / var
        try self.eatTrivia(&children);
        try children.append(self.arena, .{ .node = try self.parsePattern() });
        try self.captureRawUntil(&children, &.{ .COLON, .EQ });
        if (self.peek() == .COLON) {
            try children.append(self.arena, .{ .token = self.advance() });
            try self.eatTrivia(&children);
            try children.append(self.arena, .{ .node = try self.parseType() });
            try self.eatTrivia(&children);
        }
        if (self.peek() == .EQ) {
            try children.append(self.arena, .{ .token = self.advance() });
            try self.eatTrivia(&children);
            try children.append(self.arena, .{ .node = try self.parseExpr() });
        }
        return try cst.makeNode(self.arena, kind, children.items);
    }

    /// `return`/`break` with an optional trailing expression on the line.
    fn parseReturnLike(self: *Parser, kind: cst.SyntaxKind) !*const cst.Node {
        var children: std.ArrayList(cst.Element) = .empty;
        try children.append(self.arena, .{ .token = self.advance() }); // keyword
        if (self.nextIsExprOnLine()) {
            try self.eatTrivia(&children);
            try children.append(self.arena, .{ .node = try self.parseExpr() });
        }
        return try cst.makeNode(self.arena, kind, children.items);
    }

    fn parseBareKeywordStmt(self: *Parser, kind: cst.SyntaxKind) !*const cst.Node {
        var children: std.ArrayList(cst.Element) = .empty;
        try children.append(self.arena, .{ .token = self.advance() });
        return try cst.makeNode(self.arena, kind, children.items);
    }

    /// `PanicStmt := "panic" Expr`.
    fn parsePanicStmt(self: *Parser) !*const cst.Node {
        var children: std.ArrayList(cst.Element) = .empty;
        try children.append(self.arena, .{ .token = self.advance() }); // panic
        if (self.nextIsExprOnLine()) {
            try self.eatTrivia(&children);
            try children.append(self.arena, .{ .node = try self.parseExpr() });
        }
        return try cst.makeNode(self.arena, .PANIC_STMT, children.items);
    }

    /// `IfStmt := "if" IfCond Block ("else" (IfStmt | Block))?`, where
    /// `IfCond` is an expression or an `if let` binding. The scrutinee
    /// expression stops at the block's `{` (no record-literal primary,
    /// so there's no struct-literal-in-condition ambiguity).
    fn parseIfStmt(self: *Parser) std.mem.Allocator.Error!*const cst.Node {
        var children: std.ArrayList(cst.Element) = .empty;
        try children.append(self.arena, .{ .token = self.advance() }); // if
        try self.eatTrivia(&children);

        if (self.peek() == .KW_LET) {
            var cl: std.ArrayList(cst.Element) = .empty;
            try cl.append(self.arena, .{ .token = self.advance() }); // let
            try self.eatTrivia(&cl);
            try cl.append(self.arena, .{ .node = try self.parsePattern() });
            try self.captureRawUntil(&cl, &.{.EQ});
            if (self.peek() == .EQ) {
                try cl.append(self.arena, .{ .token = self.advance() });
                try self.eatTrivia(&cl);
                self.no_record_depth += 1;
                try cl.append(self.arena, .{ .node = try self.parseExpr() });
                self.no_record_depth -= 1;
            }
            try children.append(self.arena, .{ .node = try cst.makeNode(self.arena, .IF_COND_LET, cl.items) });
        } else {
            self.no_record_depth += 1;
            try children.append(self.arena, .{ .node = try self.parseExpr() });
            self.no_record_depth -= 1;
        }

        try self.eatTrivia(&children);
        if (self.peek() == .L_BRACE) {
            try children.append(self.arena, .{ .node = try self.parseBlock() });
        }

        // `else` may sit after the block on the same or a later line.
        // Look past trivia; if there's no `else`, leave it for the caller.
        const save = self.pos;
        var lead: std.ArrayList(cst.Element) = .empty;
        try self.eatTrivia(&lead);
        if (self.peek() == .KW_ELSE) {
            try children.appendSlice(self.arena, lead.items);
            try children.append(self.arena, .{ .token = self.advance() }); // else
            try self.eatTrivia(&children);
            if (self.peek() == .KW_IF) {
                try children.append(self.arena, .{ .node = try self.parseIfStmt() });
            } else if (self.peek() == .L_BRACE) {
                try children.append(self.arena, .{ .node = try self.parseBlock() });
            }
        } else {
            self.pos = save;
        }
        return try cst.makeNode(self.arena, .IF_STMT, children.items);
    }

    fn parseWhileStmt(self: *Parser) std.mem.Allocator.Error!*const cst.Node {
        var children: std.ArrayList(cst.Element) = .empty;
        try children.append(self.arena, .{ .token = self.advance() }); // while
        try self.eatTrivia(&children);
        self.no_record_depth += 1;
        try children.append(self.arena, .{ .node = try self.parseExpr() });
        self.no_record_depth -= 1;
        try self.eatTrivia(&children);
        if (self.peek() == .L_BRACE) {
            try children.append(self.arena, .{ .node = try self.parseBlock() });
        }
        return try cst.makeNode(self.arena, .WHILE_STMT, children.items);
    }

    fn parseLoopStmt(self: *Parser) std.mem.Allocator.Error!*const cst.Node {
        var children: std.ArrayList(cst.Element) = .empty;
        try children.append(self.arena, .{ .token = self.advance() }); // loop
        try self.eatTrivia(&children);
        if (self.peek() == .L_BRACE) {
            try children.append(self.arena, .{ .node = try self.parseBlock() });
        }
        return try cst.makeNode(self.arena, .LOOP_STMT, children.items);
    }

    /// `ForStmt := "for" Pattern "in" Expr Block`. Pattern is a raw span.
    fn parseForStmt(self: *Parser) std.mem.Allocator.Error!*const cst.Node {
        var children: std.ArrayList(cst.Element) = .empty;
        try children.append(self.arena, .{ .token = self.advance() }); // for
        try self.eatTrivia(&children);
        try children.append(self.arena, .{ .node = try self.parsePattern() });
        try self.captureRawUntil(&children, &.{.KW_IN});
        if (self.peek() == .KW_IN) {
            try children.append(self.arena, .{ .token = self.advance() });
            try self.eatTrivia(&children);
            self.no_record_depth += 1;
            try children.append(self.arena, .{ .node = try self.parseExpr() });
            self.no_record_depth -= 1;
            try self.eatTrivia(&children);
            if (self.peek() == .L_BRACE) {
                try children.append(self.arena, .{ .node = try self.parseBlock() });
            }
        }
        return try cst.makeNode(self.arena, .FOR_STMT, children.items);
    }

    /// `MatchStmt := "match" Expr "{" MatchArm ("," MatchArm)* ","? "}"`.
    fn parseMatchStmt(self: *Parser) std.mem.Allocator.Error!*const cst.Node {
        return self.parseMatch(.MATCH_STMT);
    }

    /// One grammar, two positions: a `match` statement or a `match`
    /// expression (`let x = match l { … }`) — only the node kind
    /// differs (spec/grammar.md: `match` yields a value).
    fn parseMatch(self: *Parser, kind: cst.SyntaxKind) std.mem.Allocator.Error!*const cst.Node {
        var children: std.ArrayList(cst.Element) = .empty;
        try children.append(self.arena, .{ .token = self.advance() }); // match
        try self.eatTrivia(&children);
        self.no_record_depth += 1;
        try children.append(self.arena, .{ .node = try self.parseExpr() });
        self.no_record_depth -= 1;
        try self.eatTrivia(&children);
        if (self.peek() == .L_BRACE) {
            try children.append(self.arena, .{ .token = self.advance() }); // {
            while (!self.isEof()) {
                try self.eatTrivia(&children);
                if (self.peek() == .R_BRACE) break;
                try children.append(self.arena, .{ .node = try self.parseMatchArm() });
                try self.eatTrivia(&children);
                if (self.peek() == .COMMA) {
                    try children.append(self.arena, .{ .token = self.advance() });
                }
            }
            if (self.peek() == .R_BRACE) {
                try children.append(self.arena, .{ .token = self.advance() });
            }
        }
        return try cst.makeNode(self.arena, kind, children.items);
    }

    /// `MatchArm := Pattern "->" (Block | Expr)`. Pattern is a raw span.
    fn parseMatchArm(self: *Parser) std.mem.Allocator.Error!*const cst.Node {
        var children: std.ArrayList(cst.Element) = .empty;
        try children.append(self.arena, .{ .node = try self.parsePattern() });
        // Any remainder before `->` (e.g. a guard `if cond`) is raw for now.
        try self.captureRawUntil(&children, &.{.ARROW});
        if (self.peek() == .ARROW) {
            try children.append(self.arena, .{ .token = self.advance() });
            try self.eatTrivia(&children);
            if (self.peek() == .L_BRACE) {
                try children.append(self.arena, .{ .node = try self.parseBlock() });
            } else {
                try children.append(self.arena, .{ .node = try self.parseExpr() });
            }
        }
        return try cst.makeNode(self.arena, .MATCH_ARM, children.items);
    }

    /// Fallback: an expression statement, or an assignment when an
    /// assignment operator follows the parsed l-value. Trailing tokens
    /// up to the statement end are swept in for losslessness/recovery.
    fn parseExprOrAssignStmt(self: *Parser) std.mem.Allocator.Error!*const cst.Node {
        var children: std.ArrayList(cst.Element) = .empty;
        try children.append(self.arena, .{ .node = try self.parseExpr() });

        const save = self.pos;
        var lead: std.ArrayList(cst.Element) = .empty;
        try self.eatTrivia(&lead);
        if (isAssignOp(self.peek())) {
            try children.appendSlice(self.arena, lead.items);
            try children.append(self.arena, .{ .token = self.advance() }); // assign op
            try self.eatTrivia(&children);
            try children.append(self.arena, .{ .node = try self.parseExpr() });
            try self.sweepToStmtEnd(&children);
            return try cst.makeNode(self.arena, .ASSIGN_STMT, children.items);
        }
        self.pos = save;
        try self.sweepToStmtEnd(&children);
        return try cst.makeNode(self.arena, .EXPR_STMT, children.items);
    }

    fn sweepToStmtEnd(self: *Parser, children: *std.ArrayList(cst.Element)) !void {
        while (!self.isEof()) {
            const k = self.peek();
            if (k == .NEWLINE or k == .SEMICOLON or k == .R_BRACE) break;
            try children.append(self.arena, .{ .token = self.advance() });
        }
    }

    // -----------------------------------------------------------------
    // Patterns (spec/grammar.md §Patterns, v0 floor)
    // -----------------------------------------------------------------
    //
    // Wild / literal / ident / tuple / tuple-struct / record-struct /
    // enum-variant. Guards, or-patterns, ranges, and deep destructuring
    // are deferred (grammar open items); callers capture any post-pattern
    // remainder raw before the delimiter.

    fn parsePattern(self: *Parser) std.mem.Allocator.Error!*const cst.Node {
        switch (self.peek()) {
            .INT_LIT, .FLOAT_LIT => {
                var children: std.ArrayList(cst.Element) = .empty;
                try children.append(self.arena, .{ .token = self.advance() });
                if (self.peek() == .NUM_SUFFIX) try children.append(self.arena, .{ .token = self.advance() });
                return try cst.makeNode(self.arena, .LITERAL_PATTERN, children.items);
            },
            .STR_PLAIN, .STR_RAW, .KW_TRUE, .KW_FALSE => {
                var children: std.ArrayList(cst.Element) = .empty;
                try children.append(self.arena, .{ .token = self.advance() });
                return try cst.makeNode(self.arena, .LITERAL_PATTERN, children.items);
            },
            .STR_PREFIX => {
                var children: std.ArrayList(cst.Element) = .empty;
                try children.append(self.arena, .{ .token = self.advance() });
                if (self.peek() == .STR_PLAIN or self.peek() == .STR_RAW) {
                    try children.append(self.arena, .{ .token = self.advance() });
                }
                return try cst.makeNode(self.arena, .LITERAL_PATTERN, children.items);
            },
            .L_PAREN => return self.parseTuplePattern(),
            .KW_NONE => {
                var children: std.ArrayList(cst.Element) = .empty;
                try children.append(self.arena, .{ .token = self.advance() });
                return try cst.makeNode(self.arena, .ENUM_VARIANT_PATTERN, children.items);
            },
            else => {
                if (isPathStart(self.peek())) return self.parsePathPattern();
                // Fallback: one token so the caller still gets a node and
                // the parser makes progress.
                var children: std.ArrayList(cst.Element) = .empty;
                if (!self.isEof()) try children.append(self.arena, .{ .token = self.advance() });
                return try cst.makeNode(self.arena, .IDENT_PATTERN, children.items);
            },
        }
    }

    fn parseTuplePattern(self: *Parser) std.mem.Allocator.Error!*const cst.Node {
        var children: std.ArrayList(cst.Element) = .empty;
        try children.append(self.arena, .{ .token = self.advance() }); // (
        try self.parsePatternListInto(&children, .R_PAREN);
        if (self.peek() == .R_PAREN) try children.append(self.arena, .{ .token = self.advance() });
        return try cst.makeNode(self.arena, .TUPLE_PATTERN, children.items);
    }

    /// Comma-separated patterns up to `close`, appended into `children`.
    fn parsePatternListInto(self: *Parser, children: *std.ArrayList(cst.Element), close: cst.SyntaxKind) !void {
        while (!self.isEof()) {
            try self.eatTrivia(children);
            if (self.peek() == close or self.peek() == .R_BRACE) break;
            try children.append(self.arena, .{ .node = try self.parsePattern() });
            try self.eatTrivia(children);
            if (self.peek() == .COMMA) try children.append(self.arena, .{ .token = self.advance() });
        }
    }

    /// A path-led pattern: bare ident (binding / `_` wildcard), dotted
    /// enum variant, or a variant/tuple-struct with a `(…)` or `{…}`
    /// payload.
    fn parsePathPattern(self: *Parser) std.mem.Allocator.Error!*const cst.Node {
        var children: std.ArrayList(cst.Element) = .empty;
        const first = self.advance();
        try children.append(self.arena, .{ .token = first });
        var dotted = false;
        while (self.peek() == .DOT and isPathStart(self.kindAfterDot())) {
            try children.append(self.arena, .{ .token = self.advance() }); // DOT
            try children.append(self.arena, .{ .token = self.advance() }); // segment
            dotted = true;
        }

        // A `(`/`{` payload may sit after inline whitespace (`Tool { … }`);
        // a newline ends the pattern. Look past inline trivia only.
        const save = self.pos;
        var lead: std.ArrayList(cst.Element) = .empty;
        try self.eatTrivia(&lead);
        const crossed_newline = for (lead.items) |e| {
            if (e.kind() == .NEWLINE) break true;
        } else false;
        const payload = self.peek();
        if (!crossed_newline and payload == .L_PAREN) {
            try children.appendSlice(self.arena, lead.items);
            try children.append(self.arena, .{ .token = self.advance() }); // (
            try self.parsePatternListInto(&children, .R_PAREN);
            if (self.peek() == .R_PAREN) try children.append(self.arena, .{ .token = self.advance() });
            return try cst.makeNode(self.arena, .TUPLE_STRUCT_PATTERN, children.items);
        }
        if (!crossed_newline and payload == .L_BRACE) {
            try children.appendSlice(self.arena, lead.items);
            try children.append(self.arena, .{ .token = self.advance() }); // {
            while (!self.isEof()) {
                try self.eatTrivia(&children);
                if (self.peek() == .R_BRACE) break;
                try children.append(self.arena, .{ .node = try self.parseFieldPattern() });
                try self.eatTrivia(&children);
                if (self.peek() == .COMMA) try children.append(self.arena, .{ .token = self.advance() });
            }
            if (self.peek() == .R_BRACE) try children.append(self.arena, .{ .token = self.advance() });
            return try cst.makeNode(self.arena, .RECORD_STRUCT_PATTERN, children.items);
        }
        self.pos = save;
        if (!dotted and std.mem.eql(u8, first.text, "_")) {
            return try cst.makeNode(self.arena, .WILD_PATTERN, children.items);
        }
        if (!dotted) return try cst.makeNode(self.arena, .IDENT_PATTERN, children.items);
        return try cst.makeNode(self.arena, .ENUM_VARIANT_PATTERN, children.items);
    }

    /// `FieldPattern := IDENT (":" Pattern)?`.
    fn parseFieldPattern(self: *Parser) std.mem.Allocator.Error!*const cst.Node {
        var children: std.ArrayList(cst.Element) = .empty;
        if (self.peek() == .IDENT) try children.append(self.arena, .{ .token = self.advance() });
        try self.eatTrivia(&children);
        if (self.peek() == .COLON) {
            try children.append(self.arena, .{ .token = self.advance() });
            try self.eatTrivia(&children);
            try children.append(self.arena, .{ .node = try self.parsePattern() });
        }
        return try cst.makeNode(self.arena, .FIELD_PATTERN, children.items);
    }

    /// Parse one expression. A value expression is a `PipeExpr` per
    /// spec/grammar.md §Expressions (assignment is statement-level); the
    /// full precedence chain is `parseBinExpr` (precedence climbing) over
    /// `parseUnary` → `parseTryExpr` → `parsePostfix` → `parsePrimary`.
    /// A dotted path is still consumed greedily into one `PATH_EXPR`, so
    /// `env.out(…)` keeps its `CALL_EXPR[PATH_EXPR, CALL_ARGS]` shape.
    fn parseExpr(self: *Parser) std.mem.Allocator.Error!*const cst.Node {
        return self.parseBinExpr(1);
    }

    /// Left binding power for each binary operator; `null` for tokens
    /// that don't open a binary expression. Higher binds tighter. Mirrors
    /// the precedence table in spec/grammar.md §"Operator precedence".
    fn binBindingPower(k: cst.SyntaxKind) ?u8 {
        return switch (k) {
            .PIPE_GT => 1,
            .PIPE_PIPE => 2,
            .AMP_AMP => 3,
            .EQ_EQ, .BANG_EQ, .L_ANGLE, .R_ANGLE, .LT_EQ, .GT_EQ => 4,
            .PIPE => 5,
            .CARET => 6,
            .AMP => 7,
            .SHL, .SHR => 8,
            .PLUS, .MINUS => 9,
            .STAR, .SLASH, .PERCENT => 10,
            else => null,
        };
    }

    /// Precedence-climbing binary-expression parser. Operators at or above
    /// `min_bp` bind here; tighter operators recurse. Trivia between
    /// operands and operators is captured so the tree stays lossless; if
    /// the next significant token isn't an operator we restore the cursor
    /// and leave that trivia for the caller.
    fn parseBinExpr(self: *Parser, min_bp: u8) std.mem.Allocator.Error!*const cst.Node {
        var lhs = try self.parseUnary();

        while (true) {
            const save = self.pos;
            var lead_trivia: std.ArrayList(cst.Element) = .empty;
            try self.eatTrivia(&lead_trivia);

            const k = self.peek();
            const bp = binBindingPower(k) orelse {
                self.pos = save;
                break;
            };
            if (bp < min_bp) {
                self.pos = save;
                break;
            }

            var children: std.ArrayList(cst.Element) = .empty;
            try children.append(self.arena, .{ .node = lhs });
            try children.appendSlice(self.arena, lead_trivia.items);
            const op_tok = self.advance();
            try children.append(self.arena, .{ .token = op_tok });
            try self.eatTrivia(&children);
            // Left-associative: the right operand stops at the next
            // operator of strictly lower binding power.
            const rhs = try self.parseBinExpr(bp + 1);
            try children.append(self.arena, .{ .node = rhs });

            const kind: cst.SyntaxKind = if (k == .PIPE_GT) .PIPE_EXPR else .BIN_EXPR;
            lhs = try cst.makeNode(self.arena, kind, children.items);
        }
        return lhs;
    }

    /// `UnaryExpr := UnaryOp UnaryExpr | TryExpr`.
    fn parseUnary(self: *Parser) std.mem.Allocator.Error!*const cst.Node {
        const k = self.peek();
        if (k == .BANG or k == .MINUS or k == .TILDE or k == .KW_REF or k == .KW_MOVE) {
            var children: std.ArrayList(cst.Element) = .empty;
            try children.append(self.arena, .{ .token = self.advance() });
            try self.eatTrivia(&children);
            const operand = try self.parseUnary();
            try children.append(self.arena, .{ .node = operand });
            return try cst.makeNode(self.arena, .UNARY_EXPR, children.items);
        }
        return self.parseTryExpr();
    }

    /// `TryExpr := "try" CallExpr | CallExpr`; `try` binds tighter than
    /// any binary operator (spec/grammar.md notes).
    fn parseTryExpr(self: *Parser) std.mem.Allocator.Error!*const cst.Node {
        if (self.peek() == .KW_TRY) {
            var children: std.ArrayList(cst.Element) = .empty;
            try children.append(self.arena, .{ .token = self.advance() });
            try self.eatTrivia(&children);
            const operand = try self.parsePostfix();
            try children.append(self.arena, .{ .node = operand });
            return try cst.makeNode(self.arena, .TRY_EXPR, children.items);
        }
        return self.parsePostfix();
    }

    /// `Postfix := Primary PostfixOp*`. Postfix operators are adjacent
    /// (no leading trivia): a call `(…)`, index `[…]`, field/method
    /// `.name` / `.name(…)`, tuple field `.0`, or `?.name`. A leading
    /// dotted path is already one `PATH_EXPR` from `parsePrimary`, so the
    /// `.name` arm here only fires after a call/index base (`f().g`).
    fn parsePostfix(self: *Parser) std.mem.Allocator.Error!*const cst.Node {
        var base = try self.parsePrimary();
        while (true) {
            // A record literal usually has space before its `{`
            // (`Point { x: 1 }`); look past trivia for that one case —
            // the trivia is captured inside the RECORD_EXPR node.
            if (self.peek().isTrivia()) {
                if (base.kind == .PATH_EXPR and self.no_record_depth == 0 and
                    self.nextNonTrivia() == .L_BRACE)
                {
                    base = try self.parseRecordExpr(base);
                    continue;
                }
                break;
            }
            switch (self.peek()) {
                .L_PAREN => {
                    var children: std.ArrayList(cst.Element) = .empty;
                    try children.append(self.arena, .{ .node = base });
                    const args = try self.parseCallArgs();
                    try children.append(self.arena, .{ .node = args });
                    base = try cst.makeNode(self.arena, .CALL_EXPR, children.items);
                },
                .L_BRACK => {
                    var children: std.ArrayList(cst.Element) = .empty;
                    try children.append(self.arena, .{ .node = base });
                    try children.append(self.arena, .{ .token = self.advance() }); // [
                    try self.eatTrivia(&children);
                    const idx = try self.parseExprUnrestricted();
                    try children.append(self.arena, .{ .node = idx });
                    try self.eatTrivia(&children);
                    if (self.peek() == .R_BRACK) {
                        try children.append(self.arena, .{ .token = self.advance() });
                    }
                    base = try cst.makeNode(self.arena, .INDEX_EXPR, children.items);
                },
                .L_BRACE => {
                    // `Path { field: expr, … }` — a record literal
                    // (spec/grammar.md §"Record literals"). Only on a
                    // plain path base, and not in a restricted position
                    // (the bare head of an `if`/`while`/`for`/`match`,
                    // where `{` opens the statement's block).
                    if (base.kind != .PATH_EXPR or self.no_record_depth > 0) break;
                    base = try self.parseRecordExpr(base);
                },
                .DOT => {
                    const after = self.kindAfterDot();
                    if (isPathStart(after)) {
                        var children: std.ArrayList(cst.Element) = .empty;
                        try children.append(self.arena, .{ .node = base });
                        try children.append(self.arena, .{ .token = self.advance() }); // DOT
                        try self.eatTrivia(&children);
                        try children.append(self.arena, .{ .token = self.advance() }); // name
                        if (self.peek() == .L_PAREN) {
                            const args = try self.parseCallArgs();
                            try children.append(self.arena, .{ .node = args });
                            base = try cst.makeNode(self.arena, .METHOD_EXPR, children.items);
                        } else {
                            base = try cst.makeNode(self.arena, .FIELD_EXPR, children.items);
                        }
                    } else if (after == .INT_LIT) {
                        var children: std.ArrayList(cst.Element) = .empty;
                        try children.append(self.arena, .{ .node = base });
                        try children.append(self.arena, .{ .token = self.advance() }); // DOT
                        try self.eatTrivia(&children);
                        try children.append(self.arena, .{ .token = self.advance() }); // INT_LIT
                        base = try cst.makeNode(self.arena, .TUPLE_FIELD_EXPR, children.items);
                    } else break;
                },
                .QUESTION_DOT => {
                    var children: std.ArrayList(cst.Element) = .empty;
                    try children.append(self.arena, .{ .node = base });
                    try children.append(self.arena, .{ .token = self.advance() }); // ?.
                    try self.eatTrivia(&children);
                    if (isPathStart(self.peek())) {
                        try children.append(self.arena, .{ .token = self.advance() });
                    }
                    base = try cst.makeNode(self.arena, .QUESTION_DOT_EXPR, children.items);
                },
                else => break,
            }
        }
        return base;
    }

    /// `RecordExpr := PathExpr "{" (RecordInit ("," RecordInit)* ","?)? "}"`
    /// with `RecordInit := IDENT (":" Expr)?` (shorthand binds the field
    /// from a same-named binding). `base` is the already-parsed path.
    /// An unrecognized shape inside the braces degrades losslessly: the
    /// remaining tokens are captured raw (brace-balanced) inside the
    /// RECORD_EXPR node.
    fn parseRecordExpr(self: *Parser, base: *const cst.Node) std.mem.Allocator.Error!*const cst.Node {
        var children: std.ArrayList(cst.Element) = .empty;
        try children.append(self.arena, .{ .node = base });
        try self.eatTrivia(&children); // space before the brace
        std.debug.assert(self.peek() == .L_BRACE);
        try children.append(self.arena, .{ .token = self.advance() }); // {
        try self.eatTrivia(&children);

        while (!self.isEof() and self.peek() != .R_BRACE) {
            if (self.peek() == .IDENT and (self.peekSecond() == .COLON or
                self.peekSecond() == .COMMA or self.peekSecond() == .R_BRACE))
            {
                var init_children: std.ArrayList(cst.Element) = .empty;
                try init_children.append(self.arena, .{ .token = self.advance() }); // field name
                try self.eatTrivia(&init_children);
                if (self.peek() == .COLON) {
                    try init_children.append(self.arena, .{ .token = self.advance() });
                    try self.eatTrivia(&init_children);
                    try init_children.append(self.arena, .{ .node = try self.parseExprUnrestricted() });
                }
                try children.append(self.arena, .{ .node = try cst.makeNode(self.arena, .RECORD_INIT, init_children.items) });
                try self.eatTrivia(&children);
                if (self.peek() == .COMMA) {
                    try children.append(self.arena, .{ .token = self.advance() });
                    try self.eatTrivia(&children);
                }
            } else {
                // Not a field-init shape: capture the rest raw,
                // brace-balanced, so the node stays lossless.
                var depth: usize = 0;
                while (!self.isEof()) {
                    const k = self.peek();
                    if (k == .L_BRACE) depth += 1;
                    if (k == .R_BRACE) {
                        if (depth == 0) break;
                        depth -= 1;
                    }
                    try children.append(self.arena, .{ .token = self.advance() });
                }
                break;
            }
        }
        if (self.peek() == .R_BRACE) {
            try children.append(self.arena, .{ .token = self.advance() });
        }
        return try cst.makeNode(self.arena, .RECORD_EXPR, children.items);
    }

    /// `Primary` — the leaf forms. Statement-keyword primaries (match /
    /// if / block / scope / spawn / …) are not yet parsed and fall to
    /// `parseUnknownExpr` recovery.
    fn parsePrimary(self: *Parser) std.mem.Allocator.Error!*const cst.Node {
        const k = self.peek();
        if (k == .STR_PLAIN or k == .STR_PREFIX or k == .STR_RAW) return self.parseStringLit();
        if (k == .INT_LIT or k == .FLOAT_LIT) return self.parseNumLit();
        if (k == .KW_TRUE or k == .KW_FALSE or k == .KW_NONE) {
            var children: std.ArrayList(cst.Element) = .empty;
            try children.append(self.arena, .{ .token = self.advance() });
            return try cst.makeNode(self.arena, .LITERAL_EXPR, children.items);
        }
        if (k == .L_PAREN) return self.parseParenOrTuple();
        if (k == .L_BRACK) return self.parseArrayExpr();
        if (k == .KW_MATCH) return self.parseMatch(.MATCH_EXPR);
        if (isPathStart(k)) return self.parsePath();
        return self.parseUnknownExpr();
    }

    /// `(` Expr `)` → `PAREN_EXPR`; `(` Expr (`,` Expr)* `)` →
    /// `TUPLE_EXPR`; `()` → unit `TUPLE_EXPR`.
    fn parseParenOrTuple(self: *Parser) std.mem.Allocator.Error!*const cst.Node {
        var children: std.ArrayList(cst.Element) = .empty;
        try children.append(self.arena, .{ .token = self.advance() }); // (
        try self.eatTrivia(&children);
        if (self.peek() == .R_PAREN) {
            try children.append(self.arena, .{ .token = self.advance() });
            return try cst.makeNode(self.arena, .TUPLE_EXPR, children.items);
        }
        try children.append(self.arena, .{ .node = try self.parseExprUnrestricted() });
        try self.eatTrivia(&children);
        var is_tuple = false;
        while (self.peek() == .COMMA) {
            is_tuple = true;
            try children.append(self.arena, .{ .token = self.advance() });
            try self.eatTrivia(&children);
            if (self.peek() == .R_PAREN) break; // trailing comma
            try children.append(self.arena, .{ .node = try self.parseExprUnrestricted() });
            try self.eatTrivia(&children);
        }
        if (self.peek() == .R_PAREN) {
            try children.append(self.arena, .{ .token = self.advance() });
        }
        return try cst.makeNode(self.arena, if (is_tuple) .TUPLE_EXPR else .PAREN_EXPR, children.items);
    }

    /// `[` Expr (`,` Expr)* `]` (list) or `[` Expr `;` Expr `]` (repeat).
    /// Elements parse unrestricted (record literals are unambiguous
    /// inside brackets).
    fn parseArrayExpr(self: *Parser) std.mem.Allocator.Error!*const cst.Node {
        var children: std.ArrayList(cst.Element) = .empty;
        try children.append(self.arena, .{ .token = self.advance() }); // [
        try self.eatTrivia(&children);
        if (self.peek() == .R_BRACK) {
            try children.append(self.arena, .{ .token = self.advance() });
            return try cst.makeNode(self.arena, .ARRAY_EXPR, children.items);
        }
        try children.append(self.arena, .{ .node = try self.parseExprUnrestricted() });
        try self.eatTrivia(&children);
        if (self.peek() == .SEMICOLON) {
            try children.append(self.arena, .{ .token = self.advance() });
            try self.eatTrivia(&children);
            try children.append(self.arena, .{ .node = try self.parseExprUnrestricted() });
            try self.eatTrivia(&children);
        } else {
            while (self.peek() == .COMMA) {
                try children.append(self.arena, .{ .token = self.advance() });
                try self.eatTrivia(&children);
                if (self.peek() == .R_BRACK) break;
                try children.append(self.arena, .{ .node = try self.parseExprUnrestricted() });
                try self.eatTrivia(&children);
            }
        }
        if (self.peek() == .R_BRACK) {
            try children.append(self.arena, .{ .token = self.advance() });
        }
        return try cst.makeNode(self.arena, .ARRAY_EXPR, children.items);
    }

    /// Tokens that can start a path segment. Beyond plain `IDENT`,
    /// the param-mode soft keywords (`in`, `out`, `ref`, `move`) are
    /// accepted: they're only reserved in param positions, and the
    /// lexer doesn't have that context. Letting them through in
    /// path / call positions is what makes `env.out(…)` and
    /// `chan.in()` parse.
    fn isPathStart(k: cst.SyntaxKind) bool {
        return switch (k) {
            // Keywords admissible as a field/path segment after `.`. `on` joins
            // the list so a host-face call like `qview.on(node, event, handler)`
            // (the QView retained Renderer op, spec/qview-protocol.md) parses as
            // member access — the `on`-handler keyword only begins a member of a
            // `screen { … }` block, a distinct parse position, so there is no
            // ambiguity here. `self` joins so a method body's receiver
            // access (`self.w`, `self.area()`) parses as the same greedy
            // PATH_EXPR every other name uses (B4 fit-method dispatch
            // reads it).
            .IDENT, .KW_IN, .KW_OUT, .KW_REF, .KW_MOVE, .KW_ON, .KW_SELF => true,
            else => false,
        };
    }

    fn parseStringLit(self: *Parser) !*const cst.Node {
        var children: std.ArrayList(cst.Element) = .empty;
        // Optional STR_PREFIX (e.g. `url"…"`).
        if (self.peek() == .STR_PREFIX) {
            try children.append(self.arena, .{ .token = self.advance() });
        }
        if (self.peek() == .STR_PLAIN or self.peek() == .STR_RAW) {
            try children.append(self.arena, .{ .token = self.advance() });
        }
        return try cst.makeNode(self.arena, .STR_LITERAL, children.items);
    }

    fn parseNumLit(self: *Parser) !*const cst.Node {
        var children: std.ArrayList(cst.Element) = .empty;
        try children.append(self.arena, .{ .token = self.advance() }); // INT_LIT / FLOAT_LIT
        if (self.peek() == .NUM_SUFFIX) {
            try children.append(self.arena, .{ .token = self.advance() });
        }
        return try cst.makeNode(self.arena, .NUM_LITERAL, children.items);
    }

    fn parsePath(self: *Parser) !*const cst.Node {
        std.debug.assert(isPathStart(self.peek()));
        var children: std.ArrayList(cst.Element) = .empty;
        try children.append(self.arena, .{ .token = self.advance() }); // IDENT or soft kw
        while (self.peek() == .DOT) {
            // Look one ahead: only continue if `.` is followed by an
            // identifier-or-soft-keyword.
            const save = self.pos;
            const dot = self.advance();
            if (isPathStart(self.peek())) {
                try children.append(self.arena, .{ .token = dot });
                try children.append(self.arena, .{ .token = self.advance() });
                continue;
            }
            self.pos = save;
            break;
        }
        return try cst.makeNode(self.arena, .PATH_EXPR, children.items);
    }

    fn parseCallArgs(self: *Parser) !*const cst.Node {
        std.debug.assert(self.peek() == .L_PAREN);
        var children: std.ArrayList(cst.Element) = .empty;
        try children.append(self.arena, .{ .token = self.advance() }); // L_PAREN
        try self.eatTrivia(&children);

        while (!self.isEof() and self.peek() != .R_PAREN) {
            const arg = try self.parseCallArg();
            try children.append(self.arena, .{ .node = arg });
            try self.eatTrivia(&children);
            if (self.peek() == .COMMA) {
                try children.append(self.arena, .{ .token = self.advance() });
                try self.eatTrivia(&children);
            }
        }
        if (self.peek() == .R_PAREN) {
            try children.append(self.arena, .{ .token = self.advance() });
        }
        return try cst.makeNode(self.arena, .CALL_ARGS, children.items);
    }

    fn parseCallArg(self: *Parser) !*const cst.Node {
        var children: std.ArrayList(cst.Element) = .empty;
        const expr = try self.parseExprUnrestricted();
        try children.append(self.arena, .{ .node = expr });
        return try cst.makeNode(self.arena, .CALL_ARG, children.items);
    }

    fn parseUnknownExpr(self: *Parser) !*const cst.Node {
        // Recovery: wrap whatever token we're sitting on as a
        // degenerate LITERAL_EXPR so the caller still gets *some*
        // expression node and the parser makes progress.
        var children: std.ArrayList(cst.Element) = .empty;
        if (!self.isEof()) {
            try children.append(self.arena, .{ .token = self.advance() });
        }
        return try cst.makeNode(self.arena, .LITERAL_EXPR, children.items);
    }
};

// =====================================================================
// Tests
// =====================================================================

const testing = std.testing;
const ast = @import("ast.zig");

test "round-trip: serialize(parse(s)) == s" {
    const sources = [_][]const u8{
        "fn main { env.out(\"hi\") }\n",
        "//! header\n\npub fn helper -> i64 { 42 }\n",
        "let xs: [i64; 4] = [1, 2, 3, 4]\n",
        "@stage\nfn mic_input -> Signal<PCM<f32>, 48.kHz> {\n    env.audio.input()\n}\n",
        "",
        "fn a {} fn b {}\n",
        "import dev.q64.hello_world.{version}\n\nfn main { env.out(version()) }\n",
        "import q64.math\n",
        "import q64.math as m\n",
        "import q64.math.{Vec3, dot}\n",
        "import \"./util.q\".{helper}\n",
        "screen counter {\n    state count: i64 = 0\n\n    draw {\n        number(40, 120, count)\n        button(1, 40, 180, 280, 72, 1)\n    }\n\n    on press(id: i64) {\n        count = count + 1\n    }\n}\n",
        "screen {\n    draw { text(0, 0, 0) }\n}\n",
    };

    for (sources) |src| {
        const r = try parse(testing.allocator, src, "test.q");
        defer r.deinit(testing.allocator);

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(testing.allocator);
        try cst.serialize(r.root, testing.allocator, &out);

        try testing.expectEqualStrings(src, out.items);
    }
}

test "screen DSL: a screen decl structures state / draw / on members" {
    const src =
        \\screen counter {
        \\    state count: i64 = 0
        \\    draw {
        \\        number(40, 120, count)
        \\        button(1, 40, 180, 280, 72, 1)
        \\    }
        \\    on press(id: i64) {
        \\        count = count + 1
        \\    }
        \\}
        \\
    ;
    const r = try parse(testing.allocator, src, "screen.q");
    defer r.deinit(testing.allocator);

    const sf = ast.SourceFile.cast(r.root).?;
    var items = sf.items();
    const item = items.next() orelse return error.TestExpectedItem;
    const screen = switch (item) {
        .screen_decl => |s| s,
        else => return error.TestExpectedScreen,
    };
    try testing.expect(items.next() == null); // exactly one top-level item

    // Name.
    try testing.expectEqualStrings("counter", (screen.name() orelse return error.TestNoName).text);

    // One `state` member, named `count`.
    var states = screen.states();
    const st = states.next() orelse return error.TestNoState;
    try testing.expectEqualStrings("count", (st.name() orelse return error.TestNoStateName).text);
    try testing.expect(states.next() == null);

    // The `draw` block holds the widget calls as statements.
    const draw = screen.draw() orelse return error.TestNoDraw;
    var draw_stmts = (draw.body() orelse return error.TestNoDrawBody).statements();
    try testing.expect(draw_stmts.next() != null); // number(...)
    try testing.expect(draw_stmts.next() != null); // button(...)

    // One `on press(id)` handler with a param and a body.
    var handlers = screen.handlers();
    const h = handlers.next() orelse return error.TestNoHandler;
    try testing.expectEqualStrings("press", (h.event() orelse return error.TestNoEvent).text);
    try testing.expect(h.params() != null);
    try testing.expect(h.body() != null);
    try testing.expect(handlers.next() == null);
}

test "stray carriage return produces LEX010 in parse result" {
    const r = try parse(testing.allocator, "fn main\r{}\n", "stray.q");
    defer r.deinit(testing.allocator);

    var found = false;
    for (r.diagnostics) |d| {
        if (std.mem.eql(u8, d.code, "LEX010")) found = true;
    }
    try testing.expect(found);
}

test "parses `fn main { ... }` into a single FN_DECL item" {
    const src = "fn main { env.out(\"hi\") }\n";
    const r = try parse(testing.allocator, src, "main.q");
    defer r.deinit(testing.allocator);

    const sf = ast.SourceFile.cast(r.root) orelse return error.TestExpectedSourceFile;
    var iter = sf.items();
    const item = iter.next() orelse return error.TestExpectedItem;
    const fd = item.fn_decl;

    try testing.expectEqualStrings("main", fd.name().?.text);
    try testing.expect(!fd.isPublic());
    try testing.expect(fd.params() == null);
    try testing.expect(fd.returnType() == null);
    try testing.expect(fd.body() != null);
    try testing.expect(iter.next() == null);
}

test "parses `pub fn helper -> i64 { 42 }` with all positions populated" {
    const src = "pub fn helper -> i64 { 42 }\n";
    const r = try parse(testing.allocator, src, "helper.q");
    defer r.deinit(testing.allocator);

    const sf = ast.SourceFile.cast(r.root).?;
    var iter = sf.items();
    const fd = (iter.next() orelse return error.TestExpectedItem).fn_decl;

    try testing.expect(fd.isPublic());
    try testing.expectEqualStrings("helper", fd.name().?.text);
    try testing.expect(fd.params() == null);
    try testing.expect(fd.returnType() != null);
    try testing.expect(fd.body() != null);
}

test "parses `fn f(x: i32, y: i32) -> i32 { x + y }` with params + return + body" {
    const src = "fn f(x: i32, y: i32) -> i32 { x + y }\n";
    const r = try parse(testing.allocator, src, "f.q");
    defer r.deinit(testing.allocator);

    const sf = ast.SourceFile.cast(r.root).?;
    var iter = sf.items();
    const fd = (iter.next() orelse return error.TestExpectedItem).fn_decl;

    try testing.expectEqualStrings("f", fd.name().?.text);
    try testing.expect(fd.params() != null);
    try testing.expect(fd.returnType() != null);
    try testing.expect(fd.body() != null);

    // Params are structured: two PARAMs, each with a name and a type.
    var it = fd.params().?.iter();
    const a = (it.next() orelse return error.TestExpectedNonNull);
    try testing.expectEqualStrings("x", a.name().?.text);
    const at = (try a.typeText(testing.allocator)).?;
    defer testing.allocator.free(at);
    try testing.expectEqualStrings("i32", at);
    const b = (it.next() orelse return error.TestExpectedNonNull);
    try testing.expectEqualStrings("y", b.name().?.text);
    const bt = (try b.typeText(testing.allocator)).?;
    defer testing.allocator.free(bt);
    try testing.expectEqualStrings("i32", bt);
    try testing.expect(it.next() == null);
}

test "parses a param mode and a generic param type" {
    // `ref` is a mode; the `Map<K, V>` type's inner comma must not split
    // the param.
    const src = "fn f(ref m: Map<K, V>, x: i32) { 0 }\n";
    const r = try parse(testing.allocator, src, "modes.q");
    defer r.deinit(testing.allocator);

    const sf = ast.SourceFile.cast(r.root).?;
    var items = sf.items();
    const fd = (items.next() orelse return error.TestExpectedItem).fn_decl;

    var it = fd.params().?.iter();
    const m = (it.next() orelse return error.TestExpectedNonNull);
    try testing.expectEqualStrings("ref", m.mode().?.text);
    try testing.expectEqualStrings("m", m.name().?.text);
    const mt = (try m.typeText(testing.allocator)).?;
    defer testing.allocator.free(mt);
    try testing.expectEqualStrings("Map<K, V>", mt);
    const x = (it.next() orelse return error.TestExpectedNonNull);
    try testing.expect(x.mode() == null);
    try testing.expectEqualStrings("x", x.name().?.text);
    try testing.expect(it.next() == null);
}

test "parses nested `<…>` in return type without breaking the block" {
    const src = "fn g -> Signal<PCM<f32>, 48.kHz> { todo }\n";
    const r = try parse(testing.allocator, src, "g.q");
    defer r.deinit(testing.allocator);

    const sf = ast.SourceFile.cast(r.root).?;
    var iter = sf.items();
    const fd = (iter.next() orelse return error.TestExpectedItem).fn_decl;

    try testing.expect(fd.returnType() != null);
    try testing.expect(fd.body() != null);
}

test "parses two fn items in one file" {
    const src = "fn a { 1 }\nfn b { 2 }\n";
    const r = try parse(testing.allocator, src, "two.q");
    defer r.deinit(testing.allocator);

    const sf = ast.SourceFile.cast(r.root).?;
    var iter = sf.items();
    const first = (iter.next() orelse return error.TestExpectedItem).fn_decl;
    const second = (iter.next() orelse return error.TestExpectedItem).fn_decl;
    try testing.expectEqualStrings("a", first.name().?.text);
    try testing.expectEqualStrings("b", second.name().?.text);
    try testing.expect(iter.next() == null);
}

test "parses a selective import into an IMPORT_STMT with path + names" {
    const src = "import dev.q64.hello_world.{version, build}\nfn main { 0 }\n";
    const r = try parse(testing.allocator, src, "imp.q");
    defer r.deinit(testing.allocator);

    const sf = ast.SourceFile.cast(r.root) orelse return error.TestExpectedSourceFile;
    var imports = sf.imports();
    const im = imports.next() orelse return error.TestExpectedImport;

    try testing.expect(!im.isRelative());
    const p = (try im.path(testing.allocator)) orelse return error.TestExpectedPath;
    defer testing.allocator.free(p);
    try testing.expectEqualStrings("dev.q64.hello_world", p);

    var names = im.names();
    try testing.expectEqualStrings("version", (names.next() orelse return error.TestExpectedName).text);
    try testing.expectEqualStrings("build", (names.next() orelse return error.TestExpectedName).text);
    try testing.expect(names.next() == null);
    try testing.expect(imports.next() == null);

    // The fn item is still surfaced alongside the import.
    var items = sf.items();
    const fd = (items.next() orelse return error.TestExpectedItem).fn_decl;
    try testing.expectEqualStrings("main", fd.name().?.text);
}

test "parses namespace and alias imports" {
    const src = "import q64.math as m\n";
    const r = try parse(testing.allocator, src, "alias.q");
    defer r.deinit(testing.allocator);

    const sf = ast.SourceFile.cast(r.root).?;
    var imports = sf.imports();
    const im = imports.next() orelse return error.TestExpectedImport;
    const p = (try im.path(testing.allocator)).?;
    defer testing.allocator.free(p);
    try testing.expectEqualStrings("q64.math", p);
    // No selective names on an alias import.
    var names = im.names();
    try testing.expect(names.next() == null);
}

test "parses a quoted relative import path" {
    const src = "import \"./util.q\".{helper}\n";
    const r = try parse(testing.allocator, src, "rel.q");
    defer r.deinit(testing.allocator);

    const sf = ast.SourceFile.cast(r.root).?;
    var imports = sf.imports();
    const im = imports.next() orelse return error.TestExpectedImport;
    try testing.expect(im.isRelative());
    const p = (try im.path(testing.allocator)).?;
    defer testing.allocator.free(p);
    try testing.expectEqualStrings("./util.q", p);
    var names = im.names();
    try testing.expectEqualStrings("helper", (names.next() orelse return error.TestExpectedName).text);
}

fn hasDiag(r: Result, code: []const u8) bool {
    for (r.diagnostics) |d| {
        if (std.mem.eql(u8, d.code, code)) return true;
    }
    return false;
}

fn expectDiagAndLossless(src: []const u8, code: []const u8) !void {
    const r = try parse(testing.allocator, src, "t.q");
    defer r.deinit(testing.allocator);
    try testing.expect(hasDiag(r, code));

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try cst.serialize(r.root, testing.allocator, &out);
    try testing.expectEqualStrings(src, out.items);
}

test "NAM003 — wildcard import is forbidden" {
    try expectDiagAndLossless("import q64.math.*\n\nfn main { env.out(\"hi\") }\n", "NAM003");
}

test "NAM004 — selective import combined with alias" {
    try expectDiagAndLossless("import q64.math.{Vec3, dot} as v\n", "NAM004");
}

test "NAM011 — dash in a bare module path" {
    try expectDiagAndLossless("import audio-filters.{LowPass}\n", "NAM011");
}

test "NAM009 — block pub form is forbidden" {
    try expectDiagAndLossless("pub {\n    fn a -> i64 { 1 }\n}\n", "NAM009");
}

fn binOpKind(node: *const cst.Node) cst.SyntaxKind {
    for (node.children) |c| switch (c) {
        .token => |t| if (!t.kind.isTrivia()) return t.kind,
        .node => {},
    };
    return .EOF;
}

fn firstChildNode(node: *const cst.Node) ?*const cst.Node {
    for (node.children) |c| switch (c) {
        .node => |n| return n,
        .token => {},
    };
    return null;
}

fn lastChildNode(node: *const cst.Node) ?*const cst.Node {
    var r: ?*const cst.Node = null;
    for (node.children) |c| switch (c) {
        .node => |n| r = n,
        .token => {},
    };
    return r;
}

test "expression losslessness across forms" {
    const sources = [_][]const u8{
        "fn m { a + b }\n",
        "fn m { a + b * c - d }\n",
        "fn m { !flag }\n",
        "fn m { -x + y }\n",
        "fn m { a && b || c }\n",
        "fn m { x == y }\n",
        "fn m { try foo() }\n",
        "fn m { obj.field }\n",
        "fn m { f().g().h }\n",
        "fn m { xs[0] + xs[1] }\n",
        "fn m { (a + b) * c }\n",
        "fn m { [1, 2, 3] }\n",
        "fn m { [x; 4] }\n",
        "fn m { a?.b }\n",
        "fn m { t.0 }\n",
        "fn m { env.out(\"hi\") }\n",
        "fn m { foo(a, b + c, d) }\n",
        "fn m { x |> f(y) }\n",
        "fn m { 1 + 2 * 3 - 4 / 5 % 6 }\n",
    };
    for (sources) |src| {
        const r = try parse(testing.allocator, src, "e.q");
        defer r.deinit(testing.allocator);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(testing.allocator);
        try cst.serialize(r.root, testing.allocator, &out);
        try testing.expectEqualStrings(src, out.items);
    }
}

test "precedence: `*` binds tighter than `+`" {
    const r = try parseExpression(testing.allocator, "a + b * c", "e.q");
    defer r.deinit(testing.allocator);
    try testing.expectEqual(cst.SyntaxKind.BIN_EXPR, r.root.kind);
    try testing.expectEqual(cst.SyntaxKind.PLUS, binOpKind(r.root));
    const rhs = lastChildNode(r.root).?;
    try testing.expectEqual(cst.SyntaxKind.BIN_EXPR, rhs.kind);
    try testing.expectEqual(cst.SyntaxKind.STAR, binOpKind(rhs));
}

test "left-associativity: `a - b - c` nests as `(a - b) - c`" {
    const r = try parseExpression(testing.allocator, "a - b - c", "e.q");
    defer r.deinit(testing.allocator);
    try testing.expectEqual(cst.SyntaxKind.BIN_EXPR, r.root.kind);
    try testing.expectEqual(cst.SyntaxKind.MINUS, binOpKind(r.root));
    const lhs = firstChildNode(r.root).?;
    try testing.expectEqual(cst.SyntaxKind.BIN_EXPR, lhs.kind);
}

test "postfix: `env.out(...)` stays CALL_EXPR over a dotted PATH_EXPR" {
    const r = try parseExpression(testing.allocator, "env.out(\"hi\")", "e.q");
    defer r.deinit(testing.allocator);
    try testing.expectEqual(cst.SyntaxKind.CALL_EXPR, r.root.kind);
    const callee = firstChildNode(r.root).?;
    try testing.expectEqual(cst.SyntaxKind.PATH_EXPR, callee.kind);
}

test "postfix: method call on a call result is METHOD_EXPR" {
    const r = try parseExpression(testing.allocator, "f().g()", "e.q");
    defer r.deinit(testing.allocator);
    try testing.expectEqual(cst.SyntaxKind.METHOD_EXPR, r.root.kind);
}

test "record literal: `Point { x: 1, y: 2 }` is RECORD_EXPR with two inits" {
    const r = try parseExpression(testing.allocator, "Point { x: 1, y: 2 }", "e.q");
    defer r.deinit(testing.allocator);
    try testing.expectEqual(cst.SyntaxKind.RECORD_EXPR, r.root.kind);
    var inits: usize = 0;
    for (r.root.children) |c| switch (c) {
        .node => |n| if (n.kind == .RECORD_INIT) {
            inits += 1;
        },
        .token => {},
    };
    try testing.expectEqual(@as(usize, 2), inits);
}

test "record literal: shorthand, empty, nested-in-array all parse losslessly" {
    const cases = [_]struct { src: []const u8, kind: cst.SyntaxKind }{
        .{ .src = "Color { r }", .kind = .RECORD_EXPR },
        .{ .src = "DemoTools {}", .kind = .RECORD_EXPR },
        .{ .src = "[Color { r: 1 }, Color { r: 2 }]", .kind = .ARRAY_EXPR },
        .{ .src = "f(Point { x: 1 })", .kind = .CALL_EXPR },
    };
    for (cases) |cse| {
        const r = try parseExpression(testing.allocator, cse.src, "e.q");
        defer r.deinit(testing.allocator);
        try testing.expectEqual(cse.kind, r.root.kind);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(testing.allocator);
        try cst.serialize(r.root, testing.allocator, &out);
        try testing.expectEqualStrings(cse.src, out.items);
    }
}

test "record literal: restricted in if/while/match heads - brace opens the block" {
    const src =
        "fn f(x: bool) {\n" ++
        "    if x { env.out(\"y\") }\n" ++
        "    while x { env.out(\"w\") }\n" ++
        "    match x { _ -> env.out(\"m\"), }\n" ++
        "}\n";
    const r = try parse(testing.allocator, src, "t.q");
    defer r.deinit(testing.allocator);
    try testing.expect(!nodeContainsKind(r.root, .RECORD_EXPR));
    try testing.expect(nodeContainsKind(r.root, .IF_STMT));
    try testing.expect(nodeContainsKind(r.root, .WHILE_STMT));
    try testing.expect(nodeContainsKind(r.root, .MATCH_STMT));
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try cst.serialize(r.root, testing.allocator, &out);
    try testing.expectEqualStrings(src, out.items);
}

test "record literal: parenthesized form lifts the restriction" {
    const src = "fn f { if (Point { x: 1 }).ok { env.out(\"y\") } }\n";
    const r = try parse(testing.allocator, src, "t.q");
    defer r.deinit(testing.allocator);
    try testing.expect(nodeContainsKind(r.root, .RECORD_EXPR));
}

fn nodeContainsKind(node: *const cst.Node, kind: cst.SyntaxKind) bool {
    if (node.kind == kind) return true;
    for (node.children) |c| switch (c) {
        .node => |n| if (nodeContainsKind(n, kind)) return true,
        .token => {},
    };
    return false;
}

test "expression views: bin / unary / try / index / field / method / tuple-field / paren / tuple / array" {
    const tag = std.meta.activeTag;
    const Case = struct { src: []const u8, want: std.meta.Tag(ast.Expr) };
    const cases = [_]Case{
        .{ .src = "a + b", .want = .bin },
        .{ .src = "-x", .want = .unary },
        .{ .src = "try f()", .want = .@"try" },
        .{ .src = "xs[0]", .want = .index },
        .{ .src = "f().x", .want = .field },
        .{ .src = "f().g()", .want = .method },
        .{ .src = "f().0", .want = .tuple_field },
        .{ .src = "f()?.x", .want = .question_dot },
        .{ .src = "(a, b)", .want = .tuple },
        .{ .src = "(a)", .want = .paren },
        .{ .src = "[1, 2, 3]", .want = .array },
    };
    for (cases) |cse| {
        const r = try parseExpression(testing.allocator, cse.src, "e.q");
        defer r.deinit(testing.allocator);
        const e = ast.Expr.cast(r.root) orelse return error.TestExpectedNonNull;
        try testing.expectEqual(cse.want, tag(e));
    }

    // Accessor spot-checks.
    {
        const r = try parseExpression(testing.allocator, "a + b", "e.q");
        defer r.deinit(testing.allocator);
        const e = ast.Expr.cast(r.root).?;
        try testing.expectEqual(cst.SyntaxKind.PLUS, e.bin.op().?.kind);
        try testing.expect(e.bin.lhs() != null);
        try testing.expect(e.bin.rhs() != null);
    }
    {
        const r = try parseExpression(testing.allocator, "f().x", "e.q");
        defer r.deinit(testing.allocator);
        const e = ast.Expr.cast(r.root).?;
        try testing.expect(e.field.base() != null);
        try testing.expectEqualStrings("x", e.field.field().?.text);
    }
    {
        const r = try parseExpression(testing.allocator, "[1, 2, 3]", "e.q");
        defer r.deinit(testing.allocator);
        const e = ast.Expr.cast(r.root).?;
        var els = e.array.elements();
        var n: usize = 0;
        while (els.next()) |_| n += 1;
        try testing.expectEqual(@as(usize, 3), n);
    }
}

fn blockOf(sf: ast.SourceFile) ?*const cst.Node {
    var items = sf.items();
    const fd = (items.next() orelse return null).fn_decl;
    const body = fd.body() orelse return null;
    return body.cst;
}

fn hasChildKind(node: *const cst.Node, kind: cst.SyntaxKind) bool {
    for (node.children) |c| switch (c) {
        .node => |n| if (n.kind == kind) return true,
        .token => {},
    };
    return false;
}

fn childKindNode(node: *const cst.Node, kind: cst.SyntaxKind) ?*const cst.Node {
    for (node.children) |c| switch (c) {
        .node => |n| if (n.kind == kind) return n,
        .token => {},
    };
    return null;
}

fn firstArmPatternKind(src: []const u8) !cst.SyntaxKind {
    const r = try parse(testing.allocator, src, "p.q");
    defer r.deinit(testing.allocator);
    const sf = ast.SourceFile.cast(r.root).?;
    const block = blockOf(sf) orelse return error.TestExpectedBlock;
    const match = childKindNode(block, .MATCH_STMT) orelse return error.TestExpectedMatch;
    const arm = childKindNode(match, .MATCH_ARM) orelse return error.TestExpectedArm;
    const pat = firstChildNode(arm) orelse return error.TestExpectedPattern;
    return pat.kind;
}

test "pattern kinds in match arms" {
    try testing.expectEqual(cst.SyntaxKind.WILD_PATTERN, try firstArmPatternKind("fn m {\n    match x {\n        _ -> 0,\n    }\n}\n"));
    try testing.expectEqual(cst.SyntaxKind.LITERAL_PATTERN, try firstArmPatternKind("fn m {\n    match x {\n        \"echo\" -> 0,\n    }\n}\n"));
    try testing.expectEqual(cst.SyntaxKind.LITERAL_PATTERN, try firstArmPatternKind("fn m {\n    match x {\n        42 -> 0,\n    }\n}\n"));
    try testing.expectEqual(cst.SyntaxKind.IDENT_PATTERN, try firstArmPatternKind("fn m {\n    match x {\n        other -> 0,\n    }\n}\n"));
    try testing.expectEqual(cst.SyntaxKind.TUPLE_STRUCT_PATTERN, try firstArmPatternKind("fn m {\n    match x {\n        Ok(v) -> 0,\n    }\n}\n"));
    try testing.expectEqual(cst.SyntaxKind.ENUM_VARIANT_PATTERN, try firstArmPatternKind("fn m {\n    match x {\n        McpError.Unsupported -> 0,\n    }\n}\n"));
    try testing.expectEqual(cst.SyntaxKind.RECORD_STRUCT_PATTERN, try firstArmPatternKind("fn m {\n    match x {\n        Tool { name } -> 0,\n    }\n}\n"));
}

test "pattern losslessness in let / for / match / if-let" {
    const sources = [_][]const u8{
        "fn m {\n    let (a, b) = pair\n}\n",
        "fn m {\n    let Tool { name, description } = t\n}\n",
        "fn m {\n    for (k, v) in entries {\n        use(k)\n    }\n}\n",
        "fn m {\n    if let Some(n) = opt {\n        use(n)\n    }\n}\n",
        "fn m {\n    match r {\n        Ok(v) -> v,\n        Err(e) -> panic e,\n        _ -> 0,\n    }\n}\n",
    };
    for (sources) |src| {
        const r = try parse(testing.allocator, src, "p.q");
        defer r.deinit(testing.allocator);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(testing.allocator);
        try cst.serialize(r.root, testing.allocator, &out);
        try testing.expectEqualStrings(src, out.items);
    }
}

test "item losslessness across forms" {
    const sources = [_][]const u8{
        "pub struct Vec3<T> { x: T, y: T, z: T }\n",
        "struct Empty\n",
        "pub struct UserId(i64)\n",
        "pub enum Color { Rgb, Hsv, Lab }\n",
        "pub enum McpError {\n    Unsupported,\n    ToolNotFound(str),\n    InvalidArguments(str),\n}\n",
        "pub type Hz = f64\n",
        "type Pair<A, B> = (A, B)\n",
        "pub const PI: f64 = 3.14159\n",
        "pub face Eq {\n    fn eq(self, other: Self) -> bool\n}\n",
        "pub fit Vec3<f32> : Eq {\n    fn eq(self, other: Self) -> bool { true }\n}\n",
        "//! header\n\nimport q64.math.{Vec3}\n\npub struct P { x: i64 }\n\nfn main { 0 }\n",
    };
    for (sources) |src| {
        const r = try parse(testing.allocator, src, "i.q");
        defer r.deinit(testing.allocator);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(testing.allocator);
        try cst.serialize(r.root, testing.allocator, &out);
        try testing.expectEqualStrings(src, out.items);
    }
}

test "struct fields are structured" {
    const src = "pub struct Tool {\n    name: str,\n    description: str,\n}\n";
    const r = try parse(testing.allocator, src, "t.q");
    defer r.deinit(testing.allocator);
    const sf = ast.SourceFile.cast(r.root).?;
    const decl = childKindNode(sf.cst, .STRUCT_DECL) orelse return error.TestExpectedStruct;
    const body = childKindNode(decl, .RECORD_BODY) orelse return error.TestExpectedBody;
    var fields: usize = 0;
    for (body.children) |c| switch (c) {
        .node => |n| if (n.kind == .FIELD) {
            fields += 1;
        },
        .token => {},
    };
    try testing.expectEqual(@as(usize, 2), fields);
}

test "enum variants are structured" {
    const src = "pub enum E { A, B(i64), C { x: i64 } }\n";
    const r = try parse(testing.allocator, src, "e.q");
    defer r.deinit(testing.allocator);
    const sf = ast.SourceFile.cast(r.root).?;
    const decl = childKindNode(sf.cst, .ENUM_DECL) orelse return error.TestExpectedEnum;
    var variants: usize = 0;
    for (decl.children) |c| switch (c) {
        .node => |n| if (n.kind == .VARIANT) {
            variants += 1;
        },
        .token => {},
    };
    try testing.expectEqual(@as(usize, 3), variants);
}

test "enum: a `None` variant parses (KW_NONE name; the loop must progress)" {
    // `None` lexes as KW_NONE; parseVariant accepts it as a name. The
    // regression: the variant loop hung forever on any keyword-shaped
    // name (no progress guard).
    const src = "enum Opt { Some(i64), None }\n";
    const r = try parse(testing.allocator, src, "opt.q");
    defer r.deinit(testing.allocator);
    const sf = ast.SourceFile.cast(r.root).?;
    const decl = childKindNode(sf.cst, .ENUM_DECL) orelse return error.TestExpectedEnum;
    var names: [2][]const u8 = undefined;
    var n: usize = 0;
    for (decl.children) |c| switch (c) {
        .node => |node| if (node.kind == .VARIANT) {
            const v = ast.Variant{ .cst = node };
            names[n] = (v.name() orelse return error.TestExpectedName).text;
            n += 1;
        },
        .token => {},
    };
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("Some", names[0]);
    try testing.expectEqualStrings("None", names[1]);
}

test "ItemIter surfaces struct / enum / fn declarations in order" {
    const src = "pub struct P { x: i64 }\npub enum E { A }\nfn main { 0 }\n";
    const r = try parse(testing.allocator, src, "mix.q");
    defer r.deinit(testing.allocator);
    const sf = ast.SourceFile.cast(r.root).?;
    var items = sf.items();

    const s = items.next() orelse return error.TestExpectedItem;
    try testing.expectEqualStrings("P", s.struct_decl.name().?.text);
    try testing.expect(s.struct_decl.isPublic());

    const e = items.next() orelse return error.TestExpectedItem;
    try testing.expectEqualStrings("E", e.enum_decl.name().?.text);

    const f = items.next() orelse return error.TestExpectedItem;
    try testing.expectEqualStrings("main", f.fn_decl.name().?.text);
    try testing.expect(items.next() == null);
}

test "item views: struct fields, enum variants, type/const/face/fit names" {
    const src =
        \\pub struct Point { x: i64, y: i64 }
        \\enum Dir { North, South }
        \\pub type Id = i64
        \\const MAX: i64 = 99
        \\face Greeter { fn hi() -> str }
        \\fit Point : Greeter { fn hi() -> str { "" } }
        \\fn main { 0 }
        \\
    ;
    const r = try parse(testing.allocator, src, "items.q");
    defer r.deinit(testing.allocator);
    const sf = ast.SourceFile.cast(r.root).?;
    var it = sf.items();

    const s = (it.next() orelse return error.TestExpectedItem).struct_decl;
    try testing.expect(s.isPublic());
    try testing.expectEqualStrings("Point", s.name().?.text);
    var fields = s.fields();
    const fx = fields.next() orelse return error.TestExpectedItem;
    try testing.expectEqualStrings("x", fx.name().?.text);
    const ftx = (try fx.typeText(testing.allocator)).?;
    defer testing.allocator.free(ftx);
    try testing.expectEqualStrings("i64", ftx);
    try testing.expect(fields.next() != null); // y
    try testing.expect(fields.next() == null);

    const e = (it.next() orelse return error.TestExpectedItem).enum_decl;
    try testing.expectEqualStrings("Dir", e.name().?.text);
    var variants = e.variants();
    try testing.expectEqualStrings("North", (variants.next() orelse return error.TestExpectedItem).name().?.text);
    try testing.expectEqualStrings("South", (variants.next() orelse return error.TestExpectedItem).name().?.text);
    try testing.expect(variants.next() == null);

    const t = (it.next() orelse return error.TestExpectedItem).type_decl;
    try testing.expectEqualStrings("Id", t.name().?.text);
    const at = (try t.aliasedText(testing.allocator)).?;
    defer testing.allocator.free(at);
    try testing.expectEqualStrings("i64", at);

    const cd = (it.next() orelse return error.TestExpectedItem).const_decl;
    try testing.expectEqualStrings("MAX", cd.name().?.text);
    try testing.expect(cd.value() != null);

    const fc = (it.next() orelse return error.TestExpectedItem).face_decl;
    try testing.expectEqualStrings("Greeter", fc.name().?.text);

    const ft = (it.next() orelse return error.TestExpectedItem).fit_decl;
    try testing.expectEqualStrings("Point", ft.name().?.text);

    const mn = (it.next() orelse return error.TestExpectedItem).fn_decl;
    try testing.expectEqualStrings("main", mn.name().?.text);
    try testing.expect(it.next() == null);
}

test "type views: path / generic / slice / array / tuple / optional / ref" {
    const src = "fn f(a: i64, b: Map<K, V>, c: [u8], d: [i32; 4], e: (A, B), g: T?, h: ref Foo) { 0 }\n";
    const r = try parse(testing.allocator, src, "types.q");
    defer r.deinit(testing.allocator);
    const sf = ast.SourceFile.cast(r.root).?;
    var items = sf.items();
    const fd = (items.next() orelse return error.TestExpectedItem).fn_decl;
    var ps = (fd.params() orelse return error.TestExpectedItem).iter();
    const tag = std.meta.activeTag;

    const a = ps.next() orelse return error.TestExpectedItem;
    const at = a.type_() orelse return error.TestExpectedNonNull;
    try testing.expectEqual(tag(at), .path);
    {
        const nm = try at.path.name(testing.allocator);
        defer testing.allocator.free(nm);
        try testing.expectEqualStrings("i64", nm);
    }

    const b = ps.next() orelse return error.TestExpectedItem;
    const bt = b.type_() orelse return error.TestExpectedNonNull;
    try testing.expectEqual(tag(bt), .path);
    try testing.expect(bt.path.hasGenericArgs());
    {
        const nm = try bt.path.name(testing.allocator);
        defer testing.allocator.free(nm);
        try testing.expectEqualStrings("Map", nm);
        const ga = (try bt.path.genericArgsText(testing.allocator)) orelse return error.TestExpectedNonNull;
        defer testing.allocator.free(ga);
        try testing.expectEqualStrings("<K, V>", ga);
    }

    const c = ps.next() orelse return error.TestExpectedItem;
    const ct = c.type_() orelse return error.TestExpectedNonNull;
    try testing.expectEqual(tag(ct), .slice);
    try testing.expectEqual(tag(ct.slice.element() orelse return error.TestExpectedNonNull), .path);

    try testing.expectEqual(tag((ps.next() orelse return error.TestExpectedItem).type_().?), .array);
    try testing.expectEqual(tag((ps.next() orelse return error.TestExpectedItem).type_().?), .tuple);
    try testing.expectEqual(tag((ps.next() orelse return error.TestExpectedItem).type_().?), .optional);
    try testing.expectEqual(tag((ps.next() orelse return error.TestExpectedItem).type_().?), .ref);
}

test "statement views: assign / if-else / while / for / loop / match / panic" {
    const src =
        \\fn m {
        \\    x = 1
        \\    if a {
        \\        y()
        \\    } else {
        \\        z()
        \\    }
        \\    while ok {
        \\        continue
        \\    }
        \\    for t in tools {
        \\        use(t)
        \\    }
        \\    loop {
        \\        break
        \\    }
        \\    match v {
        \\        A -> p(),
        \\    }
        \\    panic "boom"
        \\}
        \\
    ;
    const r = try parse(testing.allocator, src, "stmts.q");
    defer r.deinit(testing.allocator);
    const sf = ast.SourceFile.cast(r.root).?;
    const block = blockOf(sf) orelse return error.TestExpectedItem;
    var it = (ast.Block{ .cst = block }).statements();
    const tag = std.meta.activeTag;

    const asn = it.next() orelse return error.TestExpectedItem;
    try testing.expectEqual(tag(asn), .assign_stmt);
    try testing.expect(asn.assign_stmt.target() != null);
    try testing.expect(asn.assign_stmt.value() != null);
    try testing.expectEqual(cst.SyntaxKind.EQ, asn.assign_stmt.op().?.kind);

    const iff = it.next() orelse return error.TestExpectedItem;
    try testing.expectEqual(tag(iff), .if_stmt);
    try testing.expect(iff.if_stmt.condition() != null);
    try testing.expect(iff.if_stmt.thenBody() != null);
    try testing.expect(iff.if_stmt.elseBody() != null);

    const whl = it.next() orelse return error.TestExpectedItem;
    try testing.expectEqual(tag(whl), .while_stmt);
    try testing.expect(whl.while_stmt.condition() != null);
    try testing.expect(whl.while_stmt.body() != null);

    const forr = it.next() orelse return error.TestExpectedItem;
    try testing.expectEqual(tag(forr), .for_stmt);
    try testing.expectEqualStrings("t", forr.for_stmt.pattern().?.bindingName().?.text);
    try testing.expect(forr.for_stmt.iterable() != null);
    try testing.expect(forr.for_stmt.body() != null);

    const lp = it.next() orelse return error.TestExpectedItem;
    try testing.expectEqual(tag(lp), .loop_stmt);
    try testing.expect(lp.loop_stmt.body() != null);

    const mt = it.next() orelse return error.TestExpectedItem;
    try testing.expectEqual(tag(mt), .match_stmt);
    try testing.expect(mt.match_stmt.scrutinee() != null);
    var arms = mt.match_stmt.arms();
    const arm = arms.next() orelse return error.TestExpectedItem;
    try testing.expectEqualStrings("A", arm.pattern().?.bindingName().?.text);
    try testing.expect(arm.expression() != null);

    const pn = it.next() orelse return error.TestExpectedItem;
    try testing.expectEqual(tag(pn), .panic_stmt);
    try testing.expect(pn.panic_stmt.value() != null);
}

test "statement losslessness across forms" {
    const sources = [_][]const u8{
        "fn m {\n    let x = 1\n}\n",
        "fn m {\n    let x: i64 = 1 + 2\n}\n",
        "fn m {\n    var count = 0\n    count += 1\n}\n",
        "fn m {\n    let xs: [i64; 4] = [1, 2, 3, 4]\n}\n",
        "fn m {\n    return 42\n}\n",
        "fn m {\n    return\n}\n",
        "fn m {\n    if a < b {\n        env.out(\"lt\")\n    }\n}\n",
        "fn m {\n    if a {\n        x()\n    } else {\n        y()\n    }\n}\n",
        "fn m {\n    if a {\n        p()\n    } else if b {\n        q()\n    }\n}\n",
        "fn m {\n    while running {\n        tick()\n    }\n}\n",
        "fn m {\n    loop {\n        step()\n    }\n}\n",
        "fn m {\n    for tool in tools {\n        env.out(tool)\n    }\n}\n",
        "fn m {\n    match x {\n        Ok(v) -> use(v),\n        Err(e) -> panic e,\n    }\n}\n",
        "fn m {\n    obj.field = value\n    arr[0] = 1\n}\n",
        "fn m {\n    break\n    continue\n}\n",
        "fn m {\n    env.out(\"a\")\n    env.out(\"b\")\n}\n",
    };
    for (sources) |src| {
        const r = try parse(testing.allocator, src, "s.q");
        defer r.deinit(testing.allocator);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(testing.allocator);
        try cst.serialize(r.root, testing.allocator, &out);
        try testing.expectEqualStrings(src, out.items);
    }
}

test "statement structure: let + if/else inside a body" {
    const src = "fn m {\n    let x = compute()\n    if x {\n        a()\n    } else {\n        b()\n    }\n}\n";
    const r = try parse(testing.allocator, src, "s.q");
    defer r.deinit(testing.allocator);
    const sf = ast.SourceFile.cast(r.root).?;
    const block = blockOf(sf) orelse return error.TestExpectedBlock;
    try testing.expect(hasChildKind(block, .LET_STMT));
    try testing.expect(hasChildKind(block, .IF_STMT));
}

test "statement structure: match yields arms" {
    const src = "fn m {\n    match x {\n        A -> 1,\n        B -> 2,\n    }\n}\n";
    const r = try parse(testing.allocator, src, "s.q");
    defer r.deinit(testing.allocator);
    const sf = ast.SourceFile.cast(r.root).?;
    const block = blockOf(sf) orelse return error.TestExpectedBlock;
    try testing.expect(hasChildKind(block, .MATCH_STMT));
    // The match node carries MATCH_ARM children.
    var match_node: ?*const cst.Node = null;
    for (block.children) |c| switch (c) {
        .node => |n| if (n.kind == .MATCH_STMT) {
            match_node = n;
        },
        .token => {},
    };
    try testing.expect(hasChildKind(match_node.?, .MATCH_ARM));
}

test "codegen-facing shape unchanged: env.out body is one EXPR_STMT" {
    const src = "fn main {\n    env.out(\"hi\")\n}\n";
    const r = try parse(testing.allocator, src, "m.q");
    defer r.deinit(testing.allocator);
    const sf = ast.SourceFile.cast(r.root).?;
    var items = sf.items();
    const fd = (items.next() orelse return error.TestExpectedItem).fn_decl;
    var stmts = fd.body().?.statements();
    const stmt = stmts.next() orelse return error.TestExpectedStmt;
    const expr = stmt.expr_stmt.expression() orelse return error.TestExpectedExpr;
    try testing.expect(expr == .call);
    try testing.expect(stmts.next() == null);
}

test "generic-looking call in expression position is not flagged" {
    // `PCM<f32>(0.0)` is a generic constructor, not a comparison.
    // Distinguishing it from `a < b > c` needs name resolution, so the
    // parser stays quiet here (no PAR040) and parses losslessly. PAR040
    // is deferred to the name-resolution pass.
    const src = "fn m { PCM<f32>(0.0) }\n";
    const r = try parse(testing.allocator, src, "e.q");
    defer r.deinit(testing.allocator);
    try testing.expect(!hasDiag(r, "PAR040"));

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try cst.serialize(r.root, testing.allocator, &out);
    try testing.expectEqualStrings(src, out.items);
}

test "a well-formed import emits no diagnostics" {
    const r = try parse(testing.allocator, "import q64.math.{Vec3, dot}\n", "ok.q");
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), r.diagnostics.len);
}

test "mixed items round-trip losslessly and all surface" {
    const src = "struct Point { x: i32 }\nfn main { 0 }\n";
    const r = try parse(testing.allocator, src, "mixed.q");
    defer r.deinit(testing.allocator);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try cst.serialize(r.root, testing.allocator, &out);
    try testing.expectEqualStrings(src, out.items);

    const sf = ast.SourceFile.cast(r.root).?;
    var iter = sf.items();
    const s = iter.next() orelse return error.TestExpectedItem;
    try testing.expectEqualStrings("Point", s.struct_decl.name().?.text);
    const fd = (iter.next() orelse return error.TestExpectedItem).fn_decl;
    try testing.expectEqualStrings("main", fd.name().?.text);
}

test "record body: a keyword-shaped field name cannot hang the parser" {
    // `on` lexes as KW_ON, so parseField consumes nothing — the body loop
    // must still make progress (the field degrades, the parse terminates).
    const r = try parse(std.testing.allocator, "struct Flag { on: bool, n: i64 }\n", "<t>");
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(ast.SourceFile.cast(r.root) != null);
}

test "B3: face body method signatures parse structured (incl. self + bodyless)" {
    const src =
        \\pub face Display {
        \\    fn fmt(self) -> str @pure
        \\    fn describe(self, prefix: str) -> str { prefix }
        \\}
        \\
    ;
    const r = try parse(testing.allocator, src, "face.q");
    defer r.deinit(testing.allocator);
    const sf = ast.SourceFile.cast(r.root).?;
    var it = sf.items();
    const face = (it.next() orelse return error.TestExpectedItem).face_decl;
    try testing.expectEqualStrings("Display", face.name().?.text);

    var ms = face.methods();
    const fmt = ms.next() orelse return error.TestExpectedItem;
    try testing.expectEqualStrings("fmt", fmt.name().?.text);
    try testing.expect(!fmt.hasBody()); // signature only — `@pure` stays raw
    var fps = fmt.params().?.iter();
    const recv = fps.next() orelse return error.TestExpectedItem;
    try testing.expect(recv.isSelf());
    try testing.expect(fps.next() == null);
    const rt = try fmt.returnType().?.text(testing.allocator);
    defer testing.allocator.free(rt.?);
    try testing.expectEqualStrings("str", rt.?);

    const desc = ms.next() orelse return error.TestExpectedItem;
    try testing.expectEqualStrings("describe", desc.name().?.text);
    try testing.expect(desc.hasBody()); // a default impl
    var dps = desc.params().?.iter();
    try testing.expect((dps.next() orelse return error.TestExpectedItem).isSelf());
    const p2 = dps.next() orelse return error.TestExpectedItem;
    try testing.expectEqualStrings("prefix", p2.name().?.text);
    try testing.expect(ms.next() == null);
}

test "B3: fit spec — colon form names target and face" {
    const src =
        \\pub fit Color : Display {
        \\    fn fmt(self) -> str { "x" }
        \\}
        \\
    ;
    const r = try parse(testing.allocator, src, "fit.q");
    defer r.deinit(testing.allocator);
    const sf = ast.SourceFile.cast(r.root).?;
    var it = sf.items();
    const fit = (it.next() orelse return error.TestExpectedItem).fit_decl;
    try testing.expectEqualStrings("Color", fit.name().?.text);

    const spec = fit.spec().?;
    try testing.expect(spec.isColonForm());
    const tgt = try spec.target().?.text(testing.allocator);
    defer testing.allocator.free(tgt);
    try testing.expectEqualStrings("Color", tgt);
    const fc = try spec.face().?.text(testing.allocator);
    defer testing.allocator.free(fc);
    try testing.expectEqualStrings("Display", fc);

    var ms = fit.methods();
    const m = ms.next() orelse return error.TestExpectedItem;
    try testing.expectEqualStrings("fmt", m.name().?.text);
    try testing.expect(m.hasBody());
    try testing.expect(ms.next() == null);
}

test "B3: fit spec — bare multi-param form is one generic face path" {
    // The *wrong-fit-form* fixtures depend on this distinction: sema's
    // TYP201/TYP202 (B4) read which form was written and check it against
    // the face's arity. The grammar admits both.
    const src =
        \\pub fit Eq<Point> {
        \\    fn eq(self, other: Self) -> bool @pure { true }
        \\}
        \\
    ;
    const r = try parse(testing.allocator, src, "fit2.q");
    defer r.deinit(testing.allocator);
    const sf = ast.SourceFile.cast(r.root).?;
    var it = sf.items();
    const fit = (it.next() orelse return error.TestExpectedItem).fit_decl;
    try testing.expectEqualStrings("Eq", fit.name().?.text);

    const spec = fit.spec().?;
    try testing.expect(!spec.isColonForm());
    try testing.expect(spec.target() == null);
    const fc = spec.face().?;
    try testing.expect(fc == .path);
    try testing.expect(fc.path.hasGenericArgs());

    var ms = fit.methods();
    const m = ms.next() orelse return error.TestExpectedItem;
    var ps = m.params().?.iter();
    try testing.expect((ps.next() orelse return error.TestExpectedItem).isSelf());
    const other = ps.next() orelse return error.TestExpectedItem;
    try testing.expectEqualStrings("other", other.name().?.text);
}

test "B3: face super list parses as FACE_REF nodes; type/law stay raw runs" {
    const src =
        \\face Ord : Eq + Display {
        \\    type Key = i64
        \\    fn cmp(self, other: Self) -> i64
        \\    law reflexive: forall a => a.cmp(a) == 0
        \\}
        \\
    ;
    const r = try parse(testing.allocator, src, "super.q");
    defer r.deinit(testing.allocator);
    const sf = ast.SourceFile.cast(r.root).?;
    var it = sf.items();
    const face = (it.next() orelse return error.TestExpectedItem).face_decl;
    try testing.expectEqualStrings("Ord", face.name().?.text);
    // The `type`/`law` runs don't break method iteration: exactly one sig.
    var ms = face.methods();
    try testing.expectEqualStrings("cmp", (ms.next() orelse return error.TestExpectedItem).name().?.text);
    try testing.expect(ms.next() == null);
    try testing.expect(it.next() == null); // nothing leaked past the body
}
