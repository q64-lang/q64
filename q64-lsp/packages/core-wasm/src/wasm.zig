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

/// Hover: `{ "contents": "<kind> <name>" }` for the symbol under `off`
/// (e.g. `"fn greet"`), or `{ "contents": null }` when nothing names a
/// top-level symbol there. Returns 0 only on allocation failure.
export fn q64_hover(src_ptr: [*]const u8, src_len: usize, off: u32) u64 {
    return hoverInner(src_ptr[0..src_len], off) catch 0;
}

fn hoverInner(source: []const u8, off: u32) !u64 {
    var arena_state = std.heap.ArenaAllocator.init(host_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const none = "{\"contents\":null}";
    const result = try parse.parse(arena, source, "buffer.q");
    const sf = ast.SourceFile.cast(result.root) orelse return ownJson(none);
    const tok = identAtOffset(result.root, off) orelse return ownJson(none);

    var table = try sema.build(arena, sf);
    defer table.deinit();
    const sym = table.lookup(tok.text) orelse return ownJson(none);

    const json = try std.fmt.allocPrint(arena, "{{\"contents\":\"{s} {s}\"}}", .{ sym.kind.label(), sym.name });
    return ownJson(json);
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

    const none = "{\"found\":false}";
    const result = try parse.parse(arena, source, "buffer.q");
    const sf = ast.SourceFile.cast(result.root) orelse return ownJson(none);
    const tok = identAtOffset(result.root, off) orelse return ownJson(none);

    var table = try sema.build(arena, sf);
    defer table.deinit();
    const sym = table.lookup(tok.text) orelse return ownJson(none);

    const json = try std.fmt.allocPrint(arena, "{{\"found\":true,\"offset\":{d},\"len\":{d}}}", .{ sym.offset, sym.name.len });
    return ownJson(json);
}
