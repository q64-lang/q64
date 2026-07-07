//! The `q64 fmt` formatter engine (v0).
//!
//! The formatter reprints the lossless token stream the parser emits:
//! it recomputes indentation from bracket nesting (with continuation-line
//! indent), applies a canonical single-space style *between* tokens
//! (spaces around binary operators, after `,`/`:`, tight
//! `foo(x)`/`a.b`/`Vec<T>`), tabwriter-aligns columns (`=`, record-literal
//! grids, trailing comments), adds a trailing comma to multi-line lists,
//! normalizes vertical whitespace, and strips trailing whitespace — while
//! preserving every significant token and every comment.
//!
//! Spacing decisions come from token kinds plus three CST-resolved
//! `Role`s that disambiguate the tokens context alone can't: `< >`
//! (generic delimiter vs comparison), a leading sigil in a `UNARY_EXPR`
//! (`-x` vs `a - b`), and `|` (lambda-param delimiter vs bit-or).
//!
//! Safety. Everything but the trailing-comma pass rewrites only the
//! trivia between tokens; the trailing-comma pass may insert a comma
//! immediately before a closing bracket, and nothing else. This is
//! enforced at runtime by a fail-safe (`outputIsSafe`): the output is
//! re-parsed and its significant-token sequence compared to the input's,
//! allowing *only* those inserted trailing commas. On any other
//! difference — a dropped space that merged two tokens, a stray token, or
//! output that no longer parses — the original source is returned
//! untouched, so the formatter can never corrupt code. `format` is also
//! idempotent. Both properties are checked in the tests below and were
//! verified across every `.q` file in the repo.
//!
//! What it deliberately does NOT do yet: reflow/wrap long lines, and grid
//! alignment of multi-line call arguments (record and array literals get
//! grids; ordinary calls are left alone). See `README.md` §"Deferred".
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

    // Fail-safe. Formatting rewrites trivia and may insert trailing commas
    // before a closer, and nothing else. If the output ever fails that
    // contract — a dropped space that merged two tokens (`let x` → `letx`),
    // a stray token, or output that no longer parses — return the source
    // untouched rather than emit anything questionable. The exact-output
    // unit tests catch the underlying bug instead.
    if (!try outputIsSafe(gpa, source, out)) {
        gpa.free(out);
        return .{ .formatted = try gpa.dupe(u8, source) };
    }
    return .{ .formatted = out };
}

/// The output is safe iff it parses without errors and its significant-token
/// sequence equals the input's — except the output may carry extra commas,
/// each immediately before a closing bracket (the trailing-comma pass). Any
/// other difference means a bug, and the caller falls back to the source.
fn outputIsSafe(gpa: std.mem.Allocator, input: []const u8, output: []const u8) !bool {
    // The output must still parse cleanly (an inserted comma in a context
    // that rejected it would be caught here, not just at lex level).
    const r = try parse.parse(gpa, output, "<fmt-verify>");
    defer r.deinit(gpa);
    for (r.diagnostics) |d| {
        if (d.severity == .err) return false;
    }

    const lex = parser.lex;
    const ra = try lex.tokenize(gpa, input);
    defer ra.deinit(gpa);
    const rb = try lex.tokenize(gpa, output);
    defer rb.deinit(gpa);

    var ia: usize = 0;
    var ib: usize = 0;
    while (true) {
        while (ia < ra.tokens.len and (ra.tokens[ia].kind.isTrivia() or ra.tokens[ia].kind == .EOF)) ia += 1;
        while (ib < rb.tokens.len and (rb.tokens[ib].kind.isTrivia() or rb.tokens[ib].kind == .EOF)) ib += 1;
        const a_done = ia >= ra.tokens.len;
        const b_done = ib >= rb.tokens.len;
        if (a_done and b_done) return true;

        if (!a_done and !b_done and
            ra.tokens[ia].kind == rb.tokens[ib].kind and
            std.mem.eql(u8, ra.tokens[ia].text, rb.tokens[ib].text))
        {
            ia += 1;
            ib += 1;
            continue;
        }
        // Otherwise the only permitted difference is a comma the output
        // inserted immediately before a closer.
        if (!b_done and rb.tokens[ib].kind == .COMMA and nextSigIsCloser(rb.tokens, ib)) {
            ib += 1;
            continue;
        }
        return false;
    }
}

/// True if the first significant token after index `i` in `toks` is a
/// closing bracket.
fn nextSigIsCloser(toks: []const cst.Token, i: usize) bool {
    var j = i + 1;
    while (j < toks.len) : (j += 1) {
        if (toks[j].kind.isTrivia()) continue;
        return isCloser(toks[j].kind);
    }
    return false;
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

/// Two content rows belong to the same alignment block iff they sit at the
/// same indent and expose the identical sequence of stop kinds (offsets may
/// differ). Same shape ⇒ same column count ⇒ every column is meaningful.
fn sameShape(a: Row, b: Row) bool {
    if (b.blank or a.indent != b.indent or a.stops.len != b.stops.len) return false;
    for (a.stops, b.stops) |x, y| {
        if (x.kind != y.kind) return false;
    }
    return true;
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

/// A token that, at the start of a line, marks the line as a *continuation*
/// of the previous one rather than a new statement. Deliberately excludes
/// tokens that can legitimately begin a fresh statement in prefix position
/// (`-`, `!`, `~`, `&`, `*`, `<`) — only unambiguous infix/postfix leaders
/// qualify, so the heuristic never mis-indents a real statement.
fn isContinuationLead(k: cst.SyntaxKind) bool {
    return switch (k) {
        .ARROW, .FAT_ARROW, .PIPE_GT, .DOT, .QUESTION_DOT => true,
        .PLUS, .SLASH, .PERCENT => true,
        .EQ_EQ, .BANG_EQ, .LT_EQ, .GT_EQ => true,
        .AMP_AMP, .PIPE_PIPE => true,
        else => false,
    };
}

/// An alignment tab-stop: a byte offset into a row's `text` and what kind
/// of construct sits there. The column *before* the offset is padded so
/// the text *at* the offset lines up down a block.
const StopKind = enum(u8) { eq, field, brace, brack, cmt };
const Stop = struct { off: usize, kind: StopKind };

/// One formatted line, held until the alignment pass can look across a
/// block of them. `text` is the canonically-spaced content (no leading
/// indent, no trailing newline). `stops` are the tab-stops in ascending
/// order (owned): a depth-0 assignment `=`, each record-literal field
/// start (`{ … , →here }`), the closing `}` of a multi-field record, and
/// a trailing line comment. A `blank` row separates blocks.
const Row = struct {
    blank: bool = false,
    indent: usize = 0,
    text: []u8 = &.{},
    stops: []Stop = &.{},
};

/// A currently-open bracket group. `indent` is the display indent of the
/// line that opened it (drives the indent of lines inside). `had_comma`
/// records whether a comma has appeared at this group's own level — i.e.
/// it's a comma-list (call args, array, record, match arms), not a block
/// or a grouping paren — which is what makes a trailing comma appropriate.
const Group = struct { indent: usize, had_comma: bool = false };

const Formatter = struct {
    toks: []const cst.Token,
    gpa: std.mem.Allocator,
    roles: *const RoleMap,
    i: usize = 0,
    out: std.ArrayList(u8) = .empty,
    rows: std.ArrayList(Row) = .empty,
    /// The open-bracket stack; the innermost entry (top) drives indent.
    stack: std.ArrayList(Group) = .empty,
    /// Index into `rows` of the last content (non-blank) row, or null.
    last_content: ?usize = null,
    /// Blank lines seen since the last content line (for collapsing).
    pending_blanks: usize = 0,
    /// Whether any content line has been emitted (suppresses leading
    /// blank lines at the top of the file).
    wrote_content: bool = false,

    fn deinit(self: *Formatter) void {
        self.out.deinit(self.gpa);
        for (self.rows.items) |r| {
            self.gpa.free(r.text);
            self.gpa.free(r.stops);
        }
        self.rows.deinit(self.gpa);
        self.stack.deinit(self.gpa);
    }

    fn run(self: *Formatter) !void {
        while (self.i < self.toks.len) try self.formatLine();
        try self.alignRows();
        try self.serialize();
    }

    /// Tabwriter pass. Aligns the tab-stops of each maximal run of
    /// consecutive content rows that share the same indent *and* the same
    /// shape (the same sequence of stop kinds). Rows with no tab-stop,
    /// blank rows, indent changes, and differently-shaped rows all break a
    /// run, so a column never spills across unrelated code.
    fn alignRows(self: *Formatter) !void {
        var i: usize = 0;
        while (i < self.rows.items.len) {
            const r = self.rows.items[i];
            if (r.blank or r.stops.len == 0) {
                i += 1;
                continue;
            }
            var j = i + 1;
            while (j < self.rows.items.len and sameShape(r, self.rows.items[j])) : (j += 1) {}
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
        const ncols = block[0].stops.len;

        // Column widths = max trimmed-prefix width across the block.
        var widths: std.ArrayList(usize) = .empty;
        defer widths.deinit(self.gpa);
        try widths.appendNTimes(self.gpa, 0, ncols);
        for (block) |r| {
            var start: usize = 0;
            for (r.stops, 0..) |stop, k| {
                const w = std.mem.trimEnd(u8, r.text[start..stop.off], " ").len;
                if (w > widths.items[k]) widths.items[k] = w;
                start = stop.off;
            }
        }

        // Rebuild each row's text with padded columns.
        for (block) |*r| {
            var rebuilt: std.ArrayList(u8) = .empty;
            errdefer rebuilt.deinit(self.gpa);
            var start: usize = 0;
            for (r.stops, 0..) |stop, k| {
                const cell = std.mem.trimEnd(u8, r.text[start..stop.off], " ");
                try rebuilt.appendSlice(self.gpa, cell);
                try rebuilt.appendNTimes(self.gpa, ' ', widths.items[k] - cell.len + 1);
                start = stop.off;
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
        const top: ?Group = if (self.stack.items.len > 0)
            self.stack.items[self.stack.items.len - 1]
        else
            null;
        const first_is_closer = has_content and isCloser(line[first_sig.?].kind);
        var disp: usize = if (first_is_closer)
            (if (top) |g| g.indent else 0)
        else if (top) |g|
            g.indent + 1
        else
            0;

        // Trailing comma: a comma-list whose closer sits on its own line
        // (this line begins with it) is multi-line, so its last element —
        // the previous content row — gets a trailing comma if it lacks one.
        if (first_is_closer) {
            if (top) |g| {
                if (g.had_comma) try self.addTrailingComma();
            }
        }

        // Continuation lines — a wrapped statement that begins with an
        // operator/`.`/`->`/`|>` (a token that can't start a fresh
        // statement) — indent one level under the line they continue, so
        // a wrapped `-> ReturnType`, a `.method()` chain, or a `|>`
        // pipeline reads as subordinate rather than as a new statement.
        if (has_content and !first_is_closer and isContinuationLead(line[first_sig.?].kind)) {
            disp += 1;
        }

        try self.recordLine(disp, line);
        self.updateNesting(disp, line);
    }

    /// Build the canonically-spaced text for one content line and push it
    /// as a `Row` (deferring output until the alignment pass), recording
    /// its alignment tab-stops as byte offsets into the text.
    fn recordLine(self: *Formatter, disp: usize, line: []const cst.Token) !void {
        // Build the body from the significant/comment tokens, inserting
        // canonical spacing between each adjacent pair (leading whitespace
        // is replaced by the computed indent). Original whitespace tokens
        // are dropped — spacing is decided from token kinds and CST roles.
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        var stops: std.ArrayList(Stop) = .empty;
        errdefer stops.deinit(self.gpa);

        // Bracket stack for this line: kind + whether the group has seen a
        // top-level comma (i.e. it's a multi-field record when `{`).
        const Bracket = struct { kind: cst.SyntaxKind, had_field: bool };
        var brackets: std.ArrayList(Bracket) = .empty;
        defer brackets.deinit(self.gpa);

        var prev: ?cst.Token = null;
        var have_eq = false;
        var pending_field = false; // a record-field comma awaits its next field
        for (line) |t| {
            if (t.kind == .WHITESPACE) continue; // spacing is recomputed
            if (prev) |p| {
                if (wantSpace(p.kind, self.roleOf(p), t.kind, self.roleOf(t))) {
                    try body.append(self.gpa, ' ');
                }
            }

            // A record-field comma's tab-stop is the *start* of the next
            // field (so fields line up). Skip it if the next token closes
            // the record (a trailing comma).
            if (pending_field) {
                pending_field = false;
                if (!isCloser(t.kind)) try stops.append(self.gpa, .{ .off = body.items.len, .kind = .field });
            }
            // Assignment `=` at bracket depth 0 (first one only).
            if (t.kind == .EQ and brackets.items.len == 0 and !have_eq) {
                try stops.append(self.gpa, .{ .off = body.items.len, .kind = .eq });
                have_eq = true;
            }
            // Trailing line comment (there is at most one, and it's last).
            if ((t.kind == .LINE_COMMENT or t.kind == .DOC_COMMENT) and prev != null) {
                try stops.append(self.gpa, .{ .off = body.items.len, .kind = .cmt });
            }
            // The closing `}`/`]` of a multi-element record/array is a
            // tab-stop, so the last column (hence the closer) aligns too.
            // Pop before appending so the offset points at the closer.
            if (isCloser(t.kind)) {
                if (brackets.items.len > 0) {
                    const e = brackets.pop().?;
                    if (e.had_field) {
                        if (t.kind == .R_BRACE) try stops.append(self.gpa, .{ .off = body.items.len, .kind = .brace });
                        if (t.kind == .R_BRACK) try stops.append(self.gpa, .{ .off = body.items.len, .kind = .brack });
                    }
                }
            }

            try body.appendSlice(self.gpa, t.text);

            if (isOpener(t.kind)) {
                try brackets.append(self.gpa, .{ .kind = t.kind, .had_field = false });
            } else if (t.kind == .COMMA and brackets.items.len > 0 and
                (brackets.items[brackets.items.len - 1].kind == .L_BRACE or
                    brackets.items[brackets.items.len - 1].kind == .L_BRACK))
            {
                brackets.items[brackets.items.len - 1].had_field = true;
                pending_field = true;
            }
            prev = t;
        }
        // Strip trailing spaces/tabs (also trims inside a trailing line
        // comment; interior bytes are never touched, so raw-string
        // contents survive exactly).
        const trimmed = std.mem.trimEnd(u8, body.items, " \t");
        if (trimmed.len == 0) {
            stops.deinit(self.gpa);
            return; // nothing but whitespace after all
        }

        // Collapse deferred blank lines to one (never at file start).
        if (self.wrote_content and self.pending_blanks > 0) {
            try self.rows.append(self.gpa, .{ .blank = true });
        }
        self.pending_blanks = 0;

        try self.rows.append(self.gpa, .{
            .indent = disp,
            .text = try self.gpa.dupe(u8, trimmed),
            .stops = try stops.toOwnedSlice(self.gpa),
        });
        self.last_content = self.rows.items.len - 1;
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
        // Line-local angle depth for generic-argument spans: a `<` glued
        // directly to an identifier (no trivia between — `Simd<f32, 4>`,
        // `Vec<i64>`) opens a type-argument list whose commas belong to IT,
        // not to the innermost ()/[]/{} group — attributing them there made
        // the enclosing block a comma-list and grew a spurious trailing
        // comma. A spaced `<` is a comparison and never enters here.
        var angle: usize = 0;
        var prev: ?cst.SyntaxKind = null; // previous token INCLUDING trivia
        for (line) |t| {
            const p = prev;
            prev = t.kind;
            if (t.kind.isTrivia()) continue;
            if (t.kind == .L_ANGLE and p == .IDENT) {
                angle += 1;
            } else if (t.kind == .R_ANGLE and angle > 0) {
                angle -= 1;
            } else if (isOpener(t.kind)) {
                self.stack.append(self.gpa, .{ .indent = disp }) catch {};
            } else if (isCloser(t.kind)) {
                if (self.stack.items.len > 0) _ = self.stack.pop();
            } else if (t.kind == .COMMA and angle == 0 and self.stack.items.len > 0) {
                // A comma at the innermost open group's level marks it a
                // comma-list (persists across lines until the group closes).
                self.stack.items[self.stack.items.len - 1].had_comma = true;
            }
        }
    }

    /// Insert a trailing comma into the last content row's element (before
    /// any trailing comment), unless it already ends in a comma or is a
    /// comment-only row.
    fn addTrailingComma(self: *Formatter) !void {
        const idx = self.last_content orelse return;
        const row = &self.rows.items[idx];
        if (std.mem.startsWith(u8, row.text, "//")) return; // comment-only line

        // Insert just before a trailing comment, else at end of the text.
        var pos = row.text.len;
        for (row.stops) |s| {
            if (s.kind == .cmt and s.off > 0) pos = s.off - 1; // before the space
        }
        if (pos == 0 or row.text[pos - 1] == ',') return; // nothing to do

        var nt = try self.gpa.alloc(u8, row.text.len + 1);
        @memcpy(nt[0..pos], row.text[0..pos]);
        nt[pos] = ',';
        @memcpy(nt[pos + 1 ..], row.text[pos..]);
        self.gpa.free(row.text);
        row.text = nt;
        for (row.stops) |*s| {
            if (s.off >= pos) s.off += 1; // a trailing comment shifts right
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

test "aligns record-literal field columns across rows (grid)" {
    try expectFmt(
        "fn main {\n" ++
            "    print_all([\n" ++
            "        Color { r: 255, g: 0, b: 0 },\n" ++
            "        Color { r: 0, g: 255, b: 0 },\n" ++
            "        Color { r: 0, g: 0, b: 255 },\n" ++
            "    ])\n" ++
            "}\n",
        "fn main {\n" ++
            "    print_all([\n" ++
            "        Color { r: 255, g: 0,   b: 0   },\n" ++
            "        Color { r: 0,   g: 255, b: 0   },\n" ++
            "        Color { r: 0,   g: 0,   b: 255 },\n" ++
            "    ])\n" ++
            "}\n",
    );
}

test "aligns array-literal columns across rows (grid)" {
    try expectFmt(
        "fn f {\n    let m = [\n        [1, 2, 3],\n        [40, 5, 6],\n        [7, 80, 900],\n    ]\n}\n",
        "fn f {\n    let m = [\n        [1,  2,  3   ],\n        [40, 5,  6   ],\n        [7,  80, 900 ],\n    ]\n}\n",
    );
}

test "grid alignment only groups same-shape (field-count) rows" {
    // The two two-field rows align (fields and the closing `}`); the
    // single-field `Q { a: 1 }` has no field comma, so it's left alone.
    try expectFmt(
        "fn f {\n    P { x: 1, y: 22 }\n    P { x: 333, y: 4 }\n    Q { a: 1 }\n}\n",
        "fn f {\n    P { x: 1,   y: 22 }\n    P { x: 333, y: 4  }\n    Q { a: 1 }\n}\n",
    );
}

test "indents a wrapped return type under its signature" {
    try expectFmt(
        "fn denoise(x: i64)\n-> Signal\n{\n    x\n}\n",
        "fn denoise(x: i64)\n    -> Signal\n{\n    x\n}\n",
    );
}

test "indents method-chain and pipe continuations" {
    try expectFmt(
        "fn f {\n    clean\n|> denoise()\n|> play\n}\n",
        "fn f {\n    clean\n        |> denoise()\n        |> play\n}\n",
    );
    try expectFmt(
        "fn f {\n    thing\n.bar()\n.baz()\n}\n",
        "fn f {\n    thing\n        .bar()\n        .baz()\n}\n",
    );
}

test "ordinary consecutive statements are not treated as continuations" {
    // Neither line starts with a continuation lead, so both stay at the
    // block indent (no spurious extra level).
    try expectFmt(
        "fn f {\n    aaa()\n    bbb()\n}\n",
        "fn f {\n    aaa()\n    bbb()\n}\n",
    );
}

test "adds a trailing comma to multi-line lists" {
    // Call args, record fields, arrays, and match arms all get one.
    try expectFmt(
        "fn f {\n    foo(\n        a,\n        b\n    )\n}\n",
        "fn f {\n    foo(\n        a,\n        b,\n    )\n}\n",
    );
    try expectFmt(
        "fn f {\n    let c = P {\n        x: 1,\n        y: 2\n    }\n}\n",
        "fn f {\n    let c = P {\n        x: 1,\n        y: 2,\n    }\n}\n",
    );
}

test "does not add a trailing comma to single-line lists or blocks" {
    // Closer on the same line ⇒ not multi-line ⇒ untouched.
    try expectFmt("fn f {\n    foo(a, b)\n}\n", "fn f {\n    foo(a, b)\n}\n");
    // A block has no top-level commas ⇒ not a comma-list ⇒ untouched.
    try expectFmt("fn f {\n    let x = 1\n    let y = 2\n}\n", "fn f {\n    let x = 1\n    let y = 2\n}\n");
}

test "trailing comma goes before a trailing comment" {
    try expectFmt(
        "fn f {\n    foo(\n        a,\n        b // last\n    )\n}\n",
        "fn f {\n    foo(\n        a,\n        b, // last\n    )\n}\n",
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

test "a comma inside generic type args does not grow a trailing comma" {
    // `Simd<f32, 4>` was the first statement-position annotation carrying a
    // comma; attributing it to the enclosing `{}` block marked the block a
    // comma-list and appended a spurious trailing comma to its last stmt.
    const src = "fn main {\n    let v: Simd<f32, 4> = Simd.splat(s)\n    env.out(\"{v}\")\n}\n";
    const got = try fmtOk(src);
    defer testing.allocator.free(got);
    try testing.expect(std.mem.indexOf(u8, got, "env.out(\"{v}\"),") == null);
    // A real comma-list inside the block still gets its trailing comma
    // treatment via its own () group — the comparison `a < b` (spaced)
    // must not open an angle span and swallow the call's comma.
    const src2 = "fn main {\n    foo(\n        a < b,\n        c,\n    )\n}\n";
    const got2 = try fmtOk(src2);
    defer testing.allocator.free(got2);
    try testing.expect(std.mem.indexOf(u8, got2, "c,") != null);
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
