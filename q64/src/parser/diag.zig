//! Diagnostic envelope construction. Matches the JSON shape in
//! spec/diagnostics.md.
//!
//! This module is the bridge between in-pass diagnostic emission
//! (lex.zig / parse.zig produce raw `{code, offset}` pairs) and the
//! envelope every q64 binary prints on stderr.
//!
//! v0 scope: writes the minimal envelope — `ok` + `diagnostics[]`
//! with `code`, `severity`, `message`, and `location`. Labels,
//! notes, and repair are left unfilled until the passes that
//! produce them land.

const std = @import("std");

pub const Severity = enum {
    err, // emitted as "error" — `error` is a Zig keyword
    warning,
    note,
    help,
    internal,

    pub fn toString(self: Severity) []const u8 {
        return switch (self) {
            .err => "error",
            .warning => "warning",
            .note => "note",
            .help => "help",
            .internal => "internal",
        };
    }
};

pub const Diagnostic = struct {
    code: []const u8,
    severity: Severity,
    message: []const u8,
    file: []const u8,
    offset: u32,
};

/// Line-break index built once per file; converts byte offsets to
/// `(line, col)` in O(log n).
pub const LineIndex = struct {
    breaks: []const u32,
    allocator: std.mem.Allocator,

    pub fn build(allocator: std.mem.Allocator, source: []const u8) !LineIndex {
        var list: std.ArrayList(u32) = .empty;
        defer list.deinit(allocator);
        try list.append(allocator, 0); // line 1 starts at offset 0
        var i: u32 = 0;
        while (i < source.len) : (i += 1) {
            if (source[i] == '\n') try list.append(allocator, i + 1);
        }
        return .{ .breaks = try list.toOwnedSlice(allocator), .allocator = allocator };
    }

    pub fn deinit(self: LineIndex) void {
        self.allocator.free(self.breaks);
    }

    /// 1-based line and column.
    pub fn locate(self: LineIndex, offset: u32) struct { line: u32, col: u32 } {
        // Find the largest break index whose value is <= offset.
        var lo: usize = 0;
        var hi: usize = self.breaks.len;
        while (lo + 1 < hi) {
            const mid = (lo + hi) / 2;
            if (self.breaks[mid] <= offset) lo = mid else hi = mid;
        }
        const line = @as(u32, @intCast(lo + 1));
        const col = offset - self.breaks[lo] + 1;
        return .{ .line = line, .col = col };
    }
};

/// Canonical host the compiler points diagnostic URLs at. Each code's
/// documentation page lives at `<diagnostics_base>/<CODE>` — the page the
/// docs site generates from this same registry (spec/q64-cli.md §"explain").
pub const diagnostics_base = "https://docs.q64.dev/diagnostics";

/// One row of the diagnostics registry — the single source of truth shared by
/// the emitter (`messageFor`), `q64 explain`, and `q64 doc --json`. Enriching a
/// diagnostic (subsystem, future summary/examples) happens here, once.
pub const CodeInfo = struct {
    code: []const u8,
    subsystem: []const u8,
    severity: Severity,
    message: []const u8,
    /// One or two sentences explaining the diagnostic and how to resolve it.
    /// Surfaced by `q64 explain`, `q64 doc --json`, and the docs pages. May be
    /// `""` for codes whose prose hasn't been written yet.
    summary: []const u8 = "",
};

/// Look up the canonical short-message for a diagnostic code.
/// Returns `""` for unknown codes — the caller is responsible for
/// supplying a message in that case.
pub fn messageFor(code: []const u8) []const u8 {
    inline for (codes) |entry| {
        if (std.mem.eql(u8, entry.code, code)) return entry.message;
    }
    return "";
}

/// The full registry entry for a code, or `null` if unknown. Used by
/// `q64 explain` (single-row lookup) and `q64 doc --json` (full iteration).
pub fn lookup(code: []const u8) ?CodeInfo {
    inline for (codes) |entry| {
        if (std.mem.eql(u8, entry.code, code)) return entry;
    }
    return null;
}

/// The subsystem a code belongs to, derived from its letter prefix. The
/// registry stores it explicitly (above), but this also classifies codes the
/// registry hasn't enumerated yet (e.g. a freshly emitted `TYP…`).
pub fn subsystemFor(code: []const u8) []const u8 {
    if (std.mem.startsWith(u8, code, "LEX")) return "Lexical";
    if (std.mem.startsWith(u8, code, "PAR")) return "Parser";
    if (std.mem.startsWith(u8, code, "NAM")) return "Names";
    if (std.mem.startsWith(u8, code, "TYP")) return "Type checking";
    if (std.mem.startsWith(u8, code, "EFF")) return "Effects";
    if (std.mem.startsWith(u8, code, "REG")) return "Regions";
    if (std.mem.startsWith(u8, code, "STR")) return "Streams";
    if (std.mem.startsWith(u8, code, "CONC")) return "Concurrency";
    if (std.mem.startsWith(u8, code, "Q9")) return "Internal";
    return "Other";
}

/// Stable diagnostics registry. Mirrors the rows in each spec's "Diagnostic
/// codes" section. New codes append; numbers are never reused. `severity` is
/// the canonical level the code is emitted at. (Title/summary/examples for the
/// web pages land here as the per-spec prose is filled in.)
pub const codes = [_]CodeInfo{
    // Lexical
    .{ .code = "LEX010", .subsystem = "Lexical", .severity = .err, .message = "stray carriage return", .summary = "A bare carriage return (CR) was found in the source. q64 source uses Unix line endings (LF, `\\n`); a lone `\\r` not paired with `\\n` is rejected. Re-save the file with LF line endings." },
    .{ .code = "LEX020", .subsystem = "Lexical", .severity = .err, .message = "unknown string-literal prefix", .summary = "An identifier directly preceding a string literal was read as a typed-string prefix (e.g. `url\"…\"`), but it isn't a recognized prefix. Check the spelling, or add a space if you didn't mean a typed string." },
    .{ .code = "LEX021", .subsystem = "Lexical", .severity = .err, .message = "unexpected `&` in type position", .summary = "`&` is not q64's reference sigil. References are written `ref T` (and `ref`/`out`/`move` parameter modes), not `&T`. See spec/types.md." },
    .{ .code = "LEX030", .subsystem = "Lexical", .severity = .err, .message = "unterminated string literal", .summary = "A string literal opened with `\"` but the line or file ended before a closing `\"`. Add the closing quote, or use a raw string (`r\"…\"`) if the content spans forms the lexer can't see through." },
    .{ .code = "LEX031", .subsystem = "Lexical", .severity = .err, .message = "char literals are not supported", .summary = "q64 has no character-literal type, so `'a'` is invalid. Use a one-character string `\"a\"`, or a numeric code point if you need the integer value." },
    .{ .code = "LEX040", .subsystem = "Lexical", .severity = .err, .message = "unexpected character", .summary = "A character that isn't part of any q64 token appeared in the source. Remove it or check for a stray/non-ASCII symbol." },
    // Parser
    .{ .code = "PAR040", .subsystem = "Parser", .severity = .err, .message = "generic vs less-than ambiguity", .summary = "A `<` following a name was ambiguous between a generic-argument list (`Vec<T>`) and a less-than comparison (`a < b`). Add parentheses to force the comparison, or whitespace/turbofish per the grammar (spec/grammar.md)." },
    // Names
    .{ .code = "NAM001", .subsystem = "Names", .severity = .err, .message = "unknown module", .summary = "An `import` names a module the compiler can't resolve. Check the dotted module path and that the dependency is declared in `qube.json5` (or provided via `--module`). See spec/modules.md." },
    .{ .code = "NAM002", .subsystem = "Names", .severity = .err, .message = "import path escapes qube", .summary = "A quoted relative import (e.g. `\"../other/lib.q\"`) resolves outside the qube's own source tree. Imports may not escape the qube; depend on the other qube by its module path instead." },
    .{ .code = "NAM003", .subsystem = "Names", .severity = .err, .message = "wildcard import is forbidden", .summary = "Glob imports like `import foo.*` are not allowed — they make the imported surface implicit. List names explicitly (`import foo.{a, b}`) or import the namespace and qualify uses." },
    .{ .code = "NAM004", .subsystem = "Names", .severity = .err, .message = "selective import combined with alias", .summary = "A selective import (`import foo.{a, b}`) cannot also carry an `as` alias — the two binding forms are mutually exclusive. Use one or the other." },
    .{ .code = "NAM005", .subsystem = "Names", .severity = .err, .message = "name collision in import scope", .summary = "Two imports bind the same name into one scope, so a use would be ambiguous. Rename one binding with `as`." },
    .{ .code = "NAM006", .subsystem = "Names", .severity = .err, .message = "name is private to its qube", .summary = "The imported name exists in the target module but isn't `pub`, so it's private to its qube. Only `pub` declarations are importable; export it or import a different name." },
    .{ .code = "NAM007", .subsystem = "Names", .severity = .err, .message = "sub-module not re-exported", .summary = "A sub-module isn't re-exported by its parent, so it can't be reached through that path. Add a `pub use` re-export in the parent, or import the sub-module by its own path. See spec/modules.md." },
    .{ .code = "NAM008", .subsystem = "Names", .severity = .err, .message = "re-export cycle", .summary = "The `pub use` re-exports form a cycle (A re-exports B which re-exports A). Break the loop so the export graph is acyclic." },
    .{ .code = "NAM009", .subsystem = "Names", .severity = .err, .message = "block `pub` form is forbidden", .summary = "A `pub { … }` block applying visibility to a group of items is not allowed. Mark each item `pub` individually." },
    .{ .code = "NAM010", .subsystem = "Names", .severity = .err, .message = "unknown name in source module", .summary = "A name referenced here is neither declared in this module nor brought into scope by an `import`. Check for a typo, a missing `import`, or a name that isn't `pub` in its module." },
    .{ .code = "NAM011", .subsystem = "Names", .severity = .err, .message = "dash in bare module path", .summary = "A bare (dotted) module path segment contains `-`, but segments are snake_case identifiers (`[a-z][a-z0-9_]*`). Rename the segment, or use a quoted relative path for a file whose name contains a dash." },
    // Type checking (emitted by the sema check pass)
    .{ .code = "TYP042", .subsystem = "Type checking", .severity = .err, .message = "implicit numeric conversion is forbidden", .summary = "An arithmetic site mixes two different numeric types (e.g. `i32 + i64`). q64 never converts implicitly; cast one side explicitly so the widths and signedness are visible. See spec/types.md §arithmetic." },
    .{ .code = "TYP051", .subsystem = "Type checking", .severity = .err, .message = "integer used as bool", .summary = "An `if`/`while` condition is an integer, but conditions require `bool` (e.g. `if 1 { … }`). Write the comparison out (`if x != 0`). See spec/types.md §bool." },
    .{ .code = "TYP061", .subsystem = "Type checking", .severity = .err, .message = "wrong number of call arguments", .summary = "A call supplies more or fewer arguments than the function declares. Match the declaration's parameter list (generic-argument count is TYP100). See spec/types.md." },
    .{ .code = "TYP062", .subsystem = "Type checking", .severity = .err, .message = "non-exhaustive match", .summary = "A `match` over an enum covers neither every variant nor a `_` arm. Add the missing variant arms or a `_` default. See spec/types.md." },
    .{ .code = "TYP300", .subsystem = "Type checking", .severity = .err, .message = "`try` requires `Result` return type", .summary = "`try` propagates an `Err` to the enclosing function, so that function must return `Result<_, _>`. Change the return type, or handle the value with `match`. See spec/errors.md §\"Type-system rules\"." },
    .{ .code = "TYP305", .subsystem = "Type checking", .severity = .err, .message = "postfix `?` is not an error operator", .summary = "q64 propagates errors with the `try` keyword, not a `?` sigil (spec/errors.md §\"why a keyword not a sigil\"). Write `try expr` instead of `expr?`. Note `T?` is still the `Option<T>` type sugar." },
    .{ .code = "TYP200", .subsystem = "Type checking", .severity = .err, .message = "type does not fit face", .summary = "A generic call requires `T: Face`, but the inferred type has no fit for that face. Declare `fit Type : Face { … }`, or pass a type that fits. See spec/faces.md §\"Diagnostic codes\"." },
    .{ .code = "TYP201", .subsystem = "Type checking", .severity = .err, .message = "wrong fit form for single-param face", .summary = "A single-parameter face (its methods take `self`) must be fit with the implementer first: `fit Type : Face`, not `fit Face<Type>`. See spec/faces.md §\"Fit declaration\"." },
    .{ .code = "TYP202", .subsystem = "Type checking", .severity = .err, .message = "wrong fit form for multi-param face", .summary = "A multi-parameter face (no `self`; every type a named parameter) must be fit positionally: `fit Face<T1, T2>`, with no implementer prefix. See spec/faces.md §\"Fit declaration\"." },
    .{ .code = "ENV050", .subsystem = "Capabilities", .severity = .err, .message = "`main` Form 2 ends without return", .summary = "A `fn main -> Result<…>` falls off the end without an explicit `return` or a `Result` tail expression. End the body with `Ok(())` (or a `return`). See spec/env.md §\"main signature\"." },
    .{ .code = "ENV052", .subsystem = "Capabilities", .severity = .err, .message = "`main` signature mismatch", .summary = "`main` must be one of the four permitted shapes: `fn main`, `fn main -> Result<…>`, `fn main(env: Env)`, or `fn main(env: Env) -> Result<…>`. Adjust the parameters or return type. See spec/env.md §\"main signature\"." },
    .{ .code = "ENV056", .subsystem = "Capabilities", .severity = .err, .message = "`env` reference from `@pure` function", .summary = "A `@pure` function references the ambient `env` (`env.out`, `env.fs.read`, …); ambient capability use is incompatible with purity. Drop `@pure`, or thread the capability explicitly. See spec/env.md §\"Diagnostic codes\"." },
    .{ .code = "ENV055", .subsystem = "Capabilities", .severity = .err, .message = "`with_capabilities(use:)` field not on `Env`", .summary = "A key in the `use: { … }` map doesn't name a field of `Env` (`out`, `err`, `net`, `fs`, `kv`, `time`, `random`, `audio`, `midi`, `ai`, `ui`, `exit`, `args`, `envvars`). Use a real sub-capability name. See spec/env.md §\"Overriding the ambient binding\"." },
    .{ .code = "TYP108", .subsystem = "Type checking", .severity = .err, .message = "non-default generic parameter after a default", .summary = "Once a generic parameter declares a default (`T = i64`), every parameter after it must also have a default — a required parameter can't follow a defaulted one. Reorder the parameters or give the later one a default. See spec/generics.md." },
    .{ .code = "EFF120", .subsystem = "Effects", .severity = .err, .message = "contradictory effects declared", .summary = "A function's declared effect set is internally contradictory — an assert forbids a capability it's combined with (e.g. `@realtime + @io`, `@pure + @network`). `@realtime` permits only the realtime-safe `@time`/`@random`/`@audio`. Drop the conflicting marker. See spec/effects.md §\"Effect annotations on functions\"." },
    .{ .code = "EFF160", .subsystem = "Effects", .severity = .err, .message = "`@cancel` without `ctx` parameter", .summary = "A function declared `@cancel` observes cancellation, so it must take a `ctx: Cancel` parameter. Add `ctx: Cancel` to the signature, or drop `@cancel` if the function doesn't observe `ctx.cancelled()`. See spec/effects.md §\"`@cancel` and `@uncancellable`\"." },
    .{ .code = "EFF140", .subsystem = "Effects", .severity = .err, .message = "user effect shadows a core marker", .summary = "A `pub effect @<name>` reuses the name of a blessed core marker (e.g. `@realtime`, `@io`, `@pure`). Pick a non-colliding name for the user-defined effect. See spec/effects.md §\"User-defined effects\"." },
    .{ .code = "EFF141", .subsystem = "Effects", .severity = .err, .message = "invalid effect name", .summary = "A user-defined effect name must match `^@[a-z][a-z_]*$` — lowercase letters and underscores, leading letter (e.g. `@logging`, `@audit`). See spec/effects.md §\"User-defined effects\"." },
    .{ .code = "REG020", .subsystem = "Regions", .severity = .err, .message = "linear pointer in `@managed` struct", .summary = "A `@managed` struct (WasmGC) may only hold managed or `Copy`-style value fields. A `ref` into linear memory can't be a field — store a managed reference (`ManagedBox<T>`, `Vec<T, Managed>`) or a value type instead. See spec/memory.md §\"Marking a struct `@managed`\"." },
    .{ .code = "CONC050", .subsystem = "Concurrency", .severity = .err, .message = "channel policy required", .summary = "`channel<T>(…)` has no default policy — pass one: `channel<T>(policy: Backpressure, capacity: N)` (or `LatestValue` / `RingBuffer` / `Unbounded`). See spec/concurrency.md §\"Channel construction\"." },
    .{ .code = "CONC053", .subsystem = "Concurrency", .severity = .err, .message = "`for x in rx` over cancel-aware receiver without ctx", .summary = "Iterating a cancel-aware receiver (`Backpressure` / `LatestValue`) suspends on `recv`, which needs a `ctx: Cancel` in scope. Add a `ctx: Cancel` parameter, or use a non-cancel-aware policy. See spec/concurrency.md §\"`for x in rx` loop form\"." },
    .{ .code = "CONC020", .subsystem = "Concurrency", .severity = .err, .message = "`tell` on a reply-bearing handler", .summary = "`c.tell(Msg)` is fire-and-forget, but `Msg`'s handler declares a reply (`handle Msg -> T`). Use `c.ask(Msg)` to receive the `Future<T>`. See spec/concurrency.md §\"`tell` vs `ask`\"." },
    .{ .code = "STR060", .subsystem = "Streams", .severity = .err, .message = "`@realtime` × `|>` effect violation", .summary = "A `@realtime` stage is piped into a non-`@realtime` stage (the realtime output would feed a consumer that can block), or a buffered stream feeds a `@realtime` stage. Keep the realtime segment contiguous, or insert an explicit boundary. See spec/streams.md §\"Effects on stages\"." },
    .{ .code = "STR051", .subsystem = "Streams", .severity = .err, .message = "`pre()` on `Event<T>`", .summary = "`Event<T>` is pointwise and has no previous-tick value, so `.pre()` (the one-tick feedback delay) doesn't apply. `pre()` is for `Signal<T>` feedback cycles. See spec/streams.md §\"`pre()` for feedback cycles\"." },
    .{ .code = "REG050", .subsystem = "Regions", .severity = .err, .message = "unknown transfer verb", .summary = "The only cross-region/cross-heap move is `transfer(to: …)`. `copy_to`, `pin_to`, and `intern` are not in the language — rewrite the call as `value.transfer(to: <region>)`. See spec/memory.md §\"Cross-region transfers\"." },
};

/// Emit a JSON envelope per spec/diagnostics.md §"Envelope shape"
/// to `writer`. `ok` is true iff `diagnostics` contains no
/// error-severity entries.
pub fn emitJson(
    writer: *std.Io.Writer,
    source: []const u8,
    diagnostics: []const Diagnostic,
    allocator: std.mem.Allocator,
) !void {
    const idx = try LineIndex.build(allocator, source);
    defer idx.deinit();

    var ok = true;
    for (diagnostics) |d| if (d.severity == .err) {
        ok = false;
        break;
    };

    try writer.print("{{\"ok\":{s},\"diagnostics\":[", .{if (ok) "true" else "false"});
    for (diagnostics, 0..) |d, i| {
        if (i > 0) try writer.writeByte(',');
        const loc = idx.locate(d.offset);
        try writer.writeAll("{\"code\":\"");
        try writer.writeAll(d.code);
        try writer.writeAll("\",\"severity\":\"");
        try writer.writeAll(d.severity.toString());
        try writer.writeAll("\",\"message\":");
        try writeJsonString(writer, d.message);
        try writer.writeAll(",\"location\":{\"file\":");
        try writeJsonString(writer, d.file);
        try writer.print(",\"line\":{d},\"col\":{d}}}}}", .{ loc.line, loc.col });
    }
    try writer.writeAll("]}");
    try writer.writeByte('\n');
}

/// Write `s` as a JSON string literal (with surrounding quotes), escaping the
/// control characters and `"`/`\`. Shared by the diagnostics envelope and
/// `q64 doc --json` so both encode strings identically.
pub fn writeJsonString(writer: *std.Io.Writer, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0...0x08, 0x0b, 0x0c, 0x0e...0x1f => try writer.print("\\u{x:0>4}", .{c}),
        else => try writer.writeByte(c),
    };
    try writer.writeByte('"');
}

// =====================================================================
// Tests
// =====================================================================

const testing = std.testing;

test "line index: basic two-line file" {
    const src = "abc\ndef\n";
    const idx = try LineIndex.build(testing.allocator, src);
    defer idx.deinit();

    try testing.expectEqual(@as(u32, 1), idx.locate(0).line);
    try testing.expectEqual(@as(u32, 1), idx.locate(0).col);
    try testing.expectEqual(@as(u32, 1), idx.locate(2).line);
    try testing.expectEqual(@as(u32, 3), idx.locate(2).col);
    try testing.expectEqual(@as(u32, 2), idx.locate(4).line);
    try testing.expectEqual(@as(u32, 1), idx.locate(4).col);
    try testing.expectEqual(@as(u32, 2), idx.locate(6).line);
    try testing.expectEqual(@as(u32, 3), idx.locate(6).col);
}

test "messageFor: known and unknown codes" {
    try testing.expectEqualStrings("stray carriage return", messageFor("LEX010"));
    try testing.expectEqualStrings("", messageFor("XYZ999"));
}

test "emitJson: ok envelope" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try emitJson(&aw.writer, "", &.{}, testing.allocator);
    try testing.expectEqualStrings("{\"ok\":true,\"diagnostics\":[]}\n", aw.writer.buffered());
}

test "emitJson: single LEX010 envelope" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const src = "fn main\r{}\n";
    const diags = [_]Diagnostic{.{
        .code = "LEX010",
        .severity = .err,
        .message = messageFor("LEX010"),
        .file = "stray.q",
        .offset = 7,
    }};
    try emitJson(&aw.writer, src, &diags, testing.allocator);
    const buf_items = aw.writer.buffered();
    // Spot-check the envelope rather than full byte match.
    try testing.expect(std.mem.indexOf(u8, buf_items, "\"ok\":false") != null);
    try testing.expect(std.mem.indexOf(u8, buf_items, "\"code\":\"LEX010\"") != null);
    try testing.expect(std.mem.indexOf(u8, buf_items, "\"severity\":\"error\"") != null);
    try testing.expect(std.mem.indexOf(u8, buf_items, "\"file\":\"stray.q\"") != null);
    try testing.expect(std.mem.indexOf(u8, buf_items, "\"line\":1") != null);
    try testing.expect(std.mem.indexOf(u8, buf_items, "\"col\":8") != null);
}
