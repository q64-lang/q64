//! Wasm ABI over q64's analysis core.
//!
//! The host (the TypeScript LSP server, or any browser / Worker) drives
//! this module through a few exports. All language intelligence lives in
//! q64's Zig modules (`parser`, `sema`); this file is only the boundary
//! that turns "bytes in, JSON out" into calls on them.
//!
//! Memory protocol (every query shares it):
//!   1. `q64_alloc(len)` → ptr. Host writes `len` source bytes there.
//!   2. A query — `q64_diagnose(ptr, len)`, `q64_hover(ptr, len, off)`,
//!      `q64_definition(ptr, len, off)` — returns a packed result:
//!      (out_ptr << 32) | out_len, a UTF-8 JSON payload.
//!   3. Host reads [out_ptr .. out_ptr+out_len], then frees BOTH buffers
//!      with `q64_free(ptr, len)`.
//!
//! Positional queries take a UTF-8 *byte* offset into the source (the host
//! maps an editor position to bytes). They report the definition's byte
//! offset + name length back; the host maps those to editor coordinates.
//!
//! wasm32 pointers are 32-bit, so packing ptr+len into a u64 is lossless.

const std = @import("std");
const parser = @import("parser");
const sema = @import("sema");
const parse = parser.parse;
const diag = parser.diag;
const ast = parser.ast;
const cst = parser.cst;
const lex = parser.lex;

/// Caller-facing buffers (the source the host writes, and the JSON we hand
/// back) are allocated from the page allocator so their lifetime is
/// independent of any per-call arena and `q64_free` can release them.
const host_allocator = std.heap.page_allocator;

export fn q64_alloc(len: usize) ?[*]u8 {
    const buf = host_allocator.alloc(u8, len) catch return null;
    return buf.ptr;
}

export fn q64_free(ptr: [*]u8, len: usize) void {
    host_allocator.free(ptr[0..len]);
}

/// Copy `json` into a host-owned buffer that outlives the per-call arena and
/// pack its (ptr, len) into the u64 the host unpacks. The host frees it via
/// `q64_free`. Every query returns through here.
fn ownJson(json: []const u8) !u64 {
    const out = try host_allocator.alloc(u8, json.len);
    @memcpy(out, json);
    const ptr_bits: u64 = @intFromPtr(out.ptr);
    return (ptr_bits << 32) | @as(u64, out.len);
}

/// The innermost IDENT token whose byte span contains `off`, or null. Walks
/// the CST depth-first; only identifiers can name a symbol, so keywords,
/// punctuation, and trivia are skipped.
fn identAtOffset(node: *const cst.Node, off: u32) ?cst.Token {
    for (node.children) |child| switch (child) {
        .token => |t| {
            const end = t.offset + @as(u32, @intCast(t.text.len));
            if (t.kind == .IDENT and off >= t.offset and off < end) return t;
        },
        .node => |n| if (identAtOffset(n, off)) |found| return found,
    };
    return null;
}

/// Parse `src` and return a JSON diagnostic envelope. Returns 0 on
/// allocation failure (the host treats 0 as "no result").
export fn q64_diagnose(src_ptr: [*]const u8, src_len: usize) u64 {
    return diagnoseInner(src_ptr[0..src_len]) catch 0;
}

fn diagnoseInner(source: []const u8) !u64 {
    // Everything transient — the parse tree, the symbol table, the type store,
    // the diagnostics, the JSON builder's scratch — lives in a per-call arena
    // that is freed on return. So the per-pass `deinit`s below free back into the
    // arena (a no-op); the arena is the single owner.
    var arena_state = std.heap.ArenaAllocator.init(host_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const path = "buffer.q";
    const result = try parse.parse(arena, source, path);

    // Collect parse diagnostics, then the semantic passes — the same order and
    // sources as the native `q64 check` pipeline (q64/src/main.zig), so the
    // editor surfaces the same LEX/PAR/NAM/TYP/EFF/REG diagnostics the compiler
    // does. The one omission is NAM002 (a relative import escaping the qube): it
    // walks the filesystem for the qube root, and the language server has no disk
    // — it only ever sees the single buffer the host hands it.
    var all: std.ArrayList(diag.Diagnostic) = .empty;
    try all.appendSlice(arena, result.diagnostics);

    if (ast.SourceFile.cast(result.root)) |sf| {
        // Name resolution (NAM*): file-level symbol table + import-scope checks.
        var table = try sema.build(arena, sf);
        defer table.deinit();
        try all.appendSlice(arena, try sema.fileDiagnostics(arena, &table, path));

        // The fit registry powers the fit-form checks (TYP200/201/202).
        var fitreg = try sema.fits.build(arena, sf);
        defer fitreg.deinit();

        // The A4 check pass (TYP*/EFF*/REG*), typed against the signature table.
        var store = try sema.types.TypeStore.init(arena);
        defer store.deinit();
        var sigs = try sema.types.collectSignatures(&store, &table, sf);
        defer sigs.deinit();
        const check_diags = try sema.check.checkFile(arena, sf, &table, &store, &sigs, &fitreg);

        // check + fit diagnostics carry only a code + byte offset; widen them to
        // the full envelope shape (severity/message/file) exactly as main.zig does.
        for (check_diags) |cd| try all.append(arena, .{
            .code = cd.code,
            .severity = .err,
            .message = diag.messageFor(cd.code),
            .file = path,
            .offset = cd.offset,
        });
        for (fitreg.diags.items) |fd| try all.append(arena, .{
            .code = fd.code,
            .severity = .err,
            .message = diag.messageFor(fd.code),
            .file = path,
            .offset = fd.offset,
        });
    }

    var aw: std.Io.Writer.Allocating = .init(arena);
    try diag.emitJson(&aw.writer, source, all.items, arena);
    return ownJson(aw.writer.buffered());
}

/// What an identifier under the cursor resolves to: a rendered `kind` label
/// (`"fn"`, `"struct"`, `"local"`, …), the symbol's name, and the byte offset
/// of its declaration. Definition uses `def_offset`. Hover renders `signature`
/// when present (a function's full `fn name(params) -> ret`), else `kind name`.
const SymInfo = struct {
    kind: []const u8,
    name: []const u8,
    def_offset: u32,
    signature: ?[]const u8 = null,
};

/// The source text of a top-level function's signature — everything from `fn`
/// (or `pub fn …`) up to, but not including, the body block. Reproduced
/// verbatim from the lossless CST, so it shows exactly as written
/// (`fn add(a: i64, b: i64) -> i64`). `name_offset` is the symbol's name token,
/// used to find the matching declaration. Null if no such function is found.
fn fnSignature(arena: std.mem.Allocator, sf: ast.SourceFile, name_offset: u32) !?[]const u8 {
    var it = sf.items();
    while (it.next()) |item| switch (item) {
        .fn_decl => |fd| {
            const nt = fd.name() orelse continue;
            if (nt.offset != name_offset) continue;
            var buf: std.ArrayList(u8) = .empty;
            for (fd.cst.children) |c| switch (c) {
                .node => |n| {
                    if (n.kind == .BLOCK) break; // stop at the body
                    try cst.serialize(n, arena, &buf);
                },
                .token => |t| try buf.appendSlice(arena, t.text),
            };
            return std.mem.trim(u8, buf.items, " \t\r\n");
        },
        else => {},
    };
    return null;
}

/// Write `s` as a JSON string literal (quotes included), escaping `"` and `\`
/// and folding control characters to spaces. Signatures can carry a quote (a
/// string-typed param default), so hover contents must be escaped, not
/// concatenated raw.
fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        0...0x1f => try w.writeByte(' '),
        else => try w.writeByte(ch),
    };
    try w.writeByte('"');
}

/// Resolve the identifier at byte `off`. Locals win over file-level symbols
/// (a local shadows a same-named top-level), matching q64's scoping — so we
/// consult the body resolution first, then the file symbol table.
fn symbolAt(arena: std.mem.Allocator, source: []const u8, off: u32) !?SymInfo {
    const result = try parse.parse(arena, source, "buffer.q");
    const sf = ast.SourceFile.cast(result.root) orelse return null;
    const tok = identAtOffset(result.root, off) orelse return null;

    const table = try sema.build(arena, sf);
    const res = try sema.resolve.resolveBodies(arena, sf, &table);

    // A local: the cursor is on a use of a binding, or on the binding itself.
    for (res.locals.items) |l| {
        if (tok.offset == l.offset or tok.offset == l.def_offset) {
            return .{ .kind = "local", .name = l.name, .def_offset = l.def_offset };
        }
    }
    // Otherwise a file-level symbol (fn / struct / enum / const / …).
    if (table.lookup(tok.text)) |sym| {
        const sig = if (sym.kind == .function) try fnSignature(arena, sf, sym.offset) else null;
        return .{ .kind = sym.kind.label(), .name = sym.name, .def_offset = sym.offset, .signature = sig };
    }
    return null;
}

/// Hover: `{ "contents": "<kind> <name>" }` for the symbol under `off`
/// (e.g. `"fn greet"`, `"local x"`), or `{ "contents": null }`. Returns 0
/// only on allocation failure.
export fn q64_hover(src_ptr: [*]const u8, src_len: usize, off: u32) u64 {
    return hoverInner(src_ptr[0..src_len], off) catch 0;
}

fn hoverInner(source: []const u8, off: u32) !u64 {
    var arena_state = std.heap.ArenaAllocator.init(host_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const info = (try symbolAt(arena, source, off)) orelse return ownJson("{\"contents\":null}");
    // A function shows its full signature; everything else shows `kind name`.
    const text = info.signature orelse
        try std.fmt.allocPrint(arena, "{s} {s}", .{ info.kind, info.name });

    var aw: std.Io.Writer.Allocating = .init(arena);
    try aw.writer.writeAll("{\"contents\":");
    try writeJsonString(&aw.writer, text);
    try aw.writer.writeByte('}');
    return ownJson(aw.writer.buffered());
}

/// Go-to-definition: `{ "found": true, "offset": <byte>, "len": <bytes> }`
/// locating the declaration of the symbol under `off`, or `{ "found": false }`.
/// The host turns the byte span into an editor range. Returns 0 only on
/// allocation failure.
export fn q64_definition(src_ptr: [*]const u8, src_len: usize, off: u32) u64 {
    return definitionInner(src_ptr[0..src_len], off) catch 0;
}

fn definitionInner(source: []const u8, off: u32) !u64 {
    var arena_state = std.heap.ArenaAllocator.init(host_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const info = (try symbolAt(arena, source, off)) orelse return ownJson("{\"found\":false}");
    const json = try std.fmt.allocPrint(arena, "{{\"found\":true,\"offset\":{d},\"len\":{d}}}", .{ info.def_offset, info.name.len });
    return ownJson(json);
}

/// Document symbols: the file outline as
/// `{ "symbols": [ { "name", "kind", "offset", "len" }, … ] }` in declaration
/// order — every top-level declaration (fn / struct / enum / type / const /
/// state / face / screen / actor / graph). `offset`/`len` are the name token's
/// byte span; the host maps them to editor ranges. Returns 0 only on
/// allocation failure.
export fn q64_symbols(src_ptr: [*]const u8, src_len: usize) u64 {
    return symbolsInner(src_ptr[0..src_len]) catch 0;
}

fn symbolsInner(source: []const u8) !u64 {
    var arena_state = std.heap.ArenaAllocator.init(host_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try parse.parse(arena, source, "buffer.q");
    const sf = ast.SourceFile.cast(result.root) orelse return ownJson("{\"symbols\":[]}");
    const table = try sema.build(arena, sf);

    var aw: std.Io.Writer.Allocating = .init(arena);
    try aw.writer.writeAll("{\"symbols\":[");
    var first = true;
    for (table.syms.items) |s| {
        // `fit` and `import_binding` are introspection entries, not outline
        // declarations (a fit's name is its type's; imports aren't decls).
        if (s.kind == .fit or s.kind == .import_binding) continue;
        if (!first) try aw.writer.writeByte(',');
        first = false;
        try aw.writer.writeAll("{\"name\":");
        try writeJsonString(&aw.writer, s.name);
        try aw.writer.print(",\"kind\":\"{s}\",\"offset\":{d},\"len\":{d}}}", .{ s.kind.label(), s.offset, s.name.len });
    }
    try aw.writer.writeAll("]}");
    return ownJson(aw.writer.buffered());
}

/// Emit one completion item `{ "label": …, "kind": … }`, handling the
/// leading comma via `first`.
fn emitItem(w: *std.Io.Writer, first: *bool, label: []const u8, kind: []const u8) !void {
    if (!first.*) try w.writeByte(',');
    first.* = false;
    try w.writeAll("{\"label\":");
    try writeJsonString(w, label);
    try w.writeAll(",\"kind\":\"");
    try w.writeAll(kind);
    try w.writeAll("\"}");
}

/// Byte offset of the leftmost token under `node` (its start), or null if the
/// node has no tokens.
fn firstTokenOffset(node: *const cst.Node) ?u32 {
    for (node.children) |c| switch (c) {
        .token => |t| return t.offset,
        .node => |n| if (firstTokenOffset(n)) |o| return o,
    };
    return null;
}

/// The top-level function whose body contains byte `off`, or null. The CST is
/// lossless and contiguous, so a node's span is [firstToken, firstToken+textLen).
fn fnContaining(sf: ast.SourceFile, off: u32) ?ast.FnDecl {
    var it = sf.items();
    while (it.next()) |item| switch (item) {
        .fn_decl => |fd| {
            const body = fd.body() orelse continue;
            const start = firstTokenOffset(body.cst) orelse continue;
            const len: u32 = @intCast((cst.Element{ .node = body.cst }).textLen());
            if (off >= start and off <= start + len) return fd;
        },
        else => {},
    };
    return null;
}

/// Emit every `IDENT_PATTERN` binding under `node` as a `local` completion,
/// deduped via `seen`.
fn emitPatternLocals(
    node: *const cst.Node,
    w: *std.Io.Writer,
    first: *bool,
    seen: *std.StringHashMapUnmanaged(void),
    arena: std.mem.Allocator,
) !void {
    if (node.kind == .IDENT_PATTERN) {
        for (node.children) |c| switch (c) {
            .token => |t| if (t.kind == .IDENT) {
                const gop = try seen.getOrPut(arena, t.text);
                if (!gop.found_existing) try emitItem(w, first, t.text, "local");
            },
            .node => {},
        };
        return;
    }
    for (node.children) |c| switch (c) {
        .node => |n| try emitPatternLocals(n, w, first, seen, arena),
        .token => {},
    };
}

/// Add the locals of the function enclosing `off` — its params and every
/// `let`/pattern binding in its body — as `local` completions. Function-scoped,
/// so it may over-offer a binding from a sibling block or one declared below
/// the cursor; the client filters by prefix, and precise per-cursor scoping is
/// a future refinement.
fn appendLocals(
    w: *std.Io.Writer,
    first: *bool,
    arena: std.mem.Allocator,
    sf: ast.SourceFile,
    off: u32,
) !void {
    const fd = fnContaining(sf, off) orelse return;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    if (fd.params()) |ps| {
        var pit = ps.iter();
        while (pit.next()) |p| if (p.name()) |t| {
            const gop = try seen.getOrPut(arena, t.text);
            if (!gop.found_existing) try emitItem(w, first, t.text, "local");
        };
    }
    const body = fd.body() orelse return;
    try emitPatternLocals(body.cst, w, first, &seen, arena);
}

/// Completion: `{ "items": [ { "name"/"kind" }, … ] }` — the file's top-level
/// symbols plus the language keywords. The LSP client filters by the typed
/// prefix, so we offer the whole in-scope set rather than reading the partial
/// word. `off` is accepted for a future scope-aware locals pass. Returns 0
/// only on allocation failure.
export fn q64_complete(src_ptr: [*]const u8, src_len: usize, off: u32) u64 {
    return completeInner(src_ptr[0..src_len], off) catch 0;
}

fn completeInner(source: []const u8, off: u32) !u64 {
    var arena_state = std.heap.ArenaAllocator.init(host_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try parse.parse(arena, source, "buffer.q");

    var aw: std.Io.Writer.Allocating = .init(arena);
    try aw.writer.writeAll("{\"items\":[");
    var first = true;

    // Top-level declarations (skip `fit` — its label is a duplicate type name)
    // plus the locals of the function the cursor sits in.
    if (ast.SourceFile.cast(result.root)) |sf| {
        const table = try sema.build(arena, sf);
        for (table.syms.items) |s| {
            if (s.kind == .fit) continue;
            try emitItem(&aw.writer, &first, s.name, s.kind.label());
        }
        try appendLocals(&aw.writer, &first, arena, sf, off);
    }
    // The language keywords (authoritative list from the lexer).
    for (lex.keywords) |kw| try emitItem(&aw.writer, &first, kw.text, "keyword");

    try aw.writer.writeAll("]}");
    return ownJson(aw.writer.buffered());
}
