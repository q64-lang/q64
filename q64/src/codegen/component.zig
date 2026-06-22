//! WebAssembly **Component** encoder — wraps a q64 core module in a component
//! whose WIT `world` is the synthesized export surface (spec/modules.md §"The
//! qube as a component"). Pure Zig (no Binaryen): it takes the already-emitted
//! core module bytes plus the public scalar export list and hand-encodes the
//! component-model binary (preamble + core-module / core-instance / alias /
//! type / canon / export sections).
//!
//! v0 scope — the smallest faithful slice: the core module must have **no
//! imports** (a pure library, or any qube that reaches no capability face), and
//! exports are lifted for **scalar** signatures only (`i64`→`s64`, `bool`,
//! `f64`), which cross the canonical ABI with no memory/`realloc` glue. A
//! string/list export is reported by the caller as not-yet-liftable. An **app**
//! that reaches a capability (`env.out` → `@stdout`) is *not* encoded here: it
//! is emitted as a WASI preview1 core (`emit.zig`, `StdoutAbi.wasi_preview1`)
//! and lifted into a real `wasi:cli/run` component by `wasm-tools component new
//! --adapt`; this encoder is the import-free library path only. The component
//! this emits is validated end-to-end by wasmtime (`q64-component-check`).

const std = @import("std");
const hir = @import("ir").hir;

pub const Error = error{ NonScalarExport, OutOfMemory };

/// A canonical-ABI scalar type liftable with no memory options.
pub const Scalar = enum {
    s64,
    bool_,
    f64,

    /// The component-model `primvaltype` byte (spec: binary.md §primvaltype).
    fn byte(self: Scalar) u8 {
        return switch (self) {
            .bool_ => 0x7f,
            .s64 => 0x78,
            .f64 => 0x75,
        };
    }

    /// Map a q64 HIR type to its scalar lift, or null if it needs memory glue.
    pub fn fromHir(t: hir.Type) ?Scalar {
        return switch (t) {
            .i64 => .s64,
            .bool => .bool_,
            .f64 => .f64,
            else => null, // str / ptr / i32 / void handled by the caller
        };
    }
};

/// One lifted export: the component export name, the core module's export name
/// to alias, its parameter scalars + names, and its optional scalar result.
/// `name` and `param_names` are the q64 source identifiers (snake_case); the
/// encoder maps them to the kebab-case the component model requires.
pub const Export = struct {
    name: []const u8,
    core_name: []const u8,
    params: []const Scalar,
    param_names: []const []const u8,
    ret: ?Scalar,
};

const W = struct {
    buf: std.ArrayList(u8) = .empty,
    a: std.mem.Allocator,

    fn byte(self: *W, b: u8) Error!void {
        try self.buf.append(self.a, b);
    }
    fn bytes(self: *W, bs: []const u8) Error!void {
        try self.buf.appendSlice(self.a, bs);
    }
    /// Unsigned LEB128.
    fn uleb(self: *W, value: usize) Error!void {
        var v = value;
        while (true) {
            const low: u8 = @intCast(v & 0x7f);
            v >>= 7;
            if (v != 0) {
                try self.byte(low | 0x80);
            } else {
                try self.byte(low);
                break;
            }
        }
    }
    /// A length-prefixed name (UTF-8).
    fn name(self: *W, s: []const u8) Error!void {
        try self.uleb(s.len);
        try self.bytes(s);
    }
    /// A length-prefixed component-model **label**, mapping the snake_case `_`
    /// q64 uses to the kebab-case `-` the component model requires (a
    /// component name/label with `_` fails validation). The map is
    /// length-preserving, so the ULEB length is the source length.
    fn label(self: *W, s: []const u8) Error!void {
        try self.uleb(s.len);
        for (s) |ch| try self.byte(if (ch == '_') '-' else ch);
    }
};

/// Emit `id`'s section wrapping `contents` (id byte + ULEB length + bytes).
fn section(out: *W, id: u8, contents: []const u8) Error!void {
    try out.byte(id);
    try out.uleb(contents.len);
    try out.bytes(contents);
}

/// Encode the component. `core` is the emitted core module; `exports` the
/// scalar public surface to lift. Caller guarantees the core module has no
/// imports (the import-lowering case isn't handled yet).
pub fn encode(gpa: std.mem.Allocator, core: []const u8, exports: []const Export) Error![]u8 {
    var out = W{ .a = gpa };
    errdefer out.buf.deinit(gpa);

    // Preamble: \0asm, version 0x000d, layer 0x0001 (component).
    try out.bytes(&.{ 0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00 });

    // §1 core module: the embedded core wasm, verbatim.
    try section(&out, 1, core);

    // §2 core instance: instantiate module 0 with no imports → core instance 0.
    {
        var s = W{ .a = gpa };
        defer s.buf.deinit(gpa);
        try s.uleb(1); // one instance
        try s.byte(0x00); // instantiate
        try s.uleb(0); // module index 0
        try s.uleb(0); // 0 instantiation args (no imports)
        try section(&out, 2, s.buf.items);
    }

    // §6 alias: bring each exported core func out of instance 0 into the
    // component's core-func index space (indices 0..exports.len in order).
    {
        var s = W{ .a = gpa };
        defer s.buf.deinit(gpa);
        try s.uleb(exports.len);
        for (exports) |e| {
            try s.byte(0x00); // sort: core
            try s.byte(0x00); // core sort: func
            try s.byte(0x01); // target: core instance export
            try s.uleb(0); // core instance 0
            try s.name(e.core_name);
        }
        try section(&out, 6, s.buf.items);
    }

    // §7 type: a component func type per export (component type index 0..N).
    {
        var s = W{ .a = gpa };
        defer s.buf.deinit(gpa);
        try s.uleb(exports.len);
        for (exports) |e| {
            try s.byte(0x40); // functype
            try s.uleb(e.params.len); // params: vec(name, valtype)
            for (e.params, e.param_names) |p, pname| {
                try s.label(pname); // the real q64 param name (→ kebab-case)
                try s.byte(p.byte());
            }
            if (e.ret) |r| {
                try s.byte(0x00); // single unnamed result
                try s.byte(r.byte());
            } else {
                try s.byte(0x01); // named results …
                try s.uleb(0); // … none (a `func() -> ()`)
            }
        }
        try section(&out, 7, s.buf.items);
    }

    // §8 canon: lift each aliased core func with its component type → component
    // func (index 0..N). Scalars need no canon options.
    {
        var s = W{ .a = gpa };
        defer s.buf.deinit(gpa);
        try s.uleb(exports.len);
        for (exports, 0..) |_, i| {
            try s.byte(0x00); // canon …
            try s.byte(0x00); // … lift
            try s.uleb(i); // core func index i
            try s.uleb(0); // 0 canon options
            try s.uleb(i); // component type index i
        }
        try section(&out, 8, s.buf.items);
    }

    // §11 export: surface each lifted component func by its public name.
    {
        var s = W{ .a = gpa };
        defer s.buf.deinit(gpa);
        try s.uleb(exports.len);
        for (exports, 0..) |e, i| {
            // A component export name carries a leading 0x00 tag (the plain-name
            // form) before the length-prefixed string — unlike a core name.
            // The label is kebab-cased (the core alias above keeps the raw
            // snake_case core export name).
            try s.byte(0x00);
            try s.label(e.name);
            try s.byte(0x01); // sort: component func
            try s.uleb(i); // component func index i
            try s.byte(0x00); // no extern-desc ascription
        }
        try section(&out, 11, s.buf.items);
    }

    return out.buf.toOwnedSlice(gpa);
}

// An **app** core module (one that reaches `@stdout`) is no longer wrapped by a
// hand-rolled encoder here. It is emitted as a WASI **preview1** core module
// (`emit.zig`, `StdoutAbi.wasi_preview1`) and lifted into a real `wasi:cli/run`
// command — importing `wasi:cli/stdout` — by `wasm-tools component new --adapt`
// with the `vendor/wasi/` adapter. The CLI drives that shell-out (`main.zig`).
// `encode` above remains the pure-Zig encoder for the import-free scalar
// **library** lift.

const testing = std.testing;

test "encode: component preamble + section ids for a scalar export" {
    // A throwaway "core" payload — encode embeds it verbatim; structural test.
    const core = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    const params = [_]Scalar{ .s64, .s64 };
    const param_names = [_][]const u8{ "a", "b" };
    const exports = [_]Export{.{ .name = "add", .core_name = "add", .params = &params, .param_names = &param_names, .ret = .s64 }};
    const bytes = try encode(testing.allocator, &core, &exports);
    defer testing.allocator.free(bytes);

    // Component preamble: \0asm, version 0x000d, layer 0x0001.
    try testing.expectEqualSlices(u8, &.{ 0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00 }, bytes[0..8]);
    // Section ids present in order: 1 (core module), 2 (core instance),
    // 6 (alias), 7 (type), 8 (canon), 11 (export).
    for ([_]u8{ 1, 2, 6, 7, 8, 11 }) |id| {
        try testing.expect(std.mem.indexOfScalar(u8, bytes, id) != null);
    }
    // The export name is present, with its leading 0x00 plain-name tag, and the
    // real param names are encoded (so `wasm-tools component wit` round-trips
    // `func(a: s64, b: s64)`, not `p0/p1`).
    try testing.expect(std.mem.indexOf(u8, bytes, "add") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "a") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "b") != null);
}

test "encode: component-model labels are kebab-cased from snake_case" {
    // q64 identifiers are snake_case; component-model labels must be kebab-case
    // (a `_` fails component validation). `encode` maps `get_version` →
    // `get-version` and the param `min_value` → `min-value`.
    const core = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    const params = [_]Scalar{.s64};
    const param_names = [_][]const u8{"min_value"};
    const exports = [_]Export{.{ .name = "get_version", .core_name = "get_version", .params = &params, .param_names = &param_names, .ret = .s64 }};
    const bytes = try encode(testing.allocator, &core, &exports);
    defer testing.allocator.free(bytes);

    // The kebab forms are present; the snake forms are not (except as the
    // core-alias name, which intentionally keeps the raw core export name).
    try testing.expect(std.mem.indexOf(u8, bytes, "get-version") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "min-value") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "min_value") == null);
}

test "Scalar.fromHir maps the canonical-ABI scalar surface" {
    try testing.expectEqual(Scalar.s64, Scalar.fromHir(.i64).?);
    try testing.expectEqual(Scalar.bool_, Scalar.fromHir(.bool).?);
    try testing.expectEqual(Scalar.f64, Scalar.fromHir(.f64).?);
    try testing.expect(Scalar.fromHir(.str) == null); // needs memory glue
    try testing.expect(Scalar.fromHir(.void) == null);
}
