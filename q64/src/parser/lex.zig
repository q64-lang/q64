//! Lexer — q64 source bytes to a stream of CST tokens.
//!
//! Trivia (whitespace, newlines, comments) is preserved as tokens, not
//! discarded — every byte of the source ends up in exactly one token's
//! `text` slice. The lossless invariant holds at this level:
//!
//!     concat(every token.text) == source
//!
//! Errors are reported via a side-channel `Diagnostic` list. The lexer
//! emits an `ERROR` token at the offending span so parser-level
//! recovery can keep going.
//!
//! See spec/grammar.md §"Lexical structure" for the rules each step
//! implements.

const std = @import("std");
const Allocator = std.mem.Allocator;
const cst = @import("cst.zig");

/// A lexer-level diagnostic. Code matches the `LEX*` band in
/// spec/diagnostics.md. The full envelope (severity, message,
/// labels, repair) is constructed later in diag.zig — at this
/// level we only need the code and the offset.
pub const Diagnostic = struct {
    code: []const u8,
    offset: u32,
};

/// The result of tokenizing a buffer. `tokens` always ends in an
/// `EOF` token whose text is empty and whose offset is the source
/// length. `diagnostics` is empty when the buffer is lexically
/// clean.
pub const Result = struct {
    tokens: []const cst.Token,
    diagnostics: []const Diagnostic,

    pub fn deinit(self: Result, allocator: Allocator) void {
        allocator.free(self.tokens);
        allocator.free(self.diagnostics);
    }
};

/// Tokenize `source` into the supplied allocator. The slices in
/// the returned `Result` are owned by the caller and must be freed
/// via `Result.deinit`.
pub fn tokenize(allocator: Allocator, source: []const u8) !Result {
    var tokens: std.ArrayList(cst.Token) = .empty;
    errdefer tokens.deinit(allocator);
    var diags: std.ArrayList(Diagnostic) = .empty;
    errdefer diags.deinit(allocator);

    var lex = Lexer{
        .source = source,
        .pos = 0,
        .allocator = allocator,
        .tokens = &tokens,
        .diags = &diags,
    };

    while (lex.pos < lex.source.len) try lex.nextToken();

    // Final EOF marker.
    try tokens.append(allocator, .{ .kind = .EOF, .text = "", .offset = lex.pos });

    return .{
        .tokens = try tokens.toOwnedSlice(allocator),
        .diagnostics = try diags.toOwnedSlice(allocator),
    };
}

const Lexer = struct {
    source: []const u8,
    pos: u32,
    allocator: Allocator,
    tokens: *std.ArrayList(cst.Token),
    diags: *std.ArrayList(Diagnostic),

    fn nextToken(self: *Lexer) !void {
        const start = self.pos;
        const c = self.source[self.pos];

        if (c == ' ' or c == '\t') return self.lexWhitespace(start);
        if (c == '\n') return self.lexLf(start);
        if (c == '\r') return self.lexCr(start);
        if (c == '/' and self.peek(1) == '/') return self.lexComment(start);
        if (isDigit(c)) return self.lexNumber(start);
        if (c == '"') return self.lexString(start, .plain, .none);
        if (c == '\'') return self.lexCharLitInvalid(start);
        if (isIdentStart(c)) return self.lexIdentOrTypedString(start);
        if (c == '@') return self.emit1(.AT);
        return self.lexPunct(start);
    }

    // -----------------------------------------------------------
    // Trivia
    // -----------------------------------------------------------

    fn lexWhitespace(self: *Lexer, start: u32) !void {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c != ' ' and c != '\t') break;
            self.pos += 1;
        }
        try self.push(.WHITESPACE, start);
    }

    fn lexLf(self: *Lexer, start: u32) !void {
        self.pos += 1;
        try self.push(.NEWLINE, start);
    }

    fn lexCr(self: *Lexer, start: u32) !void {
        if (self.peek(1) == '\n') {
            self.pos += 2;
            try self.push(.NEWLINE, start);
            return;
        }
        // Stray CR — LEX010.
        try self.diag("LEX010", start);
        self.pos += 1;
        try self.push(.ERROR, start);
    }

    fn lexComment(self: *Lexer, start: u32) !void {
        // We already saw `//`. Check for `//!` doc-comment.
        const is_doc = self.peek(2) == '!';
        self.pos += if (is_doc) 3 else 2;
        while (self.pos < self.source.len and self.source[self.pos] != '\n') {
            self.pos += 1;
        }
        try self.push(if (is_doc) .DOC_COMMENT else .LINE_COMMENT, start);
    }

    // -----------------------------------------------------------
    // Identifiers and keywords (and typed-prefix strings)
    // -----------------------------------------------------------

    fn lexIdentOrTypedString(self: *Lexer, start: u32) !void {
        while (self.pos < self.source.len and isIdentCont(self.source[self.pos])) {
            self.pos += 1;
        }
        const text = self.source[start..self.pos];

        // Raw string? A bare `r` immediately followed by `"` or `#` opens
        // a raw string `r"…"` / `r#"…"#` (spec/grammar.md §"String
        // literals"): no escapes, no interpolation.
        if (text.len == 1 and text[0] == 'r' and self.pos < self.source.len and
            (self.source[self.pos] == '"' or self.source[self.pos] == '#'))
        {
            return self.lexRawString(start);
        }

        // Typed-prefix string? IDENT directly followed by `"` is
        // STR_PREFIX, not an ordinary identifier. (Typed-raw forms
        // like `urlR"…"` are deferred.)
        if (self.pos < self.source.len and self.source[self.pos] == '"') {
            try self.pushAs(.STR_PREFIX, start, self.pos);
            return self.lexString(self.pos, .plain, .typed);
        }

        try self.pushAs(classifyIdent(text), start, self.pos);
    }

    /// Lex a raw string starting at `start` (the `r`). `self.pos` is just
    /// past the `r`, on the first `#` or `"`. The literal closes at a `"`
    /// followed by the same number of `#`s as opened it.
    fn lexRawString(self: *Lexer, start: u32) !void {
        var hashes: u32 = 0;
        while (self.pos < self.source.len and self.source[self.pos] == '#') {
            self.pos += 1;
            hashes += 1;
        }
        if (self.pos >= self.source.len or self.source[self.pos] != '"') {
            // `r#…` not opening a string after all; flag and recover.
            try self.diag("LEX040", start);
            try self.pushAs(.ERROR, start, self.pos);
            return;
        }
        self.pos += 1; // opening quote

        while (self.pos < self.source.len) {
            if (self.source[self.pos] == '"' and self.closesRawString(hashes)) {
                self.pos += 1 + hashes; // closing quote + matching hashes
                try self.pushAs(.STR_RAW, start, self.pos);
                return;
            }
            self.pos += 1;
        }
        // EOF before the close.
        try self.diag("LEX030", start);
        try self.pushAs(.STR_RAW, start, self.pos);
    }

    /// At a `"`, does it close a raw string opened with `hashes` `#`s
    /// (i.e. is it followed by exactly that many `#`)?
    fn closesRawString(self: *const Lexer, hashes: u32) bool {
        var j = self.pos + 1;
        var n: u32 = 0;
        while (n < hashes) : (n += 1) {
            if (j >= self.source.len or self.source[j] != '#') return false;
            j += 1;
        }
        return true;
    }

    // -----------------------------------------------------------
    // Numbers — INT_LIT, FLOAT_LIT, with optional NUM_SUFFIX tail
    // -----------------------------------------------------------

    fn lexNumber(self: *Lexer, start: u32) !void {
        // Detect 0x / 0o / 0b prefixes.
        if (self.source[self.pos] == '0' and self.pos + 1 < self.source.len) {
            const p1 = self.source[self.pos + 1];
            if (p1 == 'x' or p1 == 'X') return self.lexRadix(start, isHexDigit);
            if (p1 == 'o' or p1 == 'O') return self.lexRadix(start, isOctDigit);
            if (p1 == 'b' or p1 == 'B') return self.lexRadix(start, isBinDigit);
        }

        // Decimal integer / float.
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (isDigit(c) or c == '_') {
                self.pos += 1;
            } else break;
        }

        var is_float = false;
        // Distinguish `42.0` (float) from `42.kHz` (int + suffix) from `42.method()` (int + dot).
        if (self.peek(0) == '.' and isDigit(self.peek(1))) {
            is_float = true;
            self.pos += 1; // consume `.`
            while (self.pos < self.source.len) {
                const c = self.source[self.pos];
                if (isDigit(c) or c == '_') {
                    self.pos += 1;
                } else break;
            }
        }

        // Optional float exponent.
        if (self.peek(0) == 'e' or self.peek(0) == 'E') {
            is_float = true;
            self.pos += 1;
            if (self.peek(0) == '+' or self.peek(0) == '-') self.pos += 1;
            while (self.pos < self.source.len and isDigit(self.source[self.pos])) {
                self.pos += 1;
            }
        }

        try self.pushAs(if (is_float) .FLOAT_LIT else .INT_LIT, start, self.pos);

        // Optional numeric suffix: `.i32`, `.kHz`, `.MB`, … The dot
        // followed by an identifier is the suffix shape (per
        // types.md §"Numeric literals and suffixes"). It is **not**
        // emitted on a float literal whose dot was already consumed.
        if (!is_float and self.peek(0) == '.' and isIdentStart(self.peek(1))) {
            const suf_start = self.pos;
            self.pos += 1; // dot
            while (self.pos < self.source.len and isIdentCont(self.source[self.pos])) {
                self.pos += 1;
            }
            try self.pushAs(.NUM_SUFFIX, suf_start, self.pos);
        }
    }

    fn lexRadix(self: *Lexer, start: u32, comptime ok: fn (u8) bool) !void {
        self.pos += 2; // consume `0x` / `0o` / `0b`
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (ok(c) or c == '_') {
                self.pos += 1;
            } else break;
        }
        try self.pushAs(.INT_LIT, start, self.pos);

        // Suffix is permitted on radix literals too: `0xFF.u24`.
        if (self.peek(0) == '.' and isIdentStart(self.peek(1))) {
            const suf_start = self.pos;
            self.pos += 1;
            while (self.pos < self.source.len and isIdentCont(self.source[self.pos])) {
                self.pos += 1;
            }
            try self.pushAs(.NUM_SUFFIX, suf_start, self.pos);
        }
    }

    // -----------------------------------------------------------
    // Strings
    // -----------------------------------------------------------

    const StrKind = enum { plain, raw };
    const StrPrefix = enum { none, typed };

    fn lexString(self: *Lexer, start: u32, kind: StrKind, _: StrPrefix) !void {
        std.debug.assert(self.source[self.pos] == '"');
        self.pos += 1;
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == '\\' and kind == .plain) {
                // Skip escape: consume the backslash plus next byte.
                // (`\u{HHHH}` and `\xHH` are handled coarsely here; the
                //  parser does the semantic check.)
                self.pos += if (self.pos + 1 < self.source.len) 2 else 1;
                continue;
            }
            if (c == '"') {
                self.pos += 1;
                try self.pushAs(.STR_PLAIN, start, self.pos);
                return;
            }
            self.pos += 1;
        }
        // EOF inside string — emit as STR_PLAIN with the partial
        // body; the parser will pick up the diagnostic.
        try self.diag("LEX030", start);
        try self.pushAs(.STR_PLAIN, start, self.pos);
    }

    fn lexCharLitInvalid(self: *Lexer, start: u32) !void {
        // q64 has no char literals. Emit ERROR for the single quote.
        try self.diag("LEX031", start);
        self.pos += 1;
        try self.pushAs(.ERROR, start, self.pos);
    }

    // -----------------------------------------------------------
    // Punctuators and operators
    // -----------------------------------------------------------

    fn lexPunct(self: *Lexer, start: u32) !void {
        const c = self.source[self.pos];
        const p1 = self.peek(1);
        const p2 = self.peek(2);

        // 3-character punctuators.
        if (c == '.' and p1 == '.' and p2 == '=') return self.emitN(.DOT_DOT_EQ, 3);

        // 2-character punctuators.
        if (c == '-' and p1 == '>') return self.emitN(.ARROW, 2);
        if (c == '=' and p1 == '>') return self.emitN(.FAT_ARROW, 2);
        if (c == ':' and p1 == ':') return self.emitN(.COLON_COLON, 2);
        if (c == '.' and p1 == '.') return self.emitN(.DOT_DOT, 2);
        if (c == '=' and p1 == '=') return self.emitN(.EQ_EQ, 2);
        if (c == '!' and p1 == '=') return self.emitN(.BANG_EQ, 2);
        if (c == '<' and p1 == '=') return self.emitN(.LT_EQ, 2);
        if (c == '>' and p1 == '=') return self.emitN(.GT_EQ, 2);
        if (c == '<' and p1 == '<') return self.emitN(.SHL, 2);
        if (c == '>' and p1 == '>') return self.emitN(.SHR, 2);
        if (c == '&' and p1 == '&') return self.emitN(.AMP_AMP, 2);
        if (c == '|' and p1 == '|') return self.emitN(.PIPE_PIPE, 2);
        if (c == '+' and p1 == '=') return self.emitN(.PLUS_EQ, 2);
        if (c == '-' and p1 == '=') return self.emitN(.MINUS_EQ, 2);
        if (c == '*' and p1 == '=') return self.emitN(.STAR_EQ, 2);
        if (c == '/' and p1 == '=') return self.emitN(.SLASH_EQ, 2);
        if (c == '%' and p1 == '=') return self.emitN(.PERCENT_EQ, 2);
        if (c == '|' and p1 == '>') return self.emitN(.PIPE_GT, 2);
        if (c == '?' and p1 == '.') return self.emitN(.QUESTION_DOT, 2);

        // 1-character punctuators.
        switch (c) {
            '(' => return self.emit1(.L_PAREN),
            ')' => return self.emit1(.R_PAREN),
            '{' => return self.emit1(.L_BRACE),
            '}' => return self.emit1(.R_BRACE),
            '[' => return self.emit1(.L_BRACK),
            ']' => return self.emit1(.R_BRACK),
            '<' => return self.emit1(.L_ANGLE),
            '>' => return self.emit1(.R_ANGLE),
            ',' => return self.emit1(.COMMA),
            ';' => return self.emit1(.SEMICOLON),
            ':' => return self.emit1(.COLON),
            '.' => return self.emit1(.DOT),
            '=' => return self.emit1(.EQ),
            '|' => return self.emit1(.PIPE),
            '?' => return self.emit1(.QUESTION),
            '+' => return self.emit1(.PLUS),
            '-' => return self.emit1(.MINUS),
            '*' => return self.emit1(.STAR),
            '/' => return self.emit1(.SLASH),
            '%' => return self.emit1(.PERCENT),
            '!' => return self.emit1(.BANG),
            '^' => return self.emit1(.CARET),
            '~' => return self.emit1(.TILDE),
            '&' => return self.emit1(.AMP),
            else => {
                try self.diag("LEX040", start);
                self.pos += 1;
                try self.pushAs(.ERROR, start, self.pos);
            },
        }
    }

    // -----------------------------------------------------------
    // Low-level helpers
    // -----------------------------------------------------------

    fn peek(self: *const Lexer, n: u32) u8 {
        const i = self.pos + n;
        if (i >= self.source.len) return 0;
        return self.source[i];
    }

    fn emit1(self: *Lexer, kind: cst.SyntaxKind) !void {
        const start = self.pos;
        self.pos += 1;
        try self.pushAs(kind, start, self.pos);
    }

    fn emitN(self: *Lexer, kind: cst.SyntaxKind, n: u32) !void {
        const start = self.pos;
        self.pos += n;
        try self.pushAs(kind, start, self.pos);
    }

    fn push(self: *Lexer, kind: cst.SyntaxKind, start: u32) !void {
        try self.pushAs(kind, start, self.pos);
    }

    fn pushAs(self: *Lexer, kind: cst.SyntaxKind, start: u32, end: u32) !void {
        try self.tokens.append(self.allocator, .{
            .kind = kind,
            .text = self.source[start..end],
            .offset = start,
        });
    }

    fn diag(self: *Lexer, code: []const u8, at: u32) !void {
        try self.diags.append(self.allocator, .{ .code = code, .offset = at });
    }
};

// =====================================================================
// Character classes
// =====================================================================

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isHexDigit(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn isOctDigit(c: u8) bool {
    return c >= '0' and c <= '7';
}

fn isBinDigit(c: u8) bool {
    return c == '0' or c == '1';
}

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isIdentCont(c: u8) bool {
    return isIdentStart(c) or isDigit(c);
}

// =====================================================================
// Keyword table
// =====================================================================

pub const Keyword = struct { text: []const u8, kind: cst.SyntaxKind };

/// The complete keyword table, in source-spelling order. `pub` so the
/// documentation generator (`q64 doc --json`) can enumerate the language's
/// reserved words from the same array the lexer classifies against — one
/// source of truth, no drift between the lexer and the published reference.
pub const keywords = [_]Keyword{
    .{ .text = "actor", .kind = .KW_ACTOR },
    .{ .text = "as", .kind = .KW_AS },
    .{ .text = "break", .kind = .KW_BREAK },
    .{ .text = "catch", .kind = .KW_CATCH },
    .{ .text = "const", .kind = .KW_CONST },
    .{ .text = "continue", .kind = .KW_CONTINUE },
    .{ .text = "draw", .kind = .KW_DRAW },
    .{ .text = "dyn", .kind = .KW_DYN },
    .{ .text = "effect", .kind = .KW_EFFECT },
    .{ .text = "else", .kind = .KW_ELSE },
    .{ .text = "enum", .kind = .KW_ENUM },
    .{ .text = "face", .kind = .KW_FACE },
    .{ .text = "false", .kind = .KW_FALSE },
    .{ .text = "fit", .kind = .KW_FIT },
    .{ .text = "fn", .kind = .KW_FN },
    .{ .text = "for", .kind = .KW_FOR },
    .{ .text = "forall", .kind = .KW_FORALL },
    .{ .text = "from", .kind = .KW_FROM },
    .{ .text = "graph", .kind = .KW_GRAPH },
    .{ .text = "handle", .kind = .KW_HANDLE },
    .{ .text = "if", .kind = .KW_IF },
    .{ .text = "import", .kind = .KW_IMPORT },
    .{ .text = "in", .kind = .KW_IN },
    .{ .text = "law", .kind = .KW_LAW },
    .{ .text = "let", .kind = .KW_LET },
    .{ .text = "loop", .kind = .KW_LOOP },
    .{ .text = "match", .kind = .KW_MATCH },
    .{ .text = "move", .kind = .KW_MOVE },
    .{ .text = "on", .kind = .KW_ON },
    .{ .text = "out", .kind = .KW_OUT },
    .{ .text = "panic", .kind = .KW_PANIC },
    .{ .text = "pub", .kind = .KW_PUB },
    .{ .text = "ref", .kind = .KW_REF },
    .{ .text = "region", .kind = .KW_REGION },
    .{ .text = "return", .kind = .KW_RETURN },
    .{ .text = "scope", .kind = .KW_SCOPE },
    .{ .text = "screen", .kind = .KW_SCREEN },
    .{ .text = "select", .kind = .KW_SELECT },
    .{ .text = "self", .kind = .KW_SELF },
    .{ .text = "Self", .kind = .KW_SELF_TYPE },
    .{ .text = "spawn", .kind = .KW_SPAWN },
    .{ .text = "state", .kind = .KW_STATE },
    .{ .text = "struct", .kind = .KW_STRUCT },
    .{ .text = "tell", .kind = .KW_TELL },
    .{ .text = "trap", .kind = .KW_TRAP },
    .{ .text = "true", .kind = .KW_TRUE },
    .{ .text = "try", .kind = .KW_TRY },
    .{ .text = "type", .kind = .KW_TYPE },
    .{ .text = "use", .kind = .KW_USE },
    .{ .text = "var", .kind = .KW_VAR },
    .{ .text = "where", .kind = .KW_WHERE },
    .{ .text = "while", .kind = .KW_WHILE },
    .{ .text = "with_capabilities", .kind = .KW_WITH_CAPABILITIES },
    .{ .text = "None", .kind = .KW_NONE },
};

fn classifyIdent(text: []const u8) cst.SyntaxKind {
    for (keywords) |kw| {
        if (std.mem.eql(u8, text, kw.text)) return kw.kind;
    }
    return .IDENT;
}

// =====================================================================
// Tests
// =====================================================================

const testing = std.testing;

fn expectKinds(source: []const u8, expected: []const cst.SyntaxKind) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try tokenize(arena.allocator(), source);

    // Build a non-trivia view to compare against `expected`. Trivia
    // is verified separately by the lossless test.
    var got: std.ArrayList(cst.SyntaxKind) = .empty;
    defer got.deinit(testing.allocator);
    for (r.tokens) |t| {
        if (t.kind == .EOF) continue;
        if (t.kind.isTrivia()) continue;
        try got.append(testing.allocator, t.kind);
    }
    try testing.expectEqualSlices(cst.SyntaxKind, expected, got.items);
}

fn expectLossless(source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try tokenize(arena.allocator(), source);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    for (r.tokens) |t| try out.appendSlice(testing.allocator, t.text);

    try testing.expectEqualStrings(source, out.items);
}

test "keywords vs identifiers" {
    try expectKinds("fn main", &[_]cst.SyntaxKind{ .KW_FN, .IDENT });
    try expectKinds("let x = 1", &[_]cst.SyntaxKind{ .KW_LET, .IDENT, .EQ, .INT_LIT });
    try expectKinds("pub fn helper", &[_]cst.SyntaxKind{ .KW_PUB, .KW_FN, .IDENT });
    try expectKinds("Self self struct", &[_]cst.SyntaxKind{ .KW_SELF_TYPE, .KW_SELF, .KW_STRUCT });
}

test "numeric literals with suffixes" {
    try expectKinds("42", &[_]cst.SyntaxKind{.INT_LIT});
    try expectKinds("3.14", &[_]cst.SyntaxKind{.FLOAT_LIT});
    try expectKinds("42.i32", &[_]cst.SyntaxKind{ .INT_LIT, .NUM_SUFFIX });
    try expectKinds("48.kHz", &[_]cst.SyntaxKind{ .INT_LIT, .NUM_SUFFIX });
    try expectKinds("0xFF.u24", &[_]cst.SyntaxKind{ .INT_LIT, .NUM_SUFFIX });
    try expectKinds("1_000_000", &[_]cst.SyntaxKind{.INT_LIT});
    try expectKinds("1.5e-3", &[_]cst.SyntaxKind{.FLOAT_LIT});
    try expectKinds("0b1010", &[_]cst.SyntaxKind{.INT_LIT});
    try expectKinds("0o777", &[_]cst.SyntaxKind{.INT_LIT});
}

test "punctuators — single and compound" {
    try expectKinds(
        "() {} [] , ; : :: . .. ..= -> => = |",
        &[_]cst.SyntaxKind{
            .L_PAREN, .R_PAREN, .L_BRACE, .R_BRACE, .L_BRACK, .R_BRACK,
            .COMMA, .SEMICOLON, .COLON, .COLON_COLON, .DOT, .DOT_DOT, .DOT_DOT_EQ,
            .ARROW, .FAT_ARROW, .EQ, .PIPE,
        },
    );
    try expectKinds(
        "+ - * / % == != <= >= && || |> ?.",
        &[_]cst.SyntaxKind{
            .PLUS, .MINUS, .STAR, .SLASH, .PERCENT,
            .EQ_EQ, .BANG_EQ, .LT_EQ, .GT_EQ, .AMP_AMP, .PIPE_PIPE, .PIPE_GT, .QUESTION_DOT,
        },
    );
}

test "string literals — plain and typed prefix" {
    try expectKinds("\"hello\"", &[_]cst.SyntaxKind{.STR_PLAIN});
    try expectKinds(
        "url\"https://example.com\"",
        &[_]cst.SyntaxKind{ .STR_PREFIX, .STR_PLAIN },
    );
    try expectKinds(
        "\"line one\\nline two\"",
        &[_]cst.SyntaxKind{.STR_PLAIN},
    );
}

test "raw string literals" {
    try expectKinds("r\"no escapes \\n here\"", &[_]cst.SyntaxKind{.STR_RAW});
    try expectKinds("r#\"has \"quotes\" inside\"#", &[_]cst.SyntaxKind{.STR_RAW});
    try expectKinds("r##\"with #\"# inside\"##", &[_]cst.SyntaxKind{.STR_RAW});
    // A bare `r` not opening a string stays an identifier.
    try expectKinds("let r = 5", &[_]cst.SyntaxKind{ .KW_LET, .IDENT, .EQ, .INT_LIT });
    try expectLossless("r#\"{\"k\":1}\"#");
    try expectLossless("let r = r\"raw\"\n");
}

test "comments — line and doc" {
    try expectKinds(
        "// regular\n//! doc\nfn",
        &[_]cst.SyntaxKind{.KW_FN},
    );
    // Now check the trivia stream explicitly.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try tokenize(arena.allocator(), "// regular\n//! doc\nfn");
    var saw_line = false;
    var saw_doc = false;
    for (r.tokens) |t| {
        if (t.kind == .LINE_COMMENT) saw_line = true;
        if (t.kind == .DOC_COMMENT) saw_doc = true;
    }
    try testing.expect(saw_line);
    try testing.expect(saw_doc);
}

test "lossless: scattered source reassembles" {
    try expectLossless("fn main { env.out(\"hi\") }");
    try expectLossless("//! header\n\npub fn helper -> i64 { 42 }\n");
    try expectLossless("let xs: [i64; 4] = [1, 2, 3, 4]\n");
    try expectLossless("a |> b |> c\n");
    try expectLossless("@stage @fuse\nfn f -> Signal<f32, 48.kHz> { … }\n");
}

test "LEX010 — stray carriage return" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try tokenize(arena.allocator(), "fn main\r{}\n");
    var found = false;
    for (r.diagnostics) |d| {
        if (std.mem.eql(u8, d.code, "LEX010")) found = true;
    }
    try testing.expect(found);
}

test "tokenize a small golden program losslessly and without ERROR" {
    const source =
        \\//! hello — entry point.
        \\
        \\fn main {
        \\    env.out("Hello, q64.")
        \\}
        \\
    ;
    try expectLossless(source);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try tokenize(arena.allocator(), source);
    for (r.tokens) |t| {
        try testing.expect(t.kind != .ERROR);
    }
    try testing.expectEqual(@as(usize, 0), r.diagnostics.len);
}

test "tokenize a graph + stages program losslessly" {
    const source =
        \\@stage
        \\fn mic_input -> Signal<PCM<f32>, 48.kHz> {
        \\    env.audio.input()
        \\}
        \\
        \\graph audio_path {
        \\    let pcm   = mic_input()
        \\    let clean = pcm |> denoise(threshold: 0.05)
        \\    let _     = clean |> play
        \\}
        \\
    ;
    try expectLossless(source);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try tokenize(arena.allocator(), source);
    for (r.tokens) |t| {
        try testing.expect(t.kind != .ERROR);
    }
    try testing.expectEqual(@as(usize, 0), r.diagnostics.len);
}
