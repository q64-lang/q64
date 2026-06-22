//! Wasm ABI over q64's *codegen* core — the on-device compiler entry.
//!
//! This is the Option B compiler face (see `../../docs/browser-codegen.md`):
//! the whole pipeline (parse → sema → ir → emit) is compiled to `wasm32-wasi`
//! with Binaryen left **unlinked**, so every Binaryen C-API call is a wasm
//! import a JS host fills via `binaryen.js`. A WebView host writes `.q` source
//! into our linear memory and calls `q64_compile` to get back a core `.wasm`
//! module — no server, no subprocess.
//!
//! Memory protocol (mirrors `q64-lsp/packages/core-wasm`):
//!   1. `q64_alloc(len)` → ptr. Host writes `len` source bytes there.
//!   2. `q64_compile(ptr, len, wasm64)` → packed `(out_ptr << 32) | out_len`
//!      of the emitted core module, or `0` on failure. `q64_diagnostics`
//!      explains a failure (and surfaces warnings on success).
//!   3. `q64_diagnostics(ptr, len, wasm64)` → packed result whose `out` is a
//!      UTF-8 JSON diagnostic envelope (spec/diagnostics.md).
//!   4. Host reads `[out_ptr .. out_ptr+out_len]`, then frees every buffer it
//!      received (source + each result) with `q64_free(ptr, len)`.
//!
//! wasm32 pointers are 32-bit, so packing ptr+len into a u64 is lossless. The
//! emitted *module* may itself be wasm32 or wasm64 (the `wasm64` arg) — that is
//! the address space of the compiled program, independent of this host wasm.

const std = @import("std");
const emit = @import("emit");
const parser = @import("parser");
const sema = @import("sema");
const parse = parser.parse;
const diag = parser.diag;

/// Caller-facing buffers (the source the host writes, the emitted wasm, and the
/// JSON envelope) come from the page allocator so their lifetime is independent
/// of any per-call arena and `q64_free` can release them.
const host_allocator = std.heap.page_allocator;

export fn q64_alloc(len: usize) ?[*]u8 {
    if (len == 0) return null;
    const buf = host_allocator.alloc(u8, len) catch return null;
    return buf.ptr;
}

export fn q64_free(ptr: [*]u8, len: usize) void {
    if (len == 0) return;
    host_allocator.free(ptr[0..len]);
}

/// libc `malloc`, exported for the host shim alone. `BinaryenModuleAllocateAndWrite`
/// hands back a `result.binary` pointer that `emit.zig` reads and then releases
/// with `std.c.free` (the native contract: Binaryen `malloc`s it, q64 frees it).
/// Under Option B the shim *is* "Binaryen", so it must place those bytes in this
/// module's libc heap — the only allocator `std.c.free` can release. The shim
/// fills the result struct with this pointer; q64 copies out and frees it.
export fn q64_libc_malloc(n: usize) ?*anyopaque {
    return std.c.malloc(n);
}

/// Pack a host-owned slice into the `(ptr << 32) | len` ABI result.
fn pack(slice: []const u8) u64 {
    const ptr_bits: u64 = @intFromPtr(slice.ptr);
    return (ptr_bits << 32) | @as(u64, slice.len);
}

/// Compile `.q` source to a core `.wasm` module. `addr_is_wasm64` picks the
/// compiled program's address space (`0` → wasm32, the WebKit/iPad baseline;
/// nonzero → wasm64/Memory64). Returns packed `(ptr << 32) | len` of the
/// emitted bytes (host frees via `q64_free`), or `0` on any failure — call
/// `q64_diagnostics` for the reason.
///
/// We emit a bare core module (what the run / qview lanes consume), never a
/// component: `q64 emit --component` shells out to `wasm-tools`, impossible on
/// device. `emitFromSource` is already the in-process call `qube build` needs.
export fn q64_compile(src_ptr: [*]const u8, src_len: usize, addr_is_wasm64: u32) u64 {
    const source = src_ptr[0..src_len];
    const addr: emit.AddressSpace = if (addr_is_wasm64 != 0) .wasm64 else .wasm32;
    // emitFromSource allocates the result from `host_allocator`, so the slice
    // already outlives this call and is freeable via `q64_free`.
    const bytes = emit.emitFromSource(host_allocator, source, "main.q", &.{}, addr) catch return 0;
    return pack(bytes);
}

/// A length-prefixed reader over the host-written project buffer. All lengths
/// are little-endian `u32` (lossless on wasm32). Every read is bounds-checked;
/// a short/garbled buffer yields `null` and the caller fails the compile (→ 0).
const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    fn u32le(self: *Reader) ?u32 {
        if (self.pos + 4 > self.buf.len) return null;
        const v = std.mem.readInt(u32, self.buf[self.pos..][0..4], .little);
        self.pos += 4;
        return v;
    }
    fn slice(self: *Reader, n: usize) ?[]const u8 {
        if (self.pos + n > self.buf.len) return null;
        const s = self.buf[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }
};

/// Compile a **multi-module project** to a core `.wasm` module — the on-device
/// equivalent of `q64 emit --module name=dir …` (manifest `dependencies`). The
/// codegen already links modules (`emitFromSource(…, modules, …)`); this entry
/// just lets the host hand them across the wasm boundary, so a qube that
/// `import`s a sibling **library** qube builds in the browser.
///
/// `buf` (written via `q64_alloc`) is a self-describing wire image:
///
///   u32 main_len, main_bytes,
///   u32 module_count,
///   repeat module_count times: u32 name_len, name_bytes, u32 src_len, src_bytes
///
/// Names/sources are zero-copy slices into `buf` (it outlives the call). With
/// `module_count == 0` this is exactly `q64_compile`. Returns packed
/// `(ptr << 32) | len` of the emitted bytes (host frees via `q64_free`), or `0`
/// on a malformed buffer or any compile failure (call `q64_diagnostics` on the
/// main source for the reason).
export fn q64_compile_project(buf_ptr: [*]const u8, buf_len: usize, addr_is_wasm64: u32) u64 {
    var r = Reader{ .buf = buf_ptr[0..buf_len] };
    const main_len = r.u32le() orelse return 0;
    const main_src = r.slice(main_len) orelse return 0;
    const mod_count = r.u32le() orelse return 0;

    const mods = host_allocator.alloc(emit.ModuleSource, mod_count) catch return 0;
    defer host_allocator.free(mods);
    for (mods) |*m| {
        const name_len = r.u32le() orelse return 0;
        const name = r.slice(name_len) orelse return 0;
        const src_len = r.u32le() orelse return 0;
        const src = r.slice(src_len) orelse return 0;
        m.* = .{ .name = name, .source = src };
    }

    const addr: emit.AddressSpace = if (addr_is_wasm64 != 0) .wasm64 else .wasm32;
    const bytes = emit.emitFromSource(host_allocator, main_src, "main.q", mods, addr) catch return 0;
    return pack(bytes);
}

/// Produce the spec/diagnostics.md JSON envelope for `source`. Returns packed
/// `(ptr << 32) | len` of the UTF-8 JSON (host frees via `q64_free`), or `0` on
/// allocation failure.
export fn q64_diagnostics(src_ptr: [*]const u8, src_len: usize, addr_is_wasm64: u32) u64 {
    return diagnosticsInner(src_ptr[0..src_len], addr_is_wasm64 != 0) catch 0;
}

fn diagnosticsInner(source: []const u8, wasm64: bool) !u64 {
    // Everything transient — the parse tree, the symbol/type tables, the
    // diagnostics, the JSON builder's scratch — lives in a per-call arena freed
    // on return. Caller buffers are copied out below.
    var arena_state = std.heap.ArenaAllocator.init(host_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var diags: std.ArrayList(diag.Diagnostic) = .empty;

    // Same analysis `q64 check` runs (spec/q64-cli.md §"check"): lex/parse
    // diagnostics, then — when the file parsed into a source-file root — the
    // sema name pass, the type/check pass, and the fit registry. The
    // filesystem-only NAM002 (relative import escaping the qube) is skipped:
    // there is no filesystem in the WebView host.
    const result = try parse.parse(arena, source, "main.q");
    try diags.appendSlice(arena, result.diagnostics);
    if (parser.ast.SourceFile.cast(result.root)) |sf| {
        var table = try sema.build(arena, sf);
        const sema_diags = try sema.fileDiagnostics(arena, &table, "main.q");
        try diags.appendSlice(arena, sema_diags);

        var fitreg = try sema.fits.build(arena, sf);
        var store = try sema.types.TypeStore.init(arena);
        var sigs = try sema.types.collectSignatures(&store, &table, sf);
        const check_diags = try sema.check.checkFile(arena, sf, &table, &store, &sigs, &fitreg);
        for (check_diags) |cd| {
            try diags.append(arena, .{
                .code = cd.code,
                .severity = .err,
                .message = diag.messageFor(cd.code),
                .file = "main.q",
                .offset = cd.offset,
            });
        }
        for (fitreg.diags.items) |fd| {
            try diags.append(arena, .{
                .code = fd.code,
                .severity = .err,
                .message = diag.messageFor(fd.code),
                .file = "main.q",
                .offset = fd.offset,
            });
        }
    }

    // If analysis is clean but codegen still can't lower this program (a
    // construct the checker accepts that `emit` doesn't support yet), surface
    // the codegen failure as one honest diagnostic rather than a silent `0`
    // from `q64_compile`. When analysis already found an error, the emit error
    // is just its downstream echo — don't double-report.
    const has_error = blk: {
        for (diags.items) |d| if (d.severity == .err) break :blk true;
        break :blk false;
    };
    if (!has_error) {
        const addr: emit.AddressSpace = if (wasm64) .wasm64 else .wasm32;
        if (emit.emitFromSource(arena, source, "main.q", &.{}, addr)) |bytes| {
            arena.free(bytes);
        } else |err| {
            try diags.append(arena, codegenDiagnostic(err));
        }
    }

    var aw: std.Io.Writer.Allocating = .init(arena);
    try diag.emitJson(&aw.writer, source, diags.items, arena);
    const json = aw.writer.buffered();

    // Copy the envelope into a host-owned buffer that outlives the arena.
    const out = try host_allocator.alloc(u8, json.len);
    @memcpy(out, json);
    return pack(out);
}

/// Map a codegen-stage `emit.Error` to a diagnostic. These fire only when
/// analysis passed but `emit` cannot lower the program — an honest "codegen
/// doesn't support this yet" rather than an internal error. Code `Q9002` is the
/// codegen-limitation sibling of the `Q9001` ICE (spec/diagnostics.md). Offset
/// `0` (no precise span — the failure is whole-program); message names the
/// limitation so the terminal shows something actionable.
fn codegenDiagnostic(err: anyerror) diag.Diagnostic {
    const message: []const u8 = switch (err) {
        error.NoMainFunction => "no `main` function to compile",
        error.UnsupportedStatement => "codegen does not support this statement yet",
        error.UnsupportedExpression => "codegen does not support this expression yet",
        error.UnsupportedCall => "codegen does not support this call yet",
        error.UnsupportedImport => "codegen cannot resolve this import yet",
        error.UnsupportedInterpolation => "string interpolation needs a compile-time-constant value",
        error.UnknownModule => "import names a module not supplied to the compiler",
        error.NameNotFound => "import names something the module does not define",
        error.NotConstExpr => "this expression must be a compile-time constant",
        error.ImmutableAssign => "cannot assign to a `let` binding or a parameter",
        error.UndeclaredName => "assignment target names no in-scope binding",
        error.BreakOutsideLoop => "`break`/`continue` outside a loop",
        error.OutOfMemory => "out of memory while compiling",
        else => "codegen failed to lower this program",
    };
    return .{ .code = "Q9002", .severity = .err, .message = message, .file = "main.q", .offset = 0 };
}
