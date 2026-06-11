//! The auto-prelude name table — the identifier-shaped entries of
//! [`spec/modules.md` §"The auto-prelude"](../../../spec/modules.md),
//! mirrored by hand (the prelude is curated; new names land by spec
//! amendment there and are added here).
//!
//! Two consumers:
//! - `resolve.zig` — a path head naming a prelude entry is resolved,
//!   not recorded as unknown (`sleep(16.ms)`, `channel<…>(…)`).
//! - `types.zig` — a type annotation naming a prelude type/face lowers
//!   to `.named{.kind = .prelude}` instead of `.unresolved`
//!   (`Vec<f32>`, `Signal<…>`, `Display`).
//!
//! Not in this table: keywords the lexer owns (`let`, `try`, `spawn`,
//! `scope`, …) — they never reach name resolution as identifier heads —
//! and the *transitive* prelude (types reachable through capability-face
//! signatures: `Url`, `Response`, `IoError`, …), which is computed, not
//! curated; it joins when the stdlib face signatures are loadable.
//! Until then those names stay conservative (recorded, never emitted).

const std = @import("std");

pub const Kind = enum {
    /// A type (struct/enum/builtin-generic) usable in type position.
    type_,
    /// An auto-prelude face (usable as a bound / in type position).
    face,
    /// A value/callable (usable as an expression head).
    value,
};

const Entry = struct { name: []const u8, kind: Kind };

/// spec/modules.md §"The auto-prelude", identifier-shaped rows only.
const entries = [_]Entry{
    // Strings (the numeric tower + bool/str are builtins in types.zig).
    .{ .name = "String", .kind = .type_ },
    // Compound numerics.
    .{ .name = "Simd", .kind = .type_ },
    .{ .name = "Tensor", .kind = .type_ },
    .{ .name = "DynTensor", .kind = .type_ },
    // Optionality / errors.
    .{ .name = "Option", .kind = .type_ },
    .{ .name = "Result", .kind = .type_ },
    .{ .name = "PanicMessage", .kind = .type_ },
    .{ .name = "Cancelled", .kind = .type_ },
    .{ .name = "Closed", .kind = .type_ },
    .{ .name = "RuntimeDenied", .kind = .type_ },
    .{ .name = "RangeError", .kind = .type_ },
    // Auto-prelude faces.
    .{ .name = "Eq", .kind = .face },
    .{ .name = "Ord", .kind = .face },
    .{ .name = "Hash", .kind = .face },
    .{ .name = "Clone", .kind = .face },
    .{ .name = "Display", .kind = .face },
    .{ .name = "Debug", .kind = .face },
    .{ .name = "Iterator", .kind = .face },
    .{ .name = "Default", .kind = .face },
    .{ .name = "From", .kind = .face },
    .{ .name = "Into", .kind = .face },
    .{ .name = "TryFrom", .kind = .face },
    .{ .name = "TryInto", .kind = .face },
    .{ .name = "Arbitrary", .kind = .face },
    .{ .name = "Error", .kind = .face },
    .{ .name = "Panic", .kind = .face },
    // Collections.
    .{ .name = "Vec", .kind = .type_ },
    .{ .name = "Map", .kind = .type_ },
    .{ .name = "Set", .kind = .type_ },
    .{ .name = "Box", .kind = .type_ },
    .{ .name = "Bytes", .kind = .type_ },
    // Regions.
    .{ .name = "Region", .kind = .face },
    .{ .name = "Arena", .kind = .type_ },
    .{ .name = "Pool", .kind = .type_ },
    .{ .name = "Stack", .kind = .type_ },
    .{ .name = "FreeList", .kind = .type_ },
    .{ .name = "Managed", .kind = .type_ },
    .{ .name = "Interned", .kind = .type_ },
    .{ .name = "transfer", .kind = .value },
    // Shared memory.
    .{ .name = "Atomic", .kind = .type_ },
    .{ .name = "Shared", .kind = .type_ },
    .{ .name = "ManagedBox", .kind = .type_ },
    .{ .name = "Mutex", .kind = .type_ },
    .{ .name = "RwLock", .kind = .type_ },
    .{ .name = "LockFree", .kind = .type_ },
    .{ .name = "Disjoint", .kind = .type_ },
    // Capabilities.
    .{ .name = "Env", .kind = .type_ },
    .{ .name = "Net", .kind = .type_ },
    .{ .name = "Fs", .kind = .type_ },
    .{ .name = "Audio", .kind = .type_ },
    .{ .name = "Midi", .kind = .type_ },
    .{ .name = "AiEnv", .kind = .type_ },
    .{ .name = "Ui", .kind = .type_ },
    .{ .name = "Clock", .kind = .type_ },
    .{ .name = "Rng", .kind = .type_ },
    .{ .name = "Stdout", .kind = .type_ },
    .{ .name = "Stderr", .kind = .type_ },
    .{ .name = "ExitFn", .kind = .type_ },
    .{ .name = "EnvVars", .kind = .type_ },
    .{ .name = "with_capabilities", .kind = .value },
    // Concurrency primitives.
    .{ .name = "channel", .kind = .value },
    .{ .name = "tell", .kind = .value },
    .{ .name = "ask", .kind = .value },
    .{ .name = "Cancel", .kind = .type_ },
    .{ .name = "Handle", .kind = .type_ },
    .{ .name = "Future", .kind = .type_ },
    .{ .name = "Sender", .kind = .type_ },
    .{ .name = "Receiver", .kind = .type_ },
    .{ .name = "Policy", .kind = .face },
    .{ .name = "CancelPolicy", .kind = .face },
    .{ .name = "NonCancelPolicy", .kind = .face },
    .{ .name = "Backpressure", .kind = .type_ },
    .{ .name = "RingBuffer", .kind = .type_ },
    .{ .name = "LatestValue", .kind = .type_ },
    .{ .name = "Unbounded", .kind = .type_ },
    .{ .name = "timeout", .kind = .value },
    .{ .name = "sleep", .kind = .value },
    .{ .name = "SendError", .kind = .type_ },
    .{ .name = "RecvError", .kind = .type_ },
    // Stream primitives.
    .{ .name = "Signal", .kind = .type_ },
    .{ .name = "Event", .kind = .type_ },
    .{ .name = "Stream", .kind = .type_ },
    .{ .name = "SharedSignal", .kind = .type_ },
    .{ .name = "Graph", .kind = .face },
    .{ .name = "pre", .kind = .value },
    .{ .name = "changes", .kind = .value },
    .{ .name = "hold", .kind = .value },
    .{ .name = "fold", .kind = .value },
    .{ .name = "sample", .kind = .value },
};

/// The prelude kind of `name`, or null when it isn't auto-prelude.
pub fn kindOf(name: []const u8) ?Kind {
    inline for (entries) |e| {
        if (std.mem.eql(u8, name, e.name)) return e.kind;
    }
    return null;
}

/// Usable in type position (a type or a face).
pub fn isType(name: []const u8) bool {
    return switch (kindOf(name) orelse return false) {
        .type_, .face => true,
        .value => false,
    };
}

/// Resolvable as an expression head (any prelude entry — type heads
/// appear in expressions too: `RingBuffer` as a policy argument,
/// `Map.new()` as a constructor).
pub fn contains(name: []const u8) bool {
    return kindOf(name) != null;
}

test "prelude: kinds and membership" {
    try std.testing.expectEqual(Kind.value, kindOf("sleep").?);
    try std.testing.expectEqual(Kind.value, kindOf("channel").?);
    try std.testing.expectEqual(Kind.type_, kindOf("Vec").?);
    try std.testing.expectEqual(Kind.type_, kindOf("Signal").?);
    try std.testing.expectEqual(Kind.face, kindOf("Display").?);
    try std.testing.expect(kindOf("Mat4") == null); // q64.math: explicit import
    try std.testing.expect(isType("Result"));
    try std.testing.expect(!isType("sleep"));
    try std.testing.expect(contains("Backpressure"));
}
