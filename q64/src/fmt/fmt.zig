//! The `q64 fmt` formatter engine (v0).
//!
//! v0 is a **structural reindenter** over the lossless token stream:
//! it recomputes leading indentation from bracket nesting, collapses
//! each interior run of whitespace to a single space, normalizes
//! vertical whitespace (blank lines, trailing newline), and strips
//! trailing whitespace — while preserving every significant token and
//! every comment.
//!
//! What it deliberately does NOT do yet: insert or remove spaces around
//! operators/commas (it only *collapses* existing runs, so `a+b` stays
//! `a+b` and `( x )` stays `( x )`), reflow long lines, or normalize
//! trailing commas. Those are the next slices (see `README.md` §Scope).
//! Keeping v0 to indentation + whitespace normalization makes it *safe*:
//! the multiset of significant tokens is identical between input and
//! output, so formatting can never change a program's meaning — only
//! its layout.
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

    var f: Formatter = .{ .toks = toks.items, .gpa = gpa };
    defer f.deinit();
    try f.run();
    return .{ .formatted = try f.out.toOwnedSlice(gpa) };
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

const Formatter = struct {
    toks: []const cst.Token,
    gpa: std.mem.Allocator,
    i: usize = 0,
    out: std.ArrayList(u8) = .empty,
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
        self.stack.deinit(self.gpa);
    }

    fn run(self: *Formatter) !void {
        while (self.i < self.toks.len) try self.formatLine();
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

        try self.emitLine(disp, line);
        self.updateNesting(disp, line);
    }

    /// Emit one content line: collapsed blank(s), indentation, the
    /// line's content (interior spacing preserved, trailing stripped),
    /// and a single `\n`.
    fn emitLine(self: *Formatter, disp: usize, line: []const cst.Token) !void {
        if (self.wrote_content and self.pending_blanks > 0) {
            // Collapse any run of blank lines to exactly one.
            try self.out.append(self.gpa, '\n');
        }
        self.pending_blanks = 0;

        // Build the line body from the first non-whitespace token
        // onward. Leading whitespace is replaced by computed indentation;
        // each interior run of whitespace collapses to a single space;
        // comments are kept as content. Collapsing only ever turns a run
        // of ≥1 spaces into exactly one — it never inserts a space where
        // there was none nor removes a lone space, so it needs no
        // operator disambiguation (`a+b` stays `a+b`) and can't change
        // meaning.
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        var pending_space = false;
        for (line) |t| {
            if (t.kind == .WHITESPACE) {
                if (body.items.len > 0) pending_space = true; // drop leading
                continue;
            }
            if (pending_space) {
                try body.append(self.gpa, ' ');
                pending_space = false;
            }
            try body.appendSlice(self.gpa, t.text);
        }
        // Strip trailing spaces/tabs inside a trailing line comment's own
        // text (interior bytes are never touched, so multi-line raw-string
        // contents are preserved exactly).
        const trimmed = std.mem.trimEnd(u8, body.items, " \t");
        if (trimmed.len == 0) return; // nothing but whitespace after all

        try self.appendIndent(disp);
        try self.out.appendSlice(self.gpa, trimmed);
        try self.out.append(self.gpa, '\n');
        self.wrote_content = true;
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
};

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

test "collapses interior whitespace runs to a single space" {
    try expectFmt(
        "fn   main {\n    env.out(   \"x\"   )\n}\n",
        "fn main {\n    env.out( \"x\" )\n}\n",
    );
    // Zero- and single-space boundaries are left alone (no operator
    // disambiguation needed): `x=1+2` and `foo(` keep their adjacency.
    try expectFmt("fn f {\n    let x=1+2\n}\n", "fn f {\n    let x=1+2\n}\n");
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
