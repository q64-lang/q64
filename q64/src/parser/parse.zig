//! Parser — tokens to CST.
//!
//! v0 scaffold. The real production-by-production parse against
//! spec/grammar.md will fill this in incrementally. For now, this
//! file provides the bare bones that complete the lex → parse →
//! serialize round-trip:
//!
//!   - `parse(allocator, source)` runs the lexer, wraps every
//!     resulting token in a flat `SOURCE_FILE` node, and returns
//!     the tree + any lex diagnostics.
//!   - The lossless invariant `serialize(parse(s)) == s` holds at
//!     this level, validated by tests below.
//!
//! As the parser fills in, `SOURCE_FILE`'s children stop being a
//! flat token list and start being a proper item-by-item structure.
//! The lossless invariant remains the contract throughout.

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

    // Lex. The token slices are owned by the arena so the CST
    // elements that wrap them stay valid for the result's
    // lifetime.
    const lex_result = try lex.tokenize(a, source);

    // Build the flat SOURCE_FILE node: every token becomes a child
    // Element. The composite kind is correct (SOURCE_FILE); the
    // structure is provisional until real productions land.
    var elements = std.ArrayList(cst.Element).init(a);
    for (lex_result.tokens) |t| {
        if (t.kind == .EOF) continue;
        try elements.append(.{ .token = t });
    }
    const root = try cst.makeNode(a, .SOURCE_FILE, elements.items);

    // Promote lex diagnostics into the full Diagnostic shape.
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

    return .{
        .arena = arena,
        .root = root,
        .diagnostics = try diags.toOwnedSlice(),
    };
}

// =====================================================================
// Tests
// =====================================================================

const testing = std.testing;

test "round-trip: lex + flat parse + serialize == source" {
    const sources = [_][]const u8{
        "fn main { env.out(\"hi\") }\n",
        "//! header\n\npub fn helper -> i64 { 42 }\n",
        "let xs: [i64; 4] = [1, 2, 3, 4]\n",
        "@stage\nfn mic_input -> Signal<PCM<f32>, 48.kHz> {\n    env.audio.input()\n}\n",
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
