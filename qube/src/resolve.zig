//! Qube resolution — the **single source of truth** for turning a manifest into
//! the facts every `qube` front-end needs: the entry source, and (later) the
//! dependency module specs. Pure, allocation-free, and **wasm-compatible** (no
//! fs, no spawn, no argv) — so the *same* logic backs the native CLI and the
//! wasm `qube` the browser shell runs. There must be exactly one answer to
//! "what does `qube run` build", native and on-device; this module is it.
//!
//! Previously this was re-coded per front-end (native Zig here, a TypeScript port
//! in the web shell, a Swift port on iOS), and the copies drifted —
//! `src/main.q` vs `main.q`. Centralising the rule here is step one of collapsing
//! those to one implementation.

const std = @import("std");

/// Spec defaults (spec/qube-cli.md §`qube new` / §run): an application's entry is
/// `src/main.q`, a library's is `src/lib.q`. The manifest's `entry` overrides.
pub const DEFAULT_APP_ENTRY = "src/main.q";
pub const DEFAULT_LIB_ENTRY = "src/lib.q";

/// The qube's entry source: the manifest's `entry` field when present, else the
/// type default. `entry_field` is the parsed `entry` string (or null); the same
/// answer the native CLI builds and `qube run` in any shell must honour.
pub fn entryOf(entry_field: ?[]const u8, is_library: bool) []const u8 {
    return entry_field orelse if (is_library) DEFAULT_LIB_ENTRY else DEFAULT_APP_ENTRY;
}

test "entryOf: manifest entry wins; type default otherwise" {
    const t = std.testing;
    // Explicit entry is honoured for either kind.
    try t.expectEqualStrings("src/main.q", entryOf("src/main.q", false));
    try t.expectEqualStrings("custom.q", entryOf("custom.q", false));
    try t.expectEqualStrings("lib/api.q", entryOf("lib/api.q", true));
    // Absent entry → the type default (the spec standard).
    try t.expectEqualStrings("src/main.q", entryOf(null, false));
    try t.expectEqualStrings("src/lib.q", entryOf(null, true));
}
