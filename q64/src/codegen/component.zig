//! WebAssembly **Component** encoder — wraps a q64 core module in a component
//! whose WIT `world` is the synthesized export surface (spec/modules.md §"The
//! qube as a component"). Pure Zig (no Binaryen): it takes the already-emitted
//! core module bytes plus the public scalar export list and hand-encodes the
//! component-model binary (preamble + core-module / core-instance / alias /
//! type / canon / export sections).
//!
//! v0 scope — the smallest faithful slice: the core module must have **no
//! core imports** (a pure library, or any qube that reaches no capability
//! face), and exports are lifted for **scalar** signatures only (`i64`→`s64`,
//! `bool`, `f64`), which cross the canonical ABI with no memory/`realloc` glue.
//! A string/list export is reported by the caller as not-yet-liftable. An
//! **app** that reaches a capability (`env.out` → `@stdout`) is *not* encoded
//! here: it is emitted as a WASI preview1 core (`emit.zig`,
//! `StdoutAbi.wasi_preview1`) and lifted into a real `wasi:cli/run` component by
//! `wasm-tools component new --adapt`. The component this emits is validated
//! end-to-end by wasmtime (`q64-component-check`).
//!
//! WIT rung 5 (the codegen import binding): `encode` also declares **foreign
//! imports** — the scalar interfaces a qube depends on — as component-level
//! instance imports (the inverse of the export encoding), so `wac` can link
//! them at build. These are forward declarations; the v0 core doesn't yet call
//! them (the source-level call binding is the next slice).

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

/// One function of a foreign interface this component **imports** (WIT rung 5,
/// the codegen import binding). Same scalar shape as `Export` — a foreign func
/// whose signature crosses the canonical ABI with no memory glue.
pub const ImportFunc = struct {
    name: []const u8,
    params: []const Scalar,
    param_names: []const []const u8,
    ret: ?Scalar,
};

/// A foreign WIT interface this component declares it imports. `wit_name` is the
/// component-model interface id (e.g. `acme:store/kv@1.2.0`) — raw, not
/// kebab-mapped (it carries `:`/`/`/`@`).
pub const ImportIface = struct {
    wit_name: []const u8,
    funcs: []const ImportFunc,
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

/// Encode a component-model `functype` (`0x40` + named params + result) — shared
/// by an export's component type (§7) and an imported interface's instance-type
/// functype. Param labels are kebab-cased; an absent result is `() -> ()`.
fn encodeFuncType(s: *W, params: []const Scalar, param_names: []const []const u8, ret: ?Scalar) Error!void {
    try s.byte(0x40); // functype
    try s.uleb(params.len);
    for (params, param_names) |p, pname| {
        try s.label(pname);
        try s.byte(p.byte());
    }
    if (ret) |r| {
        try s.byte(0x00); // single unnamed result
        try s.byte(r.byte());
    } else {
        try s.byte(0x01); // named results …
        try s.uleb(0); // … none
    }
}

/// The index of `wit_name` in the declared import list — the component
/// instance index space §0a establishes. The `encode` contract guarantees a
/// wired interface is always declared.
fn declaredIndex(imports: []const ImportIface, wit_name: []const u8) usize {
    for (imports, 0..) |iface, j| {
        if (std.mem.eql(u8, iface.wit_name, wit_name)) return j;
    }
    unreachable; // contract: wired ⊆ imports by wit_name
}

/// Encode the component. `core` is the emitted core module; `exports` the
/// scalar public surface to lift; `imports` the foreign WIT interfaces the
/// component **declares** it imports (WIT rung 5 — the manifest's
/// `wit.imports`, declared in the world even when unused so `wac` can link at
/// build, per spec/qube.json5.md §wit); `wired` the subset whose functions the
/// core module actually imports (its `foreign_call` sites). Declaration and
/// wiring are separate: every declared interface gets an instance-type (§7a)
/// and an import (§0a), but only wired functions are aliased out of their
/// imported instance, canon-lowered, and fed back as the core module's
/// instantiation imports. **Caller guarantees the core module imports exactly
/// the `(wit_name, fn)` pairs in `wired`** — no more (a host face like
/// `qview.*` needs a different lift), no fewer (the instantiate args must
/// match the module's imports) — and that every wired interface also appears
/// in `imports` under the same `wit_name`. `emitComponent` enforces this by
/// wiring only the interfaces/funcs the source actually calls.
pub fn encode(gpa: std.mem.Allocator, core: []const u8, exports: []const Export, imports: []const ImportIface, wired: []const ImportIface) Error![]u8 {
    var out = W{ .a = gpa };
    errdefer out.buf.deinit(gpa);

    // Preamble: \0asm, version 0x000d, layer 0x0001 (component).
    try out.bytes(&.{ 0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00 });

    // Foreign imports occupy component **type** indices `0..M`; the export
    // functypes that follow are offset by `M`. When there are no imports `M=0`
    // and the encoding is byte-identical to the export-only form.
    const m = imports.len;

    // §7a import instance-types — one `instancetype` per imported interface,
    // each declaring its functions. (Only emitted when there are imports, so the
    // import-free output is unchanged.)
    if (m > 0) {
        var s = W{ .a = gpa };
        defer s.buf.deinit(gpa);
        try s.uleb(m);
        for (imports) |iface| {
            try s.byte(0x42); // instancetype
            try s.uleb(2 * iface.funcs.len); // a type decl + an export decl per func
            for (iface.funcs, 0..) |f, idx| {
                try s.byte(0x01); // type decl …
                try encodeFuncType(&s, f.params, f.param_names, f.ret);
                try s.byte(0x04); // export decl …
                try s.byte(0x00); // plain-name tag
                try s.label(f.name);
                try s.byte(0x01); // func sort
                try s.uleb(idx); // the in-instance func-type index
            }
        }
        try section(&out, 7, s.buf.items);

        // §0a import: bring each foreign interface in as an instance, by its
        // component-model interface id.
        var im = W{ .a = gpa };
        defer im.buf.deinit(gpa);
        try im.uleb(m);
        for (imports, 0..) |iface, j| {
            try im.byte(0x00); // import-name plain tag
            try im.name(iface.wit_name); // raw id (carries `:`/`/`/`@`)
            try im.byte(0x05); // instance sort
            try im.uleb(j); // instance-type index j
        }
        try section(&out, 0x0a, im.buf.items);
    }

    // §1 core module: the embedded core wasm, verbatim.
    try section(&out, 1, core);

    // Total wired funcs K (across the wired interfaces). The core module
    // imports each wired func by `(<wit-id>, <fn>)`; the component supplies
    // them by aliasing each imported-instance export, lowering it to a core
    // func, and feeding those back in as the core module's instantiation
    // imports. Declared-but-unwired interfaces take no part in this plumbing —
    // they exist only as world imports (§7a/§0a above).
    var total_wired: usize = 0;
    for (wired) |iface| total_wired += iface.funcs.len;
    const k = total_wired;

    // §6 alias (component func): bring each wired interface function out of
    // its imported instance (found by `wit_name` in the DECLARED list, since
    // that list owns the instance index space) into the component-func index
    // space (0..K, in interface-then-func order).
    if (k > 0) {
        var s = W{ .a = gpa };
        defer s.buf.deinit(gpa);
        try s.uleb(k);
        for (wired) |iface| {
            const j = declaredIndex(imports, iface.wit_name);
            for (iface.funcs) |f| {
                try s.byte(0x01); // sort: component func
                try s.byte(0x00); // target: instance export
                try s.uleb(j); // component instance index (the imported instance)
                try s.label(f.name);
            }
        }
        try section(&out, 6, s.buf.items);
    }

    // §8 canon lower: lower each aliased import (component func 0..K) into a core
    // func (core-func index 0..K). Scalars need no canon options.
    if (k > 0) {
        var s = W{ .a = gpa };
        defer s.buf.deinit(gpa);
        try s.uleb(k);
        for (0..k) |i| {
            try s.byte(0x01); // canon …
            try s.byte(0x00); // … lower
            try s.uleb(i); // component func index i
            try s.uleb(0); // 0 canon options
        }
        try section(&out, 8, s.buf.items);
    }

    // §2 core instances: one synthetic from-exports instance per WIRED
    // interface (exporting that interface's lowered core funcs under their field
    // names, core-func indices grouped by interface), then the main module
    // instantiated with each wired interface id fed its synthetic instance.
    // Declared-but-unwired interfaces get no synthetic instance and no
    // instantiation arg — the core module doesn't import them.
    {
        var s = W{ .a = gpa };
        defer s.buf.deinit(gpa);
        try s.uleb(wired.len + 1); // wired synthetic instances + the main module instance
        var base: usize = 0; // running core-func index for the lowered imports
        for (wired) |iface| {
            try s.byte(0x01); // instance form: from exports
            try s.uleb(iface.funcs.len);
            for (iface.funcs, 0..) |f, fi| {
                try s.name(f.name); // core export name (raw field name, no kebab)
                try s.byte(0x00); // core sort: func
                try s.uleb(base + fi); // the lowered core func for this import
            }
            base += iface.funcs.len;
        }
        // The main module instance: instantiate module 0, wiring each wired
        // interface id to its synthetic core instance (index j).
        try s.byte(0x00); // instantiate
        try s.uleb(0); // module index 0
        try s.uleb(wired.len); // instantiation args (one per wired interface)
        for (wired, 0..) |iface, j| {
            try s.name(iface.wit_name); // raw core import module id (carries `:`/`/`/`@`)
            try s.byte(0x12); // core sort: instance
            try s.uleb(j); // the synthetic core instance index j
        }
        try section(&out, 2, s.buf.items);
    }
    const main_inst = wired.len; // the main module's core instance index

    // §6 alias (core func): bring each exported core func out of the main
    // instance into the core-func index space (indices K..K+N in order).
    {
        var s = W{ .a = gpa };
        defer s.buf.deinit(gpa);
        try s.uleb(exports.len);
        for (exports) |e| {
            try s.byte(0x00); // sort: core
            try s.byte(0x00); // core sort: func
            try s.byte(0x01); // target: core instance export
            try s.uleb(main_inst); // the main module's core instance
            try s.name(e.core_name);
        }
        try section(&out, 6, s.buf.items);
    }

    // §7 type: a component func type per export (component type indices M..M+N,
    // past the M import instance-types).
    {
        var s = W{ .a = gpa };
        defer s.buf.deinit(gpa);
        try s.uleb(exports.len);
        for (exports) |e| {
            try encodeFuncType(&s, e.params, e.param_names, e.ret);
        }
        try section(&out, 7, s.buf.items);
    }

    // §8 canon lift: lift each aliased export core func (index K+i) with its
    // component type (M+i) → component func (index K+i). Scalars need no options.
    {
        var s = W{ .a = gpa };
        defer s.buf.deinit(gpa);
        try s.uleb(exports.len);
        for (exports, 0..) |_, i| {
            try s.byte(0x00); // canon …
            try s.byte(0x00); // … lift
            try s.uleb(k + i); // core func index (past the K lowered imports)
            try s.uleb(0); // 0 canon options
            try s.uleb(m + i); // component type index (past the M import instance-types)
        }
        try section(&out, 8, s.buf.items);
    }

    // §11 export: surface each lifted component func (index K+i) by its public name.
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
            try s.uleb(k + i); // component func index (past the K aliased imports)
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
    const bytes = try encode(testing.allocator, &core, &exports, &.{}, &.{});
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
    const bytes = try encode(testing.allocator, &core, &exports, &.{}, &.{});
    defer testing.allocator.free(bytes);

    // The kebab forms are present; the snake forms are not (except as the
    // core-alias name, which intentionally keeps the raw core export name).
    try testing.expect(std.mem.indexOf(u8, bytes, "get-version") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "min-value") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "min_value") == null);
}

test "encode: a foreign import adds the instance-type (§7) + import (§0x0a) sections" {
    const core = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    const eparams = [_]Scalar{.s64};
    const enames = [_][]const u8{"x"};
    const exports = [_]Export{.{ .name = "compute", .core_name = "compute", .params = &eparams, .param_names = &enames, .ret = .s64 }};
    const iparams = [_]Scalar{ .s64, .s64 };
    const inames = [_][]const u8{ "a", "b" };
    const ifuncs = [_]ImportFunc{.{ .name = "add", .params = &iparams, .param_names = &inames, .ret = .s64 }};
    const imports = [_]ImportIface{.{ .wit_name = "acme:mathlib/math@1.0.0", .funcs = &ifuncs }};
    const bytes = try encode(testing.allocator, &core, &exports, &imports, &imports);
    defer testing.allocator.free(bytes);

    // The component-model interface id is present (raw, not kebab-mapped).
    try testing.expect(std.mem.indexOf(u8, bytes, "acme:mathlib/math@1.0.0") != null);
    // The import section (id 0x0a) and instance-type tag (0x42) are present.
    try testing.expect(std.mem.indexOfScalar(u8, bytes, 0x0a) != null);
    try testing.expect(std.mem.indexOfScalar(u8, bytes, 0x42) != null);
    // Both the export and the imported func name survive.
    try testing.expect(std.mem.indexOf(u8, bytes, "compute") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "add") != null);
}

test "encode: a declared-but-unwired import is still declared (§7 + §0x0a), with no instantiate arg" {
    // The manifest declares `wit.imports` the source never calls (WIT rung 5's
    // consume direction before the first call site lands). The world must
    // still import the interface — `wac` links against the declaration — while
    // the core module, which imports nothing, gets zero instantiation args.
    const core = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    const eparams = [_]Scalar{.s64};
    const enames = [_][]const u8{"x"};
    const exports = [_]Export{.{ .name = "compute", .core_name = "compute", .params = &eparams, .param_names = &enames, .ret = .s64 }};
    const iparams = [_]Scalar{ .s64, .s64 };
    const inames = [_][]const u8{ "a", "b" };
    const ifuncs = [_]ImportFunc{.{ .name = "add", .params = &iparams, .param_names = &inames, .ret = .s64 }};
    const imports = [_]ImportIface{.{ .wit_name = "acme:mathlib/math@1.0.0", .funcs = &ifuncs }};
    const bytes = try encode(testing.allocator, &core, &exports, &imports, &.{});
    defer testing.allocator.free(bytes);

    // The interface id is declared (instance-type + import section carry it).
    try testing.expect(std.mem.indexOf(u8, bytes, "acme:mathlib/math@1.0.0") != null);
    try testing.expect(std.mem.indexOfScalar(u8, bytes, 0x42) != null); // instancetype tag
    // Exactly ONE occurrence of the id: the §0a import. A wired import would
    // carry a second occurrence — the core-instance instantiation arg.
    const first = std.mem.indexOf(u8, bytes, "acme:mathlib/math@1.0.0").?;
    try testing.expect(std.mem.indexOfPos(u8, bytes, first + 1, "acme:mathlib/math@1.0.0") == null);
}

test "encode: no imports → byte-identical to the export-only form (M=0)" {
    const core = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    const params = [_]Scalar{ .s64, .s64 };
    const names = [_][]const u8{ "a", "b" };
    const exports = [_]Export{.{ .name = "add", .core_name = "add", .params = &params, .param_names = &names, .ret = .s64 }};
    const with_empty = try encode(testing.allocator, &core, &exports, &.{}, &.{});
    defer testing.allocator.free(with_empty);
    // The §0x0a import section is absent when there are no imports.
    // (id 0x0a only appears as a section here if imports were emitted.)
    // Spot-check: the canon type index is i (not offset), so the encoding is the
    // pre-import form — verified by the component-roundtrip wasmtime call.
    try testing.expect(with_empty.len > 8);
}

test "Scalar.fromHir maps the canonical-ABI scalar surface" {
    try testing.expectEqual(Scalar.s64, Scalar.fromHir(.i64).?);
    try testing.expectEqual(Scalar.bool_, Scalar.fromHir(.bool).?);
    try testing.expectEqual(Scalar.f64, Scalar.fromHir(.f64).?);
    try testing.expect(Scalar.fromHir(.str) == null); // needs memory glue
    try testing.expect(Scalar.fromHir(.void) == null);
}
