//! qube-resolve.wasm — the `qube` manifest-resolution core, compiled to wasm so
//! the browser shell runs the SAME logic as the native CLI instead of a port.
//!
//! This is the first wasm slice of `qube`: the pure resolution (manifest text →
//! the entry path), the exact rule that drifted into the TS/Swift ports
//! (`main.q` vs `src/main.q`). It shares `json5.zig` + `resolve.zig` with the
//! native binary — one implementation, native and on-device.
//!
//! ABI (a minimal linear-memory string ABI; no wasm-bindgen):
//!   qube_alloc(n)            -> ptr      host writes `n` bytes there
//!   qube_resolve_entry(p,n)  -> u64      parse the JSON5 manifest at [p,n];
//!                                        returns (out_ptr<<32 | out_len) of the
//!                                        entry path (UTF-8) in wasm memory, or 0
//!                                        on a parse error (host uses its default)
//!   qube_free(p,n)                       release a buffer
//!
//! Next slices graduate this to the full `qube run`/`build` orchestration
//! (dependency entries via a host `read` import; compile + run via host imports).

const std = @import("std");
const json5 = @import("json5.zig");
const resolve = @import("resolve.zig");

const gpa = std.heap.wasm_allocator;

/// Allocate `n` bytes of wasm memory for the host to fill (e.g. the manifest).
export fn qube_alloc(n: usize) ?[*]u8 {
    const buf = gpa.alloc(u8, n) catch return null;
    return buf.ptr;
}

/// Free a buffer previously returned by `qube_alloc` / `qube_resolve_entry`.
export fn qube_free(ptr: [*]u8, n: usize) void {
    gpa.free(ptr[0..n]);
}

/// Resolve the entry source path from a JSON5 manifest. Returns the result
/// packed as `(ptr << 32) | len` (wasm32: pointers are 32-bit); 0 = parse error.
/// The qube's `entry`, defaulting per type — the single rule `resolve.entryOf`
/// owns, shared with the native CLI.
export fn qube_resolve_entry(ptr: [*]const u8, len: usize) u64 {
    const src = ptr[0..len];
    const json = json5.toJson(gpa, src) catch return 0;
    defer gpa.free(json);
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, json, .{}) catch return 0;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return 0,
    };
    const type_str: []const u8 = if (root.get("type")) |t| switch (t) {
        .string => |s| s,
        else => "library",
    } else "library";
    const is_lib = !std.mem.eql(u8, type_str, "application");
    const entry_field: ?[]const u8 = if (root.get("entry")) |e| switch (e) {
        .string => |s| s,
        else => null,
    } else null;
    const entry = resolve.entryOf(entry_field, is_lib);
    const out = gpa.alloc(u8, entry.len) catch return 0;
    @memcpy(out, entry);
    return (@as(u64, @intFromPtr(out.ptr)) << 32) | @as(u64, entry.len);
}
