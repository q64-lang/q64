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

    var diags = std.ArrayList(diag.Diagnostic).init(allocator);
    errdefer diags.deinit();
    for (lex_result.diagnostics) |d| {
        try diags.append(.{
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
    };
    const root = try parser.parseSourceFile();

    return .{
        .arena = arena,
        .root = root,
        .diagnostics = try diags.toOwnedSlice(),
    };
}

// =====================================================================
// Parser
// =====================================================================

const Parser = struct {
    tokens: []const cst.Token,
    pos: usize,
    arena: Allocator,

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

    /// Consume any leading trivia tokens into `out`. Trivia at the
    /// boundary between productions ends up at the *outer* level —
    /// this helper is what places it there.
    fn eatTrivia(self: *Parser, out: *std.ArrayList(cst.Element)) !void {
        while (!self.isEof() and self.peek().isTrivia()) {
            try out.append(.{ .token = self.advance() });
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
        var children = std.ArrayList(cst.Element).init(self.arena);

        while (!self.isEof()) {
            if (self.atFnItem()) {
                const fn_node = try self.parseFnDecl();
                try children.append(.{ .node = fn_node });
                continue;
            }
            // Anything we don't recognize — trivia, unimplemented
            // items, stray tokens — passes through as a direct
            // token child of SOURCE_FILE. Lossless by construction.
            try children.append(.{ .token = self.advance() });
        }

        return try cst.makeNode(self.arena, .SOURCE_FILE, children.items);
    }

    // -----------------------------------------------------------------
    // FnDecl
    // -----------------------------------------------------------------

    fn parseFnDecl(self: *Parser) !*const cst.Node {
        var children = std.ArrayList(cst.Element).init(self.arena);

        if (self.peek() == .KW_PUB) {
            const vis_node = try self.parseVisibility();
            try children.append(.{ .node = vis_node });
            try self.eatTrivia(&children);
        }

        std.debug.assert(self.peek() == .KW_FN);
        try children.append(.{ .token = self.advance() }); // KW_FN
        try self.eatTrivia(&children);

        if (self.peek() == .IDENT) {
            try children.append(.{ .token = self.advance() });
        }
        try self.eatTrivia(&children);

        if (self.peek() == .L_PAREN) {
            const params_node = try self.parseParams();
            try children.append(.{ .node = params_node });
            try self.eatTrivia(&children);
        }

        if (self.peek() == .ARROW) {
            const ret_node = try self.parseReturnType();
            try children.append(.{ .node = ret_node });
            try self.eatTrivia(&children);
        }

        // EffectSpec / WhereClause aren't parsed yet. Anything
        // between the return type and the body's `{` collects here
        // so the lossless invariant holds.
        while (!self.isEof() and self.peek() != .L_BRACE) {
            try children.append(.{ .token = self.advance() });
        }

        if (self.peek() == .L_BRACE) {
            const block_node = try self.parseBlock();
            try children.append(.{ .node = block_node });
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

    /// Collect everything from the opening `(` to its matching `)`,
    /// inclusive. v0 carries the contents as raw tokens; the
    /// `Param` production fills in once todo.md "Parser: items
    /// productions" lands.
    fn parseParams(self: *Parser) !*const cst.Node {
        var children = std.ArrayList(cst.Element).init(self.arena);
        var depth: i32 = 0;
        while (!self.isEof()) {
            const t = self.advance();
            try children.append(.{ .token = t });
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
        var children = std.ArrayList(cst.Element).init(self.arena);
        try children.append(.{ .token = self.advance() }); // ARROW

        var depth: i32 = 0;
        while (!self.isEof()) {
            const k = self.peek();
            if (depth == 0 and k == .L_BRACE) break;
            switch (k) {
                .L_PAREN, .L_BRACK, .L_ANGLE => depth += 1,
                .R_PAREN, .R_BRACK, .R_ANGLE => depth -= 1,
                else => {},
            }
            try children.append(.{ .token = self.advance() });
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

    /// Collect a balanced `{...}` body. v0: interior tokens land
    /// directly as children; statement parsing happens in a follow-up
    /// pass (todo.md).
    fn parseBlock(self: *Parser) !*const cst.Node {
        var children = std.ArrayList(cst.Element).init(self.arena);
        var depth: i32 = 0;
        while (!self.isEof()) {
            const t = self.advance();
            try children.append(.{ .token = t });
            switch (t.kind) {
                .L_BRACE => depth += 1,
                .R_BRACE => {
                    depth -= 1;
                    if (depth == 0) break;
                },
                else => {},
            }
        }
        return try cst.makeNode(self.arena, .BLOCK, children.items);
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
    };

    for (sources) |src| {
        const r = try parse(testing.allocator, src, "test.q");
        defer r.deinit(testing.allocator);

        var out = std.ArrayList(u8).init(testing.allocator);
        defer out.deinit();
        try cst.serialize(r.root, &out);

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

test "unimplemented items don't break losslessness or item iteration" {
    // `struct` isn't an item production yet; its tokens pass through
    // SOURCE_FILE directly. The single `fn` item should still be
    // surfaced by SourceFile.items().
    const src = "struct Point { x: i32 }\nfn main { 0 }\n";
    const r = try parse(testing.allocator, src, "mixed.q");
    defer r.deinit(testing.allocator);

    var out = std.ArrayList(u8).init(testing.allocator);
    defer out.deinit();
    try cst.serialize(r.root, &out);
    try testing.expectEqualStrings(src, out.items);

    const sf = ast.SourceFile.cast(r.root).?;
    var iter = sf.items();
    const fd = (iter.next() orelse return error.TestExpectedItem).fn_decl;
    try testing.expectEqualStrings("main", fd.name().?.text);
}
