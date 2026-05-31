//! q64/src/codegen — AST → Wasm 3.0 via Binaryen.
//!
//! v0 surface: a single entry point `emitHelloWasm` that builds the
//! hand-equivalent of `runtime/wasmtime/hello.wat` directly via the
//! Binaryen C API. This proves the Binaryen integration and gives
//! us a byte-level shape codegen will later produce from a typed AST.
//!
//! Module shape produced:
//!
//!   (module
//!     (import "env" "out" (func (param i64 i64)))
//!     (memory (export "memory") i64 1)
//!     (data (i64.const 0) "Hello, q64.\n")
//!     (func (export "_start")
//!       i64.const 0
//!       i64.const 12
//!       call $env_out))
//!
//! The result instantiates against `runtime/wasmtime/q64-wasmtime-host`
//! and prints `Hello, q64.\n` to stdout, matching the hand-written
//! hello.wat byte-for-byte in behavior (the exact byte stream may
//! differ in section ordering / type-index layout — Binaryen and
//! wabt make different but equally valid choices).

const std = @import("std");
const parser = @import("parser");
const parse = parser.parse;
const ast = parser.ast;
const ir = @import("ir");
const component = @import("component.zig");

const c = @cImport({
    @cInclude("binaryen-c.h");
});

pub const Error = error{
    ModuleCreate,
    ModuleInvalid,
    SerializeEmpty,
    NoMainFunction,
    NoBody,
    UnsupportedStatement,
    UnsupportedExpression,
    UnsupportedCall,
    BadStringLiteral,
    // Linking / const-evaluation (ladder steps 0, 3, 5, 6).
    UnknownModule, // an `import` names a module not supplied via --module (NAM001-ish)
    NameNotFound, // a selectively-imported name isn't defined in the module (NAM010-ish)
    UnsupportedImport, // import form codegen can't resolve yet (relative, stdlib)
    UnsupportedInterpolation, // `{expr}` whose value isn't a compile-time constant
    NotConstExpr, // an expression codegen cannot evaluate at compile time
    ImmutableAssign, // assignment to a `let` binding or a parameter
    UndeclaredName, // assignment target names no in-scope binding
    BreakOutsideLoop, // `break`/`continue` with no enclosing loop
    CfgUnsupported, // a MIR func body in CFG form — the WASM backend only takes structured
    // Component lift (q64 emit --component).
    ComponentNeedsImportLowering, // the core module imports a capability; lowering not yet implemented
    ComponentNoExports, // nothing in the public surface lifts to the canonical ABI yet
    NonScalarExport,
    OutOfMemory,
};

/// The linear-memory address space a build targets (spec/memory.md §"The
/// platform"). It is an explicit per-build choice: `wasm32` (i32 addresses,
/// the WebKit/iPad baseline) or `wasm64` (Memory64, i64 addresses). Values stay
/// i64 either way — only memory *addresses* differ — so the wasm32 POC supports
/// the integer/import subset today and guards the string/arena ABI (i32 pointer
/// conversion) as a Path-B follow-up rather than emitting an invalid module.
pub const AddressSpace = enum {
    wasm32,
    wasm64,

    pub fn memory64(self: AddressSpace) bool {
        return self == .wasm64;
    }
};

/// How a core module's stdout capability (`env.out`) is lowered to a wasm
/// import (spec/env.md §"Env ↔ WASI"). Two shapes:
///   - `.env_out` — q64's raw host face `(import "env" "out" (func (param ptr
///     len)))`, satisfied directly by `runtime/wasmtime/` and `runtime/browser/`.
///   - `.wasi_preview1` — the WASI preview1 `fd_write` import `(import
///     "wasi_snapshot_preview1" "fd_write" (func (param i32 i32 i32 i32) (result
///     i32)))`, writing one iovec to fd 1. This is the shape `wasm-tools
///     component new --adapt` lifts (via `vendor/wasi/`) into a real
///     `wasi:cli/run` command that imports `wasi:cli/stdout`. Preview1 is 32-bit,
///     so this lowering is wasm32-only.
pub const StdoutAbi = enum {
    env_out,
    wasi_preview1,
};

/// A dependency module made available to codegen. `name` is the bare-
/// dotted module path (`dev.q64.hello_world`); `source` is the text of
/// that module's entry file (`src/lib.q`). The compiler resolves
/// `import <name>.{…}` against this set — it never reads `qube.json5`
/// or touches the filesystem itself (per spec/q64-cli.md §"--module").
pub const ModuleSource = struct {
    name: []const u8,
    source: []const u8,
};

/// Build the hello-world wasm module and return its bytes. Caller
/// owns the returned slice and must free it via `allocator`.
pub fn emitHelloWasm(allocator: std.mem.Allocator) ![]u8 {
    const module = c.BinaryenModuleCreate() orelse return error.ModuleCreate;
    defer c.BinaryenModuleDispose(module);

    // q64 targets Wasm Memory64 (spec/memory.md): 64-bit linear memory,
    // i64 pointers, so env.out is (i64, i64) -> ().
    c.BinaryenModuleSetFeatures(module, c.BinaryenFeatureMemory64());

    const i64_type = c.BinaryenTypeInt64();
    const none_type = c.BinaryenTypeNone();

    // env.out :: (i64, i64) -> () — imported from "env"."out".
    var env_out_params = [_]c.BinaryenType{ i64_type, i64_type };
    const env_out_params_type = c.BinaryenTypeCreate(&env_out_params, env_out_params.len);
    c.BinaryenAddFunctionImport(
        module,
        "env_out", // internal name
        "env", // external module
        "out", // external field
        env_out_params_type,
        none_type,
    );

    // Memory: 1 page, exported as "memory", with one active data
    // segment at offset 0 holding "Hello, q64.\n".
    const payload = "Hello, q64.\n";
    var seg_datas = [_][*c]const u8{payload.ptr};
    var seg_passives = [_]bool{false};
    var seg_offsets = [_]c.BinaryenExpressionRef{
        c.BinaryenConst(module, c.BinaryenLiteralInt64(0)),
    };
    var seg_sizes = [_]c.BinaryenIndex{@intCast(payload.len)};

    c.BinaryenSetMemory(
        module,
        1, // initial pages
        1, // maximum pages
        "memory", // export name
        null, // segmentNames — Binaryen auto-generates from indices
        @ptrCast(&seg_datas),
        @ptrCast(&seg_passives),
        @ptrCast(&seg_offsets),
        @ptrCast(&seg_sizes),
        seg_sizes.len,
        false, // shared
        true, // memory64
        "0", // internal memory name
    );

    // _start body: call env.out(0, payload.len).
    const ptr_arg = c.BinaryenConst(module, c.BinaryenLiteralInt64(0));
    const len_arg = c.BinaryenConst(module, c.BinaryenLiteralInt64(@intCast(payload.len)));
    var call_args = [_]c.BinaryenExpressionRef{ ptr_arg, len_arg };
    const body = c.BinaryenCall(
        module,
        "env_out",
        @ptrCast(&call_args),
        call_args.len,
        none_type,
    );

    _ = c.BinaryenAddFunction(
        module,
        "start", // internal name
        none_type, // params
        none_type, // results
        null, // varTypes
        0,
        body,
    );

    _ = c.BinaryenAddFunctionExport(module, "start", "_start");

    if (!c.BinaryenModuleValidate(module)) {
        return error.ModuleInvalid;
    }

    const result = c.BinaryenModuleAllocateAndWrite(module, null);
    defer if (result.binary) |b| std.c.free(b);
    defer if (result.sourceMap) |s| std.c.free(s);

    const binary_ptr = result.binary orelse return error.SerializeEmpty;
    if (result.binaryBytes == 0) return error.SerializeEmpty;

    const src: [*]const u8 = @ptrCast(binary_ptr);
    const out = try allocator.alloc(u8, result.binaryBytes);
    @memcpy(out, src[0..result.binaryBytes]);
    return out;
}

// =====================================================================
// AST-driven emission
// =====================================================================
//
// `emitFromSource` parses a source string, resolves imports, and emits a
// wasm module through the Q64 IR pipeline (AST → HIR → MIR → Binaryen).
// `showHir`/`showMir` share its front (parse + resolve + build HIR) and dump
// the IR tier as text for `q64 show hir|mir`. A construct the IR doesn't
// represent yet is reported as an honest `Error.UnsupportedExpression`.

pub fn emitFromSource(
    allocator: std.mem.Allocator,
    source: []const u8,
    file: []const u8,
    modules: []const ModuleSource,
    addr: AddressSpace,
) ![]u8 {
    var hmod = try buildHir(allocator, source, file, modules);
    defer hmod.deinit();
    var mmod = ir.lower.lower(allocator, &hmod) catch |e| switch (e) {
        // A shape the lowerer doesn't handle yet → honest UnsupportedExpression.
        error.Unsupported => return Error.UnsupportedExpression,
        else => |other| return other,
    };
    defer mmod.deinit();
    // The raw core module keeps q64's `env.out` host face (the contract with
    // `runtime/wasmtime/` and `runtime/browser/`). The component path emits the
    // preview1 variant separately.
    return lowerToWasm(allocator, &mmod, addr, .env_out);
}

/// The product of `emitComponent`. Either a finished component (the import-free
/// scalar library lift, which `component.zig` encodes in pure Zig), or — for an
/// app that reaches stdout — a WASI **preview1 core module** the caller adapts
/// into a real `wasi:cli/run` component (`q64 emit --component` shells out to
/// `wasm-tools component new --adapt` with the `vendor/wasi/` adapter). Keeping
/// the adapter shell-out in the CLI layer leaves this codegen module free of
/// subprocess/filesystem concerns.
pub const ComponentArtifact = union(enum) {
    /// A finished WebAssembly component, ready to write. Caller owns the slice.
    component: []u8,
    /// A WASI preview1 core module (imports `wasi_snapshot_preview1.fd_write`,
    /// exports `_start`) to be wrapped by the WASI adapter. Caller owns it.
    preview1_app: []u8,
};

/// Emit the component artifact for `q64 emit --component` (spec/modules.md §"The
/// qube as a component"). A library lifts the import-free, scalar-signature
/// slice of its public surface through the canonical ABI (`component.encode`).
/// An app — one that reaches the `@stdout` capability (`env.out`) — is emitted
/// as a WASI **preview1 core module** (the `fd_write` import shape) for the
/// caller to run through the WASI adapter; preview1 is 32-bit, so a wasm64 app
/// is `ComponentNeedsImportLowering`. A library whose core still imports a
/// capability the lift can't satisfy (e.g. a `qview.*` face) is likewise
/// `ComponentNeedsImportLowering`; a surface with no liftable export is
/// `ComponentNoExports`.
pub fn emitComponent(allocator: std.mem.Allocator, source: []const u8, file: []const u8, modules: []const ModuleSource, addr: AddressSpace) !ComponentArtifact {
    var hmod = try buildHir(allocator, source, file, modules);
    defer hmod.deinit();
    var mmod = ir.lower.lower(allocator, &hmod) catch |e| switch (e) {
        error.Unsupported => return Error.UnsupportedExpression,
        else => |other| return other,
    };
    defer mmod.deinit();

    // An app reaches stdout (`env.out` → `@stdout`). Emit a preview1 core module
    // — `wasi_snapshot_preview1.fd_write`, `_start` — and hand it back for the
    // WASI adapter to lift into `wasi:cli/run` importing `wasi:cli/stdout`. The
    // preview1 ABI is 32-bit (i32 iovec/fd_write); a wasm64 app isn't lowerable.
    if (usesEnvOut(&mmod)) {
        if (addr != .wasm32) return Error.ComponentNeedsImportLowering;
        return .{ .preview1_app = try lowerToWasm(allocator, &mmod, addr, .wasi_preview1) };
    }

    const core = try lowerToWasm(allocator, &mmod, addr, .env_out);
    defer allocator.free(core);

    // A library core that still imports something (e.g. a `qview.*` host face)
    // can't be lifted by the scalar encoder — report it honestly rather than
    // emitting an invalid component.
    if (coreHasImports(core)) return Error.ComponentNeedsImportLowering;

    // Gather the scalar public exports. A non-scalar (`str`/list) export needs
    // memory/realloc canon options not in this slice — skip it for now.
    var exports: std.ArrayList(component.Export) = .empty;
    defer exports.deinit(allocator);
    for (hmod.funcs, 0..) |f, i| {
        const is_entry = (hmod.entry != null and hmod.entry.? == i);
        if (f.visibility != .public and !is_entry) continue;
        const params = try allocator.alloc(component.Scalar, f.params.len);
        var ok = true;
        for (f.params, 0..) |p, j| {
            params[j] = component.Scalar.fromHir(p.ty) orelse {
                ok = false;
                break;
            };
        }
        const ret: ?component.Scalar = if (f.ret == .void) null else component.Scalar.fromHir(f.ret) orelse {
            allocator.free(params);
            continue;
        };
        if (!ok) {
            allocator.free(params);
            continue;
        }
        try exports.append(allocator, .{
            .name = f.name,
            .core_name = if (is_entry) "_start" else f.name,
            .params = params,
            .ret = ret,
        });
    }
    defer for (exports.items) |e| allocator.free(e.params);

    if (exports.items.len == 0) return Error.ComponentNoExports;
    return .{ .component = try component.encode(allocator, core, exports.items) };
}

/// Scan a core module for an import section (id 2). Used to gate component
/// emission — an import-free module is the slice the lift handles today.
fn coreHasImports(core: []const u8) bool {
    if (core.len < 8) return false;
    var p: usize = 8; // skip the 8-byte preamble
    while (p < core.len) {
        const id = core[p];
        p += 1;
        var size: usize = 0;
        var shift: u6 = 0;
        while (p < core.len) : (shift += 7) {
            const b = core[p];
            p += 1;
            size |= @as(usize, b & 0x7f) << shift;
            if (b & 0x80 == 0) break;
        }
        if (id == 2) return true; // import section
        p += size;
    }
    return false;
}

/// Build the HIR for `source` and return its text dump (`q64 show hir`).
pub fn showHir(allocator: std.mem.Allocator, source: []const u8, file: []const u8, modules: []const ModuleSource) ![]u8 {
    var hmod = try buildHir(allocator, source, file, modules);
    defer hmod.deinit();
    return ir.print.hirToString(allocator, &hmod);
}

/// Lower `source` to MIR and return its text dump (`q64 show mir`).
pub fn showMir(allocator: std.mem.Allocator, source: []const u8, file: []const u8, modules: []const ModuleSource) ![]u8 {
    var hmod = try buildHir(allocator, source, file, modules);
    defer hmod.deinit();
    var mmod = ir.lower.lower(allocator, &hmod) catch |e| switch (e) {
        error.Unsupported => return Error.UnsupportedExpression,
        else => |other| return other,
    };
    defer mmod.deinit();
    return ir.print.mirToString(allocator, &mmod);
}

/// `q64 show effects <fn> --qube <file>` — the inferred capability effect set
/// of one function (spec/q64-cli.md §"show", spec/effects.md). Builds the
/// effect-annotated HIR and prints `<fn>: @stdout + @io` (or `: (none)` for a
/// function that reaches no capability). An unknown function name is
/// `NameNotFound`, matching `emit`/`show hir`.
pub fn showEffects(allocator: std.mem.Allocator, source: []const u8, file: []const u8, modules: []const ModuleSource, fn_name: []const u8) ![]u8 {
    var hmod = try buildHir(allocator, source, file, modules);
    defer hmod.deinit();
    for (hmod.funcs) |f| {
        if (std.mem.eql(u8, f.name, fn_name)) {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(allocator);
            try out.appendSlice(allocator, fn_name);
            try out.appendSlice(allocator, ": ");
            try appendEffectSet(allocator, &out, f.effects);
            try out.append(allocator, '\n');
            return out.toOwnedSlice(allocator);
        }
    }
    return Error.NameNotFound;
}

/// `q64 show capabilities --qube <file>` — the qube's compiler-derived
/// capability set: the closure of effects over its public (exported) surface
/// (spec/q64-cli.md §"show", spec/modules.md §"The qube as a component"). One
/// marker per line, finest-grained first; `(none)` when the surface is pure.
pub fn showCapabilities(allocator: std.mem.Allocator, source: []const u8, file: []const u8, modules: []const ModuleSource) ![]u8 {
    var hmod = try buildHir(allocator, source, file, modules);
    defer hmod.deinit();
    const caps = qubeCapabilities(&hmod);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    if (caps.count() == 0) {
        try out.appendSlice(allocator, "(none)\n");
    } else {
        var it = caps.iterator();
        while (it.next()) |eff| {
            try out.appendSlice(allocator, eff.marker());
            try out.append(allocator, '\n');
        }
    }
    return out.toOwnedSlice(allocator);
}

/// `q64 show world --qube <file>` — the synthesized WIT `world` for the qube
/// (spec/q64-cli.md §"show", spec/modules.md §"The qube as a component"):
/// exports = the public surface, imports = the derived capability set mapped
/// through the effect→WIT-import table (spec/effects.md). The format is
/// human/test-facing, not a stable serialization.
pub fn showWorld(allocator: std.mem.Allocator, source: []const u8, file: []const u8, modules: []const ModuleSource) ![]u8 {
    var hmod = try buildHir(allocator, source, file, modules);
    defer hmod.deinit();
    const caps = qubeCapabilities(&hmod);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const world = worldName(file);
    try out.print(allocator, "// synthesized WIT world for {s} (q64 show world)\n", .{file});
    try out.print(allocator, "world {s} {{\n", .{world});

    // Imports — the derived capability set, mapped to WIT interfaces. `@io`
    // (the umbrella) and `@wire` carry no fixed interface, so they're noted but
    // not emitted as an `import`.
    try out.appendSlice(allocator, "  // imports — derived capability set\n");
    var any_import = false;
    var it = caps.iterator();
    while (it.next()) |eff| {
        if (eff.witImport()) |wit| {
            try out.print(allocator, "  import {s};\n", .{wit});
            any_import = true;
        }
    }
    if (!any_import) try out.appendSlice(allocator, "  // (none — pure surface)\n");

    // Exports — the public surface. An **app** (one with an entry point) is a
    // WASI command: the adapter lifts `_start` to `wasi:cli/run`, so the world
    // exports exactly that — its `pub` functions aren't lifted across the
    // canonical ABI. A **library** exports each `pub` function whose signature
    // lowers to the canonical ABI.
    try out.appendSlice(allocator, "  // exports — public surface\n");
    if (hmod.entry != null) {
        try out.appendSlice(allocator, "  export wasi:cli/run;\n");
    } else {
        for (hmod.funcs, 0..) |f, i| {
            const is_entry = (hmod.entry != null and hmod.entry.? == i);
            if (f.visibility != .public and !is_entry) continue;
            try out.print(allocator, "  export {s}: func(", .{f.name});
            for (f.params, 0..) |p, pi| {
                if (pi > 0) try out.appendSlice(allocator, ", ");
                try out.print(allocator, "{s}: {s}", .{ p.name, witType(p.ty) });
            }
            try out.appendSlice(allocator, ")");
            if (f.ret != .void) try out.print(allocator, " -> {s}", .{witType(f.ret)});
            try out.appendSlice(allocator, ";\n");
        }
    }

    try out.appendSlice(allocator, "}\n");
    return out.toOwnedSlice(allocator);
}

/// Union the effect sets of the qube's public surface (entry + `pub` funcs).
/// Each function's `effects` is already the transitive closure, so a private
/// helper's capabilities are folded into its public callers — unioning the
/// public funcs yields the whole qube's capability set.
fn qubeCapabilities(m: *const ir.hir.Module) std.EnumSet(ir.hir.Effect) {
    var caps = std.EnumSet(ir.hir.Effect).initEmpty();
    for (m.funcs, 0..) |f, i| {
        const is_entry = (m.entry != null and m.entry.? == i);
        if (f.visibility != .public and !is_entry) continue;
        for (f.effects) |eff| caps.insert(eff);
    }
    return caps;
}

/// Append an effect set as `@a + @b`, or `(none)` when empty.
fn appendEffectSet(allocator: std.mem.Allocator, out: *std.ArrayList(u8), effs: []const ir.hir.Effect) !void {
    if (effs.len == 0) {
        try out.appendSlice(allocator, "(none)");
        return;
    }
    for (effs, 0..) |eff, i| {
        if (i > 0) try out.appendSlice(allocator, " + ");
        try out.appendSlice(allocator, eff.marker());
    }
}

/// Lower a q64 type to its WIT canonical-ABI name (spec/modules.md §"Lowering
/// q64 types to the canonical ABI"). v0 covers the scalar surface the compiler
/// emits; `ptr` is an internal lowering artifact and should not reach a `pub`
/// signature.
fn witType(t: ir.hir.Type) []const u8 {
    return switch (t) {
        .i64 => "s64",
        .i32 => "s32",
        .f64 => "f64",
        .bool => "bool",
        .str => "string",
        .ptr => "u64", // internal pointer width; not a canonical-ABI export type
        .void => "_",
    };
}

/// Derive a WIT world name from the source file: its basename without the
/// extension, with non-identifier bytes mapped to `-` (WIT uses kebab-case).
fn worldName(file: []const u8) []const u8 {
    var name = file;
    if (std.mem.lastIndexOfScalar(u8, name, '/')) |slash| name = name[slash + 1 ..];
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| {
        if (dot > 0) name = name[0..dot];
    }
    return if (name.len == 0) "qube" else name;
}

/// Adapts the codegen `Resolver` to the IR builder's `ModuleResolver` so
/// `build_hir` can resolve call targets to their AST without `ir/` depending
/// on `codegen/`.
fn resolverLookupShim(ctx: *anyopaque, name: []const u8) ?ast.FnDecl {
    const r: *Resolver = @ptrCast(@alignCast(ctx));
    return r.lookup(name);
}

/// Parse `source`, resolve its imports against `modules`, and build the HIR —
/// the shared front of `emitFromSource` and `q64 show hir|mir`. Returns the
/// arena-owned HIR module (caller `deinit`s). A construct the IR can't yet
/// represent is an honest `UnsupportedExpression`; a definite semantic error
/// surfaces as its diagnostic code (`build_hir.Reject` → `mapReject`). The
/// parse result and resolver are scoped to HIR construction (the HIR retains
/// no AST or resolver pointers), so both are freed before returning.
fn buildHir(allocator: std.mem.Allocator, source: []const u8, file: []const u8, modules: []const ModuleSource) !ir.hir.Module {
    const parse_result = try parse.parse(allocator, source, file);
    defer parse_result.deinit(allocator);
    const sf = ast.SourceFile.cast(parse_result.root) orelse return Error.NoMainFunction;

    // Resolve every import against `modules` and index this file's own
    // functions (so a local `version()` resolves without an import). An
    // unresolvable import is an honest error here (ladder step 0).
    var resolver = Resolver.init(allocator, modules);
    defer resolver.deinit();
    try resolver.indexLocalFunctions(sf);
    try resolver.resolveImports(sf);

    const mres = ir.hir.ModuleResolver{ .ctx = &resolver, .lookupFn = resolverLookupShim };
    return switch (try ir.build_hir.tryBuild(allocator, sf, mres)) {
        .unsupported => Error.UnsupportedExpression,
        .rejected => |r| mapReject(r),
        .module => |m| m,
    };
}

/// Map an IR-detected semantic error to its honest-baseline diagnostic code
/// (the codes the now-removed legacy emitter used, kept stable for callers).
fn mapReject(r: ir.hir.Reject) Error {
    return switch (r) {
        .no_main => Error.NoMainFunction,
        .unsupported_call => Error.UnsupportedCall,
        .name_not_found => Error.NameNotFound,
        .not_const => Error.NotConstExpr,
        .immutable_assign => Error.ImmutableAssign,
    };
}

fn lowerToWasm(allocator: std.mem.Allocator, m: *const ir.mir.Module, addr: AddressSpace, stdout_abi: StdoutAbi) ![]u8 {
    const module = c.BinaryenModuleCreate() orelse return Error.ModuleCreate;
    defer c.BinaryenModuleDispose(module);

    // Wasm 3.0 feature set. Memory64 is included only for wasm64; wasm32 omits
    // it so the emitted module is a genuine 32-bit module (the WebKit/iPad
    // baseline). Multivalue + BulkMemory are address-space-independent.
    var features = c.BinaryenFeatureMultivalue() | c.BinaryenFeatureBulkMemory() |
        c.BinaryenFeatureBulkMemoryOpt() | c.BinaryenFeatureMutableGlobals();
    if (addr == .wasm64) features |= c.BinaryenFeatureMemory64();
    c.BinaryenModuleSetFeatures(module, features);

    const mem64 = addr.memory64();
    const i64_type = c.BinaryenTypeInt64();
    const i32_type = c.BinaryenTypeInt32();
    const none_type = c.BinaryenTypeNone();
    // A pointer / length is i64 on wasm64 (Memory64) and i32 on wasm32. The
    // string `(ptr, len)` pair, env.out's params, the data-segment offset, and
    // the scope arena all follow this width; integer *values* stay i64 either
    // way (q64 ints are i64 — only memory addresses are width-sensitive).
    const ptr_type = if (mem64) i64_type else i32_type;

    // A `str` value is the `(ptr, len)` pair, both at the address width. So the
    // whole string/arena ABI — env.out's params, the data-segment offset, the
    // `sp` bump global, `__fmt_i64`, concat, and str values/params/bindings —
    // is pointer-width on either address space, and runs on wasm32 (no
    // Memory64) just as on wasm64.
    var pair = [_]c.BinaryenType{ ptr_type, ptr_type };
    const pair_type = c.BinaryenTypeCreate(&pair, pair.len);

    // The `env.out` capability import — declared only when the program actually
    // writes to it (a pure library imports nothing, which lets the component
    // lift wrap it with no imports). Two import shapes (see `StdoutAbi`):
    //   - `.env_out`       → q64's raw host face `(import "env" "out")`.
    //   - `.wasi_preview1` → WASI `(import "wasi_snapshot_preview1" "fd_write")`,
    //                        which the WASI adapter lifts to `wasi:cli/stdout`.
    // The preview1 path also reserves a fixed scratch region (`iovec_base`) just
    // past the static data for the iovec + `nwritten` cell `fd_write` needs; the
    // arena starts past it so concat buffers never clobber the iovec.
    const wants_out = usesEnvOut(m);
    const preview1 = (stdout_abi == .wasi_preview1) and wants_out;
    // iovec (8 bytes: i32 buf, i32 len) + nwritten (4 bytes), padded to 16.
    const iovec_scratch: usize = if (preview1) 16 else 0;
    const iovec_base: u32 = @intCast(m.data.len);
    if (wants_out) {
        switch (stdout_abi) {
            .env_out => {
                var env_out_params = [_]c.BinaryenType{ ptr_type, ptr_type };
                const env_out_params_type = c.BinaryenTypeCreate(&env_out_params, env_out_params.len);
                c.BinaryenAddFunctionImport(module, "env_out", "env", "out", env_out_params_type, none_type);
            },
            .wasi_preview1 => {
                // fd_write(fd: i32, iovs: i32, iovs_len: i32, nwritten: i32) -> errno: i32.
                var fd_params = [_]c.BinaryenType{ i32_type, i32_type, i32_type, i32_type };
                const fd_params_type = c.BinaryenTypeCreate(&fd_params, fd_params.len);
                c.BinaryenAddFunctionImport(module, "fd_write", "wasi_snapshot_preview1", "fd_write", fd_params_type, i32_type);
            },
        }
    }

    // Memory maximum. The preview1 path leaves it unbounded (Binaryen's
    // `kUnlimitedSize` sentinel emits no max) because the WASI adapter grows the
    // memory to carve its own stack at startup — a fixed 1-page max would trap
    // `allocate_stack`. The raw `env.out`/library paths keep the 1-page cap.
    const mem_max: c.BinaryenIndex = if (preview1) 0xffff_ffff else 1;

    // One active data segment at offset 0 holds the whole memory image.
    if (m.data.len == 0) {
        c.BinaryenSetMemory(module, 1, mem_max, "memory", null, null, null, null, null, 0, false, mem64, "0");
    } else {
        var seg_datas = [_][*c]const u8{m.data.ptr};
        var seg_passives = [_]bool{false};
        var seg_offsets = [_]c.BinaryenExpressionRef{
            if (mem64)
                c.BinaryenConst(module, c.BinaryenLiteralInt64(0))
            else
                c.BinaryenConst(module, c.BinaryenLiteralInt32(0)),
        };
        var seg_sizes = [_]c.BinaryenIndex{@intCast(m.data.len)};
        c.BinaryenSetMemory(module, 1, mem_max, "memory", null, @ptrCast(&seg_datas), @ptrCast(&seg_passives), @ptrCast(&seg_offsets), @ptrCast(&seg_sizes), seg_sizes.len, false, mem64, "0");
    }

    // Int formatting needs `__fmt_i64`; either formatting or a concat needs
    // the scope-arena bump global (`sp`).
    var needs_fmt = false;
    var needs_arena = false;
    for (m.funcs) |f| {
        const inst = switch (f.body) {
            .structured => |x| x,
            .cfg => return Error.CfgUnsupported,
        };
        if (bodyHasOut(inst, true)) needs_fmt = true;
        var sc = Scratch{};
        scanScratch(inst, &sc);
        if (sc.has_concat) needs_arena = true;
    }
    if (needs_fmt) needs_arena = true;
    if (needs_arena) {
        // The scope-arena bump pointer starts just past the static data — and,
        // on the preview1 path, past the reserved iovec scratch — at the address
        // width (i32 on wasm32, i64 on wasm64).
        const arena_start = m.data.len + iovec_scratch;
        const sp_init = if (mem64)
            c.BinaryenConst(module, c.BinaryenLiteralInt64(@intCast(arena_start)))
        else
            c.BinaryenConst(module, c.BinaryenLiteralInt32(@intCast(arena_start)));
        _ = c.BinaryenAddGlobal(module, "sp", ptr_type, true, sp_init);
    }
    if (needs_fmt) try emitFmtI64(module, allocator, i64_type, pair_type, ptr_type, mem64);

    // Host-face imports (e.g. `qview.text`): declare one wasm import per distinct
    // host_call name. All args are i64 (valid on wasm32); the import returns void.
    // Names live in `name_arena` through module emission.
    var name_arena = std.heap.ArenaAllocator.init(allocator);
    defer name_arena.deinit();
    const na = name_arena.allocator();
    var host_imports = std.StringHashMapUnmanaged([*:0]const u8){};
    {
        var arity = std.StringHashMapUnmanaged(usize){};
        for (m.funcs) |f| {
            const inst = switch (f.body) {
                .structured => |x| x,
                .cfg => return Error.CfgUnsupported,
            };
            try scanHostCalls(inst, &arity, na);
        }
        var it = arity.iterator();
        while (it.next()) |e| {
            const dotted = e.key_ptr.*;
            const n = e.value_ptr.*;
            const dot = std.mem.indexOfScalar(u8, dotted, '.') orelse return Error.UnsupportedCall;
            const mod_z = try na.dupeZ(u8, dotted[0..dot]);
            const field_z = try na.dupeZ(u8, dotted[dot + 1 ..]);
            const internal = try std.fmt.allocPrint(na, "{s}_{s}", .{ dotted[0..dot], dotted[dot + 1 ..] });
            const internal_z = try na.dupeZ(u8, internal);
            const params = try na.alloc(c.BinaryenType, n);
            for (params) |*p| p.* = i64_type;
            const ptype = if (n > 0) c.BinaryenTypeCreate(params.ptr, @intCast(n)) else none_type;
            c.BinaryenAddFunctionImport(module, internal_z.ptr, mod_z.ptr, field_z.ptr, ptype, none_type);
            try host_imports.put(na, dotted, internal_z.ptr);
        }
    }

    // Module-level mutable i64 globals (reactive `state`). One `(global (mut i64))`
    // per entry, initialized to its `state` value; names `g0`, `g1`, … (arena-held).
    const global_names = try na.alloc([*:0]const u8, m.globals.len);
    for (m.globals, 0..) |init_val, gi| {
        const gz = try na.dupeZ(u8, try std.fmt.allocPrint(na, "g{d}", .{gi}));
        _ = c.BinaryenAddGlobal(module, gz.ptr, i64_type, true, c.BinaryenConst(module, c.BinaryenLiteralInt64(init_val)));
        global_names[gi] = gz.ptr;
        // Export the (mutable) global by its source name so a host can read it
        // (`exports.<name>.value`) and restore it (mutable → settable from JS).
        if (gi < m.global_names.len) {
            const ext = try na.dupeZ(u8, m.global_names[gi]);
            _ = c.BinaryenAddGlobalExport(module, gz.ptr, ext.ptr);
        }
    }

    for (m.funcs) |f| {
        const structured = switch (f.body) {
            .structured => |inst| inst,
            .cfg => return Error.CfgUnsupported,
        };
        const is_entry = (f.linkage == .entry);

        // A `str` parameter is two i64 wasm params (ptr, len); an i64 is one.
        var params_width: usize = 0;
        for (f.params) |p| params_width += if (p == .str) 2 else 1;

        // Scratch layout, just past the params + declared locals:
        //   [tuple slots × n_tuples][buf][off][len].
        // The first tuple slot doubles as the host_out pair scratch.
        var sc = Scratch{};
        scanScratch(structured, &sc);
        const n_tuples: u32 = @max(@as(u32, if (sc.host_out) 1 else 0), sc.max_tuples);
        const base: u32 = @intCast(params_width + f.locals.len);

        var lw = Lowerer{
            .allocator = allocator,
            .module = module,
            .funcs = m.funcs,
            .i64_type = i64_type,
            .i32_type = i32_type,
            .ptr_type = ptr_type,
            .none_type = none_type,
            .pair_type = pair_type,
            .pair_idx = base,
            .buf_idx = base + n_tuples,
            .off_idx = base + n_tuples + 1,
            .len_idx = base + n_tuples + 2,
            .host_imports = &host_imports,
            .global_names = global_names,
            .stdout_abi = stdout_abi,
            .iovec_base = iovec_base,
        };
        defer lw.deinit();

        // varTypes (locals beyond params): declared locals, then tuple slots,
        // then the concat scratch (buf/off/len) when concatenating.
        const n_extra = f.locals.len + n_tuples + @as(usize, if (sc.has_concat) 3 else 0);
        const vts = try allocator.alloc(c.BinaryenType, n_extra);
        defer allocator.free(vts);
        for (0..f.locals.len) |i| vts[i] = wasmType(f.locals[i], i64_type, i32_type, none_type, pair_type, ptr_type);
        for (0..n_tuples) |j| vts[f.locals.len + j] = pair_type;
        if (sc.has_concat) {
            // buf / off / len are address-width pointers/lengths.
            vts[f.locals.len + n_tuples] = ptr_type;
            vts[f.locals.len + n_tuples + 1] = ptr_type;
            vts[f.locals.len + n_tuples + 2] = ptr_type;
        }

        // Parameter wasm types (a `str` param → two address-width ptr/len).
        var ptype = none_type;
        var pbuf: []c.BinaryenType = &.{};
        if (params_width > 0) {
            pbuf = try allocator.alloc(c.BinaryenType, params_width);
            var kk: usize = 0;
            for (f.params) |p| {
                if (p == .str) {
                    pbuf[kk] = ptr_type;
                    pbuf[kk + 1] = ptr_type;
                    kk += 2;
                } else {
                    pbuf[kk] = wasmType(p, i64_type, i32_type, none_type, pair_type, ptr_type);
                    kk += 1;
                }
            }
            ptype = c.BinaryenTypeCreate(pbuf.ptr, @intCast(pbuf.len));
        }
        defer if (pbuf.len > 0) allocator.free(pbuf);

        const ret = if (is_entry) none_type else wasmType(f.ret, i64_type, i32_type, none_type, pair_type, ptr_type);
        const body = try lw.inst(structured);
        _ = c.BinaryenAddFunction(module, f.name.ptr, ptype, ret, if (n_extra > 0) @ptrCast(vts.ptr) else null, @intCast(n_extra), body);
        if (is_entry) {
            _ = c.BinaryenAddFunctionExport(module, f.name.ptr, "_start");
        } else if (f.exported) {
            _ = c.BinaryenAddFunctionExport(module, f.name.ptr, f.name.ptr);
        }
    }

    if (!c.BinaryenModuleValidate(module)) return Error.ModuleInvalid;

    const result = c.BinaryenModuleAllocateAndWrite(module, null);
    defer if (result.binary) |b| std.c.free(b);
    defer if (result.sourceMap) |s| std.c.free(s);

    const binary_ptr = result.binary orelse return Error.SerializeEmpty;
    if (result.binaryBytes == 0) return Error.SerializeEmpty;

    const src: [*]const u8 = @ptrCast(binary_ptr);
    const out = try allocator.alloc(u8, result.binaryBytes);
    @memcpy(out, src[0..result.binaryBytes]);
    return out;
}

fn wasmType(t: ir.mir.ValueType, i64_type: c.BinaryenType, i32_type: c.BinaryenType, none_type: c.BinaryenType, pair_type: c.BinaryenType, ptr_type: c.BinaryenType) c.BinaryenType {
    return switch (t) {
        .i64 => i64_type,
        .i32 => i32_type,
        .f64 => c.BinaryenTypeFloat64(),
        .str => pair_type, // a (ptr, len) multivalue
        .ptr => ptr_type, // an address-width pointer/length local
        .void => none_type,
    };
}

/// Whether the tree contains an `env.out` of an i64 / a str value. An int-out
/// needs `__fmt_i64` + the arena; either needs the entry's pair scratch local.
fn bodyHasOut(inst: *const ir.mir.Inst, want_int: bool) bool {
    return switch (inst.op) {
        .host_out_int => |h| want_int or bodyHasOut(h.value, want_int),
        .host_out_str => |h| !want_int or bodyHasOut(h.value, want_int),
        .block => |items| blk: {
            for (items) |child| if (bodyHasOut(child, want_int)) break :blk true;
            break :blk false;
        },
        .local_set => |ls| bodyHasOut(ls.value, want_int),
        .bin => |b| bodyHasOut(b.lhs, want_int) or bodyHasOut(b.rhs, want_int),
        .un => |u| bodyHasOut(u.operand, want_int),
        .call => |cl| blk: {
            for (cl.args) |a| if (bodyHasOut(a, want_int)) break :blk true;
            break :blk false;
        },
        .ret => |v| if (v) |val| bodyHasOut(val, want_int) else false,
        .if_ => |iff| bodyHasOut(iff.cond, want_int) or bodyHasOut(iff.then_, want_int) or (iff.else_ != null and bodyHasOut(iff.else_.?, want_int)),
        .while_ => |w| bodyHasOut(w.cond, want_int) or bodyHasOut(w.body, want_int),
        .loop => |body| bodyHasOut(body, want_int),
        .str_concat => |pieces| blk: {
            for (pieces) |p| if (bodyHasOut(p, want_int)) break :blk true;
            break :blk false;
        },
        .str_bind => |sb| bodyHasOut(sb.value, want_int),
        .fmt_int_to_str => |inner| want_int or bodyHasOut(inner, want_int),
        .host_call => |hc| blk: {
            for (hc.args) |a| if (bodyHasOut(a, want_int)) break :blk true;
            break :blk false;
        },
        .global_set => |gs| bodyHasOut(gs.value, want_int),
        .host_out_const, .const_i64, .const_i32, .local_get, .global_get, .str_const_val, .str_param, .str_binding, .br, .br_cont, .@"unreachable" => false,
    };
}

/// Per-function scratch needs, gathered in one pass: whether it writes an i64
/// or str value (needs the pair scratch local), whether it concatenates (needs
/// the arena buf/off/len), and the most call-result tuple slots any single
/// concat requires.
/// Whether any function in the module calls `env.out` (a `host_out_*` op) —
/// gates the `env.out` import declaration. `host_call` (`qview.*`) faces have
/// their own imports and don't count.
fn usesEnvOut(m: *const ir.mir.Module) bool {
    for (m.funcs) |f| switch (f.body) {
        .structured => |root| if (instUsesEnvOut(root)) return true,
        .cfg => {},
    };
    return false;
}

fn instUsesEnvOut(inst: *const ir.mir.Inst) bool {
    switch (inst.op) {
        .host_out_const, .host_out_int, .host_out_str => return true,
        .str_concat => |pieces| for (pieces) |p| {
            if (instUsesEnvOut(p)) return true;
        },
        .fmt_int_to_str => |inner| return instUsesEnvOut(inner),
        .block => |items| for (items) |ch| {
            if (instUsesEnvOut(ch)) return true;
        },
        .local_set => |ls| return instUsesEnvOut(ls.value),
        .bin => |b| return instUsesEnvOut(b.lhs) or instUsesEnvOut(b.rhs),
        .un => |u| return instUsesEnvOut(u.operand),
        .call => |cl| for (cl.args) |a| {
            if (instUsesEnvOut(a)) return true;
        },
        .ret => |v| if (v) |val| return instUsesEnvOut(val),
        .if_ => |iff| return instUsesEnvOut(iff.cond) or instUsesEnvOut(iff.then_) or
            (iff.else_ != null and instUsesEnvOut(iff.else_.?)),
        .while_ => |w| return instUsesEnvOut(w.cond) or instUsesEnvOut(w.body),
        .loop => |body| return instUsesEnvOut(body),
        .host_call => |hc| for (hc.args) |a| {
            if (instUsesEnvOut(a)) return true;
        },
        .global_set => |gs| return instUsesEnvOut(gs.value),
        .str_bind => |sb| return instUsesEnvOut(sb.value),
        else => {},
    }
    return false;
}

const Scratch = struct { host_out: bool = false, has_concat: bool = false, max_tuples: u32 = 0 };

fn scanScratch(inst: *const ir.mir.Inst, s: *Scratch) void {
    switch (inst.op) {
        .str_concat => |pieces| {
            s.has_concat = true;
            // A `call` and an `fmt_int_to_str` piece each return a (ptr, len)
            // tuple that needs one tuple slot at the concat's call site.
            var tuples: u32 = 0;
            for (pieces) |p| {
                if (p.op == .call or p.op == .fmt_int_to_str) tuples += 1;
                scanScratch(p, s);
            }
            if (tuples > s.max_tuples) s.max_tuples = tuples;
        },
        .fmt_int_to_str => |inner| scanScratch(inner, s),
        .host_out_int => |h| {
            s.host_out = true;
            scanScratch(h.value, s);
        },
        .host_out_str => |h| {
            s.host_out = true;
            scanScratch(h.value, s);
        },
        .str_bind => |sb| {
            s.host_out = true; // uses the pair scratch to split (ptr, len)
            scanScratch(sb.value, s);
        },
        .block => |items| for (items) |ch| scanScratch(ch, s),
        .local_set => |ls| scanScratch(ls.value, s),
        .bin => |b| {
            scanScratch(b.lhs, s);
            scanScratch(b.rhs, s);
        },
        .un => |u| scanScratch(u.operand, s),
        .call => |cl| for (cl.args) |a| scanScratch(a, s),
        .ret => |v| if (v) |val| scanScratch(val, s),
        .if_ => |iff| {
            scanScratch(iff.cond, s);
            scanScratch(iff.then_, s);
            if (iff.else_) |e| scanScratch(e, s);
        },
        .while_ => |w| {
            scanScratch(w.cond, s);
            scanScratch(w.body, s);
        },
        .loop => |body| scanScratch(body, s),
        .host_call => |hc| for (hc.args) |a| scanScratch(a, s),
        .global_set => |gs| scanScratch(gs.value, s),
        .host_out_const, .const_i64, .const_i32, .local_get, .global_get, .str_const_val, .str_param, .str_binding, .br, .br_cont, .@"unreachable" => {},
    }
}

/// Collect distinct host-face call names (e.g. `qview.text`) and their arity, so
/// `lowerToWasm` can declare one wasm import per face. Host calls appear only at
/// statement positions; their i64 args never contain another host call.
fn scanHostCalls(inst: *const ir.mir.Inst, out: *std.StringHashMapUnmanaged(usize), a: std.mem.Allocator) Error!void {
    switch (inst.op) {
        .block => |items| for (items) |ch| try scanHostCalls(ch, out, a),
        .if_ => |iff| {
            try scanHostCalls(iff.then_, out, a);
            if (iff.else_) |e| try scanHostCalls(e, out, a);
        },
        .while_ => |w| try scanHostCalls(w.body, out, a),
        .loop => |body| try scanHostCalls(body, out, a),
        .host_call => |hc| try out.put(a, hc.name, hc.args.len),
        else => {},
    }
}

/// Lowers MIR instructions to Binaryen expressions. Carries the per-function
/// context (the funcs table for call resolution, the pair scratch local).
const Lowerer = struct {
    allocator: std.mem.Allocator,
    module: c.BinaryenModuleRef,
    funcs: []const ir.mir.Func,
    i64_type: c.BinaryenType,
    i32_type: c.BinaryenType,
    /// Pointer/length width: `i32_type` on wasm32, `i64_type` on wasm64.
    ptr_type: c.BinaryenType,
    none_type: c.BinaryenType,
    pair_type: c.BinaryenType,
    /// The pair scratch local (host_out extraction) — also the base of the
    /// concat call-result tuple slots (`pair_idx + j`).
    pair_idx: c.BinaryenIndex,
    /// Scope-arena concat scratch locals (i64): the assembled buffer pointer,
    /// the running copy offset, and the total length.
    buf_idx: c.BinaryenIndex = 0,
    off_idx: c.BinaryenIndex = 0,
    len_idx: c.BinaryenIndex = 0,
    label_ctr: u32 = 0,
    loops: std.ArrayList(LoopLabels) = .empty,
    /// Dotted host-face name (`qview.text`) → the declared wasm import's internal
    /// name (`qview_text`, null-terminated), for lowering `host_call`.
    host_imports: *const std.StringHashMapUnmanaged([*:0]const u8) = undefined,
    /// Wasm global names by index (`g0`, `g1`, …), for `global_get`/`global_set`.
    global_names: []const [*:0]const u8 = &.{},
    /// How a stdout write (`env.out`) lowers: q64's `env.out` host face, or a
    /// WASI preview1 `fd_write` to fd 1 (see `StdoutAbi`).
    stdout_abi: StdoutAbi = .env_out,
    /// Static address of the reserved iovec scratch (preview1 path only): the
    /// iovec lives at `[iovec_base, iovec_base+8)`, `nwritten` at `iovec_base+8`.
    iovec_base: u32 = 0,

    fn deinit(self: *Lowerer) void {
        self.loops.deinit(self.allocator);
    }

    fn topLoop(self: *const Lowerer) ?LoopLabels {
        if (self.loops.items.len == 0) return null;
        return self.loops.items[self.loops.items.len - 1];
    }

    fn inst(self: *Lowerer, n: *const ir.mir.Inst) Error!c.BinaryenExpressionRef {
        const module = self.module;
        switch (n.op) {
            .block => |items| {
                const children = try self.allocator.alloc(c.BinaryenExpressionRef, items.len);
                defer self.allocator.free(children);
                for (items, 0..) |child, i| children[i] = try self.inst(child);
                return c.BinaryenBlock(module, null, @ptrCast(children.ptr), @intCast(children.len), self.wty(n.ty));
            },
            .host_out_const => |hc| return self.envOut(@intCast(hc.off), @intCast(hc.len)),
            .const_i64 => |v| return c.BinaryenConst(module, c.BinaryenLiteralInt64(v)),
            .const_i32 => |v| return c.BinaryenConst(module, c.BinaryenLiteralInt32(v)),
            .local_get => |idx| return c.BinaryenLocalGet(module, idx, self.wty(n.ty)),
            .local_set => |ls| return c.BinaryenLocalSet(module, ls.idx, try self.inst(ls.value)),
            .bin => |b| return c.BinaryenBinary(module, binOp(b.kind), try self.inst(b.lhs), try self.inst(b.rhs)),
            .un => |u| {
                const x = try self.inst(u.operand);
                return switch (u.kind) {
                    .neg => c.BinaryenBinary(module, c.BinaryenSubInt64(), c.BinaryenConst(module, c.BinaryenLiteralInt64(0)), x),
                    .bit_not => c.BinaryenBinary(module, c.BinaryenXorInt64(), x, c.BinaryenConst(module, c.BinaryenLiteralInt64(-1))),
                    // Logical not is truthiness: `x == 0 ? 1 : 0`. `eqz` already
                    // yields an i32 0/1; pick the width of the operand (a
                    // comparison is i32, any other integer expr is i64).
                    .not => c.BinaryenUnary(module, if (u.operand.ty == .i32) c.BinaryenEqZInt32() else c.BinaryenEqZInt64(), x),
                };
            },
            .call => |cl| {
                // A `str` argument expands to two i64 operands (ptr, len).
                var operands: std.ArrayList(c.BinaryenExpressionRef) = .empty;
                defer operands.deinit(self.allocator);
                for (cl.args) |a| {
                    if (a.ty == .str) {
                        try self.strOperands(a, &operands);
                    } else {
                        try operands.append(self.allocator, try self.inst(a));
                    }
                }
                return c.BinaryenCall(module, self.funcs[cl.func].name.ptr, if (operands.items.len > 0) operands.items.ptr else null, @intCast(operands.items.len), self.wty(n.ty));
            },
            .str_param => |idx| {
                var elems = [_]c.BinaryenExpressionRef{
                    self.ptrGet(idx * 2),
                    self.ptrGet(idx * 2 + 1),
                };
                return c.BinaryenTupleMake(module, @ptrCast(&elems), elems.len);
            },
            .str_concat => |pieces| return self.emitConcat(pieces),
            .str_binding => |sb| {
                var elems = [_]c.BinaryenExpressionRef{
                    self.ptrGet(sb.ptr_idx),
                    self.ptrGet(sb.len_idx),
                };
                return c.BinaryenTupleMake(module, @ptrCast(&elems), elems.len);
            },
            .str_bind => |sb| {
                // Stash the str value in the pair scratch, then split its
                // (ptr, len) into the binding's two locals.
                var seq = [_]c.BinaryenExpressionRef{
                    c.BinaryenLocalSet(module, self.pair_idx, try self.inst(sb.value)),
                    c.BinaryenLocalSet(module, sb.ptr_idx, c.BinaryenTupleExtract(module, c.BinaryenLocalGet(module, self.pair_idx, self.pair_type), 0)),
                    c.BinaryenLocalSet(module, sb.len_idx, c.BinaryenTupleExtract(module, c.BinaryenLocalGet(module, self.pair_idx, self.pair_type), 1)),
                };
                return c.BinaryenBlock(module, null, @ptrCast(&seq), seq.len, self.none_type);
            },
            .ret => |v| return c.BinaryenReturn(module, if (v) |val| try self.inst(val) else null),
            .str_const_val => |sc| {
                var elems = [_]c.BinaryenExpressionRef{
                    self.ptrConst(@intCast(sc.off)),
                    self.ptrConst(@intCast(sc.len)),
                };
                return c.BinaryenTupleMake(module, @ptrCast(&elems), elems.len);
            },
            .host_out_int => |hi| {
                // __fmt_i64(value) → (ptr, len), then write it + the newline.
                var fmt_args = [_]c.BinaryenExpressionRef{try self.inst(hi.value)};
                const fmt = c.BinaryenCall(module, "__fmt_i64", @ptrCast(&fmt_args), fmt_args.len, self.pair_type);
                return self.hostOutPair(fmt, @intCast(hi.nl_off));
            },
            .host_out_str => |hs| return self.hostOutPair(try self.inst(hs.value), @intCast(hs.nl_off)),
            .host_call => |hc| {
                var operands: std.ArrayList(c.BinaryenExpressionRef) = .empty;
                defer operands.deinit(self.allocator);
                for (hc.args) |a| try operands.append(self.allocator, try self.inst(a));
                const name = self.host_imports.get(hc.name) orelse return Error.UnsupportedCall;
                return c.BinaryenCall(module, name, if (operands.items.len > 0) operands.items.ptr else null, @intCast(operands.items.len), self.none_type);
            },
            .global_get => |idx| return c.BinaryenGlobalGet(module, self.global_names[idx], self.i64_type),
            .global_set => |gs| return c.BinaryenGlobalSet(module, self.global_names[gs.idx], try self.inst(gs.value)),
            .fmt_int_to_str => |inner| {
                // __fmt_i64(value) → (ptr, len). The (pair) result is the str
                // value; the caller consumes it just like any str-typed inst.
                var fmt_args = [_]c.BinaryenExpressionRef{try self.inst(inner)};
                return c.BinaryenCall(module, "__fmt_i64", @ptrCast(&fmt_args), fmt_args.len, self.pair_type);
            },
            .if_ => |iff| {
                const cond = try self.inst(iff.cond);
                const then_ = try self.inst(iff.then_);
                const else_ = if (iff.else_) |e| try self.inst(e) else null;
                return c.BinaryenIf(module, cond, then_, else_);
            },
            .while_ => |w| {
                // block $b { loop $l { br_if $b (eqz cond); <body>; br $l } }
                var blk_buf: [16]u8 = undefined;
                var loop_buf: [16]u8 = undefined;
                const blk_lbl = std.fmt.bufPrintZ(&blk_buf, "Lb{d}", .{self.label_ctr}) catch unreachable;
                const loop_lbl = std.fmt.bufPrintZ(&loop_buf, "Lc{d}", .{self.label_ctr}) catch unreachable;
                self.label_ctr += 1;

                const not_cond = c.BinaryenUnary(module, c.BinaryenEqZInt32(), try self.inst(w.cond));
                try self.loops.append(self.allocator, .{ .brk = blk_lbl, .cont = loop_lbl });
                const body = try self.inst(w.body);
                _ = self.loops.pop();

                var loop_items = [_]c.BinaryenExpressionRef{
                    c.BinaryenBreak(module, blk_lbl.ptr, not_cond, null),
                    body,
                    c.BinaryenBreak(module, loop_lbl.ptr, null, null),
                };
                const loop_block = c.BinaryenBlock(module, null, @ptrCast(&loop_items), loop_items.len, self.none_type);
                const loop = c.BinaryenLoop(module, loop_lbl.ptr, loop_block);
                var outer = [_]c.BinaryenExpressionRef{loop};
                return c.BinaryenBlock(module, blk_lbl.ptr, @ptrCast(&outer), outer.len, self.none_type);
            },
            .loop => |body_inst| {
                // block $b { loop $l { <body>; br $l } }
                var blk_buf: [16]u8 = undefined;
                var loop_buf: [16]u8 = undefined;
                const blk_lbl = std.fmt.bufPrintZ(&blk_buf, "Lb{d}", .{self.label_ctr}) catch unreachable;
                const loop_lbl = std.fmt.bufPrintZ(&loop_buf, "Lc{d}", .{self.label_ctr}) catch unreachable;
                self.label_ctr += 1;

                try self.loops.append(self.allocator, .{ .brk = blk_lbl, .cont = loop_lbl });
                const body = try self.inst(body_inst);
                _ = self.loops.pop();

                var loop_items = [_]c.BinaryenExpressionRef{
                    body,
                    c.BinaryenBreak(module, loop_lbl.ptr, null, null),
                };
                const loop_block = c.BinaryenBlock(module, null, @ptrCast(&loop_items), loop_items.len, self.none_type);
                const loop = c.BinaryenLoop(module, loop_lbl.ptr, loop_block);
                var outer = [_]c.BinaryenExpressionRef{loop};
                return c.BinaryenBlock(module, blk_lbl.ptr, @ptrCast(&outer), outer.len, self.none_type);
            },
            .br => {
                const lbl = self.topLoop() orelse return Error.BreakOutsideLoop;
                return c.BinaryenBreak(module, lbl.brk.ptr, null, null);
            },
            .br_cont => {
                const lbl = self.topLoop() orelse return Error.BreakOutsideLoop;
                return c.BinaryenBreak(module, lbl.cont.ptr, null, null);
            },
            .@"unreachable" => return c.BinaryenUnreachable(module),
        }
    }

    /// Write `[off, off+len)` of linear memory to stdout — `host_out_const` and
    /// the trailing newline of `host_out_*` go through here.
    fn envOut(self: *Lowerer, off: i64, len: i64) c.BinaryenExpressionRef {
        return self.writeStdout(self.ptrConst(off), self.ptrConst(len));
    }

    /// Emit a single stdout write of the `(ptr, len)` pair, lowered per the
    /// build's `StdoutAbi`: a direct `env.out(ptr, len)` call, or a WASI
    /// `fd_write` of one iovec to fd 1.
    fn writeStdout(self: *Lowerer, ptr_expr: c.BinaryenExpressionRef, len_expr: c.BinaryenExpressionRef) c.BinaryenExpressionRef {
        return switch (self.stdout_abi) {
            .env_out => blk: {
                var args = [_]c.BinaryenExpressionRef{ ptr_expr, len_expr };
                break :blk c.BinaryenCall(self.module, "env_out", @ptrCast(&args), args.len, self.none_type);
            },
            .wasi_preview1 => self.fdWrite(ptr_expr, len_expr),
        };
    }

    /// WASI preview1 stdout write: assemble an iovec `{buf: ptr, len}` at the
    /// reserved scratch address and `fd_write(1, iovec, 1, nwritten)`, dropping
    /// the errno. The preview1 ABI is 32-bit, so addresses/values are i32.
    fn fdWrite(self: *Lowerer, ptr_expr: c.BinaryenExpressionRef, len_expr: c.BinaryenExpressionRef) c.BinaryenExpressionRef {
        const m = self.module;
        const i32c = struct {
            fn f(mod: c.BinaryenModuleRef, v: i32) c.BinaryenExpressionRef {
                return c.BinaryenConst(mod, c.BinaryenLiteralInt32(v));
            }
        }.f;
        const base: i32 = @intCast(self.iovec_base);
        var call_args = [_]c.BinaryenExpressionRef{
            i32c(m, 1), // fd 1 = stdout
            i32c(m, base), // iovs: the iovec we just stored
            i32c(m, 1), // iovs_len: one iovec
            i32c(m, base + 8), // nwritten: 4-byte scratch cell
        };
        var seq = [_]c.BinaryenExpressionRef{
            // iovec.buf = ptr; iovec.len = len (4-byte i32 stores, natural align).
            c.BinaryenStore(m, 4, 0, 0, i32c(m, base), ptr_expr, self.i32_type, "0"),
            c.BinaryenStore(m, 4, 4, 0, i32c(m, base), len_expr, self.i32_type, "0"),
            c.BinaryenDrop(m, c.BinaryenCall(m, "fd_write", @ptrCast(&call_args), call_args.len, self.i32_type)),
        };
        return c.BinaryenBlock(m, null, @ptrCast(&seq), seq.len, self.none_type);
    }

    /// A pointer/length constant at the build's address-space width (i32 on
    /// wasm32, i64 on wasm64).
    fn ptrConst(self: *Lowerer, v: i64) c.BinaryenExpressionRef {
        return if (self.ptr_type == self.i32_type)
            c.BinaryenConst(self.module, c.BinaryenLiteralInt32(@intCast(v)))
        else
            c.BinaryenConst(self.module, c.BinaryenLiteralInt64(v));
    }

    /// `local.get idx` typed at the pointer width.
    fn ptrGet(self: *Lowerer, idx: c.BinaryenIndex) c.BinaryenExpressionRef {
        return c.BinaryenLocalGet(self.module, idx, self.ptr_type);
    }

    /// Pointer-width addition (`i32.add` on wasm32, `i64.add` on wasm64) — for
    /// arena bumps and offset stepping.
    fn ptrAdd(self: *Lowerer, a: c.BinaryenExpressionRef, b: c.BinaryenExpressionRef) c.BinaryenExpressionRef {
        const op = if (self.ptr_type == self.i32_type) c.BinaryenAddInt32() else c.BinaryenAddInt64();
        return c.BinaryenBinary(self.module, op, a, b);
    }

    /// Write a `(ptr, len)` pair value to env.out, then the newline byte:
    /// stash the pair in the scratch local, extract both halves, env.out them,
    /// then env.out(nl, 1).
    fn hostOutPair(self: *Lowerer, pair: c.BinaryenExpressionRef, nl_off: i64) c.BinaryenExpressionRef {
        const module = self.module;
        var seq = [_]c.BinaryenExpressionRef{
            c.BinaryenLocalSet(module, self.pair_idx, pair),
            self.writeStdout(
                c.BinaryenTupleExtract(module, c.BinaryenLocalGet(module, self.pair_idx, self.pair_type), 0),
                c.BinaryenTupleExtract(module, c.BinaryenLocalGet(module, self.pair_idx, self.pair_type), 1),
            ),
            self.envOut(nl_off, 1),
        };
        return c.BinaryenBlock(module, null, @ptrCast(&seq), seq.len, self.none_type);
    }

    /// Assemble a `str` in the scope arena from its pieces (mirrors the
    /// legacy `appendConcat`): call pieces land in tuple slots, the total
    /// length is summed, `sp` is bump-allocated, then each piece is
    /// `memory.copy`d in. Yields the `(buf, len)` pair.
    fn emitConcat(self: *Lowerer, pieces: []const *ir.mir.Inst) Error!c.BinaryenExpressionRef {
        const m = self.module;
        var stmts: std.ArrayList(c.BinaryenExpressionRef) = .empty;
        defer stmts.deinit(self.allocator);

        // 1. Evaluate each tuple-returning piece (call / fmt_int_to_str) into
        // its tuple slot. (str_param, str_binding, str_const_val don't need a
        // slot — they're computed inline below.)
        var j: c.BinaryenIndex = 0;
        for (pieces) |p| switch (p.op) {
            .call, .fmt_int_to_str => {
                try stmts.append(self.allocator, c.BinaryenLocalSet(m, self.pair_idx + j, try self.inst(p)));
                j += 1;
            },
            else => {},
        };

        // 2. len = constant total + each dynamic piece's length (all ptr-width).
        var const_total: u64 = 0;
        for (pieces) |p| switch (p.op) {
            .str_const_val => |sc| const_total += sc.len,
            else => {},
        };
        var total = self.ptrConst(@intCast(const_total));
        j = 0;
        for (pieces) |p| switch (p.op) {
            .call, .fmt_int_to_str => {
                total = self.ptrAdd(total, c.BinaryenTupleExtract(m, c.BinaryenLocalGet(m, self.pair_idx + j, self.pair_type), 1));
                j += 1;
            },
            .str_param => |idx| total = self.ptrAdd(total, self.ptrGet(idx * 2 + 1)),
            .str_binding => |sb| total = self.ptrAdd(total, self.ptrGet(sb.len_idx)),
            .str_const_val => {},
            else => return Error.UnsupportedCall,
        };
        try stmts.append(self.allocator, c.BinaryenLocalSet(m, self.len_idx, total));

        // 3. buf = sp; sp += len.
        try stmts.append(self.allocator, c.BinaryenLocalSet(m, self.buf_idx, c.BinaryenGlobalGet(m, "sp", self.ptr_type)));
        try stmts.append(self.allocator, c.BinaryenGlobalSet(m, "sp", self.ptrAdd(self.ptrGet(self.buf_idx), self.ptrGet(self.len_idx))));

        // 4. off = buf; memory.copy each piece, bumping off.
        try stmts.append(self.allocator, c.BinaryenLocalSet(m, self.off_idx, self.ptrGet(self.buf_idx)));
        j = 0;
        for (pieces) |p| {
            var src: c.BinaryenExpressionRef = undefined;
            var ln: c.BinaryenExpressionRef = undefined;
            var ln2: c.BinaryenExpressionRef = undefined;
            switch (p.op) {
                .str_const_val => |sc| {
                    src = self.ptrConst(@intCast(sc.off));
                    ln = self.ptrConst(@intCast(sc.len));
                    ln2 = self.ptrConst(@intCast(sc.len));
                },
                .str_param => |idx| {
                    src = self.ptrGet(idx * 2);
                    ln = self.ptrGet(idx * 2 + 1);
                    ln2 = self.ptrGet(idx * 2 + 1);
                },
                .str_binding => |sb| {
                    src = self.ptrGet(sb.ptr_idx);
                    ln = self.ptrGet(sb.len_idx);
                    ln2 = self.ptrGet(sb.len_idx);
                },
                .call, .fmt_int_to_str => {
                    src = c.BinaryenTupleExtract(m, c.BinaryenLocalGet(m, self.pair_idx + j, self.pair_type), 0);
                    ln = c.BinaryenTupleExtract(m, c.BinaryenLocalGet(m, self.pair_idx + j, self.pair_type), 1);
                    ln2 = c.BinaryenTupleExtract(m, c.BinaryenLocalGet(m, self.pair_idx + j, self.pair_type), 1);
                    j += 1;
                },
                else => return Error.UnsupportedCall,
            }
            try stmts.append(self.allocator, c.BinaryenMemoryCopy(m, self.ptrGet(self.off_idx), src, ln, "0", "0"));
            try stmts.append(self.allocator, c.BinaryenLocalSet(m, self.off_idx, self.ptrAdd(self.ptrGet(self.off_idx), ln2)));
        }

        // 5. The block yields the assembled (buf, len).
        var elems = [_]c.BinaryenExpressionRef{
            self.ptrGet(self.buf_idx),
            self.ptrGet(self.len_idx),
        };
        try stmts.append(self.allocator, c.BinaryenTupleMake(m, @ptrCast(&elems), elems.len));
        return c.BinaryenBlock(m, null, @ptrCast(stmts.items.ptr), @intCast(stmts.items.len), self.pair_type);
    }

    fn wty(self: *const Lowerer, t: ir.mir.ValueType) c.BinaryenType {
        return wasmType(t, self.i64_type, self.i32_type, self.none_type, self.pair_type, self.ptr_type);
    }

    /// Emit the two i64 operands (ptr, len) for a `str` argument. Only simple
    /// str values (a constant or a parameter) are passable today; a runtime
    /// str value as an argument lands with the runtime-binding slice.
    fn strOperands(self: *Lowerer, arg: *const ir.mir.Inst, out: *std.ArrayList(c.BinaryenExpressionRef)) Error!void {
        switch (arg.op) {
            .str_const_val => |sc| {
                try out.append(self.allocator, self.ptrConst(@intCast(sc.off)));
                try out.append(self.allocator, self.ptrConst(@intCast(sc.len)));
            },
            .str_param => |idx| {
                try out.append(self.allocator, self.ptrGet(idx * 2));
                try out.append(self.allocator, self.ptrGet(idx * 2 + 1));
            },
            .str_binding => |sb| {
                try out.append(self.allocator, self.ptrGet(sb.ptr_idx));
                try out.append(self.allocator, self.ptrGet(sb.len_idx));
            },
            else => return Error.UnsupportedCall,
        }
    }
};

fn binOp(kind: ir.ops.BinKind) c.BinaryenOp {
    return switch (kind) {
        .add => c.BinaryenAddInt64(),
        .sub => c.BinaryenSubInt64(),
        .mul => c.BinaryenMulInt64(),
        .div => c.BinaryenDivSInt64(),
        .rem => c.BinaryenRemSInt64(),
        .bit_and => c.BinaryenAndInt64(),
        .bit_or => c.BinaryenOrInt64(),
        .bit_xor => c.BinaryenXorInt64(),
        .shl => c.BinaryenShlInt64(),
        .shr => c.BinaryenShrSInt64(),
        .eq => c.BinaryenEqInt64(),
        .ne => c.BinaryenNeInt64(),
        .lt => c.BinaryenLtSInt64(),
        .le => c.BinaryenLeSInt64(),
        .gt => c.BinaryenGtSInt64(),
        .ge => c.BinaryenGeSInt64(),
    };
}

const Resolver = struct {
    allocator: std.mem.Allocator,
    modules: []const ModuleSource,
    /// Parsed dependency modules, kept alive so the `FnDecl` views below
    /// stay valid for the lifetime of the resolver.
    parsed: std.ArrayList(parse.Result),
    /// name → defining function. Keys are slices into a CST that outlives
    /// the resolver (the caller's parse result or a `parsed` entry).
    symbols: std.StringHashMapUnmanaged(ast.FnDecl),

    fn init(allocator: std.mem.Allocator, modules: []const ModuleSource) Resolver {
        return .{
            .allocator = allocator,
            .modules = modules,
            .parsed = .empty,
            .symbols = .empty,
        };
    }

    fn deinit(self: *Resolver) void {
        for (self.parsed.items) |r| r.deinit(self.allocator);
        self.parsed.deinit(self.allocator);
        self.symbols.deinit(self.allocator);
    }

    /// Index every top-level function in `sf` under its own name, so a
    /// program that defines and calls a local const function resolves
    /// without an import.
    fn indexLocalFunctions(self: *Resolver, sf: ast.SourceFile) !void {
        var it = sf.items();
        while (it.next()) |item| switch (item) {
            .fn_decl => |fd| {
                const name = fd.name() orelse continue;
                try self.symbols.put(self.allocator, name.text, fd);
            },
            else => {},
        };
    }

    /// Resolve each import statement against the `--module` set. Binds
    /// every selectively-imported name to its defining function. Errors
    /// on unresolvable imports (unknown module, missing name) and on
    /// import forms not yet supported (relative paths, stdlib).
    fn resolveImports(self: *Resolver, sf: ast.SourceFile) !void {
        var imports = sf.imports();
        while (imports.next()) |im| {
            if (im.isRelative()) return Error.UnsupportedImport;

            const module_path = (try im.path(self.allocator)) orelse return Error.UnsupportedImport;
            defer self.allocator.free(module_path);

            const src = self.moduleSource(module_path) orelse return Error.UnknownModule;

            const r = try parse.parse(self.allocator, src, module_path);
            try self.parsed.append(self.allocator, r);
            const dep_sf = ast.SourceFile.cast(r.root) orelse return Error.UnknownModule;

            var names = im.names();
            while (names.next()) |name_tok| {
                const fd = findPublicFn(dep_sf, name_tok.text) orelse return Error.NameNotFound;
                try self.symbols.put(self.allocator, name_tok.text, fd);
            }
        }
    }

    fn moduleSource(self: *Resolver, name: []const u8) ?[]const u8 {
        for (self.modules) |m| {
            if (std.mem.eql(u8, m.name, name)) return m.source;
        }
        return null;
    }

    fn lookup(self: *Resolver, name: []const u8) ?ast.FnDecl {
        return self.symbols.get(name);
    }
};

fn findPublicFn(sf: ast.SourceFile, name: []const u8) ?ast.FnDecl {
    var it = sf.items();
    while (it.next()) |item| switch (item) {
        .fn_decl => |fd| {
            if (!fd.isPublic()) continue;
            const fn_name = fd.name() orelse continue;
            if (std.mem.eql(u8, fn_name.text, name)) return fd;
        },
        else => {},
    };
    return null;
}

/// The wasm labels for one enclosing loop: `brk` exits it (the outer
/// `block`), `cont` re-enters it (the `loop`). `break`/`continue` target
/// the innermost — the top of `IntScope.loops`.
const LoopLabels = struct { brk: [:0]const u8, cont: [:0]const u8 };

/// Emit `__fmt_i64(n: i64) -> (i64, i64)`: format `n` to decimal in the
/// scope arena, returning (ptr, len). Writes digits backward into a 24-byte
/// bump allocation, then prepends `-` for negatives.
fn emitFmtI64(module: c.BinaryenModuleRef, allocator: std.mem.Allocator, i64_type: c.BinaryenType, pair_type: c.BinaryenType, ptr_type: c.BinaryenType, mem64: bool) !void {
    const i32_type = c.BinaryenTypeInt32();
    const none = c.BinaryenTypeNone();
    // Locals: 0=n (param, i64 value), 1=mag (i64 value), 2=p, 3=end
    // (address-width pointers into the arena), 4=neg (i32). The digit
    // arithmetic stays i64; only the cursor + arena pointers track the width.
    const N: c.BinaryenIndex = 0;
    const MAG: c.BinaryenIndex = 1;
    const P: c.BinaryenIndex = 2;
    const END: c.BinaryenIndex = 3;
    const NEG: c.BinaryenIndex = 4;
    // Pointer-width add/sub and constants (i32 on wasm32, i64 on wasm64).
    const add_p = if (mem64) c.BinaryenAddInt64() else c.BinaryenAddInt32();
    const sub_p = if (mem64) c.BinaryenSubInt64() else c.BinaryenSubInt32();
    const k = struct {
        fn i64c(m: c.BinaryenModuleRef, v: i64) c.BinaryenExpressionRef {
            return c.BinaryenConst(m, c.BinaryenLiteralInt64(v));
        }
        fn ptrc(m: c.BinaryenModuleRef, m64: bool, v: i64) c.BinaryenExpressionRef {
            return if (m64) c.BinaryenConst(m, c.BinaryenLiteralInt64(v)) else c.BinaryenConst(m, c.BinaryenLiteralInt32(@intCast(v)));
        }
        fn get(m: c.BinaryenModuleRef, idx: c.BinaryenIndex, t: c.BinaryenType) c.BinaryenExpressionRef {
            return c.BinaryenLocalGet(m, idx, t);
        }
    };

    var stmts: std.ArrayList(c.BinaryenExpressionRef) = .empty;
    defer stmts.deinit(allocator);

    // neg = n < 0
    try stmts.append(allocator, c.BinaryenLocalSet(module, NEG, c.BinaryenBinary(module, c.BinaryenLtSInt64(), k.get(module, N, i64_type), k.i64c(module, 0))));
    // mag = neg ? -n : n
    try stmts.append(allocator, c.BinaryenLocalSet(module, MAG, c.BinaryenSelect(
        module,
        k.get(module, NEG, i32_type),
        c.BinaryenBinary(module, c.BinaryenSubInt64(), k.i64c(module, 0), k.get(module, N, i64_type)),
        k.get(module, N, i64_type),
    )));
    // end = sp + 24; sp = end; p = end   (pointer arithmetic, ptr-width)
    try stmts.append(allocator, c.BinaryenLocalSet(module, END, c.BinaryenBinary(module, add_p, c.BinaryenGlobalGet(module, "sp", ptr_type), k.ptrc(module, mem64, 24))));
    try stmts.append(allocator, c.BinaryenGlobalSet(module, "sp", k.get(module, END, ptr_type)));
    try stmts.append(allocator, c.BinaryenLocalSet(module, P, k.get(module, END, ptr_type)));

    // loop: p--; mem[p] = '0' + mag%10; mag /= 10; repeat while mag != 0.
    // The store address is ptr-width; the byte value is an i64 (i64.store8).
    var loop_body: std.ArrayList(c.BinaryenExpressionRef) = .empty;
    defer loop_body.deinit(allocator);
    try loop_body.append(allocator, c.BinaryenLocalSet(module, P, c.BinaryenBinary(module, sub_p, k.get(module, P, ptr_type), k.ptrc(module, mem64, 1))));
    try loop_body.append(allocator, c.BinaryenStore(
        module,
        1,
        0,
        0,
        k.get(module, P, ptr_type),
        c.BinaryenBinary(module, c.BinaryenAddInt64(), k.i64c(module, '0'), c.BinaryenBinary(module, c.BinaryenRemUInt64(), k.get(module, MAG, i64_type), k.i64c(module, 10))),
        i64_type,
        "0",
    ));
    try loop_body.append(allocator, c.BinaryenLocalSet(module, MAG, c.BinaryenBinary(module, c.BinaryenDivUInt64(), k.get(module, MAG, i64_type), k.i64c(module, 10))));
    try loop_body.append(allocator, c.BinaryenBreak(module, "fmt", c.BinaryenBinary(module, c.BinaryenNeInt64(), k.get(module, MAG, i64_type), k.i64c(module, 0)), null));
    const loop_block = c.BinaryenBlock(module, null, @ptrCast(loop_body.items.ptr), @intCast(loop_body.items.len), none);
    try stmts.append(allocator, c.BinaryenLoop(module, "fmt", loop_block));

    // if neg: p--; mem[p] = '-'
    var sign_body = [_]c.BinaryenExpressionRef{
        c.BinaryenLocalSet(module, P, c.BinaryenBinary(module, sub_p, k.get(module, P, ptr_type), k.ptrc(module, mem64, 1))),
        c.BinaryenStore(module, 1, 0, 0, k.get(module, P, ptr_type), k.i64c(module, '-'), i64_type, "0"),
    };
    const sign_block = c.BinaryenBlock(module, null, @ptrCast(&sign_body), sign_body.len, none);
    try stmts.append(allocator, c.BinaryenIf(module, k.get(module, NEG, i32_type), sign_block, null));

    // result = (p, end - p)
    var ret = [_]c.BinaryenExpressionRef{
        k.get(module, P, ptr_type),
        c.BinaryenBinary(module, sub_p, k.get(module, END, ptr_type), k.get(module, P, ptr_type)),
    };
    try stmts.append(allocator, c.BinaryenTupleMake(module, @ptrCast(&ret), ret.len));

    const body = c.BinaryenBlock(module, null, @ptrCast(stmts.items.ptr), @intCast(stmts.items.len), pair_type);
    var var_types = [_]c.BinaryenType{ i64_type, ptr_type, ptr_type, i32_type };
    _ = c.BinaryenAddFunction(module, "__fmt_i64", i64_type, pair_type, @ptrCast(&var_types), var_types.len, body);
}

// =====================================================================
// Tests
// =====================================================================

const testing = std.testing;

// Pull the component encoder's embedded tests into the codegen test target.
test {
    _ = component;
}

test "emitHelloWasm: produces a non-empty Wasm module starting with the magic" {
    const bytes = try emitHelloWasm(testing.allocator);
    defer testing.allocator.free(bytes);

    // Every valid wasm binary starts with `\x00asm` followed by the
    // 4-byte version (currently `\x01\x00\x00\x00`).
    try testing.expect(bytes.len >= 8);
    try testing.expectEqualSlices(u8, "\x00asm", bytes[0..4]);
    try testing.expectEqualSlices(u8, "\x01\x00\x00\x00", bytes[4..8]);
}

test "emitHelloWasm: contains the expected import + export names" {
    // Cheap structural sanity check: the import/export name strings
    // should appear verbatim in the binary. Avoids parsing wasm here
    // — that's the host's job in the end-to-end test.
    const bytes = try emitHelloWasm(testing.allocator);
    defer testing.allocator.free(bytes);

    try testing.expect(std.mem.indexOf(u8, bytes, "env") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "out") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "memory") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "_start") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "Hello, q64.\n") != null);
}

test "emitFromSource: parses fn main { env.out(\"Hello, q64.\") } and emits a valid module" {
    const src =
        \\fn main {
        \\    env.out("Hello, q64.")
        \\}
        \\
    ;
    const bytes = try emitFromSource(testing.allocator, src, "hello.q", &.{}, .wasm64);
    defer testing.allocator.free(bytes);

    // Valid wasm magic + version.
    try testing.expect(bytes.len >= 8);
    try testing.expectEqualSlices(u8, "\x00asm", bytes[0..4]);

    // Payload appears verbatim in the data segment.
    try testing.expect(std.mem.indexOf(u8, bytes, "Hello, q64.\n") != null);
    // Import + export names land in their string tables.
    try testing.expect(std.mem.indexOf(u8, bytes, "env") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "out") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "_start") != null);
}

test "emitFromSource: supports multiple env.out calls" {
    const src =
        \\fn main {
        \\    env.out("one")
        \\    env.out("two")
        \\}
        \\
    ;
    const bytes = try emitFromSource(testing.allocator, src, "two.q", &.{}, .wasm64);
    defer testing.allocator.free(bytes);

    try testing.expectEqualSlices(u8, "\x00asm", bytes[0..4]);
    try testing.expect(std.mem.indexOf(u8, bytes, "one\n") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "two\n") != null);
}

test "emitFromSource: a const string emits a valid module on wasm32" {
    // The const-string path (host_out_const, i32 data offset + i32 env.out) is
    // supported on the WebKit/iPad baseline. The module validates (emit would
    // error otherwise) and carries the string bytes + newline in its data.
    const src = "fn main { env.out(\"hi\") }\n";
    const bytes = try emitFromSource(testing.allocator, src, "hi.q", &.{}, .wasm32);
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, "\x00asm", bytes[0..4]);
    try testing.expect(std.mem.indexOf(u8, bytes, "hi\n") != null);
}

test "emitFromSource: the runtime string/arena ABI emits on wasm32 (i32 pointers)" {
    // `env.out(double(21))` needs __fmt_i64 + the scope arena; both are now
    // address-width (i32 pointers on wasm32), so the module emits + validates.
    const lib = "pub fn double(n: i64) -> i64 { n + n }\n";
    const app = "import dev.q64.m.{double}\nfn main { env.out(double(21)) }\n";
    const modules = [_]ModuleSource{.{ .name = "dev.q64.m", .source = lib }};
    // Both widths emit + validate (emitFromSource validates the module, so a
    // returned slice means the i32 arena/__fmt_i64 path is well-formed).
    const w32 = try emitFromSource(testing.allocator, app, "main.q", &modules, .wasm32);
    defer testing.allocator.free(w32);
    try testing.expectEqualSlices(u8, "\x00asm", w32[0..4]);
    try testing.expect(w32.len > 8);
    const w64 = try emitFromSource(testing.allocator, app, "main.q", &modules, .wasm64);
    defer testing.allocator.free(w64);
    try testing.expectEqualSlices(u8, "\x00asm", w64[0..4]);
}

test "emitFromSource: missing main returns NoMainFunction" {
    const src = "fn helper { env.out(\"x\") }\n";
    try testing.expectError(
        Error.NoMainFunction,
        emitFromSource(testing.allocator, src, "no-main.q", &.{}, .wasm64),
    );
}

test "emitFromSource: non-env.out callee returns UnsupportedCall" {
    const src = "fn main { other.write(\"x\") }\n";
    try testing.expectError(
        Error.UnsupportedCall,
        emitFromSource(testing.allocator, src, "bad.q", &.{}, .wasm64),
    );
}

// ---------------------------------------------------------------------
// Linking: imports, const-evaluation, interpolation (ladder 0,3,5,6)
// ---------------------------------------------------------------------

test "emitFromSource: resolves a cross-module call inside interpolation" {
    // The definition of done: hello_app prints 0.1.0 by calling
    // hello_world.version().
    const lib = "//! dev.q64.hello_world\npub fn version() -> str { \"0.1.0\" }\n";
    const app =
        \\import dev.q64.hello_world.{version}
        \\
        \\fn main {
        \\    env.out("{version()}")
        \\}
        \\
    ;
    const modules = [_]ModuleSource{.{ .name = "dev.q64.hello_world", .source = lib }};
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &modules, .wasm64);
    defer testing.allocator.free(bytes);

    try testing.expectEqualSlices(u8, "\x00asm", bytes[0..4]);
    // A lone `{call}` interpolation is a single-segment concat assembled in
    // the arena at runtime; the callee's "0.1.0" is in the data image (its
    // exact placement is an implementation detail — output is covered by
    // scripts/link-roundtrip.sh).
    try testing.expect(std.mem.indexOf(u8, bytes, "0.1.0") != null);
}

test "emitFromSource: interpolation with literal text concatenates at runtime" {
    // `"v{version()}!"` is built in the scope arena from three segments —
    // the assembled "v0.1.0!" exists only at runtime, so the binary holds
    // the pieces separately, not the joined string. Behavior is covered
    // end-to-end by scripts/link-roundtrip.sh.
    const lib = "pub fn version() -> str { \"0.1.0\" }\n";
    const app = "import dev.q64.hw.{version}\nfn main { env.out(\"v{version()}!\") }\n";
    const modules = [_]ModuleSource{.{ .name = "dev.q64.hw", .source = lib }};
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &modules, .wasm64);
    defer testing.allocator.free(bytes);

    try testing.expectEqualSlices(u8, "\x00asm", bytes[0..4]);
    // The pieces are present; the joined form is not baked in.
    try testing.expect(std.mem.indexOf(u8, bytes, "0.1.0") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "v0.1.0!") == null);
}

test "emitFromSource: a local function is callable inside interpolation" {
    const app = "fn version { \"9.9.9\" }\nfn main { env.out(\"{version()}\") }\n";
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &.{}, .wasm64);
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "9.9.9\n") != null);
}

test "emitFromSource: a const fn bodied with `return` folds" {
    // `return <expr>` now surfaces through ast.Stmt, so the resolver
    // folds it the same as a tail-expression body.
    const lib = "pub fn version() -> str { return \"2.0.0\" }\n";
    const app = "import dev.q64.hw.{version}\nfn main { env.out(\"{version()}\") }\n";
    const modules = [_]ModuleSource{.{ .name = "dev.q64.hw", .source = lib }};
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &modules, .wasm64);
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "2.0.0") != null);
}

test "emitFromSource: env.out(version()) emits a real (non-folded) call" {
    // `env.out(version())` emits `version` as a real `() -> (i64, i64)`
    // function and calls it at runtime. Validation here proves the
    // multi-value module is well-formed (the ABI + Multivalue feature);
    // behavior is covered end-to-end by scripts/link-roundtrip.sh.
    const lib = "pub fn version() -> str { \"0.1.0\" }\n";
    const app =
        \\import dev.q64.hello_world.{version}
        \\
        \\fn main {
        \\    env.out(version())
        \\}
        \\
    ;
    const modules = [_]ModuleSource{.{ .name = "dev.q64.hello_world", .source = lib }};
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &modules, .wasm64);
    defer testing.allocator.free(bytes);

    try testing.expectEqualSlices(u8, "\x00asm", bytes[0..4]);
    try testing.expect(std.mem.indexOf(u8, bytes, "0.1.0") != null);
}

test "emitFromSource: env.out of an unknown function errors" {
    const app = "fn main { env.out(mystery()) }\n";
    try testing.expectError(
        Error.NameNotFound,
        emitFromSource(testing.allocator, app, "main.q", &.{}, .wasm64),
    );
}

test "emitFromSource: a string parameter is passed and returned (passthrough)" {
    // `id(s)` takes a str (lowered to two i64 params) and returns it; the
    // caller passes the literal "hi". Behavior is covered end-to-end by
    // scripts/link-roundtrip.sh.
    const lib = "pub fn id(s: str) -> str { s }\n";
    const app = "import dev.q64.s.{id}\nfn main { env.out(id(\"hi\")) }\n";
    const modules = [_]ModuleSource{.{ .name = "dev.q64.s", .source = lib }};
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &modules, .wasm64);
    defer testing.allocator.free(bytes);

    try testing.expectEqualSlices(u8, "\x00asm", bytes[0..4]);
    try testing.expect(std.mem.indexOf(u8, bytes, "hi") != null);
}

test "emitFromSource: wrong argument count errors" {
    const lib = "pub fn id(s: str) -> str { s }\n";
    const app = "import dev.q64.s.{id}\nfn main { env.out(id()) }\n";
    const modules = [_]ModuleSource{.{ .name = "dev.q64.s", .source = lib }};
    try testing.expectError(
        Error.UnsupportedCall,
        emitFromSource(testing.allocator, app, "main.q", &modules, .wasm64),
    );
}

test "emitFromSource: a parameterized body transforms its argument" {
    // `shout(s)` interpolates its parameter (`"{s}!"`); the body is built
    // in the arena from a param segment + the literal "!". The assembled
    // "hi!" exists only at runtime; behavior is covered by
    // scripts/link-roundtrip.sh.
    const lib = "pub fn shout(s: str) -> str { \"{s}!\" }\n";
    const app = "import dev.q64.s.{shout}\nfn main { env.out(shout(\"hi\")) }\n";
    const modules = [_]ModuleSource{.{ .name = "dev.q64.s", .source = lib }};
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &modules, .wasm64);
    defer testing.allocator.free(bytes);

    try testing.expectEqualSlices(u8, "\x00asm", bytes[0..4]);
    try testing.expect(std.mem.indexOf(u8, bytes, "hi") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "!") != null);
    // The joined result is assembled in the arena at runtime; behavior is
    // covered end-to-end by scripts/link-roundtrip.sh.
}

test "emitFromSource: a multi-parameter body joins its arguments" {
    // Two str params (four i64 wasm params); the body interpolates both.
    const lib = "pub fn join(a: str, b: str) -> str { \"{a}-{b}\" }\n";
    const app = "import dev.q64.s.{join}\nfn main { env.out(join(\"x\", \"y\")) }\n";
    const modules = [_]ModuleSource{.{ .name = "dev.q64.s", .source = lib }};
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &modules, .wasm64);
    defer testing.allocator.free(bytes);

    try testing.expectEqualSlices(u8, "\x00asm", bytes[0..4]);
    try testing.expect(std.mem.indexOf(u8, bytes, "x") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "y") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "-") != null);
    // "x-y" is assembled in the arena at runtime; behavior covered by
    // scripts/link-roundtrip.sh.
}

test "emitFromSource: a const-foldable call argument composes" {
    // `shout(version())`: version() folds to "0.1.0" (the argument), which
    // shout then transforms to "0.1.0!" in the arena.
    const lib = "pub fn version() -> str { \"0.1.0\" }\npub fn shout(s: str) -> str { \"{s}!\" }\n";
    const app = "import dev.q64.s.{version, shout}\nfn main { env.out(shout(version())) }\n";
    const modules = [_]ModuleSource{.{ .name = "dev.q64.s", .source = lib }};
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &modules, .wasm64);
    defer testing.allocator.free(bytes);

    try testing.expectEqualSlices(u8, "\x00asm", bytes[0..4]);
    try testing.expect(std.mem.indexOf(u8, bytes, "0.1.0") != null);
}

test "emitFromSource: a let binding folds into interpolation" {
    const app = "fn main {\n    let name = \"world\"\n    env.out(\"Hello, {name}!\")\n}\n";
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &.{}, .wasm64);
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "Hello, world!\n") != null);
}

test "emitFromSource: integer arithmetic folds at compile time" {
    const app = "fn main {\n    env.out(\"{2 + 3}\")\n    env.out(\"{(1 + 2) * 3}\")\n    env.out(\"{-5 + 8}\")\n}\n";
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &.{}, .wasm64);
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "5\n") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "9\n") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "3\n") != null);
}

test "emitFromSource: an integer binding folds in arithmetic" {
    const app = "fn main {\n    let n = 6 * 7\n    env.out(\"{n + 1}\")\n}\n";
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &.{}, .wasm64);
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "43\n") != null);
}

test "emitFromSource: division by zero isn't const-foldable" {
    const app = "fn main { env.out(\"{1 / 0}\") }\n";
    try testing.expectError(
        Error.NotConstExpr,
        emitFromSource(testing.allocator, app, "main.q", &.{}, .wasm64),
    );
}

test "emitFromSource: a runtime i64 function is called and formatted" {
    // `double(n) { n + n }` references a parameter, so it can't const-fold:
    // it's emitted as `(i64) -> i64`, called at runtime, and the result is
    // formatted by __fmt_i64. The value "42" never appears in the binary.
    const lib = "pub fn double(n: i64) -> i64 { n + n }\n";
    const app = "import dev.q64.m.{double}\nfn main { env.out(double(21)) }\n";
    const modules = [_]ModuleSource{.{ .name = "dev.q64.m", .source = lib }};
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &modules, .wasm64);
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, "\x00asm", bytes[0..4]);
    try testing.expect(std.mem.indexOf(u8, bytes, "42") == null);
}

test "emitFromSource: a multi-parameter i64 function" {
    const lib = "pub fn add(a: i64, b: i64) -> i64 { a + b }\n";
    const app = "import dev.q64.m.{add}\nfn main { env.out(add(40, 2)) }\n";
    const modules = [_]ModuleSource{.{ .name = "dev.q64.m", .source = lib }};
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &modules, .wasm64);
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, "\x00asm", bytes[0..4]);
}

test "emitFromSource: an i64 function branches on a comparison" {
    // `max(a, b) { if a > b { a } else { b } }` lowers to a wasm `if`
    // returning i64; the branch values are parameter reads. Nothing is
    // const-folded — the result is computed at runtime.
    const lib = "pub fn max(a: i64, b: i64) -> i64 { if a > b { a } else { b } }\n";
    const app = "import dev.q64.m.{max}\nfn main { env.out(max(3, 9)) }\n";
    const modules = [_]ModuleSource{.{ .name = "dev.q64.m", .source = lib }};
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &modules, .wasm64);
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, "\x00asm", bytes[0..4]);
}

test "emitFromSource: an else-if chain lowers to nested ifs" {
    const lib = "pub fn sign(n: i64) -> i64 { if n > 0 { 1 } else if n < 0 { 0 - 1 } else { 0 } }\n";
    const app = "import dev.q64.m.{sign}\nfn main { env.out(sign(0 - 7)) }\n";
    const modules = [_]ModuleSource{.{ .name = "dev.q64.m", .source = lib }};
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &modules, .wasm64);
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, "\x00asm", bytes[0..4]);
}

test "emitFromSource: a value `if` without an else is rejected" {
    // Every path of a value-producing `if` must yield an i64.
    const lib = "pub fn f(n: i64) -> i64 { if n > 0 { 1 } }\n";
    const app = "import dev.q64.m.{f}\nfn main { env.out(f(1)) }\n";
    const modules = [_]ModuleSource{.{ .name = "dev.q64.m", .source = lib }};
    try testing.expectError(
        Error.UnsupportedCall,
        emitFromSource(testing.allocator, app, "main.q", &modules, .wasm64),
    );
}

test "emitFromSource: an i64 let binding is bound, chained, and printed" {
    // `a` holds a runtime i64; it's passed as an argument (chaining) and
    // printed directly via __fmt_i64.
    const lib = "pub fn double(n: i64) -> i64 { n + n }\npub fn add(a: i64, b: i64) -> i64 { a + b }\n";
    const app = "import dev.q64.m.{double, add}\nfn main {\n    let a = double(21)\n    env.out(a)\n    env.out(add(a, 8))\n}\n";
    const modules = [_]ModuleSource{.{ .name = "dev.q64.m", .source = lib }};
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &modules, .wasm64);
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, "\x00asm", bytes[0..4]);
}

test "emitFromSource: an i64 binding interpolates into a string" {
    // `"a = {a}"` formats the runtime i64 via __fmt_i64 and concatenates it
    // into the arena. The const prefix "a = " is in the data; "42" is not.
    const lib = "pub fn double(n: i64) -> i64 { n + n }\n";
    const app = "import dev.q64.m.{double}\nfn main {\n    let a = double(21)\n    env.out(\"a = {a}\")\n}\n";
    const modules = [_]ModuleSource{.{ .name = "dev.q64.m", .source = lib }};
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &modules, .wasm64);
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, "\x00asm", bytes[0..4]);
    try testing.expect(std.mem.indexOf(u8, bytes, "a = ") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "42") == null);
}

test "emitFromSource: a string and an i64 binding interpolate together" {
    // One concat mixing a str binding (g) and an i64 binding (a) — they
    // share the arena and the tuple-slot space.
    const lib = "pub fn double(n: i64) -> i64 { n + n }\npub fn shout(s: str) -> str { \"{s}!\" }\n";
    const app = "import dev.q64.m.{double, shout}\nfn main {\n    let a = double(21)\n    let g = shout(\"hi\")\n    env.out(\"{g} a is {a}\")\n}\n";
    const modules = [_]ModuleSource{.{ .name = "dev.q64.m", .source = lib }};
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &modules, .wasm64);
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, "\x00asm", bytes[0..4]);
    try testing.expect(std.mem.indexOf(u8, bytes, " a is ") != null);
}

test "emitFromSource: a binding can name a const call result, referenced directly" {
    const lib = "pub fn version() -> str { \"0.1.0\" }\n";
    const app = "import dev.q64.s.{version}\nfn main {\n    let v = version()\n    env.out(v)\n}\n";
    const modules = [_]ModuleSource{.{ .name = "dev.q64.s", .source = lib }};
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &modules, .wasm64);
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "0.1.0\n") != null);
}

test "emitFromSource: a runtime binding holds a call result, used in interpolation" {
    // `let g = shout("hi")` isn't const-foldable, so g binds the call's
    // (ptr, len) into `_start` locals; `"[{g}]"` then concatenates it at
    // runtime. The assembled string exists only at runtime.
    const lib = "pub fn shout(s: str) -> str { \"{s}!\" }\n";
    const app =
        \\import dev.q64.s.{shout}
        \\
        \\fn main {
        \\    let g = shout("hi")
        \\    env.out(g)
        \\    env.out("[{g}]")
        \\}
        \\
    ;
    const modules = [_]ModuleSource{.{ .name = "dev.q64.s", .source = lib }};
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &modules, .wasm64);
    defer testing.allocator.free(bytes);

    try testing.expectEqualSlices(u8, "\x00asm", bytes[0..4]);
    try testing.expect(std.mem.indexOf(u8, bytes, "hi") != null);
    // Neither the call result nor the `[…]`-wrapped form is baked in.
    try testing.expect(std.mem.indexOf(u8, bytes, "hi!") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "[hi!]") == null);
}

test "emitFromSource: a runtime binding can be passed as an argument" {
    // `wrap(g)` passes g's (ptr, len) locals as the argument — a runtime
    // argument, not a const-folded one.
    const lib = "pub fn shout(s: str) -> str { \"{s}!\" }\npub fn wrap(s: str) -> str { \"[{s}]\" }\n";
    const app =
        \\import dev.q64.s.{shout, wrap}
        \\
        \\fn main {
        \\    let g = shout("hi")
        \\    env.out(wrap(g))
        \\}
        \\
    ;
    const modules = [_]ModuleSource{.{ .name = "dev.q64.s", .source = lib }};
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &modules, .wasm64);
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, "\x00asm", bytes[0..4]);
    try testing.expect(std.mem.indexOf(u8, bytes, "[hi!]") == null); // built at runtime
}

test "emitFromSource: a nested runtime call argument is unsupported" {
    // `wrap(shout("yo"))` — the argument is itself a non-const call, not a
    // binding; bind it first (`let t = shout("yo"); wrap(t)`).
    const lib = "pub fn shout(s: str) -> str { \"{s}!\" }\npub fn wrap(s: str) -> str { \"[{s}]\" }\n";
    const app = "import dev.q64.s.{shout, wrap}\nfn main { env.out(wrap(shout(\"yo\"))) }\n";
    const modules = [_]ModuleSource{.{ .name = "dev.q64.s", .source = lib }};
    try testing.expectError(
        Error.NotConstExpr,
        emitFromSource(testing.allocator, app, "main.q", &modules, .wasm64),
    );
}

test "emitFromSource: doubled braces are literal, not interpolation" {
    const app = "fn main { env.out(\"{{not interp}}\") }\n";
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &.{}, .wasm64);
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "{not interp}\n") != null);
}

test "emitFromSource: interpolating an unknown name errors (honest baseline)" {
    const app = "fn main { env.out(\"{mystery()}\") }\n";
    try testing.expectError(
        Error.NameNotFound,
        emitFromSource(testing.allocator, app, "main.q", &.{}, .wasm64),
    );
}

test "emitFromSource: an unresolved import errors (honest baseline)" {
    const app = "import dev.q64.absent.{version}\nfn main { env.out(\"hi\") }\n";
    try testing.expectError(
        Error.UnknownModule,
        emitFromSource(testing.allocator, app, "main.q", &.{}, .wasm64),
    );
}

test "emitFromSource: importing a name the module lacks errors" {
    const lib = "pub fn version() -> str { \"1.0\" }\n";
    const app = "import dev.q64.hw.{missing}\nfn main { env.out(\"hi\") }\n";
    const modules = [_]ModuleSource{.{ .name = "dev.q64.hw", .source = lib }};
    try testing.expectError(
        Error.NameNotFound,
        emitFromSource(testing.allocator, app, "main.q", &modules, .wasm64),
    );
}

test "emitFromSource: a relative import is unsupported in v0" {
    const app = "import \"./util.q\".{helper}\nfn main { env.out(\"hi\") }\n";
    try testing.expectError(
        Error.UnsupportedImport,
        emitFromSource(testing.allocator, app, "main.q", &.{}, .wasm64),
    );
}

test "emitFromSource: a while loop sums with var accumulators" {
    // `var s`/`var i`, a while guarded by a comparison, reassignment each
    // iteration. The result (55) is computed at runtime, not folded.
    const lib = "pub fn sum_to(n: i64) -> i64 { var s = 0; var i = 1; while i <= n { s = s + i; i = i + 1 } s }\n";
    const app = "import dev.q64.m.{sum_to}\nfn main { env.out(sum_to(10)) }\n";
    const modules = [_]ModuleSource{.{ .name = "dev.q64.m", .source = lib }};
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &modules, .wasm64);
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, "\x00asm", bytes[0..4]);
}

test "emitFromSource: a while loop multiplies (factorial)" {
    const lib = "pub fn fact(n: i64) -> i64 { var r = 1; var i = 2; while i <= n { r = r * i; i = i + 1 } r }\n";
    const app = "import dev.q64.m.{fact}\nfn main { env.out(fact(5)) }\n";
    const modules = [_]ModuleSource{.{ .name = "dev.q64.m", .source = lib }};
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &modules, .wasm64);
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, "\x00asm", bytes[0..4]);
}

test "emitFromSource: in-body let bindings feed the tail value" {
    const lib = "pub fn poly(n: i64) -> i64 { let a = n + 1; let b = a * 2; a + b }\n";
    const app = "import dev.q64.m.{poly}\nfn main { env.out(poly(3)) }\n";
    const modules = [_]ModuleSource{.{ .name = "dev.q64.m", .source = lib }};
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &modules, .wasm64);
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, "\x00asm", bytes[0..4]);
}

test "emitFromSource: compound assignment to a var" {
    const lib = "pub fn acc(n: i64) -> i64 { var s = 0; var i = 0; while i < n { s += i; i += 1 } s }\n";
    const app = "import dev.q64.m.{acc}\nfn main { env.out(acc(4)) }\n";
    const modules = [_]ModuleSource{.{ .name = "dev.q64.m", .source = lib }};
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &modules, .wasm64);
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, "\x00asm", bytes[0..4]);
}

test "emitFromSource: assigning to a let binding is rejected" {
    const lib = "pub fn f(n: i64) -> i64 { let a = n; a = a + 1; a }\n";
    const app = "import dev.q64.m.{f}\nfn main { env.out(f(1)) }\n";
    const modules = [_]ModuleSource{.{ .name = "dev.q64.m", .source = lib }};
    try testing.expectError(
        Error.ImmutableAssign,
        emitFromSource(testing.allocator, app, "main.q", &modules, .wasm64),
    );
}

test "emitFromSource: assigning to a parameter is rejected" {
    const lib = "pub fn f(n: i64) -> i64 { n = n + 1; n }\n";
    const app = "import dev.q64.m.{f}\nfn main { env.out(f(1)) }\n";
    const modules = [_]ModuleSource{.{ .name = "dev.q64.m", .source = lib }};
    try testing.expectError(
        Error.ImmutableAssign,
        emitFromSource(testing.allocator, app, "main.q", &modules, .wasm64),
    );
}

test "emitFromSource: an i64 function recurses (factorial)" {
    const lib = "pub fn fact(n: i64) -> i64 { if n <= 1 { 1 } else { n * fact(n - 1) } }\n";
    const app = "import dev.q64.m.{fact}\nfn main { env.out(fact(6)) }\n";
    const modules = [_]ModuleSource{.{ .name = "dev.q64.m", .source = lib }};
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &modules, .wasm64);
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, "\x00asm", bytes[0..4]);
}

test "emitFromSource: a recursive function with two self-calls (fib)" {
    const lib = "pub fn fib(n: i64) -> i64 { if n < 2 { n } else { fib(n - 1) + fib(n - 2) } }\n";
    const app = "import dev.q64.m.{fib}\nfn main { env.out(fib(10)) }\n";
    const modules = [_]ModuleSource{.{ .name = "dev.q64.m", .source = lib }};
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &modules, .wasm64);
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, "\x00asm", bytes[0..4]);
}

test "emitFromSource: composition registers a transitively-called function" {
    // main calls hyp_sq but never square directly; square is discovered and
    // emitted by the transitive registration pass.
    const lib = "pub fn square(n: i64) -> i64 { n * n }\npub fn hyp_sq(a: i64, b: i64) -> i64 { square(a) + square(b) }\n";
    const app = "import dev.q64.m.{square, hyp_sq}\nfn main { env.out(hyp_sq(3, 4)) }\n";
    const modules = [_]ModuleSource{.{ .name = "dev.q64.m", .source = lib }};
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &modules, .wasm64);
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, "\x00asm", bytes[0..4]);
}

test "emitFromSource: a call with the wrong argument count is rejected" {
    const lib = "pub fn add(a: i64, b: i64) -> i64 { a + b }\npub fn bad(n: i64) -> i64 { add(n) }\n";
    const app = "import dev.q64.m.{add, bad}\nfn main { env.out(bad(1)) }\n";
    const modules = [_]ModuleSource{.{ .name = "dev.q64.m", .source = lib }};
    try testing.expectError(
        Error.UnsupportedCall,
        emitFromSource(testing.allocator, app, "main.q", &modules, .wasm64),
    );
}

test "emitFromSource: calling a non-i64 function in an i64 expression is rejected" {
    const lib = "pub fn greet() -> str { \"hi\" }\npub fn bad(n: i64) -> i64 { greet() + n }\n";
    const app = "import dev.q64.m.{greet, bad}\nfn main { env.out(bad(1)) }\n";
    const modules = [_]ModuleSource{.{ .name = "dev.q64.m", .source = lib }};
    try testing.expectError(
        Error.UnsupportedCall,
        emitFromSource(testing.allocator, app, "main.q", &modules, .wasm64),
    );
}

// ---------------------------------------------------------------------
// Control flow: break / continue / early return / loop (ladder step 18)
// ---------------------------------------------------------------------

test "emitFromSource: a loop with an early return finds the first factor" {
    const lib = "pub fn first_factor(n: i64) -> i64 { var i = 2; loop { if n % i == 0 { return i } i = i + 1 } }\n";
    const app = "import dev.q64.m.{first_factor}\nfn main { env.out(first_factor(15)) }\n";
    const modules = [_]ModuleSource{.{ .name = "dev.q64.m", .source = lib }};
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &modules, .wasm64);
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, "\x00asm", bytes[0..4]);
}

test "emitFromSource: break exits a while loop early" {
    const lib = "pub fn count_to_sum(limit: i64) -> i64 { var s = 0; var i = 0; while i < 1000 { i = i + 1; s = s + i; if s >= limit { break } } i }\n";
    const app = "import dev.q64.m.{count_to_sum}\nfn main { env.out(count_to_sum(10)) }\n";
    const modules = [_]ModuleSource{.{ .name = "dev.q64.m", .source = lib }};
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &modules, .wasm64);
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, "\x00asm", bytes[0..4]);
}

test "emitFromSource: continue skips an iteration" {
    const lib = "pub fn sum_odd(n: i64) -> i64 { var s = 0; var i = 0; while i < n { i = i + 1; if i % 2 == 0 { continue } s = s + i } s }\n";
    const app = "import dev.q64.m.{sum_odd}\nfn main { env.out(sum_odd(10)) }\n";
    const modules = [_]ModuleSource{.{ .name = "dev.q64.m", .source = lib }};
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &modules, .wasm64);
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, "\x00asm", bytes[0..4]);
}

test "emitFromSource: an early-return guard and an inner-loop return (is_prime)" {
    const lib = "pub fn is_prime(n: i64) -> i64 { if n < 2 { return 0 } var i = 2; while i * i <= n { if n % i == 0 { return 0 } i = i + 1 } 1 }\n";
    const app = "import dev.q64.m.{is_prime}\nfn main { env.out(is_prime(13)) }\n";
    const modules = [_]ModuleSource{.{ .name = "dev.q64.m", .source = lib }};
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &modules, .wasm64);
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, "\x00asm", bytes[0..4]);
}

test "emitFromSource: break outside a loop is rejected" {
    const lib = "pub fn bad(n: i64) -> i64 { break; n }\n";
    const app = "import dev.q64.m.{bad}\nfn main { env.out(bad(1)) }\n";
    const modules = [_]ModuleSource{.{ .name = "dev.q64.m", .source = lib }};
    try testing.expectError(
        Error.BreakOutsideLoop,
        emitFromSource(testing.allocator, app, "main.q", &modules, .wasm64),
    );
}

test "emitFromSource: continue outside a loop is rejected" {
    const lib = "pub fn bad(n: i64) -> i64 { continue; n }\n";
    const app = "import dev.q64.m.{bad}\nfn main { env.out(bad(1)) }\n";
    const modules = [_]ModuleSource{.{ .name = "dev.q64.m", .source = lib }};
    try testing.expectError(
        Error.BreakOutsideLoop,
        emitFromSource(testing.allocator, app, "main.q", &modules, .wasm64),
    );
}
