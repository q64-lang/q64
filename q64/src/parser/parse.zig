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

    /// Lookahead: is the next non-trivia run an `fn` item, possibly
    /// preceded by `pub`?
    fn atFnItem(self: *const Parser) bool {
        var i = self.pos;
        if (i < self.tokens.len and self.tokens[i].kind == .KW_PUB) {
            i += 1;
            while (i < self.tokens.len and self.tokens[i].kind.isTrivia()) : (i += 1) {}
        }
        if (i >= self.tokens.len) return false;
        return self.tokens[i].kind == .KW_FN;
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
            if (self.atFnItem()) {
                const fn_node = try self.parseFnDecl();
                try children.append(self.arena, .{ .node = fn_node });
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

    fn parseFnDecl(self: *Parser) !*const cst.Node {
        var children: std.ArrayList(cst.Element) = .empty;

        if (self.peek() == .KW_PUB) {
            const vis_node = try self.parseVisibility();
            try children.append(self.arena, .{ .node = vis_node });
            try self.eatTrivia(&children);
        }

        std.debug.assert(self.peek() == .KW_FN);
        try children.append(self.arena, .{ .token = self.advance() }); // KW_FN
        try self.eatTrivia(&children);

        if (self.peek() == .IDENT) {
            try children.append(self.arena, .{ .token = self.advance() });
        }
        try self.eatTrivia(&children);

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
    fn parseParams(self: *Parser) !*const cst.Node {
        var children: std.ArrayList(cst.Element) = .empty;
        var depth: i32 = 0;
        while (!self.isEof()) {
            const t = self.advance();
            try children.append(self.arena, .{ .token = t });
            switch (t.kind) {
                .L_PAREN => depth += 1,
                .R_PAREN => {
                    depth -= 1;
                    if (depth == 0) break;
                },
                else => {},
            }
        }
        return try cst.makeNode(self.arena, .PARAMS, children.items);
    }

    /// Consume `->` followed by the type expression. The expression
    /// ends at the body's opening `{`; trailing trivia is shaved
    /// back into the parent so the return-type span stops at the
    /// last meaningful token. Bracket depth is tracked so that
    /// `Signal<PCM<f32>, 48.kHz>` parses as a single type.
    fn parseReturnType(self: *Parser) !*const cst.Node {
        std.debug.assert(self.peek() == .ARROW);
        var children: std.ArrayList(cst.Element) = .empty;
        try children.append(self.arena, .{ .token = self.advance() }); // ARROW

        var depth: i32 = 0;
        while (!self.isEof()) {
            const k = self.peek();
            if (depth == 0 and k == .L_BRACE) break;
            switch (k) {
                .L_PAREN, .L_BRACK, .L_ANGLE => depth += 1,
                .R_PAREN, .R_BRACK, .R_ANGLE => depth -= 1,
                else => {},
            }
            try children.append(self.arena, .{ .token = self.advance() });
        }

        // Shave trailing trivia back into the parser stream so the
        // return-type ends at its last semantic token. The depth
        // bookkeeping doesn't need adjustment — trivia carries no
        // bracket weight.
        var i: usize = children.items.len;
        while (i > 0) : (i -= 1) {
            if (!children.items[i - 1].kind().isTrivia()) break;
        }
        const shave = children.items.len - i;
        self.pos -= shave;
        children.shrinkRetainingCapacity(i);

        return try cst.makeNode(self.arena, .RETURN_TYPE, children.items);
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

    /// Parse a single statement. v0 only structures `ExprStmt`; any
    /// trailing tokens up to the next newline / semicolon / `}` get
    /// swept into the EXPR_STMT node so block-level iteration sees
    /// a clean boundary.
    fn parseStmt(self: *Parser) !*const cst.Node {
        var children: std.ArrayList(cst.Element) = .empty;
        const expr = try self.parseExpr();
        try children.append(self.arena, .{ .node = expr });

        // Sweep the rest of the statement. NEWLINE / SEMICOLON / `}`
        // end the statement; trivia and any unparsed tokens get
        // absorbed so the next stmt starts cleanly.
        while (!self.isEof()) {
            const k = self.peek();
            if (k == .NEWLINE or k == .SEMICOLON or k == .R_BRACE) break;
            try children.append(self.arena, .{ .token = self.advance() });
        }
        return try cst.makeNode(self.arena, .EXPR_STMT, children.items);
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
                    const idx = try self.parseExpr();
                    try children.append(self.arena, .{ .node = idx });
                    try self.eatTrivia(&children);
                    if (self.peek() == .R_BRACK) {
                        try children.append(self.arena, .{ .token = self.advance() });
                    }
                    base = try cst.makeNode(self.arena, .INDEX_EXPR, children.items);
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
        try children.append(self.arena, .{ .node = try self.parseExpr() });
        try self.eatTrivia(&children);
        var is_tuple = false;
        while (self.peek() == .COMMA) {
            is_tuple = true;
            try children.append(self.arena, .{ .token = self.advance() });
            try self.eatTrivia(&children);
            if (self.peek() == .R_PAREN) break; // trailing comma
            try children.append(self.arena, .{ .node = try self.parseExpr() });
            try self.eatTrivia(&children);
        }
        if (self.peek() == .R_PAREN) {
            try children.append(self.arena, .{ .token = self.advance() });
        }
        return try cst.makeNode(self.arena, if (is_tuple) .TUPLE_EXPR else .PAREN_EXPR, children.items);
    }

    /// `[` Expr (`,` Expr)* `]` (list) or `[` Expr `;` Expr `]` (repeat).
    fn parseArrayExpr(self: *Parser) std.mem.Allocator.Error!*const cst.Node {
        var children: std.ArrayList(cst.Element) = .empty;
        try children.append(self.arena, .{ .token = self.advance() }); // [
        try self.eatTrivia(&children);
        if (self.peek() == .R_BRACK) {
            try children.append(self.arena, .{ .token = self.advance() });
            return try cst.makeNode(self.arena, .ARRAY_EXPR, children.items);
        }
        try children.append(self.arena, .{ .node = try self.parseExpr() });
        try self.eatTrivia(&children);
        if (self.peek() == .SEMICOLON) {
            try children.append(self.arena, .{ .token = self.advance() });
            try self.eatTrivia(&children);
            try children.append(self.arena, .{ .node = try self.parseExpr() });
            try self.eatTrivia(&children);
        } else {
            while (self.peek() == .COMMA) {
                try children.append(self.arena, .{ .token = self.advance() });
                try self.eatTrivia(&children);
                if (self.peek() == .R_BRACK) break;
                try children.append(self.arena, .{ .node = try self.parseExpr() });
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
            .IDENT, .KW_IN, .KW_OUT, .KW_REF, .KW_MOVE => true,
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
        const expr = try self.parseExpr();
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

test "unimplemented items don't break losslessness or item iteration" {
    // `struct` isn't an item production yet; its tokens pass through
    // SOURCE_FILE directly. The single `fn` item should still be
    // surfaced by SourceFile.items().
    const src = "struct Point { x: i32 }\nfn main { 0 }\n";
    const r = try parse(testing.allocator, src, "mixed.q");
    defer r.deinit(testing.allocator);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try cst.serialize(r.root, testing.allocator, &out);
    try testing.expectEqualStrings(src, out.items);

    const sf = ast.SourceFile.cast(r.root).?;
    var iter = sf.items();
    const fd = (iter.next() orelse return error.TestExpectedItem).fn_decl;
    try testing.expectEqualStrings("main", fd.name().?.text);
}
