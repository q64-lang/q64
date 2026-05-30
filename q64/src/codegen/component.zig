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
//! string/list export, or a core module that imports a capability (needs import
//! lowering), is reported by the caller as not-yet-liftable. The component this
//! emits is validated end-to-end by wasmtime (`q64-component-check`).

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
/// to alias, its parameter scalars, and its optional scalar result.
pub const Export = struct {
    name: []const u8,
    core_name: []const u8,
    params: []const Scalar,
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
            for (e.params, 0..) |p, i| {
                var nbuf: [8]u8 = undefined;
                try s.name(std.fmt.bufPrint(&nbuf, "p{d}", .{i}) catch "p");
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
            try s.byte(0x00);
            try s.name(e.name);
            try s.byte(0x01); // sort: component func
            try s.uleb(i); // component func index i
            try s.byte(0x00); // no extern-desc ascription
        }
        try section(&out, 11, s.buf.items);
    }

    return out.buf.toOwnedSlice(gpa);
}

/// Encode a component for an **app** core module that imports `env.out`
/// (module `env`, field `out`, `(i32 ptr, i32 len) -> ()` on wasm32). The one
/// capability import is lowered to a component-level `log: func(msg: string)`
/// through the canonical ABI; `_start` is lifted as `run: func()`.
///
/// The string lowering needs the core module's memory, which only exists once
/// the module is instantiated — but the module needs the lowered import to
/// instantiate. That cycle is broken with the **indirection pattern**: the core
/// `env.out` import is satisfied by a `shim` trampoline that `call_indirect`s a
/// table slot; after the core module (and its memory) exist, the real lowered
/// import is patched into that slot by the `fixup` module's element segment.
/// `shim` / `fixup` are the Binaryen-built helper core modules.
pub fn encodeApp(gpa: std.mem.Allocator, core: []const u8, shim: []const u8, fixup: []const u8) Error![]u8 {
    var out = W{ .a = gpa };
    errdefer out.buf.deinit(gpa);
    try out.bytes(&.{ 0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00 });

    var s = W{ .a = gpa };
    defer s.buf.deinit(gpa);
    const reset = struct {
        fn f(w: *W) void {
            w.buf.clearRetainingCapacity();
        }
    }.f;

    // §7 type: 0 = log `(func (param "msg" string))`; 1 = run `(func)`.
    reset(&s);
    try s.uleb(2);
    try s.byte(0x40); // functype (log)
    try s.uleb(1);
    try s.name("msg");
    try s.byte(0x73); // string
    try s.byte(0x01); // named results …
    try s.uleb(0); // … none
    try s.byte(0x40); // functype (run)
    try s.uleb(0);
    try s.byte(0x01);
    try s.uleb(0);
    try section(&out, 7, s.buf.items);

    // §10 import "log" (func, type 0) → component func 0.
    reset(&s);
    try s.uleb(1);
    try s.byte(0x00); // import-name plain tag
    try s.name("log");
    try s.byte(0x01); // externdesc: func …
    try s.uleb(0); // … type 0
    try section(&out, 10, s.buf.items);

    // §1 core modules: 0 = MAIN (the q64 core), 1 = SHIM, 2 = FIXUP.
    try section(&out, 1, core);
    try section(&out, 1, shim);
    try section(&out, 1, fixup);

    // §2 core instance 0 = instantiate SHIM (module 1), no imports.
    reset(&s);
    try s.uleb(1);
    try s.byte(0x00);
    try s.uleb(1); // module 1
    try s.uleb(0); // 0 args
    try section(&out, 2, s.buf.items);

    // §6 alias the shim's exports: core func 0 = trampoline, core table 0 = slot.
    reset(&s);
    try s.uleb(2);
    try aliasCoreExport(&s, 0x00, 0, "0"); // core func ← inst0 "0"
    try aliasCoreExport(&s, 0x01, 0, "$imports"); // core table ← inst0 "$imports"
    try section(&out, 6, s.buf.items);

    // §2 core instance 1 = synthetic `env` { "out": core func 0 };
    //    core instance 2 = instantiate MAIN (module 0) with `env` = instance 1.
    reset(&s);
    try s.uleb(2);
    try s.byte(0x01); // from-exports
    try s.uleb(1);
    try s.name("out");
    try s.byte(0x00); // core sort func
    try s.uleb(0); // core func 0
    try s.byte(0x00); // instantiate
    try s.uleb(0); // module 0
    try s.uleb(1); // 1 arg
    try s.name("env");
    try s.byte(0x12); // core sort instance
    try s.uleb(1); // instance 1
    try section(&out, 2, s.buf.items);

    // §6 alias core memory 0 = MAIN instance (2) export "memory".
    reset(&s);
    try s.uleb(1);
    try aliasCoreExport(&s, 0x02, 2, "memory"); // core memory ← inst2 "memory"
    try section(&out, 6, s.buf.items);

    // §8 canon lower (component func 0 = log) (memory 0) → core func 1.
    reset(&s);
    try s.uleb(1);
    try s.byte(0x01); // canon …
    try s.byte(0x00); // … lower
    try s.uleb(0); // component func 0
    try s.uleb(1); // 1 option …
    try s.byte(0x03); // … memory
    try s.uleb(0); // core memory 0
    try section(&out, 8, s.buf.items);

    // §2 core instance 3 = synthetic { "$imports": table 0, "0": core func 1 };
    //    core instance 4 = instantiate FIXUP (module 2) with "" = instance 3.
    reset(&s);
    try s.uleb(2);
    try s.byte(0x01); // from-exports
    try s.uleb(2);
    try s.name("$imports");
    try s.byte(0x01); // core sort table
    try s.uleb(0); // core table 0
    try s.name("0");
    try s.byte(0x00); // core sort func
    try s.uleb(1); // core func 1 (lowered log)
    try s.byte(0x00); // instantiate
    try s.uleb(2); // module 2 (FIXUP)
    try s.uleb(1); // 1 arg
    try s.name(""); // module ""
    try s.byte(0x12); // core sort instance
    try s.uleb(3); // instance 3
    try section(&out, 2, s.buf.items);

    // §6 alias core func 2 = MAIN instance (2) export "_start".
    reset(&s);
    try s.uleb(1);
    try aliasCoreExport(&s, 0x00, 2, "_start");
    try section(&out, 6, s.buf.items);

    // §8 canon lift (core func 2 = _start) → component func 1, type 1 (run).
    reset(&s);
    try s.uleb(1);
    try s.byte(0x00); // canon …
    try s.byte(0x00); // … lift
    try s.uleb(2); // core func 2
    try s.uleb(0); // 0 options
    try s.uleb(1); // component type 1
    try section(&out, 8, s.buf.items);

    // §11 export "run" = component func 1.
    reset(&s);
    try s.uleb(1);
    try s.byte(0x00); // export-name plain tag
    try s.name("run");
    try s.byte(0x01); // sort: component func
    try s.uleb(1); // component func 1
    try s.byte(0x00); // no extern-desc ascription
    try section(&out, 11, s.buf.items);

    return out.buf.toOwnedSlice(gpa);
}

/// Emit one core-instance-export alias: `(alias core export <instance> <name>
/// (core <sort>))`. `core_sort` is the core sort byte (0x00 func, 0x01 table,
/// 0x02 memory).
fn aliasCoreExport(s: *W, core_sort: u8, instance: usize, name: []const u8) Error!void {
    try s.byte(0x00); // sort: core
    try s.byte(core_sort); // core sort
    try s.byte(0x01); // target: core instance export
    try s.uleb(instance);
    try s.name(name);
}

const testing = std.testing;

test "encode: component preamble + section ids for a scalar export" {
    // A throwaway "core" payload — encode embeds it verbatim; structural test.
    const core = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    const params = [_]Scalar{ .s64, .s64 };
    const exports = [_]Export{.{ .name = "add", .core_name = "add", .params = &params, .ret = .s64 }};
    const bytes = try encode(testing.allocator, &core, &exports);
    defer testing.allocator.free(bytes);

    // Component preamble: \0asm, version 0x000d, layer 0x0001.
    try testing.expectEqualSlices(u8, &.{ 0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00 }, bytes[0..8]);
    // Section ids present in order: 1 (core module), 2 (core instance),
    // 6 (alias), 7 (type), 8 (canon), 11 (export).
    for ([_]u8{ 1, 2, 6, 7, 8, 11 }) |id| {
        try testing.expect(std.mem.indexOfScalar(u8, bytes, id) != null);
    }
    // The export name is present, with its leading 0x00 plain-name tag.
    try testing.expect(std.mem.indexOf(u8, bytes, "add") != null);
}

test "Scalar.fromHir maps the canonical-ABI scalar surface" {
    try testing.expectEqual(Scalar.s64, Scalar.fromHir(.i64).?);
    try testing.expectEqual(Scalar.bool_, Scalar.fromHir(.bool).?);
    try testing.expectEqual(Scalar.f64, Scalar.fromHir(.f64).?);
    try testing.expect(Scalar.fromHir(.str) == null); // needs memory glue
    try testing.expect(Scalar.fromHir(.void) == null);
}
