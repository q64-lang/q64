//! `q64 doc --json` — the documentation index emitter.
//!
//! Hand-emits a versioned JSON document describing the q64 language surface.
//! It is the single source of truth the docs site (docs.q64.dev) renders into
//! reference pages and `llms.txt`, and the data `q64 explain` shares. The
//! JSON is written the same way as the diagnostic envelope (`diag.emitJson`):
//! straight to a `*std.Io.Writer`, no serializer, reusing `diag.writeJsonString`
//! for string escaping so both encode identically.
//!
//! ## Schema (version 1) — three tiers, forward-stable as typeck lands
//!
//!   { "schema_version": 1, "q64_version": "…", "generated_for": "language"|"qube",
//!     "language": {                         // (a) available now
//!       "keywords":      [ { "text", "kind" } ],
//!       "builtin_types": [ { "name", "category", "doc" } ],
//!       "diagnostics":   [ { "code", "subsystem", "severity", "message", "url" } ] },
//!     "qube": null | {                       // (b) parser-extractable now
//!       "file", "module_doc",
//!       "items": [ { "kind", "name", "visibility", "doc", "signature",
//!                    "params"?, "return_type"?, "fields"?, "variants"?,
//!                    "resolved": { … } } ] } }
//!
//! Tier (c) — the per-item `"resolved"` block (resolved types, effects,
//! capabilities) — is emitted empty today and filled once typeck reaches the
//! introspection path, with no schema change. See spec/q64-cli.md §"doc".

const std = @import("std");
const parser = @import("parser");
const cst = parser.cst;
const lex = parser.lex;
const diag = parser.diag;
const ast = parser.ast;
const parse = parser.parse;

pub const schema_version = 1;
pub const q64_version = "0.0.1";

// =====================================================================
// Builtin / prelude types
//
// Hand-curated until the stdlib prelude is implemented; at that point this
// becomes generated from typeck. Mirrors spec/types.md (numeric tower) and
// spec/env.md / spec/modules.md (auto-prelude names).
// =====================================================================

const BuiltinType = struct { name: []const u8, category: []const u8, doc: []const u8 };

const builtin_types = [_]BuiltinType{
    // Numeric tower (spec/types.md §"Numeric types").
    .{ .name = "i8", .category = "primitive", .doc = "8-bit signed integer." },
    .{ .name = "i16", .category = "primitive", .doc = "16-bit signed integer." },
    .{ .name = "i32", .category = "primitive", .doc = "32-bit signed integer." },
    .{ .name = "i64", .category = "primitive", .doc = "64-bit signed integer." },
    .{ .name = "u8", .category = "primitive", .doc = "8-bit unsigned integer." },
    .{ .name = "u16", .category = "primitive", .doc = "16-bit unsigned integer." },
    .{ .name = "u32", .category = "primitive", .doc = "32-bit unsigned integer." },
    .{ .name = "u64", .category = "primitive", .doc = "64-bit unsigned integer." },
    .{ .name = "f16", .category = "primitive", .doc = "16-bit IEEE-754 float." },
    .{ .name = "f32", .category = "primitive", .doc = "32-bit IEEE-754 float." },
    .{ .name = "f64", .category = "primitive", .doc = "64-bit IEEE-754 float." },
    .{ .name = "bool", .category = "primitive", .doc = "Boolean (`true` / `false`)." },
    .{ .name = "str", .category = "primitive", .doc = "UTF-8 string; `(ptr, len)` at the MIR/ABI tier." },
    // Compound builtins in the auto-prelude (spec/types.md, spec/modules.md).
    .{ .name = "Simd", .category = "prelude", .doc = "`Simd<T, const N>` — hardware-mapped SIMD lanes." },
    .{ .name = "Tensor", .category = "prelude", .doc = "`Tensor<T, const Shape>` — static-shape tensor." },
    .{ .name = "DynTensor", .category = "prelude", .doc = "`DynTensor<T>` — runtime-shape tensor." },
    .{ .name = "Option", .category = "prelude", .doc = "`Option<T>` — an optional value (`Some` / `None`)." },
    .{ .name = "Result", .category = "prelude", .doc = "`Result<T, E>` — success or error; drives `try` / `catch`." },
    .{ .name = "Vec", .category = "prelude", .doc = "`Vec<T>` — a growable, region-allocated sequence." },
    .{ .name = "Region", .category = "prelude", .doc = "A memory region handle (spec/memory.md)." },
    .{ .name = "Arena", .category = "prelude", .doc = "An arena allocator over a region (spec/memory.md)." },
};

// A short, human description per keyword. Hand-maintained here in the doc layer
// (the lexer's `keywords` table carries only text + token kind). Keywords with
// no entry emit an empty `doc`.
const KeywordDoc = struct { text: []const u8, doc: []const u8 };
const keyword_docs = [_]KeywordDoc{
    .{ .text = "actor", .doc = "Declare an actor — an isolated unit of concurrent state with message handlers." },
    .{ .text = "as", .doc = "Bind an import under a different name (`import foo as bar`)." },
    .{ .text = "break", .doc = "Exit the innermost loop, optionally yielding a value." },
    .{ .text = "catch", .doc = "Handle an error or a failed task." },
    .{ .text = "const", .doc = "A compile-time constant binding." },
    .{ .text = "continue", .doc = "Skip to the next iteration of the innermost loop." },
    .{ .text = "draw", .doc = "A `screen`'s declarative view block; its statements are widget calls." },
    .{ .text = "dyn", .doc = "Dynamic dispatch over a face used as a type (`dyn Face`)." },
    .{ .text = "effect", .doc = "Declare an effect or an effect relationship (spec/effects.md)." },
    .{ .text = "else", .doc = "The alternative branch of an `if`." },
    .{ .text = "enum", .doc = "Declare an enum (sum type) with named variants." },
    .{ .text = "face", .doc = "Declare a face — q64's interface/trait for polymorphism (spec/faces.md)." },
    .{ .text = "false", .doc = "The boolean literal `false`." },
    .{ .text = "fit", .doc = "Implement a face for a type (`fit T : Face`)." },
    .{ .text = "fn", .doc = "Declare a function." },
    .{ .text = "for", .doc = "Iterate over a sequence (`for x in xs`)." },
    .{ .text = "forall", .doc = "Universal quantifier used in laws and generic reasoning." },
    .{ .text = "from", .doc = "Source clause of a re-export." },
    .{ .text = "graph", .doc = "A stream graph — connected dataflow stages (spec/streams.md)." },
    .{ .text = "handle", .doc = "Declare an actor's handler for a message." },
    .{ .text = "if", .doc = "A conditional." },
    .{ .text = "import", .doc = "Bring a module or selected names into scope." },
    .{ .text = "in", .doc = "The by-value `in` parameter mode; also the `for x in xs` separator." },
    .{ .text = "law", .doc = "State an algebraic law a `fit` must satisfy (property-checked)." },
    .{ .text = "let", .doc = "An immutable local binding." },
    .{ .text = "loop", .doc = "An unconditional loop (exit with `break`)." },
    .{ .text = "match", .doc = "Pattern-match a value against arms." },
    .{ .text = "move", .doc = "The `move` parameter mode — transfer ownership." },
    .{ .text = "on", .doc = "An event handler in a `screen` (`on press(…) { … }`)." },
    .{ .text = "out", .doc = "The `out` parameter mode — a write-only output parameter." },
    .{ .text = "panic", .doc = "Abort the current computation with an error." },
    .{ .text = "pub", .doc = "Mark an item public — part of the qube's exported surface." },
    .{ .text = "ref", .doc = "A reference type (`ref T`) or the `ref` parameter mode." },
    .{ .text = "region", .doc = "A memory region — the unit of allocation lifetime (spec/memory.md)." },
    .{ .text = "return", .doc = "Return a value from a function." },
    .{ .text = "scope", .doc = "A structured-concurrency scope that bounds spawned tasks." },
    .{ .text = "screen", .doc = "The QView frontend DSL: `state`, a `draw` block, and `on` handlers." },
    .{ .text = "select", .doc = "Wait on multiple channel operations, taking the first ready." },
    .{ .text = "self", .doc = "The receiver value of a method." },
    .{ .text = "Self", .doc = "The enclosing / implementing type." },
    .{ .text = "spawn", .doc = "Start a concurrent task within a scope." },
    .{ .text = "state", .doc = "A reactive state binding (in a `screen` or actor)." },
    .{ .text = "struct", .doc = "Declare a struct (record type)." },
    .{ .text = "tell", .doc = "Send a fire-and-forget message to an actor." },
    .{ .text = "trap", .doc = "Raise an unrecoverable trap." },
    .{ .text = "true", .doc = "The boolean literal `true`." },
    .{ .text = "try", .doc = "Propagate an error from a `Result` (early-return on failure)." },
    .{ .text = "type", .doc = "Declare a type alias (`type Name = …`)." },
    .{ .text = "use", .doc = "Re-export names from a module (`pub use …`)." },
    .{ .text = "var", .doc = "A mutable local binding." },
    .{ .text = "where", .doc = "Attach bounds to generic parameters." },
    .{ .text = "while", .doc = "A loop that runs while a condition holds." },
    .{ .text = "with_capabilities", .doc = "Run a block with a narrowed capability set (grant / deny)." },
    .{ .text = "None", .doc = "The `Option` `None` value / pattern." },
};

fn keywordDoc(text: []const u8) []const u8 {
    for (keyword_docs) |kd| {
        if (std.mem.eql(u8, kd.text, text)) return kd.doc;
    }
    return "";
}

// =====================================================================
// Public entry points
// =====================================================================

/// Emit the language-level index only (`q64 doc --json`, no source). `qube`
/// is `null`. This is the substantive output today.
pub fn emitLanguageJson(w: *std.Io.Writer, gpa: std.mem.Allocator) !void {
    try w.print("{{\"schema_version\":{d},\"q64_version\":", .{schema_version});
    try diag.writeJsonString(w, q64_version);
    try w.writeAll(",\"generated_for\":\"language\",\"language\":");
    try writeLanguageObject(w, gpa);
    try w.writeAll(",\"qube\":null}");
    try w.writeByte('\n');
}

/// Emit the language index plus one qube's public surface (`q64 doc --json
/// --qube <file>`). Parser-only: extracts each top-level item's kind, name,
/// visibility, leading `//!` doc, and a reconstructed signature. `module`
/// dependencies are not needed for surface extraction.
pub fn emitQubeJson(
    w: *std.Io.Writer,
    gpa: std.mem.Allocator,
    source: []const u8,
    file: []const u8,
) !void {
    var result = try parse.parse(gpa, source, file);
    defer result.deinit(gpa);
    const sf = ast.SourceFile.cast(result.root) orelse return error.NotASourceFile;

    try w.print("{{\"schema_version\":{d},\"q64_version\":", .{schema_version});
    try diag.writeJsonString(w, q64_version);
    try w.writeAll(",\"generated_for\":\"qube\",\"language\":");
    try writeLanguageObject(w, gpa);
    try w.writeAll(",\"qube\":{\"file\":");
    try diag.writeJsonString(w, file);

    try w.writeAll(",\"module_doc\":");
    if (try ast.fileHeaderDoc(gpa, sf)) |hdr| {
        defer gpa.free(hdr);
        try diag.writeJsonString(w, hdr);
    } else {
        try w.writeAll("null");
    }

    try w.writeAll(",\"items\":[");
    var items = sf.items();
    var n: usize = 0;
    while (items.next()) |item| : (n += 1) {
        if (n > 0) try w.writeByte(',');
        try writeItem(w, gpa, sf, item);
    }
    try w.writeAll("]}}");
    try w.writeByte('\n');
}

// =====================================================================
// Language object (tier a)
// =====================================================================

fn writeLanguageObject(w: *std.Io.Writer, gpa: std.mem.Allocator) !void {
    // keywords
    try w.writeAll("{\"keywords\":[");
    for (lex.keywords, 0..) |kw, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"text\":");
        try diag.writeJsonString(w, kw.text);
        try w.writeAll(",\"kind\":");
        try diag.writeJsonString(w, @tagName(kw.kind));
        try w.writeAll(",\"doc\":");
        try diag.writeJsonString(w, keywordDoc(kw.text));
        try w.writeByte('}');
    }
    // builtin types
    try w.writeAll("],\"builtin_types\":[");
    for (builtin_types, 0..) |bt, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"name\":");
        try diag.writeJsonString(w, bt.name);
        try w.writeAll(",\"category\":");
        try diag.writeJsonString(w, bt.category);
        try w.writeAll(",\"doc\":");
        try diag.writeJsonString(w, bt.doc);
        try w.writeByte('}');
    }
    // diagnostics
    try w.writeAll("],\"diagnostics\":[");
    for (diag.codes, 0..) |c, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"code\":");
        try diag.writeJsonString(w, c.code);
        try w.writeAll(",\"subsystem\":");
        try diag.writeJsonString(w, c.subsystem);
        try w.writeAll(",\"severity\":");
        try diag.writeJsonString(w, c.severity.toString());
        try w.writeAll(",\"message\":");
        try diag.writeJsonString(w, c.message);
        try w.writeAll(",\"summary\":");
        try diag.writeJsonString(w, c.summary);
        try w.writeAll(",\"url\":");
        const url = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ diag.diagnostics_base, c.code });
        defer gpa.free(url);
        try diag.writeJsonString(w, url);
        try w.writeByte('}');
    }
    try w.writeAll("]}");
}

// =====================================================================
// Items (tier b) + reserved resolved block (tier c)
// =====================================================================

fn writeItem(w: *std.Io.Writer, gpa: std.mem.Allocator, sf: ast.SourceFile, item: ast.Item) !void {
    const node = itemNode(item);

    try w.writeAll("{\"kind\":");
    try diag.writeJsonString(w, itemKind(item));

    try w.writeAll(",\"name\":");
    if (itemName(item)) |tok| {
        try diag.writeJsonString(w, tok.text);
    } else {
        try w.writeAll("null");
    }

    try w.writeAll(",\"visibility\":");
    try diag.writeJsonString(w, if (itemIsPublic(item)) "pub" else "private");

    try w.writeAll(",\"doc\":");
    if (try ast.leadingDoc(gpa, sf, node)) |d| {
        defer gpa.free(d);
        try diag.writeJsonString(w, d);
    } else {
        try w.writeAll("null");
    }

    try w.writeAll(",\"signature\":");
    const sig = try renderSignature(gpa, item);
    defer gpa.free(sig);
    try diag.writeJsonString(w, sig);

    // Kind-specific structured detail.
    switch (item) {
        .fn_decl => |fd| try writeFnDetail(w, gpa, fd),
        .struct_decl => |sd| try writeStructDetail(w, gpa, sd),
        .enum_decl => |ed| try writeEnumDetail(w, ed),
        else => {},
    }

    // Tier (c): reserved for typeck. Emitted empty today.
    try w.writeAll(",\"resolved\":{\"return_type\":null,\"param_types\":[],\"effects\":[],\"capabilities\":[]}}");
}

fn writeFnDetail(w: *std.Io.Writer, gpa: std.mem.Allocator, fd: ast.FnDecl) !void {
    try w.writeAll(",\"params\":[");
    if (fd.params()) |params| {
        var it = params.iter();
        var i: usize = 0;
        while (it.next()) |p| : (i += 1) {
            if (i > 0) try w.writeByte(',');
            try w.writeAll("{\"name\":");
            if (p.name()) |nm| try diag.writeJsonString(w, nm.text) else try w.writeAll("null");
            try w.writeAll(",\"mode\":");
            if (p.mode()) |md| try diag.writeJsonString(w, md.text) else try w.writeAll("null");
            try w.writeAll(",\"type\":");
            if (try p.typeText(gpa)) |ty| {
                defer gpa.free(ty);
                try diag.writeJsonString(w, ty);
            } else try w.writeAll("null");
            try w.writeByte('}');
        }
    }
    try w.writeAll("],\"return_type\":");
    if (fd.returnType()) |rt| {
        if (try rt.text(gpa)) |ty| {
            defer gpa.free(ty);
            try diag.writeJsonString(w, ty);
        } else try w.writeAll("null");
    } else try w.writeAll("null");
}

fn writeStructDetail(w: *std.Io.Writer, gpa: std.mem.Allocator, sd: ast.StructDecl) !void {
    try w.writeAll(",\"fields\":[");
    var it = sd.fields();
    var i: usize = 0;
    while (it.next()) |f| : (i += 1) {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"name\":");
        if (f.name()) |nm| try diag.writeJsonString(w, nm.text) else try w.writeAll("null");
        try w.writeAll(",\"type\":");
        if (try f.typeText(gpa)) |ty| {
            defer gpa.free(ty);
            try diag.writeJsonString(w, ty);
        } else try w.writeAll("null");
        try w.writeByte('}');
    }
    try w.writeAll("]");
}

fn writeEnumDetail(w: *std.Io.Writer, ed: ast.EnumDecl) !void {
    try w.writeAll(",\"variants\":[");
    var it = ed.variants();
    var i: usize = 0;
    while (it.next()) |v| : (i += 1) {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"name\":");
        if (v.name()) |nm| try diag.writeJsonString(w, nm.text) else try w.writeAll("null");
        try w.writeByte('}');
    }
    try w.writeAll("]");
}

// =====================================================================
// Item helpers
// =====================================================================

fn itemNode(item: ast.Item) *const cst.Node {
    return switch (item) {
        inline else => |v| v.cst,
    };
}

fn itemName(item: ast.Item) ?cst.Token {
    return switch (item) {
        inline else => |v| v.name(),
    };
}

fn itemIsPublic(item: ast.Item) bool {
    return switch (item) {
        inline else => |v| v.visibility() != null,
    };
}

fn itemKind(item: ast.Item) []const u8 {
    return switch (item) {
        .fn_decl => "fn",
        .struct_decl => "struct",
        .enum_decl => "enum",
        .type_decl => "type",
        .const_decl => "const",
        .state_decl => "state",
        .face_decl => "face",
        .fit_decl => "fit",
        .screen_decl => "screen",
        .effect_decl => "effect",
        .actor_decl => "actor",
    };
}

/// Reconstruct a one-line signature from the structured accessors. Caller owns
/// the slice.
fn renderSignature(gpa: std.mem.Allocator, item: ast.Item) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    const name = if (itemName(item)) |t| t.text else "_";
    switch (item) {
        .fn_decl => |fd| {
            try out.appendSlice(gpa, "fn ");
            try out.appendSlice(gpa, name);
            try out.append(gpa, '(');
            if (fd.params()) |params| {
                var it = params.iter();
                var i: usize = 0;
                while (it.next()) |p| : (i += 1) {
                    if (i > 0) try out.appendSlice(gpa, ", ");
                    if (p.mode()) |md| {
                        try out.appendSlice(gpa, md.text);
                        try out.append(gpa, ' ');
                    }
                    if (p.name()) |nm| try out.appendSlice(gpa, nm.text);
                    if (try p.typeText(gpa)) |ty| {
                        defer gpa.free(ty);
                        try out.appendSlice(gpa, ": ");
                        try out.appendSlice(gpa, ty);
                    }
                }
            }
            try out.append(gpa, ')');
            if (fd.returnType()) |rt| {
                if (try rt.text(gpa)) |ty| {
                    defer gpa.free(ty);
                    try out.appendSlice(gpa, " -> ");
                    try out.appendSlice(gpa, ty);
                }
            }
        },
        .type_decl => |td| {
            try out.appendSlice(gpa, "type ");
            try out.appendSlice(gpa, name);
            if (try td.aliasedText(gpa)) |al| {
                defer gpa.free(al);
                try out.appendSlice(gpa, " = ");
                try out.appendSlice(gpa, al);
            }
        },
        else => {
            try out.appendSlice(gpa, itemKind(item));
            try out.append(gpa, ' ');
            try out.appendSlice(gpa, name);
        },
    }
    return try out.toOwnedSlice(gpa);
}

// =====================================================================
// Tests
// =====================================================================

const testing = std.testing;

fn captureLanguage(gpa: std.mem.Allocator) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try emitLanguageJson(&aw.writer, gpa);
    return aw.toOwnedSlice();
}

test "emitLanguageJson: shape and content" {
    const json = try captureLanguage(testing.allocator);
    defer testing.allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"schema_version\":1") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"generated_for\":\"language\"") != null);
    // A representative keyword and its kind.
    try testing.expect(std.mem.indexOf(u8, json, "\"text\":\"fn\",\"kind\":\"KW_FN\"") != null);
    // A builtin type.
    try testing.expect(std.mem.indexOf(u8, json, "\"name\":\"i64\"") != null);
    // A diagnostic with its canonical docs URL.
    try testing.expect(std.mem.indexOf(u8, json, "\"code\":\"LEX010\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "https://docs.q64.dev/diagnostics/LEX010") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"qube\":null") != null);
}

test "emitQubeJson: hello-world public surface + header doc" {
    const src =
        \\// banner comment
        \\//! hello — entry point.
        \\
        \\fn main {
        \\    env.out("Hello, q64.")
        \\}
        \\
    ;
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try emitQubeJson(&aw.writer, testing.allocator, src, "hello.q");
    const json = aw.writer.buffered();

    try testing.expect(std.mem.indexOf(u8, json, "\"generated_for\":\"qube\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"file\":\"hello.q\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"module_doc\":\"hello — entry point.\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"fn\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"name\":\"main\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"signature\":\"fn main()\"") != null);
    // Tier (c) reserved block present and empty.
    try testing.expect(std.mem.indexOf(u8, json, "\"effects\":[]") != null);
}

test "emitQubeJson: documented pub fn with params and return" {
    const src =
        \\//! lib header.
        \\
        \\//! Adds two integers.
        \\pub fn add(a: i64, b: i64) -> i64 { a + b }
        \\
    ;
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try emitQubeJson(&aw.writer, testing.allocator, src, "lib.q");
    const json = aw.writer.buffered();

    try testing.expect(std.mem.indexOf(u8, json, "\"visibility\":\"pub\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"doc\":\"Adds two integers.\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"signature\":\"fn add(a: i64, b: i64) -> i64\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"name\":\"a\",\"mode\":null,\"type\":\"i64\"") != null);
}
