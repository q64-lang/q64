//! Wasm ABI over q64's analysis core.
//!
//! The host (the TypeScript LSP server, or any browser / Worker) drives
//! this module through three exports. All language intelligence lives in
//! q64's Zig modules, imported as `parser`; this file is only the boundary
//! that turns "bytes in, JSON out" into calls on them.
//!
//! Memory protocol:
//!   1. `q64_alloc(len)` → ptr. Host writes `len` source bytes there.
//!   2. `q64_diagnose(ptr, len)` → packed result: (out_ptr << 32) | out_len.
//!      `out` is a UTF-8 JSON diagnostic envelope (spec/diagnostics.md).
//!   3. Host reads [out_ptr .. out_ptr+out_len], then frees BOTH buffers
//!      with `q64_free(ptr, len)`.
//!
//! wasm32 pointers are 32-bit, so packing ptr+len into a u64 is lossless.

const std = @import("std");
const parser = @import("parser");
const parse = parser.parse;
const diag = parser.diag;

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

/// Parse `src` and return a JSON diagnostic envelope. Returns 0 on
/// allocation failure (the host treats 0 as "no result").
export fn q64_diagnose(src_ptr: [*]const u8, src_len: usize) u64 {
    return diagnoseInner(src_ptr[0..src_len]) catch 0;
}

fn diagnoseInner(source: []const u8) !u64 {
    // Everything transient — the parse tree, the diagnostics, the JSON
    // builder's scratch — lives in a per-call arena that is freed on return.
    var arena_state = std.heap.ArenaAllocator.init(host_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try parse.parse(arena, source, "buffer.q");

    var aw: std.Io.Writer.Allocating = .init(arena);
    try diag.emitJson(&aw.writer, source, result.diagnostics, arena);
    const json = aw.writer.buffered();

    // Copy the envelope out of the arena into a host-owned buffer that
    // outlives this call; the host frees it via q64_free.
    const out = try host_allocator.alloc(u8, json.len);
    @memcpy(out, json);

    const ptr_bits: u64 = @intFromPtr(out.ptr);
    return (ptr_bits << 32) | @as(u64, out.len);
}
