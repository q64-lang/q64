//! The `q64 fmt` formatter engine (v0).
//!
//! The formatter reprints the lossless token stream the parser emits:
//! it recomputes leading indentation from bracket nesting, applies a
//! canonical single-space style *between* tokens (spaces around binary
//! operators, after `,`/`:`, tight `foo(x)`/`a.b`/`Vec<T>`), normalizes
//! vertical whitespace (blank lines, trailing newline), and strips
//! trailing whitespace — while preserving every significant token and
//! every comment.
//!
//! Spacing decisions come from token kinds plus three CST-resolved
//! `Role`s that disambiguate the tokens context alone can't: `< >`
//! (generic delimiter vs comparison), a leading sigil in a `UNARY_EXPR`
//! (`-x` vs `a - b`), and `|` (lambda-param delimiter vs bit-or).
//!
//! Safety. Formatting only ever rewrites the trivia between tokens, so
//! the significant-token sequence is identical in and out and `format`
//! is idempotent. This is enforced at runtime by a fail-safe: the output
//! is re-lexed and, if its token sequence differs from the input's (a
//! dropped space that merged two tokens), the original source is
//! returned untouched — the formatter can never corrupt code.
//!
//! What it deliberately does NOT do yet: reflow/wrap long lines,
//! normalize trailing commas, or reproduce hand-aligned columns (there
//! is no tabwriter — aligned runs collapse to single spaces). Those are
//! later slices (see `README.md` §Deferred).
//!
//! Safety invariant: `stripInsignificant(format(src)) ==
//! stripInsignificant(src)` for any parseable `src`, and `format` is
//! idempotent (`format(format(src)) == format(src)`). Both are checked
//! in the tests at the bottom of this file.
//!
//! Indentation model — each open bracket records the indent of the
//! *line it was opened on*. A line's indent is one level deeper than
//! the innermost still-open bracket's opener line; a line that begins
//! by closing a bracket aligns with that bracket's opener line. Because
//! every bracket opened on one line shares that line's indent,
//! stacking them (`print_all([`) indents children by exactly one level,
//! not one-per-bracket — the hug — while matching stays exact
//! (every opener pushes, every closer pops). `< >` are never
//! indentation brackets — generics stay inline.

const std = @import("std");
const parser = @import("parser");
const cst = parser.cst;
const parse = parser.parse;

/// Spaces per indentation level. q64's canonical style is 4 (matches
/// every golden example under spec/tests/).
pub const indent_width: usize = 4;

/// The result of a format request.
pub const Outcome = union(enum) {
    /// The formatted source, owned by the allocator passed to `format`.
    formatted: []u8,
    /// The source had lexical/parse errors, so it could not be safely
    /// formatted. The CLI reports this as `FMT001` and leaves the file
    /// untouched. `count` is the number of error-severity diagnostics.
    unparseable: struct { count: usize },

    pub fn deinit(self: Outcome, gpa: std.mem.Allocator) void {
        switch (self) {
            .formatted => |t| gpa.free(t),
            .unparseable => {},
        }
    }
};

/// Format `source`. Parses first: a file with syntax errors is not
/// reformatted (`.unparseable`) — formatting an unparseable buffer
/// would risk mangling it, and there's a real diagnostic to show
/// instead. A clean parse is reindented and returned as a fresh,
/// caller-owned buffer.
pub fn format(gpa: std.mem.Allocator, source: []const u8) !Outcome {
    const result = try parse.parse(gpa, source, "<fmt>");
    defer result.deinit(gpa);

    var errors: usize = 0;
    for (result.diagnostics) |d| {
        if (d.severity == .err) errors += 1;
    }
    if (errors > 0) return .{ .unparseable = .{ .count = errors } };

    // Flatten the (lossless) CST back into its leaf token stream. This
    // is exactly the source's tokens in order — reformatting operates
    // on trivia between them and never touches the tokens themselves.
    var toks: std.ArrayList(cst.Token) = .empty;
    defer toks.deinit(gpa);
    try collectTokens(gpa, result.root, &toks);

    // Resolve the context-dependent token roles once, up front.
    var roles: RoleMap = .empty;
    defer roles.deinit(gpa);
    try buildRoles(gpa, result.root, false, &roles);

    var f: Formatter = .{ .toks = toks.items, .gpa = gpa, .roles = &roles };
    defer f.deinit();
    try f.run();
    const out = try f.out.toOwnedSlice(gpa);

    // Fail-safe: re-lex the output and require its significant-token
    // sequence to be byte-identical to the input's. Formatting only ever
    // rewrites trivia, so this must hold — but a spacing bug that dropped
    // a needed space (`let x` → `letx`) would merge two tokens and be
    // caught here. If it ever fires, return the source untouched rather
    // than emit corrupted code; the exact-output unit tests catch the bug
    // instead.
    if (!try tokensPreserved(gpa, source, out)) {
        gpa.free(out);
        return .{ .formatted = try gpa.dupe(u8, source) };
    }
    return .{ .formatted = out };
}

/// True iff `a` and `b` lex to the same sequence of significant (non-trivia)
/// token texts. The formatter's core safety invariant.
fn tokensPreserved(gpa: std.mem.Allocator, a: []const u8, b: []const u8) !bool {
    const lex = parser.lex;
    const ra = try lex.tokenize(gpa, a);
    defer ra.deinit(gpa);
    const rb = try lex.tokenize(gpa, b);
    defer rb.deinit(gpa);

    var ia: usize = 0;
    var ib: usize = 0;
    while (true) {
        while (ia < ra.tokens.len and (ra.tokens[ia].kind.isTrivia() or ra.tokens[ia].kind == .EOF)) ia += 1;
        while (ib < rb.tokens.len and (rb.tokens[ib].kind.isTrivia() or rb.tokens[ib].kind == .EOF)) ib += 1;
        const a_done = ia >= ra.tokens.len;
        const b_done = ib >= rb.tokens.len;
        if (a_done or b_done) return a_done and b_done;
        if (ra.tokens[ia].kind != rb.tokens[ib].kind) return false;
        if (!std.mem.eql(u8, ra.tokens[ia].text, rb.tokens[ib].text)) return false;
        ia += 1;
        ib += 1;
    }
}

/// True iff formatting `source` would leave it unchanged. Used by
/// `--check` (exit 64 when false) and `--lint`. `.unparseable` counts
/// as "already formatted" (no rewrite happens either way).
pub fn isFormatted(gpa: std.mem.Allocator, source: []const u8) !bool {
    const outcome = try format(gpa, source);
    defer outcome.deinit(gpa);
    return switch (outcome) {
        .formatted => |t| std.mem.eql(u8, t, source),
        .unparseable => true,
    };
}

fn collectTokens(gpa: std.mem.Allocator, node: *const cst.Node, out: *std.ArrayList(cst.Token)) !void {
    for (node.children) |child| switch (child) {
        .token => |t| {
            // The synthetic EOF marker has empty text; drop it so it
            // doesn't confuse line handling.
            if (t.kind == .EOF) continue;
            try out.append(gpa, t);
        },
        .node => |n| try collectTokens(gpa, n, out),
    };
}

/// The context-dependent role of a token, resolved from the CST so the
/// spacing pass doesn't have to guess at the three genuinely ambiguous
/// tokens: `< >` (generic delimiter vs comparison), a leading sigil in a
/// `UNARY_EXPR` (prefix `-x` vs binary `a - b`), and `|` (lambda-param
/// delimiter vs bit-or). Keyed by a token's byte offset (unique per token).
const Role = enum { none, generic, unary, lambda_open, lambda_close, postfix };

const RoleMap = std.AutoHashMapUnmanaged(u32, Role);

/// Walk the CST and record the role of every token that needs one. Any
/// token not in the map is `.none` and uses the default kind-based rules.
fn buildRoles(gpa: std.mem.Allocator, node: *const cst.Node, in_generic: bool, map: *RoleMap) !void {
    const gen = in_generic or switch (node.kind) {
        .GENERIC_ARGS, .GENERIC_PARAMS, .FN_TYPE_PARAMS => true,
        else => false,
    };

    switch (node.kind) {
        // The leading operator of a unary expression is its first
        // non-trivia child token.
        .UNARY_EXPR => for (node.children) |c| switch (c) {
            .token => |t| {
                if (t.kind.isTrivia()) continue;
                try map.put(gpa, t.offset, .unary);
                break;
            },
            .node => break,
        },
        // The two `|` delimiters are direct token children of the lambda:
        // first is the opener, the next is the closer. (`||` is one token.)
        .LAMBDA_EXPR => {
            var seen_open = false;
            for (node.children) |c| switch (c) {
                .token => |t| {
                    if (t.kind != .PIPE) continue;
                    if (!seen_open) {
                        try map.put(gpa, t.offset, .lambda_open);
                        seen_open = true;
                    } else {
                        try map.put(gpa, t.offset, .lambda_close);
                        break;
                    }
                },
                .node => {},
            };
        },
        // The opening `(` of a call's argument list and the `[` of an
        // index expression are *postfix* — they hug the callee/receiver
        // (`foo(x)`, `a[0]`), unlike a grouping paren or an array literal.
        // Marking them here handles keyword-named receivers (`env.out(…)`,
        // where `out` is `KW_OUT`) that a token heuristic would miss.
        .CALL_ARGS, .PARAMS => for (node.children) |c| switch (c) {
            .token => |t| if (t.kind == .L_PAREN) {
                try map.put(gpa, t.offset, .postfix);
                break;
            },
            .node => {},
        },
        .INDEX_EXPR => for (node.children) |c| switch (c) {
            .token => |t| if (t.kind == .L_BRACK) {
                try map.put(gpa, t.offset, .postfix);
                break;
            },
            .node => {},
        },
        // A keyword-named function (`fn from(…)` — `from` is `KW_FROM`)
        // isn't structured into a PARAMS node by the parser; its params
        // `(` lands as a direct token child of the declaration. Mark the
        // first one so the name still hugs its parameter list.
        .FN_DECL, .METHOD_SIG => for (node.children) |c| switch (c) {
            .token => |t| if (t.kind == .L_PAREN) {
                try map.put(gpa, t.offset, .postfix);
                break;
            },
            .node => {},
        },
        else => {},
    }

    for (node.children) |c| switch (c) {
        .token => |t| {
            if (gen and (t.kind == .L_ANGLE or t.kind == .R_ANGLE or t.kind == .SHR)) {
                try map.put(gpa, t.offset, .generic);
            }
        },
        .node => |n| try buildRoles(gpa, n, gen, map),
    };
}

/// A row's alignment tab-stops in ascending order (`eq` before `cmt`),
/// written into `buf` and returned as a slice.
fn rowStops(r: Row, buf: *[2]usize) []usize {
    var n: usize = 0;
    if (r.eq) |e| {
        buf[n] = e;
        n += 1;
    }
    if (r.cmt) |c| {
        buf[n] = c;
        n += 1;
    }
    return buf[0..n];
}

fn isOpener(k: cst.SyntaxKind) bool {
    return switch (k) {
        .L_PAREN, .L_BRACE, .L_BRACK => true,
        else => false,
    };
}

fn isCloser(k: cst.SyntaxKind) bool {
    return switch (k) {
        .R_PAREN, .R_BRACE, .R_BRACK => true,
        else => false,
    };
}

/// One formatted line, held until the alignment pass can look across a
/// block of them. `text` is the canonically-spaced content (no leading
/// indent, no trailing newline). `eq`/`cmt` are byte offsets of the
/// alignment tab-stops within `text`: a depth-0 assignment `=` and the
/// start of a trailing line comment. A `blank` row separates blocks.
const Row = struct {
    blank: bool = false,
    indent: usize = 0,
    text: []u8 = &.{},
    eq: ?usize = null,
    cmt: ?usize = null,
};

const Formatter = struct {
    toks: []const cst.Token,
    gpa: std.mem.Allocator,
    roles: *const RoleMap,
    i: usize = 0,
    out: std.ArrayList(u8) = .empty,
    rows: std.ArrayList(Row) = .empty,
    /// One entry per currently-open bracket: the indent level of the
    /// line that opened it. The innermost entry (top) drives the indent
    /// of the lines inside it.
    stack: std.ArrayList(usize) = .empty,
    /// Blank lines seen since the last content line (for collapsing).
    pending_blanks: usize = 0,
    /// Whether any content line has been emitted (suppresses leading
    /// blank lines at the top of the file).
    wrote_content: bool = false,

    fn deinit(self: *Formatter) void {
        self.out.deinit(self.gpa);
        for (self.rows.items) |r| self.gpa.free(r.text);
        self.rows.deinit(self.gpa);
        self.stack.deinit(self.gpa);
    }

    fn run(self: *Formatter) !void {
        while (self.i < self.toks.len) try self.formatLine();
        try self.alignRows();
        try self.serialize();
    }

    /// Tabwriter pass. Aligns the tab-stops (`=`, trailing comments) of
    /// each maximal run of consecutive content rows that share the same
    /// indent *and* the same shape (same set of tab-stops). Rows with no
    /// tab-stop, blank rows, and indent changes all break a run, so an
    /// assignment column never spills across an unrelated line.
    fn alignRows(self: *Formatter) !void {
        var i: usize = 0;
        while (i < self.rows.items.len) {
            const r = self.rows.items[i];
            if (r.blank or (r.eq == null and r.cmt == null)) {
                i += 1;
                continue;
            }
            var j = i + 1;
            while (j < self.rows.items.len) : (j += 1) {
                const s = self.rows.items[j];
                if (s.blank or s.indent != r.indent) break;
                if ((s.eq != null) != (r.eq != null)) break;
                if ((s.cmt != null) != (r.cmt != null)) break;
            }
            if (j - i > 1) try self.alignBlock(self.rows.items[i..j]);
            i = j;
        }
    }

    /// Align one block of same-shape rows. For each tab-stop column, the
    /// cell before it is padded to the widest such cell in the block, plus
    /// the single canonical space. The final cell (after the last stop) is
    /// free. A one-row block is a no-op (width == its own cell), so the gap
    /// is exactly the canonical single space.
    fn alignBlock(self: *Formatter, block: []Row) !void {
        var stops: [2]usize = undefined;

        // Column widths = max trimmed-prefix width across the block.
        var widths = [2]usize{ 0, 0 };
        for (block) |r| {
            const s = rowStops(r, &stops);
            var start: usize = 0;
            for (s, 0..) |off, k| {
                const w = std.mem.trimEnd(u8, r.text[start..off], " ").len;
                if (w > widths[k]) widths[k] = w;
                start = off;
            }
        }

        // Rebuild each row's text with padded columns.
        for (block) |*r| {
            const s = rowStops(r.*, &stops);
            var rebuilt: std.ArrayList(u8) = .empty;
            errdefer rebuilt.deinit(self.gpa);
            var start: usize = 0;
            for (s, 0..) |off, k| {
                const cell = std.mem.trimEnd(u8, r.text[start..off], " ");
                try rebuilt.appendSlice(self.gpa, cell);
                try rebuilt.appendNTimes(self.gpa, ' ', widths[k] - cell.len + 1);
                start = off;
            }
            try rebuilt.appendSlice(self.gpa, r.text[start..]); // free final cell
            const owned = try rebuilt.toOwnedSlice(self.gpa);
            self.gpa.free(r.text);
            r.text = owned;
        }
    }

    /// Consume one logical line (tokens up to and including the next
    /// NEWLINE, or to end-of-input) and emit its formatted form.
    fn formatLine(self: *Formatter) !void {
        const line_start = self.i;
        var end = self.i;
        var terminated = false;
        while (end < self.toks.len) : (end += 1) {
            if (self.toks[end].kind == .NEWLINE) {
                terminated = true;
                break;
            }
        }
        // Advance past the line (and its terminating NEWLINE, if any).
        // A line with no NEWLINE is the last line in the buffer.
        self.i = if (terminated) end + 1 else self.toks.len;

        const line = self.toks[line_start..end];

        // Classify: find the first significant (non-trivia) token and
        // whether the line carries any content (code or comment).
        var first_sig: ?usize = null;
        var has_comment = false;
        for (line, 0..) |t, idx| {
            if (t.kind.isTrivia()) {
                if (t.kind == .LINE_COMMENT or t.kind == .DOC_COMMENT) has_comment = true;
                continue;
            }
            if (first_sig == null) first_sig = idx;
        }

        const has_content = first_sig != null;
        if (!has_content and !has_comment) {
            // Blank line — defer; collapsed when the next content line
            // (if any) is emitted.
            self.pending_blanks += 1;
            return;
        }

        // Display indentation for this line. A line that begins by
        // closing a bracket aligns with that bracket's opener line;
        // otherwise it sits one level inside the innermost open bracket.
        const top: ?usize = if (self.stack.items.len > 0)
            self.stack.items[self.stack.items.len - 1]
        else
            null;
        const first_is_closer = has_content and isCloser(line[first_sig.?].kind);
        const disp: usize = if (first_is_closer)
            (top orelse 0)
        else if (top) |t|
            t + 1
        else
            0;

        try self.recordLine(disp, line);
        self.updateNesting(disp, line);
    }

    /// Build the canonically-spaced text for one content line and push it
    /// as a `Row` (deferring output until the alignment pass). Records the
    /// alignment tab-stops — a depth-0 assignment `=` and a trailing line
    /// comment — as byte offsets into the text.
    fn recordLine(self: *Formatter, disp: usize, line: []const cst.Token) !void {
        // Build the body from the significant/comment tokens, inserting
        // canonical spacing between each adjacent pair (leading whitespace
        // is replaced by the computed indent). Original whitespace tokens
        // are dropped — spacing is decided from token kinds and CST roles.
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        var prev: ?cst.Token = null;
        var depth: usize = 0;
        var eq: ?usize = null;
        var cmt: ?usize = null;
        for (line) |t| {
            if (t.kind == .WHITESPACE) continue; // spacing is recomputed
            if (prev) |p| {
                if (wantSpace(p.kind, self.roleOf(p), t.kind, self.roleOf(t))) {
                    try body.append(self.gpa, ' ');
                }
            }
            // Tab-stops (recorded before the token's own text is appended,
            // so the offset points at `=` / `//`).
            if (t.kind == .EQ and depth == 0 and eq == null) eq = body.items.len;
            if ((t.kind == .LINE_COMMENT or t.kind == .DOC_COMMENT) and prev != null and cmt == null) {
                cmt = body.items.len;
            }
            try body.appendSlice(self.gpa, t.text);
            if (isOpener(t.kind)) {
                depth += 1;
            } else if (isCloser(t.kind) and depth > 0) {
                depth -= 1;
            }
            prev = t;
        }
        // Strip trailing spaces/tabs (also trims inside a trailing line
        // comment; interior bytes are never touched, so raw-string
        // contents survive exactly).
        const trimmed = std.mem.trimEnd(u8, body.items, " \t");
        if (trimmed.len == 0) return; // nothing but whitespace after all

        // Collapse deferred blank lines to one (never at file start).
        if (self.wrote_content and self.pending_blanks > 0) {
            try self.rows.append(self.gpa, .{ .blank = true });
        }
        self.pending_blanks = 0;

        try self.rows.append(self.gpa, .{
            .indent = disp,
            .text = try self.gpa.dupe(u8, trimmed),
            .eq = eq,
            .cmt = cmt,
        });
        self.wrote_content = true;
    }

    /// Emit the collected rows: indentation + text + newline.
    fn serialize(self: *Formatter) !void {
        for (self.rows.items) |r| {
            if (r.blank) {
                try self.out.append(self.gpa, '\n');
                continue;
            }
            try self.appendIndent(r.indent);
            try self.out.appendSlice(self.gpa, r.text);
            try self.out.append(self.gpa, '\n');
        }
    }

    /// Update the bracket stack from this line's brackets. Every opener
    /// pushes an entry recording `disp` — this line's display indent, so
    /// its children indent one level deeper — and every closer pops one.
    /// Matching is exact (one push per opener, one pop per closer); the
    /// hug falls out of every bracket on a line sharing that line's
    /// `disp`. `< >` are not indentation brackets.
    fn updateNesting(self: *Formatter, disp: usize, line: []const cst.Token) void {
        for (line) |t| {
            if (t.kind.isTrivia()) continue;
            if (isOpener(t.kind)) {
                self.stack.append(self.gpa, disp) catch {};
            } else if (isCloser(t.kind)) {
                if (self.stack.items.len > 0) _ = self.stack.pop();
            }
        }
    }

    fn appendIndent(self: *Formatter, level: usize) !void {
        var n = level * indent_width;
        while (n > 0) : (n -= 1) try self.out.append(self.gpa, ' ');
    }

    fn roleOf(self: *Formatter, t: cst.Token) Role {
        return self.roles.get(t.offset) orelse .none;
    }
};

/// Whether a token ends a complete operand — used to tell a postfix
/// `(`/`[` (call/index, tight) from a grouping paren / list literal
/// (spaced), and a binary `-` from a prefix one.
fn endsOperand(kind: cst.SyntaxKind, role: Role) bool {
    return switch (kind) {
        .IDENT, .INT_LIT, .FLOAT_LIT, .STR_PLAIN, .STR_RAW, .NUM_SUFFIX, .R_PAREN, .R_BRACK, .QUESTION, .KW_TRUE, .KW_FALSE => true,
        .R_ANGLE, .SHR => role == .generic, // `Vec<T>(` — a type used as a value
        else => false,
    };
}

/// Canonical spacing decision for an adjacent token pair on one line:
/// `true` = exactly one space between them, `false` = none. The three
/// context-sensitive tokens (`< >`, prefix sigils, lambda `|`) are
/// resolved via `Role`, so the rest is a pure kind-based table. Default
/// is one space; the switches carve out the tight cases.
fn wantSpace(pk: cst.SyntaxKind, pr: Role, ck: cst.SyntaxKind, cr: Role) bool {
    // Tight just inside `(` and `[` (but not `{ … }` — record/block
    // braces keep inner spaces: `Color { r: 0 }`, `{ 42 }`).
    if (pk == .L_PAREN or pk == .L_BRACK) return false;
    if (ck == .R_PAREN or ck == .R_BRACK) return false;

    // No space before these.
    switch (ck) {
        .COMMA, .SEMICOLON, .COLON, .QUESTION, .DOT, .QUESTION_DOT, .COLON_COLON, .DOT_DOT, .DOT_DOT_EQ, .NUM_SUFFIX => return false,
        else => {},
    }
    // No space after these.
    switch (pk) {
        .DOT, .QUESTION_DOT, .COLON_COLON, .DOT_DOT, .DOT_DOT_EQ, .AT, .STR_PREFIX => return false,
        else => {},
    }

    // Prefix sigil: `-x`, `!x`, `~x` (but `ref x` / `move x` keep a space).
    if (pr == .unary and (pk == .MINUS or pk == .BANG or pk == .TILDE)) return false;

    // Generic angle delimiters hug the type: `Vec<T>`, `Map<K, V>>`.
    if (pr == .generic and pk == .L_ANGLE) return false; // `<T`
    if (cr == .generic and (ck == .L_ANGLE or ck == .R_ANGLE or ck == .SHR)) return false; // `Vec<`, `T>`, `V>>`

    // Lambda parameter delimiters hug the params: `|x|`.
    if (pr == .lambda_open) return false; // `|x`
    if (cr == .lambda_close) return false; // `x|`

    // Postfix call / index (`foo(`, `a[`) — from the CST role — or a
    // declaration's parameter/tuple list, where the bracket hugs a
    // name/operand (`fn f(`, `Id(i64)`).
    if ((ck == .L_PAREN or ck == .L_BRACK) and (cr == .postfix or endsOperand(pk, pr))) return false;

    return true;
}

// ===================================================================
// Tests
// ===================================================================

const testing = std.testing;

/// Format `src` and return the owned result, asserting it parsed.
fn fmtOk(src: []const u8) ![]u8 {
    const outcome = try format(testing.allocator, src);
    switch (outcome) {
        .formatted => |t| return t,
        .unparseable => return error.TestUnexpectedUnparseable,
    }
}

fn expectFmt(src: []const u8, expected: []const u8) !void {
    const got = try fmtOk(src);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
    // Idempotence: formatting the output again is a no-op.
    const again = try fmtOk(got);
    defer testing.allocator.free(again);
    try testing.expectEqualStrings(expected, again);
}

test "reindents a badly-indented function" {
    try expectFmt(
        "fn main {\n        let x = 1\n  let y = 2\n}\n",
        "fn main {\n    let x = 1\n    let y = 2\n}\n",
    );
}

test "tabs become spaces; 2-space becomes 4" {
    try expectFmt(
        "fn f {\n\tlet a = 1\n}\n",
        "fn f {\n    let a = 1\n}\n",
    );
}

test "nested brackets hug to a single indent step" {
    // `print_all([` opens both `(` and `[` but children indent once.
    try expectFmt(
        "fn main {\nprint_all([\n1,\n2,\n])\n}\n",
        "fn main {\n    print_all([\n        1,\n        2,\n    ])\n}\n",
    );
}

test "closer-opener line keeps its body indented (} else {)" {
    try expectFmt(
        "fn f {\nif x {\na\n} else {\nb\n}\n}\n",
        "fn f {\n    if x {\n        a\n    } else {\n        b\n    }\n}\n",
    );
}

test "adjacent closers that match non-adjacent openers stay balanced" {
    // `{ ... ( ... ) }` closes as `) }` — two closers matching two
    // brackets opened apart. The block must not drift: the trailing `}`
    // returns to column 0. (Regression: a run-collapse model under-popped
    // here and indented the closing brace.)
    try expectFmt(
        "fn f {\nx.map(|v| if v { g(0) } else { v })\n}\n",
        "fn f {\n    x.map(|v| if v { g(0) } else { v })\n}\n",
    );
}

test "aligns consecutive assignments" {
    try expectFmt(
        "fn f {\n    let x = 1\n    let yyy = 2\n    let zz = 3\n}\n",
        "fn f {\n    let x   = 1\n    let yyy = 2\n    let zz  = 3\n}\n",
    );
}

test "alignment blocks break at a blank line, a non-assignment, and indent" {
    // The `foo()` line breaks the `=` column; the two groups align
    // independently.
    try expectFmt(
        "fn f {\n    let a = 1\n    let bbb = 2\n    foo()\n    let c = 3\n}\n",
        "fn f {\n    let a   = 1\n    let bbb = 2\n    foo()\n    let c = 3\n}\n",
    );
}

test "aligns trailing comments" {
    try expectFmt(
        "fn f {\n    foo() // a\n    barbar() // b\n}\n",
        "fn f {\n    foo()    // a\n    barbar() // b\n}\n",
    );
}

test "aligns `=` and trailing comments together" {
    try expectFmt(
        "fn f {\n    let x = 1 // one\n    let yyy = 22 // two\n}\n",
        "fn f {\n    let x   = 1  // one\n    let yyy = 22 // two\n}\n",
    );
}

test "a single assignment is left with one space (no spurious gap)" {
    try expectFmt("fn f {\n    let x = 1\n}\n", "fn f {\n    let x = 1\n}\n");
}

test "collapses blank lines and strips leading/trailing ones" {
    try expectFmt(
        "\n\nfn a { 0 }\n\n\n\nfn b { 1 }\n\n\n",
        "fn a { 0 }\n\nfn b { 1 }\n",
    );
}

test "strips trailing whitespace and adds a final newline" {
    try expectFmt(
        "fn f { 0 }   ",
        "fn f { 0 }\n",
    );
}

test "re-spaces to a canonical single style" {
    // Extra spaces collapse; tight `foo(x)`; binary operators get spaces.
    try expectFmt(
        "fn   main {\n    env.out(   \"x\"   )\n}\n",
        "fn main {\n    env.out(\"x\")\n}\n",
    );
    try expectFmt("fn f {\n    let x=1+2*3\n}\n", "fn f {\n    let x = 1 + 2 * 3\n}\n");
}

test "spacing: calls, indexing, member access, annotations" {
    try expectFmt(
        "@stage\nfn f {\n    let y = a . b . c ( xs [ 0 ] , 1 )\n}\n",
        "@stage\nfn f {\n    let y = a.b.c(xs[0], 1)\n}\n",
    );
}

test "spacing: generics stay tight, comparisons get spaces" {
    // `<` inside a generic hugs; `<` as less-than is spaced.
    try expectFmt(
        "pub fn f<T: Display>(xs: [T]) -> Vec<T> {\n    xs\n}\n",
        "pub fn f<T: Display>(xs: [T]) -> Vec<T> {\n    xs\n}\n",
    );
    try expectFmt("fn f {\n    let b = a<c\n}\n", "fn f {\n    let b = a < c\n}\n");
}

test "spacing: prefix minus vs binary minus" {
    try expectFmt("fn f {\n    let a = -x\n}\n", "fn f {\n    let a = -x\n}\n");
    try expectFmt("fn f {\n    let a = x - y\n}\n", "fn f {\n    let a = x - y\n}\n");
    try expectFmt("fn f {\n    let a = x*-y\n}\n", "fn f {\n    let a = x * -y\n}\n");
}

test "spacing: colon and type annotation" {
    try expectFmt(
        "pub struct P { x:i64,y:i64 }\n",
        "pub struct P { x: i64, y: i64 }\n",
    );
}

test "spacing: lambda pipes hug their params" {
    try expectFmt(
        "fn f {\n    xs.map(| v | v + 1)\n}\n",
        "fn f {\n    xs.map(|v| v + 1)\n}\n",
    );
}

test "preserves comments (line, doc, trailing)" {
    try expectFmt(
        "//! header\n// note\nfn f {\nlet x = 1 // trailing\n}\n",
        "//! header\n// note\nfn f {\n    let x = 1 // trailing\n}\n",
    );
}

test "comment-only lines follow the current indent" {
    try expectFmt(
        "fn f {\n// inside\nlet x = 1\n}\n",
        "fn f {\n    // inside\n    let x = 1\n}\n",
    );
}

test "already-formatted golden-style input is a fixed point" {
    const src =
        "pub struct Color { r: u8, g: u8, b: u8 }\n" ++
        "\n" ++
        "pub fn print_all<T: Display>(items: [T]) {\n" ++
        "    for item in items {\n" ++
        "        env.out(\"{item.fmt()}\")\n" ++
        "    }\n" ++
        "}\n";
    try expectFmt(src, src);
}

test "brace inside a string does not affect indentation" {
    try expectFmt(
        "fn f {\nenv.out(\"a {x} b\")\n}\n",
        "fn f {\n    env.out(\"a {x} b\")\n}\n",
    );
}

test "unparseable input is reported, not reformatted" {
    // An unterminated string literal is a hard lexical error (LEX030).
    const outcome = try format(testing.allocator, "fn f {\nlet s = \"oops\n}\n");
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome == .unparseable);
}

test "empty and whitespace-only input format to empty" {
    try expectFmt("", "");
    try expectFmt("   \n\n  \n", "");
}

test "significant tokens are preserved (safety invariant)" {
    const src = "pub  fn   main{let   x=1+2\nfoo( a ,b )}\n";
    const got = try fmtOk(src);
    defer testing.allocator.free(got);

    // The multiset of non-trivia tokens must be identical.
    var a = try sigTokens(src);
    defer a.deinit(testing.allocator);
    var b = try sigTokens(got);
    defer b.deinit(testing.allocator);
    try testing.expectEqual(a.items.len, b.items.len);
    for (a.items, b.items) |x, y| try testing.expectEqualStrings(x, y);
}

fn sigTokens(src: []const u8) !std.ArrayList([]const u8) {
    const lex = parser.lex;
    const r = try lex.tokenize(testing.allocator, src);
    defer r.deinit(testing.allocator);
    var out: std.ArrayList([]const u8) = .empty;
    for (r.tokens) |t| {
        if (t.kind.isTrivia() or t.kind == .EOF) continue;
        try out.append(testing.allocator, t.text);
    }
    return out;
}
