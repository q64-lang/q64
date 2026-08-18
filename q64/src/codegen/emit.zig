//! q64/src/codegen — AST → Wasm 3.0 via Binaryen.
//!
//! Main surface: `emitFromSource` / `emitFromSourceWithImports`, which
//! drive the full IR pipeline — parse → HIR (`ir.build_hir`) → MIR
//! (`ir.lower`) → Binaryen — and return a finished core module.
//! `emitComponent` layers the Component Model output on top, and
//! `showHir` / `showMir` share the same front end to dump an IR tier as
//! text for `q64 show hir|mir`. A construct the IR can't represent yet
//! is reported as an honest `Error.UnsupportedExpression` — the legacy
//! direct-from-AST emitter is removed; there is no fallback.
//!
//! `emitHelloWasm` survives as the original v0 smoke test (`q64
//! emit-hello`): it builds the hand-equivalent of
//! `runtime/wasmtime/hello.wat` directly via the Binaryen C API and
//! instantiates against `runtime/wasmtime/q64-wasmtime-host`.

const std = @import("std");
const parser = @import("parser");
const parse = parser.parse;
const ast = parser.ast;
const ir = @import("ir");
const sema = @import("sema");
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
pub const ModuleSource = sema.link.ModuleSource;

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
    return emitFromSourceWithImports(allocator, source, file, modules, addr, &.{});
}

/// As `emitFromSource`, but with a foreign WIT import table (`--wit-import`,
/// WIT rung 5). A `<iface>.<fn>(…)` source call against one of these lowers to a
/// real core import + call, so the emitted core module imports
/// `(import "<wit-id>" "<fn>" …)`. With an empty table this is `emitFromSource`.
pub fn emitFromSourceWithImports(
    allocator: std.mem.Allocator,
    source: []const u8,
    file: []const u8,
    modules: []const ModuleSource,
    addr: AddressSpace,
    foreign: []const component.ImportIface,
) ![]u8 {
    // The derived foreign table is only consulted while building the HIR (the
    // HIR's `foreign_call` nodes alias the original import data, not this table),
    // so a scratch arena freed at return covers it.
    var fa = std.heap.ArenaAllocator.init(allocator);
    defer fa.deinit();
    const foreign_table = try deriveForeignTable(fa.allocator(), foreign);
    var hmod = try buildHir(allocator, source, file, modules, foreign_table);
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
    return lowerToWasm(allocator, &mmod, addr, .env_out, null, false);
}

/// The product of `emitComponent`. Either a finished component (the import-free
/// scalar library lift, which `component.zig` encodes in pure Zig), or — for an
/// app that reaches stdout — a WASI **preview1 core module** the caller adapts
/// into a real `wasi:cli/run` component (`q64 emit --component` shells out to
/// `wasm-tools component new --adapt` with the `vendor/wasi/` adapter). Keeping
/// the adapter shell-out in the CLI layer leaves this codegen module free of
/// subprocess/filesystem concerns.
// Re-exports so the CLI can build the foreign-import model without importing
// `codegen/component.zig` directly (WIT rung 5 — the codegen import binding).
pub const Scalar = component.Scalar;
pub const ImportFunc = component.ImportFunc;
pub const ImportIface = component.ImportIface;

pub const ComponentArtifact = union(enum) {
    /// A finished WebAssembly component, ready to write. Caller owns the slice.
    component: []u8,
    /// A WASI preview1 core module (imports `wasi_snapshot_preview1.fd_write`,
    /// exports `_start`) to be wrapped by the WASI adapter. Caller owns it.
    preview1_app: []u8,
    /// A library whose scalar surface is exported under a **named WIT
    /// interface** (`<pkg>/<iface>`): the core (exports `<iface>#<fn>`) plus the
    /// world `.wit` to lift it with `wasm-tools component embed`+`new`. This is
    /// the export-mirror of the rung-5 instance import, so a q64 consumer that
    /// imports the interface can be `wac`-linked against this provider. Both
    /// slices owned by the caller.
    interface_lib: struct { core: []u8, world: []u8 },
    /// A qube that reaches `env.kv`: the core imports the **canonical**
    /// `wasi:keyvalue/{store,atomics}` ABI (`cm32p2|…` core imports, the
    /// adapter-held bucket opened host-side) plus the synthesized world `.wit`
    /// importing those interfaces. The CLI embeds the vendored `wasi:keyvalue`
    /// dep + this world and runs `wasm-tools component embed`+`new` to lift it.
    /// Both slices owned by the caller. (spec/env.md §`env.kv`; the design of
    /// record is `test/kv-component-reference/`.)
    ///
    /// Covers every storage capability that lowers to a host-opened,
    /// identity-pinned bucket over the canonical `cm32p2|…` ABI: `env.kv`
    /// (`wasi:keyvalue/{store,atomics}`) and `env.blob` (`q64:blob/store`). The
    /// world imports whichever interfaces the qube uses; the CLI embeds the
    /// matching vendored dep(s) and runs `wasm-tools component embed`+`new`.
    store_component: struct { core: []u8, world: []u8 },
};

/// The vendored `wasi:keyvalue@0.2.0-draft2` WIT (store + atomics) — the dep
/// package the kv component lift embeds. Committed as a build input
/// (`src/codegen/wit/README.md`); embedded so emit needs no external file.
pub const wasi_keyvalue_wit = @embedFile("wit/wasi-keyvalue.wit");

/// The vendored `q64:blob/store@0.2.0-draft2` WIT — the q64-owned object-store
/// dep `env.blob` lowers to (spec/env.md §`env.blob`; see the file header for
/// why it is not raw wasi:blobstore).
pub const q64_blob_wit = @embedFile("wit/q64-blob.wit");

/// The vendored `q64:db/sql@0.2.0-draft2` WIT — the q64-owned SQL dep `env.db`
/// lowers to (spec/env.md §`env.db`; see the file header for why it is not raw
/// wasi:sql).
pub const q64_db_wit = @embedFile("wit/q64-db.wit");

/// The vendored `wasi:config@0.2.0-draft` WIT — the `env.config` capability
/// target (read-only config/secrets; spec/env.md §`env.config`).
pub const wasi_config_wit = @embedFile("wit/wasi-config.wit");

/// The vendored `wasi:clocks@0.2.0` WIT — the `env.time` capability target
/// (monotonic + wall clocks; spec/env.md §`env.time`). Trimmed to the
/// functions q64 emits.
pub const wasi_clocks_wit = @embedFile("wit/wasi-clocks.wit");

/// The vendored `wasi:io@0.2.0` WIT — just the `pollable` resource the
/// blocking `env.time.sleep_ns` chain needs (see the file header).
pub const wasi_io_wit = @embedFile("wit/wasi-io.wit");

/// The vendored WASIp3 clocks WIT — wasmtime 45's own file, verbatim (the
/// p3 interfaces are rc-versioned; importing a bare `@0.3.0` fails
/// instantiation). Used only by the ASYNC-lifted export path (Slice B
/// rung 3, `test/async-export-reference/`).
pub const wasi_clocks_p3_wit = @embedFile("wit/wasi-clocks-p3.wit");

/// The component-model interface ids `env.kv` lowers to (with the version pin).
/// Core imports use the `cm32p2|<id>` form; the world imports the bare ids.
pub const kv_store_iface = "wasi:keyvalue/store@0.2.0-draft2";
pub const kv_atomics_iface = "wasi:keyvalue/atomics@0.2.0-draft2";
/// The interface id `env.blob` lowers to (q64-owned; version pin mirrors kv —
/// wit-component's world-item resolution rejects a plain `0.1.0` here).
pub const blob_store_iface = "q64:blob/store@0.2.0-draft2";
/// The interface id `env.db` lowers to (q64-owned; version pin mirrors kv/blob).
pub const db_sql_iface = "q64:db/sql@0.2.0-draft2";
/// The interface id `env.config` lowers to — the real `wasi:config` proposal.
pub const config_store_iface = "wasi:config/store@0.2.0-draft";
/// The interface id `env.time` lowers to — the stable `wasi:clocks` release
/// (the pin matches the vendored wit/wasi-clocks.wit package version).
pub const clocks_monotonic_iface = "wasi:clocks/monotonic-clock@0.2.0";
/// The cm32p2 core-import mangling for clocks. A STABLE (non-prerelease)
/// interface version mangles as the semver-compatible major.minor form —
/// `@0.2`, not `@0.2.0` — or `component new` fails to map the import to the
/// world item. The kv/config/blob/db mangles carry their full version only
/// because pre-release pins (`0.2.0-draft…`) are matched verbatim.
pub const clocks_monotonic_core_mod = "cm32p2|wasi:clocks/monotonic-clock@0.2";
/// The wall clock — `env.time.unix_ns` folds its `datetime` record to i64 ns.
pub const clocks_wall_iface = "wasi:clocks/wall-clock@0.2.0";
pub const clocks_wall_core_mod = "cm32p2|wasi:clocks/wall-clock@0.2";
/// wasi:io/poll — the pollable `env.time.sleep_ns` blocks on.
pub const io_poll_iface = "wasi:io/poll@0.2.0";
pub const io_poll_core_mod = "cm32p2|wasi:io/poll@0.2";
/// The WASIp3 monotonic clock (async `wait-for`) — rc-pinned to what the
/// vendored wasmtime provides. The async path uses LEGACY manglings (the
/// module name is the bare interface id, no cm32p2 prefix): wasm-tools'
/// standard mangling has no async support yet (see the rung-3 reference).
pub const clocks_p3_iface = "wasi:clocks/monotonic-clock@0.3.0-rc-2026-03-15";

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
/// Map a component-ABI scalar to the HIR value type the call binding uses.
fn scalarToHirType(s: component.Scalar) ir.hir.Type {
    return switch (s) {
        .s64 => .i64,
        .bool_ => .bool,
        .f64 => .f64,
    };
}

/// The q64-source name for an imported interface: the last id segment of its
/// component-model id (`acme:mathlib/math@1.0.0` → `math`). Strips the version
/// suffix and the `package:` / `path/` prefixes so source can write `math.add`.
fn ifaceLocalName(wit_name: []const u8) []const u8 {
    var s = wit_name;
    if (std.mem.indexOfScalar(u8, s, '@')) |at| s = s[0..at];
    if (std.mem.lastIndexOfScalar(u8, s, '/')) |slash| s = s[slash + 1 ..];
    return s;
}

/// Lower the codegen import descriptors (`component.ImportIface`, the same data
/// the component encoder consumes) to the HIR foreign table the builder matches
/// `<iface>.<fn>(…)` calls against. Arena-allocated from `a` (outlives the HIR).
fn deriveForeignTable(a: std.mem.Allocator, foreign: []const component.ImportIface) ![]const ir.hir.ForeignIface {
    if (foreign.len == 0) return &.{};
    const ifaces = try a.alloc(ir.hir.ForeignIface, foreign.len);
    for (foreign, ifaces) |src, *dst| {
        const funcs = try a.alloc(ir.hir.ForeignFn, src.funcs.len);
        for (src.funcs, funcs) |sf, *df| {
            const params = try a.alloc(ir.hir.Type, sf.params.len);
            for (sf.params, params) |sp, *dp| dp.* = scalarToHirType(sp);
            df.* = .{
                .name = sf.name,
                .params = params,
                .ret = if (sf.ret) |r| scalarToHirType(r) else .void,
            };
        }
        dst.* = .{ .local = ifaceLocalName(src.wit_name), .wit_id = src.wit_name, .funcs = funcs };
    }
    return ifaces;
}

/// Filter the declared foreign import table down to exactly the interfaces and
/// functions the lowered core actually calls (its `foreign_call` sites). The
/// component encoder wires the core module's instantiation imports to these, so
/// the set must match the core's real imports — a declared-but-unused interface
/// must not appear in the instantiate args (it is still DECLARED in the world;
/// `encode` takes the full table separately for that). Arena-allocated.
fn filterUsedImports(a: std.mem.Allocator, foreign: []const component.ImportIface, mmod: *const ir.mir.Module) ![]const component.ImportIface {
    if (foreign.len == 0) return &.{};
    var used = std.StringHashMapUnmanaged(*const ir.mir.Inst){};
    defer used.deinit(a);
    for (mmod.funcs) |f| switch (f.body) {
        .structured => |root| try scanForeignCalls(root, &used, a),
        .cfg => {},
    };
    var out: std.ArrayList(component.ImportIface) = .empty;
    for (foreign) |iface| {
        var funcs: std.ArrayList(component.ImportFunc) = .empty;
        for (iface.funcs) |f| {
            const key = try std.fmt.allocPrint(a, "{s}\x00{s}", .{ iface.wit_name, f.name });
            if (used.contains(key)) try funcs.append(a, f);
        }
        if (funcs.items.len > 0) try out.append(a, .{ .wit_name = iface.wit_name, .funcs = try funcs.toOwnedSlice(a) });
    }
    return out.toOwnedSlice(a);
}

pub fn emitComponent(allocator: std.mem.Allocator, source: []const u8, file: []const u8, modules: []const ModuleSource, addr: AddressSpace, foreign: []const component.ImportIface, export_interface: ?[]const u8) !ComponentArtifact {
    // Scratch arena for the derived foreign table + the used-import filter; both
    // are consumed within this call (HIR build and `component.encode`), so freeing
    // at return is safe — the returned artifact owns its own (gpa) bytes.
    var fa = std.heap.ArenaAllocator.init(allocator);
    defer fa.deinit();
    const foreign_table = try deriveForeignTable(fa.allocator(), foreign);
    var hmod = try buildHir(allocator, source, file, modules, foreign_table);
    defer hmod.deinit();
    var mmod = ir.lower.lower(allocator, &hmod) catch |e| switch (e) {
        error.Unsupported => return Error.UnsupportedExpression,
        else => |other| return other,
    };
    defer mmod.deinit();

    // An app reaches a `wasi:cli` command capability — stdout (`env.out` →
    // `@stdout` → `fd_write`) and/or exit (`env.exit` → `@exit` → `proc_exit`).
    // Emit a preview1 core module and hand it back for the WASI adapter to lift
    // into a `wasi:cli/run` command importing `wasi:cli/{stdout,exit}`. The
    // preview1 ABI is 32-bit (i32 iovec/fd_write); a wasm64 app isn't lowerable.
    if (usesEnvOut(&mmod) or usesEnvExit(&mmod)) {
        if (addr != .wasm32) return Error.ComponentNeedsImportLowering;
        return .{ .preview1_app = try lowerToWasm(allocator, &mmod, addr, .wasi_preview1, null, false) };
    }

    // A SUSPENDING export lifts async (Slice B rung 3): a single pub fn whose
    // body sleeps compiles to the Component Model async ABI — an
    // `[async-lift]` export + callback, state in a memory frame, the sleep an
    // async-lowered `wait-for` subtask parked in a waitable-set. The host is
    // never blocked. Must gate BEFORE the store path (which would grab the
    // @time use and emit the blocking 0.2 chain instead).
    if (asyncExportIndex(&mmod)) |afi| {
        if (addr != .wasm32) return Error.ComponentNeedsImportLowering;
        const core = try emitAsyncCore(allocator, &mmod, afi);
        errdefer allocator.free(core);
        const world = try synthAsyncWorld(allocator, &hmod);
        return .{ .store_component = .{ .core = core, .world = world } };
    }

    // A qube that reaches `env.kv`: lower the core with the canonical
    // `wasi:keyvalue` import ABI (cm32p2 imports, adapter-held bucket) and hand
    // back the synthesized world for the CLI to embed + lift. The canonical ABI
    // is 32-bit (cm32p2); a wasm64 qube isn't lowerable here.
    if (usesEnvKv(&mmod) or usesEnvBlob(&mmod) or usesEnvDb(&mmod) or usesEnvConfig(&mmod) or usesEnvTime(&mmod) or usesStrExport(&mmod)) {
        if (addr != .wasm32) return Error.ComponentNeedsImportLowering;
        const core = try lowerToWasm(allocator, &mmod, addr, .env_out, null, true);
        errdefer allocator.free(core);
        const world = try synthStoreWorld(allocator, &hmod, usesEnvKv(&mmod), usesEnvBlob(&mmod), usesEnvDb(&mmod), usesEnvConfig(&mmod), usesEnvTimeMono(&mmod), usesEnvTimeWall(&mmod), usesEnvTimeSleep(&mmod));
        return .{ .store_component = .{ .core = core, .world = world } };
    }

    // Interface-export library: emit the core with `<iface>#<fn>` export names
    // and the world `.wit` declaring the interface, for the caller to lift with
    // `wasm-tools component embed`+`new`. (The hand-rolled scalar encoder below
    // exports bare functions; this path exports a named interface instead.)
    if (export_interface) |iface| {
        const core = try lowerToWasm(allocator, &mmod, addr, .env_out, iface, false);
        errdefer allocator.free(core);
        if (coreHasImports(core)) {
            allocator.free(core);
            return Error.ComponentNeedsImportLowering;
        }
        const world = try synthInterfaceWorld(allocator, &hmod, iface);
        return .{ .interface_lib = .{ .core = core, .world = world } };
    }

    const core = try lowerToWasm(allocator, &mmod, addr, .env_out, null, false);
    defer allocator.free(core);

    // The only core imports the scalar encoder can wire are foreign WIT imports
    // (the `foreign_call` binding): it aliases + canon-lowers each into the core
    // module's instantiation imports. Anything else (a `qview.*` host face) can't
    // be lifted here — report it honestly. The wired set is exactly the foreign
    // funcs the source actually calls.
    const used_imports = try filterUsedImports(fa.allocator(), foreign, &mmod);
    if (coreHasImports(core) and used_imports.len == 0) return Error.ComponentNeedsImportLowering;

    // Gather the scalar public exports. A non-scalar (`str`/list) export needs
    // memory/realloc canon options not in this slice — skip it for now.
    var exports: std.ArrayList(component.Export) = .empty;
    defer exports.deinit(allocator);
    for (hmod.funcs, 0..) |f, i| {
        const is_entry = (hmod.entry != null and hmod.entry.? == i);
        if (f.visibility != .public and !is_entry) continue;
        const params = try allocator.alloc(component.Scalar, f.params.len);
        // The parallel param-name vector: the q64 source identifiers, lifted
        // into the component's WIT type so the world round-trips real names
        // (the encoder kebab-cases them). The slices alias the HIR, which
        // outlives this call (freed at function exit, after `encode`).
        const param_names = try allocator.alloc([]const u8, f.params.len);
        for (f.params, 0..) |p, j| param_names[j] = p.name;
        var ok = true;
        for (f.params, 0..) |p, j| {
            params[j] = component.Scalar.fromHir(p.ty) orelse {
                ok = false;
                break;
            };
        }
        const ret: ?component.Scalar = if (f.ret == .void) null else component.Scalar.fromHir(f.ret) orelse {
            allocator.free(params);
            allocator.free(param_names);
            continue;
        };
        if (!ok) {
            allocator.free(params);
            allocator.free(param_names);
            continue;
        }
        try exports.append(allocator, .{
            .name = f.name,
            .core_name = if (is_entry) "_start" else f.name,
            .params = params,
            .param_names = param_names,
            .ret = ret,
        });
    }
    defer for (exports.items) |e| {
        allocator.free(e.params);
        allocator.free(e.param_names);
    };

    if (exports.items.len == 0) return Error.ComponentNoExports;
    // Declare ALL manifest imports in the world (spec/qube.json5.md §wit:
    // `wit.imports` are declared even when unused, so `wac` can link at
    // build); wire only the used subset into the core instantiation.
    return .{ .component = try component.encode(allocator, core, exports.items, foreign, used_imports) };
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

/// Build the HIR for `source` and return its text dump (`q64 show hir`). The
/// foreign WIT import table (`--wit-import`) lets `<iface>.<fn>(…)` calls resolve
/// to `foreign_call` nodes; empty when the qube imports nothing.
pub fn showHir(allocator: std.mem.Allocator, source: []const u8, file: []const u8, modules: []const ModuleSource, foreign: []const component.ImportIface) ![]u8 {
    var fa = std.heap.ArenaAllocator.init(allocator);
    defer fa.deinit();
    const foreign_table = try deriveForeignTable(fa.allocator(), foreign);
    var hmod = try buildHir(allocator, source, file, modules, foreign_table);
    defer hmod.deinit();
    return ir.print.hirToString(allocator, &hmod);
}

/// Lower `source` to MIR and return its text dump (`q64 show mir`).
pub fn showMir(allocator: std.mem.Allocator, source: []const u8, file: []const u8, modules: []const ModuleSource, foreign: []const component.ImportIface) ![]u8 {
    var fa = std.heap.ArenaAllocator.init(allocator);
    defer fa.deinit();
    const foreign_table = try deriveForeignTable(fa.allocator(), foreign);
    var hmod = try buildHir(allocator, source, file, modules, foreign_table);
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
    var hmod = try buildHir(allocator, source, file, modules, &.{});
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
    var hmod = try buildHir(allocator, source, file, modules, &.{});
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
///
/// `world_override` / `package_override` (WIT rung 2) set the world name and
/// WIT package id from the qube manifest (`wit.world` / `wit.package`); when
/// null they default to the source-file basename and `q64:<world>`. `qube
/// build` passes them so the emitted world matches the manifest contract,
/// rather than the entry filename (`src/lib.q` → `lib`).
pub fn showWorld(
    allocator: std.mem.Allocator,
    source: []const u8,
    file: []const u8,
    modules: []const ModuleSource,
    world_override: ?[]const u8,
    package_override: ?[]const u8,
    foreign: []const component.ImportIface,
) ![]u8 {
    var fa = std.heap.ArenaAllocator.init(allocator);
    defer fa.deinit();
    const foreign_table = try deriveForeignTable(fa.allocator(), foreign);
    var hmod = try buildHir(allocator, source, file, modules, foreign_table);
    defer hmod.deinit();
    const caps = qubeCapabilities(&hmod);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const world = world_override orelse worldName(file);
    // Emit a valid, standalone WIT document: a `package` declaration plus the
    // synthesized `world`. This is also the on-disk `<name>.wit` artifact
    // `q64 emit --component` writes and `q64 show world --out` saves (WIT rung
    // 1) — the contract the Continuum stores and `wac` consumes. For a pure
    // library this parses standalone; an app's world references external
    // packages (wasi:cli), whose authoritative form is the adapted component.
    try out.appendSlice(allocator, "// synthesized WIT world (q64 show world)\n");
    try out.appendSlice(allocator, "package ");
    if (package_override) |pkg| {
        // Manifest-provided package id (e.g. `dev-q64:math`); kebab-normalize
        // any snake_case the author left in (the `:` separator is preserved).
        try appendKebab(allocator, &out, pkg);
    } else {
        try out.appendSlice(allocator, "q64:");
        try appendKebab(allocator, &out, world);
    }
    try out.appendSlice(allocator, ";\n\n");
    try out.appendSlice(allocator, "world ");
    try appendKebab(allocator, &out, world);
    try out.appendSlice(allocator, " {\n");

    // Imports — the derived capability set, mapped to WIT interfaces. `@io`
    // (the umbrella) and `@wire` carry no fixed interface, so they're noted but
    // not emitted as an `import`.
    try out.appendSlice(allocator, "  // imports — derived capability set\n");
    var any_import = false;
    var it = caps.iterator();
    while (it.next()) |eff| {
        for (eff.witImports()) |wit| {
            try out.print(allocator, "  import {s};\n", .{wit});
            any_import = true;
        }
    }
    // Foreign WIT imports (`--wit-import`, WIT rung 5): each interface the qube
    // links against is a named `import <interface-id>;`. Emitted whether or not
    // the source already calls it — the contract is what the qube declares.
    for (foreign) |iface| {
        try out.print(allocator, "  import {s};\n", .{iface.wit_name});
        any_import = true;
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
            try out.appendSlice(allocator, "  export ");
            try appendKebab(allocator, &out, f.name);
            try out.appendSlice(allocator, ": func(");
            for (f.params, 0..) |p, pi| {
                if (pi > 0) try out.appendSlice(allocator, ", ");
                try appendKebab(allocator, &out, p.name);
                try out.appendSlice(allocator, ": ");
                try out.appendSlice(allocator, witType(p.ty));
            }
            try out.appendSlice(allocator, ")");
            if (f.ret != .void) try out.print(allocator, " -> {s}", .{witType(f.ret)});
            try out.appendSlice(allocator, ";\n");
        }
    }

    try out.appendSlice(allocator, "}\n");
    return out.toOwnedSlice(allocator);
}

/// Synthesize the `.wit` for an **interface-export** library: the qube's scalar
/// `pub` surface wrapped in a named WIT `interface`, and a world exporting it —
/// for `wasm-tools component embed`+`new` to lift the core (whose exports are
/// `<iface>#<fn>`). `iface_id` is `<package>/<interface>` (e.g.
/// `acme:mathlib/math`); the world is named after the interface. Only scalar
/// funcs are listed (the same canonical-ABI boundary as the bare-export path).
fn synthInterfaceWorld(allocator: std.mem.Allocator, hmod: *const ir.hir.Module, iface_id: []const u8) ![]u8 {
    const slash = std.mem.indexOfScalar(u8, iface_id, '/') orelse return Error.UnsupportedExpression;
    const pkg = iface_id[0..slash];
    const iface = iface_id[slash + 1 ..];

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(allocator, "// synthesized WIT (q64 interface export)\npackage {s};\n\n", .{pkg});
    try out.print(allocator, "interface {s} {{\n", .{iface});
    for (hmod.funcs) |f| {
        if (f.visibility != .public) continue;
        var scalar = true;
        for (f.params) |p| {
            if (component.Scalar.fromHir(p.ty) == null) {
                scalar = false;
                break;
            }
        }
        if (f.ret != .void and component.Scalar.fromHir(f.ret) == null) scalar = false;
        if (!scalar) continue;
        try out.appendSlice(allocator, "  ");
        try appendKebab(allocator, &out, f.name);
        try out.appendSlice(allocator, ": func(");
        for (f.params, 0..) |p, i| {
            if (i > 0) try out.appendSlice(allocator, ", ");
            try appendKebab(allocator, &out, p.name);
            try out.appendSlice(allocator, ": ");
            try out.appendSlice(allocator, witType(p.ty));
        }
        try out.appendSlice(allocator, ")");
        if (f.ret != .void) try out.print(allocator, " -> {s}", .{witType(f.ret)});
        try out.appendSlice(allocator, ";\n");
    }
    try out.appendSlice(allocator, "}\n\n");
    // The world name must differ from the interface name within the package.
    try out.print(allocator, "world {s}-world {{\n  export {s};\n}}\n", .{ iface, iface });
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
        .u32 => "u32",
        .i16 => "s16",
        .u16 => "u16",
        .i8 => "s8",
        .u8 => "u8",
        .f32 => "f32",
        .f64 => "f64",
        // v128 has no canonical-ABI lowering; SIMD values are process-local
        // (a `pub` signature carrying one is rejected upstream by the
        // param/return allow-lists, so this arm is unreachable in practice).
        .f32x4, .i32x4 => "u64",
        .bool => "bool",
        .str => "string",
        .ptr => "u64", // internal pointer width; not a canonical-ABI export type
        .void => "_",
    };
}

/// Append `s` mapping the snake_case `_` q64 uses to the kebab-case `-` WIT
/// requires (component-model labels reject `_`). Length-preserving.
fn appendKebab(allocator: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |ch| try out.append(allocator, if (ch == '_') '-' else ch);
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

/// Adapts the sema `Linker` to the IR builder's `ModuleResolver` so
/// `build_hir` can resolve call targets to their AST without `ir/` depending
/// on `codegen/`.
fn linkerLookupShim(ctx: *anyopaque, scope: u32, name: []const u8) ?ir.hir.Resolved {
    const l: *sema.link.Linker = @ptrCast(@alignCast(ctx));
    const r = l.lookup(scope, name) orelse return null;
    return .{ .fd = r.fd, .scope = r.scope };
}

fn linkerSourceFileShim(ctx: *anyopaque, scope: u32) ?ast.SourceFile {
    const l: *sema.link.Linker = @ptrCast(@alignCast(ctx));
    return l.sourceFile(scope);
}

/// Parse `source`, resolve its imports against `modules`, and build the HIR —
/// the shared front of `emitFromSource` and `q64 show hir|mir`. Returns the
/// arena-owned HIR module (caller `deinit`s). A construct the IR can't yet
/// represent is an honest `UnsupportedExpression`; a definite semantic error
/// surfaces as its diagnostic code (`build_hir.Reject` → `mapReject`). The
/// parse result and linker are scoped to HIR construction (the HIR retains
/// no AST or linker pointers), so both are freed before returning.
fn buildHir(allocator: std.mem.Allocator, source: []const u8, file: []const u8, modules: []const ModuleSource, foreign: []const ir.hir.ForeignIface) !ir.hir.Module {
    const parse_result = try parse.parse(allocator, source, file);
    defer parse_result.deinit(allocator);
    const sf = ast.SourceFile.cast(parse_result.root) orelse return Error.NoMainFunction;

    // Resolve every import against `modules` and index this file's own
    // functions (so a local `version()` resolves without an import). An
    // unresolvable import is an honest error here (A3 final slice: this
    // lives in sema now — sema/link.zig); map the linker's error trio onto
    // the stable emit codes.
    var linker = sema.link.Linker.init(allocator, modules);
    defer linker.deinit();
    linker.build(sf) catch |e| return switch (e) {
        error.UnknownModule => Error.UnknownModule,
        error.NameNotFound => Error.NameNotFound,
        error.UnsupportedImport => Error.UnsupportedImport,
        error.OutOfMemory => error.OutOfMemory,
    };

    const mres = ir.hir.ModuleResolver{ .ctx = &linker, .lookupFn = linkerLookupShim, .sourceFileFn = linkerSourceFileShim };
    return switch (try ir.build_hir.tryBuild(allocator, sf, mres, foreign)) {
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

fn lowerToWasm(allocator: std.mem.Allocator, m: *const ir.mir.Module, addr: AddressSpace, stdout_abi: StdoutAbi, export_interface: ?[]const u8, kv_component: bool) ![]u8 {
    const module = c.BinaryenModuleCreate() orelse return Error.ModuleCreate;
    defer c.BinaryenModuleDispose(module);

    // Wasm 3.0 feature set. Memory64 is included only for wasm64; wasm32 omits
    // it so the emitted module is a genuine 32-bit module (the WebKit/iPad
    // baseline). Multivalue + BulkMemory + SIMD128 are address-space-independent
    // (SIMD128 is universal on the target hosts, incl. WebKit).
    var features = c.BinaryenFeatureMultivalue() | c.BinaryenFeatureBulkMemory() |
        c.BinaryenFeatureBulkMemoryOpt() | c.BinaryenFeatureMutableGlobals() |
        c.BinaryenFeatureNontrappingFPToInt() | // i64.trunc_sat_f64_* (__fmt_f64) — universal, incl. WebKit
        c.BinaryenFeatureSIMD128() | c.BinaryenFeatureRelaxedSIMD(); // v128 + lane ops (Simd<f32,4> / Simd<i32,4>)
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
    // `usesEnvOut` is stream-blind: true for any host byte-write (stdout OR
    // stderr), which is the right gate for the shared iovec scratch + the single
    // `fd_write` import (it serves both fd 1 and fd 2). The raw-face import
    // declaration, by contrast, is stream-specific — `env.out` vs `env.err`.
    const wants_out = usesEnvOut(m);
    const writes_stdout = usesHostStream(m, .out);
    const writes_stderr = usesHostStream(m, .err);
    const preview1 = (stdout_abi == .wasi_preview1) and wants_out;
    // A preview1 app that reads the clock lowers `env.time.monotonic_ns` to the
    // preview1 syscall `clock_time_get` (the adapter lifts it to `wasi:clocks`),
    // which writes its u64 timestamp through a pointer — reserve an 8-aligned
    // cell for it just past the iovec block.
    const preview1_time = (stdout_abi == .wasi_preview1) and usesEnvTime(m);
    // Randomness rides the same reserved 8-byte cell: preview1 random_get
    // writes bytes through a pointer, loaded back as one i64.
    const preview1_rand = (stdout_abi == .wasi_preview1) and usesEnvRandom(m);
    const preview1_sleep = (stdout_abi == .wasi_preview1) and usesEnvTimeSleep(m);
    const iovec_base: u32 = @intCast(m.data.len);
    const p1_ts_base: u32 = (iovec_base + 16 + 7) & ~@as(u32, 7);
    // iovec (8 bytes: i32 buf, i32 len) + nwritten (4 bytes), padded to 16
    // (+ the 8-byte timestamp cell when the clock is read; a sleep grows the
    // cell to poll_oneoff's buffers — subscription 48 + event 32 + nevents 8
    // at the same 8-aligned base, since no two clock ops are ever in flight).
    const iovec_scratch: usize = if (preview1_sleep) (p1_ts_base + 88 - iovec_base) else if (preview1_time or preview1_rand) (p1_ts_base + 8 - iovec_base) else if (preview1) 16 else 0;

    // env.kv → wasi:keyvalue component lowering. The core imports the canonical
    // `cm32p2|…` ABI; the host writes each call's `result<…>` into a fixed
    // return area we reserve just past the static data (the open result `{disc,
    // handle:i32}` at `kv_open_ret`, increment's `{disc, s64@8}` at
    // `kv_inc_ret`, 8-aligned so the host's i64 store lands clean). See
    // `test/kv-component-reference/`.
    // Storage capabilities (`env.kv`, `env.blob`) share this component ABI: a
    // host-opened bucket + a fixed return area. `env.blob` reuses kv's return
    // areas (kv_open_ret/kv_inc_ret) and scratch locals — only one store op is
    // ever in flight in a single expression — so the only per-capability state
    // is a separate bucket handle global. `wants_store` gates the shared
    // component scaffolding (cm32p2 memory/realloc, the reserved return area).
    const wants_kv = kv_component and usesEnvKv(m);
    const wants_blob = kv_component and usesEnvBlob(m);
    const wants_db = kv_component and usesEnvDb(m);
    const wants_config = kv_component and usesEnvConfig(m);
    // The clock faces are scalar-shaped (nullary → i64): they ride the
    // component import ABI but need none of the store scaffolding below (no
    // realloc, no box), so they do NOT fold into `wants_store`. The wall
    // clock alone needs a small return area (`time_ret`) for its datetime.
    const wants_time_mono = kv_component and usesEnvTimeMono(m);
    const wants_time_wall = kv_component and usesEnvTimeWall(m);
    const wants_time = wants_time_mono or wants_time_wall;
    // A str-returning export needs the component scaffolding (cm32p2 memory +
    // realloc for the return-area wrapper) even with no storage capability.
    const wants_str_export = kv_component and usesStrExport(m);
    const wants_store = wants_kv or wants_blob or wants_db or wants_config or wants_str_export;
    const kv_open_ret: u32 = @intCast((m.data.len + 7) & ~@as(usize, 7));
    const kv_inc_ret: u32 = kv_open_ret + 8;
    // The op return area is 24 bytes: kv/blob results fit in 16, but a
    // `result<option<s64>, error>` (env.db.query_value) is 8-aligned, so its
    // option-disc lands at +8 and the s64 at +16 (through +24).
    const kv_scratch: usize = if (wants_store) (kv_inc_ret + 24) - @as(u32, @intCast(m.data.len)) else 0;
    // wall-clock.now writes its `datetime {seconds: u64, nanoseconds: u32}`
    // record through a return pointer — reserve a 16-byte, 8-aligned cell
    // past the data + store scratch when the wall clock is reached.
    const time_ret: u32 = @intCast((m.data.len + kv_scratch + 7) & ~@as(usize, 7));
    const time_scratch: usize = if (wants_time_wall) (time_ret + 16) - (m.data.len + kv_scratch) else 0;
    if (wants_out) {
        switch (stdout_abi) {
            .env_out => {
                // Raw host faces: `(import "env" "out")` / `(import "env" "err")`,
                // each `(ptr, len) -> ()`. Declared per stream actually written,
                // so an err-only (or out-only) module imports exactly what it calls.
                var io_params = [_]c.BinaryenType{ ptr_type, ptr_type };
                const io_params_type = c.BinaryenTypeCreate(&io_params, io_params.len);
                if (writes_stdout) c.BinaryenAddFunctionImport(module, "env_out", "env", "out", io_params_type, none_type);
                if (writes_stderr) c.BinaryenAddFunctionImport(module, "env_err", "env", "err", io_params_type, none_type);
            },
            .wasi_preview1 => {
                // fd_write(fd: i32, iovs: i32, iovs_len: i32, nwritten: i32) -> errno: i32.
                // One import serves both fd 1 (stdout) and fd 2 (stderr).
                var fd_params = [_]c.BinaryenType{ i32_type, i32_type, i32_type, i32_type };
                const fd_params_type = c.BinaryenTypeCreate(&fd_params, fd_params.len);
                c.BinaryenAddFunctionImport(module, "fd_write", "wasi_snapshot_preview1", "fd_write", fd_params_type, i32_type);
            },
        }
    }

    // The `env.exit` capability import — declared only when the program calls
    // it. Same two shapes as `env.out` (see `StdoutAbi`): the raw host face
    // `(import "env" "exit" (func (param i64)))`, satisfied directly by
    // `runtime/wasmtime/` and `runtime/browser/`; or WASI preview1
    // `(import "wasi_snapshot_preview1" "proc_exit" (func (param i32)))`, which
    // the adapter lifts to `wasi:cli/exit`. The code is an i64 value (not an
    // address), so the raw face is i64 on either address space.
    const wants_exit = usesEnvExit(m);
    if (wants_exit) {
        switch (stdout_abi) {
            .env_out => {
                var exit_params = [_]c.BinaryenType{i64_type};
                const exit_params_type = c.BinaryenTypeCreate(&exit_params, exit_params.len);
                c.BinaryenAddFunctionImport(module, "env_exit", "env", "exit", exit_params_type, none_type);
            },
            .wasi_preview1 => {
                // proc_exit(code: i32) -> () (noreturn; typed as no result).
                var pe_params = [_]c.BinaryenType{i32_type};
                const pe_params_type = c.BinaryenTypeCreate(&pe_params, pe_params.len);
                c.BinaryenAddFunctionImport(module, "proc_exit", "wasi_snapshot_preview1", "proc_exit", pe_params_type, none_type);
            },
        }
    }

    // Memory maximum. The preview1 path leaves it unbounded (Binaryen's
    // `kUnlimitedSize` sentinel emits no max) because the WASI adapter grows the
    // memory to carve its own stack at startup — a fixed 1-page max would trap
    // `allocate_stack`. This holds for any preview1 module (stdout or exit-only).
    // The raw `env.out`/library paths keep the 1-page cap.
    // fs.read lets the HOST grow memory for file contents (spec/env.md
    // §"Wire ABI: fs.read"), so the max must allow it.
    var any_fs = false;
    var any_args = false;
    var any_vec = false;
    for (m.funcs) |*f2| {
        const st2 = switch (f2.body) {
            .structured => |inst| inst,
            .cfg => continue,
        };
        var sc2 = Scratch{};
        scanScratch(st2, &sc2);
        if (sc2.has_fs) any_fs = true;
        if (sc2.has_args or sc2.has_envvar) any_args = true;
        if (sc2.has_vec) any_vec = true;
    }
    // Vecs allocate their headers + data from a PERSISTENT heap (`hp`), separate
    // from the per-call stack arena (`sp`) which is restored on every call — a
    // vec that outlives the call (actor `state Vec`) would otherwise share the
    // reset `sp` base with the next call's vec. The heap lives above a 1 MiB
    // stack region; reserve enough pages to hold it.
    const vec_hp_base: u32 = 1024 * 1024; // `hp` start — stack is [arena, 1 MiB)
    const vec_mem_pages: c.BinaryenIndex = 64; // 4 MiB: 1 MiB stack + 3 MiB heap
    // The kv path keeps memory bounded but growable: the canonical `cabi_realloc`
    // serves host-side allocations (e.g. an error variant's `other(string)`) from
    // page 1 up, so reserve room above the page-0 data/scratch/arena. fs.read and
    // env.args let the host grow guest memory, so they also need headroom.
    // A vec needs the pages regardless of the store path: a store-component
    // module with actor `state Vec` still allocates at `vec_hp_base` (1 MiB),
    // so 2 initial pages would trap on the first vec write. `vec_mem_pages`
    // equals the store max (64), so the store+vec module comes out (64, 64).
    const mem_min: c.BinaryenIndex = if (any_vec) vec_mem_pages else if (wants_store) 2 else 1;
    const mem_max: c.BinaryenIndex = if (stdout_abi == .wasi_preview1) 0xffff_ffff else if (wants_store) 64 else if (any_vec) vec_mem_pages else if (any_fs or any_args) 256 else 1;
    // The component model requires the canonical memory export to be named
    // `cm32p2_memory`; the raw paths keep the plain `memory`.
    const mem_export_name = if (wants_store) "cm32p2_memory" else "memory";

    // One active data segment at offset 0 holds the whole memory image.
    if (m.data.len == 0) {
        c.BinaryenSetMemory(module, mem_min, mem_max, mem_export_name, null, null, null, null, null, 0, false, mem64, "0");
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
        c.BinaryenSetMemory(module, mem_min, mem_max, mem_export_name, null, @ptrCast(&seg_datas), @ptrCast(&seg_passives), @ptrCast(&seg_offsets), @ptrCast(&seg_sizes), seg_sizes.len, false, mem64, "0");
    }

    // Int formatting needs `__fmt_i64`; either formatting or a concat needs
    // the scope-arena bump global (`sp`).
    var needs_fmt = false;
    var needs_fmt_f64 = false;
    var needs_arena = false;
    var needs_str_eq = false;
    var needs_vec = false;
    var needs_fs = false;
    var needs_args = false;
    var needs_envvar = false;
    var needs_kv = false;
    var needs_time = false;
    var needs_time_res = false;
    var needs_time_wall = false;
    var needs_time_sleep = false;
    var needs_chan = false;
    var needs_take = false;
    var needs_connect = false;
    var needs_presses = false;
    var needs_index_of = false;
    var needs_starts_with = false;
    var needs_contains = false;
    for (m.funcs) |f| {
        const inst = switch (f.body) {
            .structured => |x| x,
            .cfg => return Error.CfgUnsupported,
        };
        if (bodyHasOut(inst, true)) needs_fmt = true;
        var sc = Scratch{};
        scanScratch(inst, &sc);
        if (sc.has_concat) needs_arena = true;
        if (sc.rec_depth > 0) needs_arena = true; // records live in the scope arena
        if (sc.has_float_fmt) needs_fmt_f64 = true;
        // Any frame-reclamation region (a call / host statement wrap)
        // reads + writes `sp`, so the arena global must exist.
        if (sc.region_depth > 0) needs_arena = true;
        if (sc.has_vec) {
            needs_vec = true;
            needs_arena = true;
        }
        if (sc.has_fs) {
            needs_fs = true;
            needs_arena = true;
        }
        if (sc.has_args) {
            needs_args = true;
            needs_arena = true; // env.args materializes into the scope arena
        }
        if (sc.has_envvar) {
            needs_envvar = true;
            needs_arena = true; // the value rides the scope arena
        }
        if (sc.has_kv) needs_kv = true;
        if (sc.has_time) needs_time = true; // scalar-only: no arena
        if (sc.has_time_res) needs_time_res = true;
        if (sc.has_time_wall) needs_time_wall = true;
        if (sc.has_time_sleep) needs_time_sleep = true;
        // set/get box their `result<…>` into the scope arena (like fs_read),
        // so the qube needs the `sp` bump pointer even if nothing else uses it.
        if (sc.has_kv_set or sc.has_kv_get or sc.has_blob_put or sc.has_blob_get or sc.has_blob_delete or sc.has_db_execute or sc.has_db_query_value or sc.has_db_query_text or sc.has_db_query_one or sc.has_config_get) needs_arena = true;
        if (sc.has_chan) needs_chan = true;
        if (sc.has_take) needs_take = true;
        if (sc.has_connect) needs_connect = true;
        if (sc.has_presses) needs_presses = true;
        if (sc.has_str_eq) needs_str_eq = true;
        if (sc.has_index_of) needs_index_of = true;
        if (sc.has_starts_with) needs_starts_with = true;
        if (sc.has_contains) needs_contains = true;
    }
    if (needs_fmt) needs_arena = true;
    if (needs_fmt_f64) needs_arena = true;
    if (needs_arena) {
        // The scope-arena bump pointer starts just past the static data — and,
        // on the preview1 path, past the reserved iovec scratch, or on the kv
        // path past the keyvalue return-area scratch — at the address width
        // (i32 on wasm32, i64 on wasm64).
        const arena_start = m.data.len + iovec_scratch + kv_scratch + time_scratch;
        const sp_init = if (mem64)
            c.BinaryenConst(module, c.BinaryenLiteralInt64(@intCast(arena_start)))
        else
            c.BinaryenConst(module, c.BinaryenLiteralInt32(@intCast(arena_start)));
        _ = c.BinaryenAddGlobal(module, "sp", ptr_type, true, sp_init);
    }
    if (needs_vec) {
        // The persistent vec heap: bumps up from `vec_hp_base` and is NEVER
        // restored (unlike `sp`), so a `state Vec`'s data survives across calls
        // and distinct vecs never collide. Leaks (no free) — fine for the
        // bounded workloads vecs serve today.
        const hp_init = if (mem64)
            c.BinaryenConst(module, c.BinaryenLiteralInt64(@intCast(vec_hp_base)))
        else
            c.BinaryenConst(module, c.BinaryenLiteralInt32(@intCast(vec_hp_base)));
        _ = c.BinaryenAddGlobal(module, "hp", ptr_type, true, hp_init);
    }
    if (needs_fs) {
        // env.fs_read : (dest, path_ptr, path_len) -> i64 (spec/env.md).
        var fsp = [_]c.BinaryenType{ ptr_type, ptr_type, ptr_type };
        const fs_params = c.BinaryenTypeCreate(&fsp, fsp.len);
        c.BinaryenAddFunctionImport(module, "env_fs_read", "env", "fs_read", fs_params, i64_type);
    }
    if (needs_args) {
        // env.args : (dest) -> i64. The host writes `[count][cells…][bytes…]`
        // at dest (growing guest memory if needed) and returns the total bytes
        // (spec/env.md §`env.args`). `wasi:cli/environment.get-arguments`.
        var ap = [_]c.BinaryenType{ptr_type};
        const args_params = c.BinaryenTypeCreate(&ap, ap.len);
        c.BinaryenAddFunctionImport(module, "env_args", "env", "args", args_params, i64_type);
    }
    if (needs_envvar) {
        // env.envvar : (dest, key_ptr, key_len) -> i64. The host writes the
        // variable's value at dest and returns its byte length (0 if unset),
        // growing guest memory if needed. `wasi:cli/environment.get-environment`.
        var ep = [_]c.BinaryenType{ ptr_type, ptr_type, ptr_type };
        const envvar_params = c.BinaryenTypeCreate(&ep, ep.len);
        c.BinaryenAddFunctionImport(module, "env_envvar", "env", "envvar", envvar_params, i64_type);
    }
    if (needs_kv and !wants_kv) {
        // Local `qube run` ABI — env.kv_increment : (key_ptr, key_len, delta) ->
        // i64 (spec/env.md §`env.kv`). The key is a str (ptr,len on the address
        // width); the keyless form passes (0, 0) — the host's empty key. delta +
        // result are i64 regardless of address space.
        var kvp = [_]c.BinaryenType{ ptr_type, ptr_type, i64_type };
        const kv_params = c.BinaryenTypeCreate(&kvp, kvp.len);
        c.BinaryenAddFunctionImport(module, "env_kv_increment", "env", "kv_increment", kv_params, i64_type);
    }
    if (wants_kv) {
        // Component ABI — the canonical `wasi:keyvalue` core imports (cm32p2):
        //   store.open(identifier_ptr, identifier_len, retptr)   -> writes result<bucket,error>
        //   atomics.increment(bucket, key_ptr, key_len, delta, retptr) -> writes result<s64,error>
        // The adapter-held bucket is opened host-side (empty identifier; the host
        // pins it to the qube's identity), cached in `kv_bucket` (-1 = unopened).
        const store_mod = "cm32p2|" ++ kv_store_iface;
        const atomics_mod = "cm32p2|" ++ kv_atomics_iface;
        var op = [_]c.BinaryenType{ i32_type, i32_type, i32_type };
        const open_params = c.BinaryenTypeCreate(&op, op.len);
        c.BinaryenAddFunctionImport(module, "kv_store_open", store_mod, "open", open_params, none_type);
        var ip = [_]c.BinaryenType{ i32_type, i32_type, i32_type, i64_type, i32_type };
        const inc_params = c.BinaryenTypeCreate(&ip, ip.len);
        c.BinaryenAddFunctionImport(module, "kv_atomics_increment", atomics_mod, "increment", inc_params, none_type);
        // Bucket resource methods (only when the qube reaches them, so an
        // increment-only qube's import surface is unchanged). The canonical
        // `wit-component` names are `[method]bucket.set` / `[method]bucket.get`
        // on the `store` interface; the bucket handle is the leading param and
        // the trailing i32 is the return-area pointer the host writes into.
        //   set(bucket, key_ptr, key_len, val_ptr, val_len, ret) -> result<_,error>
        //   get(bucket, key_ptr, key_len, ret)                   -> result<option<list<u8>>,error>
        if (usesKvSet(m)) {
            var sp = [_]c.BinaryenType{ i32_type, i32_type, i32_type, i32_type, i32_type, i32_type };
            const set_params = c.BinaryenTypeCreate(&sp, sp.len);
            c.BinaryenAddFunctionImport(module, "kv_bucket_set", store_mod, "[method]bucket.set", set_params, none_type);
        }
        if (usesKvGet(m)) {
            var gp = [_]c.BinaryenType{ i32_type, i32_type, i32_type, i32_type };
            const get_params = c.BinaryenTypeCreate(&gp, gp.len);
            c.BinaryenAddFunctionImport(module, "kv_bucket_get", store_mod, "[method]bucket.get", get_params, none_type);
        }
        _ = c.BinaryenAddGlobal(module, "kv_bucket", i32_type, true, c.BinaryenConst(module, c.BinaryenLiteralInt32(-1)));
    }
    if (wants_blob) {
        // `env.blob` → the q64-owned `q64:blob/store` core imports (cm32p2),
        // same shapes as kv's store bucket methods (probed identical mangling):
        //   open(identifier_ptr, identifier_len, ret)            -> result<bucket,error>
        //   [method]bucket.get(bucket, key_ptr, key_len, ret)    -> result<option<list<u8>>,error>
        //   [method]bucket.put(bucket, key_ptr, key_len, val_ptr, val_len, ret) -> result<_,error>
        //   [method]bucket.delete(bucket, key_ptr, key_len, ret) -> result<_,error>
        // The bucket is host-opened + identity-pinned, cached in `blob_bucket`.
        const blob_mod = "cm32p2|" ++ blob_store_iface;
        var op = [_]c.BinaryenType{ i32_type, i32_type, i32_type };
        const open_params = c.BinaryenTypeCreate(&op, op.len);
        c.BinaryenAddFunctionImport(module, "blob_store_open", blob_mod, "open", open_params, none_type);
        if (usesBlobGet(m)) {
            var gp = [_]c.BinaryenType{ i32_type, i32_type, i32_type, i32_type };
            const get_params = c.BinaryenTypeCreate(&gp, gp.len);
            c.BinaryenAddFunctionImport(module, "blob_bucket_get", blob_mod, "[method]bucket.get", get_params, none_type);
        }
        if (usesBlobPut(m)) {
            var pp = [_]c.BinaryenType{ i32_type, i32_type, i32_type, i32_type, i32_type, i32_type };
            const put_params = c.BinaryenTypeCreate(&pp, pp.len);
            c.BinaryenAddFunctionImport(module, "blob_bucket_put", blob_mod, "[method]bucket.put", put_params, none_type);
        }
        if (usesBlobDelete(m)) {
            var dp = [_]c.BinaryenType{ i32_type, i32_type, i32_type, i32_type };
            const del_params = c.BinaryenTypeCreate(&dp, dp.len);
            c.BinaryenAddFunctionImport(module, "blob_bucket_delete", blob_mod, "[method]bucket.delete", del_params, none_type);
        }
        _ = c.BinaryenAddGlobal(module, "blob_bucket", i32_type, true, c.BinaryenConst(module, c.BinaryenLiteralInt32(-1)));
    }
    if (wants_db) {
        // `env.db` → the q64-owned `q64:db/sql` core imports (cm32p2):
        //   open(identifier_ptr, identifier_len, ret)         -> result<connection,error>
        //   [method]connection.exec(conn, sql_ptr, sql_len, ret)        -> result<u64,error>
        //   [method]connection.query-value(conn, sql_ptr, sql_len, ret) -> result<option<s64>,error>
        //   [method]connection.query-text(conn, sql_ptr, sql_len, ret)  -> result<option<string>,error>
        // The connection is host-opened + identity-pinned, cached in `db_connection`.
        const db_mod = "cm32p2|" ++ db_sql_iface;
        var op = [_]c.BinaryenType{ i32_type, i32_type, i32_type };
        const open_params = c.BinaryenTypeCreate(&op, op.len);
        c.BinaryenAddFunctionImport(module, "db_conn_open", db_mod, "open", open_params, none_type);
        var mp = [_]c.BinaryenType{ i32_type, i32_type, i32_type, i32_type };
        const m_params = c.BinaryenTypeCreate(&mp, mp.len);
        if (usesDbExec(m)) c.BinaryenAddFunctionImport(module, "db_conn_exec", db_mod, "[method]connection.exec", m_params, none_type);
        if (usesDbQueryValue(m)) c.BinaryenAddFunctionImport(module, "db_conn_query_value", db_mod, "[method]connection.query-value", m_params, none_type);
        if (usesDbQueryText(m)) c.BinaryenAddFunctionImport(module, "db_conn_query_text", db_mod, "[method]connection.query-text", m_params, none_type);
        if (usesDbQueryOne(m)) c.BinaryenAddFunctionImport(module, "db_conn_query_one", db_mod, "[method]connection.query-one", m_params, none_type);
        _ = c.BinaryenAddGlobal(module, "db_connection", i32_type, true, c.BinaryenConst(module, c.BinaryenLiteralInt32(-1)));
    }
    if (wants_config) {
        // `env.config` → the real `wasi:config/store` core import (cm32p2).
        // `get` is a TOP-LEVEL interface function (no resource, no host `open`),
        // so it's a plain `get(key_ptr, key_len, ret) -> result<option<string>,
        // error>` — no handle arg and no bucket global.
        const cfg_mod = "cm32p2|" ++ config_store_iface;
        var gp = [_]c.BinaryenType{ i32_type, i32_type, i32_type };
        const get_params = c.BinaryenTypeCreate(&gp, gp.len);
        c.BinaryenAddFunctionImport(module, "config_store_get", cfg_mod, "get", get_params, none_type);
    }
    if (preview1_rand) {
        // random_get(buf: i32, buf_len: i32) -> errno — the adapter lifts it
        // to `wasi:random/random`; 8 bytes through the reserved cell.
        var rgp = [_]c.BinaryenType{ i32_type, i32_type };
        const rg_params = c.BinaryenTypeCreate(&rgp, rgp.len);
        c.BinaryenAddFunctionImport(module, "random_get", "wasi_snapshot_preview1", "random_get", rg_params, i32_type);
    } else if (usesEnvRandom(m)) {
        // Local ABI: one raw face, a bare i64 (spec/env.md `env.random`).
        c.BinaryenAddFunctionImport(module, "env_random_u64", "env", "random_u64", none_type, i64_type);
    }
    if (preview1_time) {
        // Preview1 app ABI. The adapter lifts these to `wasi:clocks/*`:
        //   clock_time_get(clockid: i32, precision: i64, ts_ptr: i32) -> errno
        //     (clockid 1 = monotonic for monotonic_ns, 0 = realtime for unix_ns)
        //   clock_res_get(clockid: i32, res_ptr: i32) -> errno
        // All write a u64 through the shared timestamp cell (`p1_ts_base`).
        if (needs_time or needs_time_wall) {
            var ctp = [_]c.BinaryenType{ i32_type, i64_type, i32_type };
            const ct_params = c.BinaryenTypeCreate(&ctp, ctp.len);
            c.BinaryenAddFunctionImport(module, "clock_time_get", "wasi_snapshot_preview1", "clock_time_get", ct_params, i32_type);
        }
        if (needs_time_res) {
            var crp = [_]c.BinaryenType{ i32_type, i32_type };
            const cr_params = c.BinaryenTypeCreate(&crp, crp.len);
            c.BinaryenAddFunctionImport(module, "clock_res_get", "wasi_snapshot_preview1", "clock_res_get", cr_params, i32_type);
        }
        if (needs_time_sleep) {
            // poll_oneoff(in: *subscription, out: *event, nsubscriptions,
            // nevents_ptr) -> errno — one monotonic-clock subscription,
            // blocking until its relative timeout elapses.
            var pop = [_]c.BinaryenType{ i32_type, i32_type, i32_type, i32_type };
            const po_params = c.BinaryenTypeCreate(&pop, pop.len);
            c.BinaryenAddFunctionImport(module, "poll_oneoff", "wasi_snapshot_preview1", "poll_oneoff", po_params, i32_type);
        }
    } else if (!wants_time) {
        // Local `qube run` ABI — one `env.*` face per op (spec/env.md
        // §`env.time`), each scalar on every address width.
        if (needs_time) c.BinaryenAddFunctionImport(module, "env_monotonic_ns", "env", "monotonic_ns", none_type, i64_type);
        if (needs_time_res) c.BinaryenAddFunctionImport(module, "env_resolution_ns", "env", "resolution_ns", none_type, i64_type);
        if (needs_time_wall) c.BinaryenAddFunctionImport(module, "env_unix_ns", "env", "unix_ns", none_type, i64_type);
        if (needs_time_sleep) c.BinaryenAddFunctionImport(module, "env_sleep_ns", "env", "sleep_ns", i64_type, none_type);
    }
    if (wants_time) {
        // Component ABI — the canonical `wasi:clocks` core imports (cm32p2),
        // declared per op actually reached. `now`/`resolution` on the
        // monotonic clock return a direct scalar (no return area, no realloc,
        // no handle — the simplest capability imports there are); the wall
        // clock's `now` returns a `datetime` record, which the canonical ABI
        // spills through a return pointer (the `time_ret` cell). Note the
        // stable major.minor mangle (see `clocks_monotonic_core_mod`).
        if (needs_time) c.BinaryenAddFunctionImport(module, "clocks_monotonic_now", clocks_monotonic_core_mod, "now", none_type, i64_type);
        if (needs_time_res) c.BinaryenAddFunctionImport(module, "clocks_monotonic_resolution", clocks_monotonic_core_mod, "resolution", none_type, i64_type);
        if (needs_time_wall) c.BinaryenAddFunctionImport(module, "clocks_wall_now", clocks_wall_core_mod, "now", i32_type, none_type);
        if (needs_time_sleep) {
            // The blocking chain: subscribe-duration(ns) -> pollable handle,
            // [method]pollable.block(handle), pollable_drop(handle) — the
            // drop intrinsic mangles as `<resource>_drop`, NOT the
            // `[resource-drop]` canon syntax (probed via `component embed
            // --dummy`). The handle parks in the `sleep_pollable` global
            // between the three calls (sleeps never nest — no local plumbing).
            c.BinaryenAddFunctionImport(module, "clocks_subscribe_duration", clocks_monotonic_core_mod, "subscribe-duration", i64_type, i32_type);
            c.BinaryenAddFunctionImport(module, "io_pollable_block", io_poll_core_mod, "[method]pollable.block", i32_type, none_type);
            c.BinaryenAddFunctionImport(module, "io_pollable_drop", io_poll_core_mod, "pollable_drop", i32_type, none_type);
            _ = c.BinaryenAddGlobal(module, "sleep_pollable", i32_type, true, c.BinaryenConst(module, c.BinaryenLiteralInt32(-1)));
        }
    }
    if (wants_store) {
        // The canonical `cabi_realloc` bump allocator, exported as
        // `cm32p2_realloc`. Allocations start at page 1 (65536), above page-0
        // data/scratch/arena; `component new` requires the export to exist.
        _ = c.BinaryenAddGlobal(module, "cabi_heap", i32_type, true, c.BinaryenConst(module, c.BinaryenLiteralInt32(65536)));
        try emitCabiRealloc(module, i32_type);
    }
    if (needs_chan) {
        // env.channel_recv : (session) -> i64 (spec/env.md §"Channel entry
        // point"). Receives the next inbound message on a remote channel
        // session: 1 = a message arrived (run the loop body), 0 = the peer
        // closed (end the loop). The session handle + result are i64 regardless
        // of address space. (The outbound `env.channel_send` is a void host call,
        // auto-declared by the host-call scan.) v0 host-import seam.
        var chp = [_]c.BinaryenType{i64_type};
        const ch_params = c.BinaryenTypeCreate(&chp, chp.len);
        c.BinaryenAddFunctionImport(module, "env_channel_recv", "env", "channel_recv", ch_params, i64_type);
    }
    if (needs_take) {
        // env.channel_take : (session) -> i64 — the i64 payload of the message
        // `channel_recv` just reported (a value-bearing `for n in session`).
        var ctp = [_]c.BinaryenType{i64_type};
        const ct_params = c.BinaryenTypeCreate(&ctp, ctp.len);
        c.BinaryenAddFunctionImport(module, "env_channel_take", "env", "channel_take", ct_params, i64_type);
    }
    if (needs_connect) {
        // env.channel_connect : () -> i64 — open the dual end of an imported
        // channel export (`connect<iface.fn>()`), yielding a session handle.
        c.BinaryenAddFunctionImport(module, "env_channel_connect", "env", "channel_connect", none_type, i64_type);
    }
    if (needs_presses) {
        // env.presses : () -> i64 — open the host press event stream (HOST SEAM
        // 2), yielding a session handle iterated like any inbound channel.
        c.BinaryenAddFunctionImport(module, "env_presses", "env", "presses", none_type, i64_type);
    }
    if (needs_fmt) try emitFmtI64(module, allocator, i64_type, pair_type, ptr_type, mem64);
    if (needs_fmt_f64) try emitFmtF64(module, allocator, i64_type, pair_type, ptr_type, mem64);
    if (needs_str_eq) try emitStrEq(module, allocator, i32_type, ptr_type, mem64);
    if (needs_index_of) try emitStrIndexOf(module, allocator, i64_type, i32_type, ptr_type, mem64);
    // `contains` is implemented on top of `starts_with`, so emit the latter when
    // either is used.
    if (needs_starts_with or needs_contains) try emitStrStartsWith(module, allocator, i32_type, ptr_type, mem64);
    if (needs_vec) try emitVecHelpers(module, allocator, i64_type, i32_type, ptr_type, mem64);
    if (needs_contains) try emitStrContains(module, allocator, i32_type, ptr_type, mem64);

    // Host-face imports (e.g. `qview.text`): declare one wasm import per distinct
    // host_call name. All args are i64 (valid on wasm32); the import returns void.
    // Names live in `name_arena` through module emission.
    var name_arena = std.heap.ArenaAllocator.init(allocator);
    defer name_arena.deinit();
    const na = name_arena.allocator();
    var host_imports = std.StringHashMapUnmanaged([*:0]const u8){};
    {
        var sigs = std.StringHashMapUnmanaged([]const *ir.mir.Inst){};
        for (m.funcs) |f| {
            const inst = switch (f.body) {
                .structured => |x| x,
                .cfg => return Error.CfgUnsupported,
            };
            try scanHostCalls(inst, &sigs, na);
        }
        var it = sigs.iterator();
        while (it.next()) |e| {
            const dotted = e.key_ptr.*;
            const cargs = e.value_ptr.*;
            const dot = std.mem.indexOfScalar(u8, dotted, '.') orelse return Error.UnsupportedCall;
            const mod_z = try na.dupeZ(u8, dotted[0..dot]);
            const field_z = try na.dupeZ(u8, dotted[dot + 1 ..]);
            const internal = try std.fmt.allocPrint(na, "{s}_{s}", .{ dotted[0..dot], dotted[dot + 1 ..] });
            const internal_z = try na.dupeZ(u8, internal);
            // Per-arg param types: a `str` arg lowers to two address-width values
            // (ptr, len); any other arg is one i64. Must match the call-site
            // operands (see the `.host_call` lowering / `strOperands`).
            var ptypes: std.ArrayList(c.BinaryenType) = .empty;
            defer ptypes.deinit(na);
            for (cargs) |arg| {
                if (arg.ty == .str) {
                    try ptypes.append(na, ptr_type);
                    try ptypes.append(na, ptr_type);
                } else {
                    try ptypes.append(na, i64_type);
                }
            }
            const ptype = if (ptypes.items.len > 0) c.BinaryenTypeCreate(ptypes.items.ptr, @intCast(ptypes.items.len)) else none_type;
            c.BinaryenAddFunctionImport(module, internal_z.ptr, mod_z.ptr, field_z.ptr, ptype, none_type);
            try host_imports.put(na, dotted, internal_z.ptr);
        }
    }

    // Foreign WIT imports (`<iface>.<fn>(…)` from `--wit-import`). Unlike host
    // faces these return a value: declare `(import "<wit-id>" "<fn>" (param …)
    // (result …))` with scalar param/result types read off a representative call
    // inst, and map "<module>\x00<field>" → the internal import name for the
    // `.foreign_call` lowering.
    var foreign_imports = std.StringHashMapUnmanaged([*:0]const u8){};
    {
        var sites = std.StringHashMapUnmanaged(*const ir.mir.Inst){};
        for (m.funcs) |f| {
            const inst = switch (f.body) {
                .structured => |x| x,
                .cfg => return Error.CfgUnsupported,
            };
            try scanForeignCalls(inst, &sites, na);
        }
        var it = sites.iterator();
        var fidx: u32 = 0;
        while (it.next()) |e| : (fidx += 1) {
            const key = e.key_ptr.*; // "<module>\x00<field>"
            const site = e.value_ptr.*;
            const fc = site.op.foreign_call;
            const mod_z = try na.dupeZ(u8, fc.module);
            const field_z = try na.dupeZ(u8, fc.field);
            const internal_z = try na.dupeZ(u8, try std.fmt.allocPrint(na, "wit_import_{d}", .{fidx}));
            // Scalar params only (the canonical-ABI boundary): one wasm value per
            // arg, typed by the arg's MIR type. The result is the call inst's type.
            var ptypes: std.ArrayList(c.BinaryenType) = .empty;
            defer ptypes.deinit(na);
            for (fc.args) |arg| try ptypes.append(na, wasmType(arg.ty, i64_type, i32_type, none_type, pair_type, ptr_type));
            const ptype = if (ptypes.items.len > 0) c.BinaryenTypeCreate(ptypes.items.ptr, @intCast(ptypes.items.len)) else none_type;
            const rtype = wasmType(site.ty, i64_type, i32_type, none_type, pair_type, ptr_type);
            c.BinaryenAddFunctionImport(module, internal_z.ptr, mod_z.ptr, field_z.ptr, ptype, rtype);
            try foreign_imports.put(na, key, internal_z.ptr);
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

    // The wasm `start` function (module-init for singleton globals), captured in
    // the loop below so `BinaryenSetStart` can wire it after all functions exist.
    var start_ref: c.BinaryenFunctionRef = null;
    for (m.funcs, 0..) |f, fi| {
        const structured = switch (f.body) {
            .structured => |inst| inst,
            .cfg => return Error.CfgUnsupported,
        };
        const is_entry = (f.linkage == .entry);
        const is_init = (m.init_fn != null and m.init_fn.? == fi);

        // A `str` parameter is two i64 wasm params (ptr, len); an i64 is one.
        var params_width: usize = 0;
        for (f.params) |p| params_width += if (p == .str) 2 else 1;

        // Scratch layout, just past the params + declared locals:
        //   [tuple slots × n_tuples][buf][off][len][record base ptrs × rec_depth].
        // The first tuple slot doubles as the host_out pair scratch.
        var sc = Scratch{};
        scanScratch(structured, &sc);
        const n_tuples: u32 = @max(@as(u32, if (sc.host_out) 1 else 0), sc.max_tuples);
        const n_concat: u32 = if (sc.has_concat) 3 else 0;
        const n_bounds: u32 = if (sc.has_bounds) 1 else 0;
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
            .rec_base = base + n_tuples + n_concat,
            .bounds_idx = base + n_tuples + n_concat + sc.rec_depth,
            .region_base = base + n_tuples + n_concat + sc.rec_depth + n_bounds,
            .fs_dest_idx = base + n_tuples + n_concat + sc.rec_depth + n_bounds + sc.region_depth * 8,
            .fs_len_idx = base + n_tuples + n_concat + sc.rec_depth + n_bounds + sc.region_depth * 8 + 1,
            .host_imports = &host_imports,
            .foreign_imports = &foreign_imports,
            .global_names = global_names,
            .stdout_abi = stdout_abi,
            .iovec_base = iovec_base,
            .kv_component = wants_kv,
            .blob_component = wants_blob,
            .db_component = wants_db,
            .config_component = wants_config,
            .time_component = wants_time,
            .time_preview1 = preview1_time,
            .rand_preview1 = preview1_rand,
            .p1_ts_base = p1_ts_base,
            .time_ret = time_ret,
            .kv_open_ret = kv_open_ret,
            .kv_inc_ret = kv_inc_ret,
            .kv_hdr_idx = base + n_tuples + n_concat + sc.rec_depth + n_bounds + sc.region_depth * 8 + (if (sc.has_fs or sc.has_envvar) @as(u32, 2) else 0),
            .kv_a_idx = base + n_tuples + n_concat + sc.rec_depth + n_bounds + sc.region_depth * 8 + (if (sc.has_fs or sc.has_envvar) @as(u32, 2) else 0) + 1,
            .kv_b_idx = base + n_tuples + n_concat + sc.rec_depth + n_bounds + sc.region_depth * 8 + (if (sc.has_fs or sc.has_envvar) @as(u32, 2) else 0) + 2,
        };
        defer lw.deinit();

        // varTypes (locals beyond params): declared locals, then tuple slots,
        // then the concat scratch (buf/off/len) when concatenating, then one
        // base-ptr scratch per record_make nesting level.
        const n_fs: u32 = if (sc.has_fs or sc.has_envvar) 2 else 0;
        // kv set/get need three address-width scratch locals (box header ptr +
        // saved key ptr/len); allocated after the fs/envvar scratch group.
        const n_kv: u32 = if (sc.has_kv_set or sc.has_kv_get or sc.has_blob_put or sc.has_blob_get or sc.has_blob_delete or sc.has_db_execute or sc.has_db_query_value or sc.has_db_query_text or sc.has_db_query_one or sc.has_config_get) 3 else 0;
        const n_extra = f.locals.len + n_tuples + n_concat + sc.rec_depth + n_bounds + sc.region_depth * 8 + n_fs + n_kv;
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
        for (0..sc.rec_depth) |j| vts[f.locals.len + n_tuples + n_concat + j] = ptr_type;
        if (sc.has_bounds) vts[f.locals.len + n_tuples + n_concat + sc.rec_depth] = i64_type;
        // Frame-reclamation scratch: per region level, [wm ptr, i64, i32,
        // f64, f32, pair, ptr, v128] (the watermark + one stash per value
        // type).
        for (0..sc.region_depth) |j| {
            const g = f.locals.len + n_tuples + n_concat + sc.rec_depth + n_bounds + j * 8;
            vts[g] = ptr_type;
            vts[g + 1] = i64_type;
            vts[g + 2] = i32_type;
            vts[g + 3] = c.BinaryenTypeFloat64();
            vts[g + 4] = c.BinaryenTypeFloat32();
            vts[g + 5] = pair_type;
            vts[g + 6] = ptr_type;
            vts[g + 7] = c.BinaryenTypeVec128();
        }
        if (sc.has_fs or sc.has_envvar) {
            const g = f.locals.len + n_tuples + n_concat + sc.rec_depth + n_bounds + sc.region_depth * 8;
            vts[g] = ptr_type; // fs/envvar dest
            vts[g + 1] = i64_type; // fs/envvar len
        }
        if (sc.has_kv_set or sc.has_kv_get or sc.has_blob_put or sc.has_blob_get or sc.has_blob_delete or sc.has_db_execute or sc.has_db_query_value or sc.has_db_query_text or sc.has_db_query_one or sc.has_config_get) {
            const g = f.locals.len + n_tuples + n_concat + sc.rec_depth + n_bounds + sc.region_depth * 8 + n_fs;
            vts[g] = ptr_type; // kv box header ptr
            vts[g + 1] = ptr_type; // kv saved key ptr
            vts[g + 2] = ptr_type; // kv saved key len
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
        const fref = c.BinaryenAddFunction(module, f.name.ptr, ptype, ret, if (n_extra > 0) @ptrCast(vts.ptr) else null, @intCast(n_extra), body);
        if (is_init) start_ref = fref;
        if (is_entry) {
            _ = c.BinaryenAddFunctionExport(module, f.name.ptr, "_start");
        } else if (f.exported) {
            // Interface-export mode: a library's funcs are exported under the
            // WIT interface id (`<pkg>/<iface>#<fn>`), the core-export naming
            // `wasm-tools component embed` maps into the named interface. Plain
            // mode exports them by name (the hand-rolled scalar encoder lifts
            // those directly).
            if (export_interface) |iface| {
                const qualified = try std.fmt.allocPrintSentinel(allocator, "{s}#{s}", .{ iface, f.name }, 0);
                defer allocator.free(qualified);
                _ = c.BinaryenAddFunctionExport(module, f.name.ptr, qualified.ptr);
            } else if (wants_store or wants_time) {
                // Store-component (kv/blob/db/config/time) mode: exports follow
                // the canonical `cm32p2||<name>` convention, kebab-cased to match
                // the synthesized world export (a `_` in the fn name → `-`, or
                // the world's kebab export wouldn't resolve against the core's
                // raw name). Time is scalar-only but still lifts through this
                // path, so its exports need the same mangle.
                const ext = try std.fmt.allocPrintSentinel(allocator, "cm32p2||{s}", .{f.name}, 0);
                defer allocator.free(ext);
                for (ext) |*ch| if (ch.* == '_') {
                    ch.* = '-';
                };
                if (f.ret == .str) {
                    // A `-> str` export needs the canonical-ABI return-area
                    // wrapper (q64 returns str as a `(ptr,len)` multivalue; the
                    // component export must return a pointer to `{ptr,len}`).
                    // Export the wrapper as `cm32p2||<name>`; the internal fn
                    // stays under `f.name`.
                    const wrapper = try std.fmt.allocPrintSentinel(allocator, "{s}$cmexport", .{f.name}, 0);
                    defer allocator.free(wrapper);
                    try emitStrExportWrapper(module, allocator, f.name.ptr, wrapper.ptr, ext.ptr, pbuf, i32_type, pair_type);
                } else {
                    _ = c.BinaryenAddFunctionExport(module, f.name.ptr, ext.ptr);
                }
            } else {
                _ = c.BinaryenAddFunctionExport(module, f.name.ptr, f.name.ptr);
            }
        }
    }

    // Wire the module-init function as the wasm `start` — it runs once at
    // instantiation (before any export call), allocating singleton globals.
    if (start_ref) |sr| c.BinaryenSetStart(module, sr);

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

/// Run Binaryen's `asyncify` pass over an already-emitted core module so a host
/// can suspend/resume the wasm at the named imports (e.g. `env.channel_recv`):
/// the transform threads an unwind/rewind data path through the call graph and
/// adds the `asyncify_*` control exports (`asyncify_start_unwind`,
/// `asyncify_stop_unwind`, `asyncify_start_rewind`, `asyncify_stop_rewind`,
/// `asyncify_get_state`). The host parks the wasm at a blocking host read and
/// rewinds it when the next message arrives — the live `@channel_handler` loop.
///
/// `suspend_imports` is the comma-separated `module.base` list that may unwind
/// (only those; everything else stays synchronous, so the transform is small).
/// A separate, isolated post-pass: it reads the emitted wasm back into Binaryen,
/// runs one pass, and re-serializes — `q64 emit … --asyncify` opts in. Caller
/// owns the returned bytes.
pub fn asyncifyWasm(allocator: std.mem.Allocator, wasm: []const u8, suspend_imports: []const u8, addr: AddressSpace) ![]u8 {
    var features = c.BinaryenFeatureMultivalue() | c.BinaryenFeatureBulkMemory() |
        c.BinaryenFeatureBulkMemoryOpt() | c.BinaryenFeatureMutableGlobals() |
        c.BinaryenFeatureNontrappingFPToInt() |
        c.BinaryenFeatureSIMD128() | c.BinaryenFeatureRelaxedSIMD(); // keep in sync with lowerToWasm — a re-read module must not drop v128
    if (addr == .wasm64) features |= c.BinaryenFeatureMemory64();

    const buf = try allocator.dupe(u8, wasm); // ModuleRead takes a mutable buffer
    defer allocator.free(buf);
    const module = c.BinaryenModuleReadWithFeatures(buf.ptr, buf.len, features) orelse return Error.ModuleInvalid;
    defer c.BinaryenModuleDispose(module);
    c.BinaryenModuleSetFeatures(module, features);

    // Only the listed imports unwind the stack; the rest stay synchronous.
    const imports_z = try allocator.dupeZ(u8, suspend_imports);
    defer allocator.free(imports_z);
    c.BinaryenSetPassArgument("asyncify-imports", imports_z.ptr);
    defer c.BinaryenClearPassArguments();

    var passes = [_][*c]const u8{"asyncify"};
    c.BinaryenModuleRunPasses(module, @ptrCast(&passes), passes.len);

    if (!c.BinaryenModuleValidate(module)) return Error.ModuleInvalid;
    const result = c.BinaryenModuleAllocateAndWrite(module, null);
    defer if (result.binary) |b| std.c.free(b);
    const ptr = result.binary orelse return Error.SerializeEmpty;
    if (result.binaryBytes == 0) return Error.SerializeEmpty;
    const out = try allocator.alloc(u8, result.binaryBytes);
    @memcpy(out, @as([*]const u8, @ptrCast(ptr))[0..result.binaryBytes]);
    return out;
}

/// Run Binaryen's standard optimization pipeline over an already-emitted core
/// module (`q64 emit … --release`). Same isolated read-back/re-serialize shape
/// as `asyncifyWasm`: the lowerer stays simple and emits whatever redundancy
/// is convenient (unconditional result slides, watermark save/restore), and
/// this post-pass cleans it up. Debug emits stay pass-free so the browser
/// codegen differential test keeps its byte-identical meaning.
pub fn optimizeWasm(allocator: std.mem.Allocator, wasm: []const u8, addr: AddressSpace) ![]u8 {
    var features = c.BinaryenFeatureMultivalue() | c.BinaryenFeatureBulkMemory() |
        c.BinaryenFeatureBulkMemoryOpt() | c.BinaryenFeatureMutableGlobals() |
        c.BinaryenFeatureNontrappingFPToInt() |
        c.BinaryenFeatureSIMD128() | c.BinaryenFeatureRelaxedSIMD(); // keep in sync with lowerToWasm — a re-read module must not drop v128
    if (addr == .wasm64) features |= c.BinaryenFeatureMemory64();

    const buf = try allocator.dupe(u8, wasm); // ModuleRead takes a mutable buffer
    defer allocator.free(buf);
    const module = c.BinaryenModuleReadWithFeatures(buf.ptr, buf.len, features) orelse return Error.ModuleInvalid;
    defer c.BinaryenModuleDispose(module);
    c.BinaryenModuleSetFeatures(module, features);

    // -O2, speed-focused, with wasm-level inlining disabled. All settings are
    // process-global in the C API, so set every one explicitly per call.
    // Inlining is off by measurement, not taste (bench/ suite): merging a hot
    // loop into its caller raises the merged frame's register pressure and
    // cost the serial DSP kernels ~2x under Cranelift, while the rest of the
    // -O2 pipeline kept its wins (fir16 ~20% faster than the debug emit).
    // Cranelift gains little from wasm-level inlining anyway.
    c.BinaryenSetOptimizeLevel(2);
    c.BinaryenSetShrinkLevel(0);
    c.BinaryenSetAlwaysInlineMaxSize(0);
    c.BinaryenSetFlexibleInlineMaxSize(0);
    c.BinaryenSetOneCallerInlineMaxSize(0);
    c.BinaryenModuleOptimize(module);

    if (!c.BinaryenModuleValidate(module)) return Error.ModuleInvalid;
    const result = c.BinaryenModuleAllocateAndWrite(module, null);
    defer if (result.binary) |b| std.c.free(b);
    defer if (result.sourceMap) |s| std.c.free(s);
    const ptr = result.binary orelse return Error.SerializeEmpty;
    if (result.binaryBytes == 0) return Error.SerializeEmpty;
    const out = try allocator.alloc(u8, result.binaryBytes);
    @memcpy(out, @as([*]const u8, @ptrCast(ptr))[0..result.binaryBytes]);
    return out;
}

fn wasmType(t: ir.mir.ValueType, i64_type: c.BinaryenType, i32_type: c.BinaryenType, none_type: c.BinaryenType, pair_type: c.BinaryenType, ptr_type: c.BinaryenType) c.BinaryenType {
    return switch (t) {
        .i64 => i64_type,
        .i32 => i32_type,
        .f32 => c.BinaryenTypeFloat32(),
        .f64 => c.BinaryenTypeFloat64(),
        .v128 => c.BinaryenTypeVec128(),
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
        .host_out_float => |h| bodyHasOut(h.value, want_int), // __fmt_f64 is its own helper
        .fmt_float_to_str => |inner| bodyHasOut(inner, want_int),
        .num_cast => |src| bodyHasOut(src, want_int),
        .bitcast => |src| bodyHasOut(src, want_int),
        .host_out_str => |h| !want_int or bodyHasOut(h.value, want_int),
        .block => |items| blk: {
            for (items) |child| if (bodyHasOut(child, want_int)) break :blk true;
            break :blk false;
        },
        .local_set => |ls| bodyHasOut(ls.value, want_int),
        .bin => |b| bodyHasOut(b.lhs, want_int) or bodyHasOut(b.rhs, want_int),
        .un => |u| bodyHasOut(u.operand, want_int),
        .simd_splat => |s| bodyHasOut(s.operand, want_int),
        .simd_extract => |s| bodyHasOut(s.vec, want_int),
        .simd_bin => |s| bodyHasOut(s.lhs, want_int) or bodyHasOut(s.rhs, want_int),
        .simd_un => |s| bodyHasOut(s.operand, want_int),
        .simd_load => |s| bodyHasOut(s.vec, want_int) or bodyHasOut(s.idx, want_int),
        .simd_store => |s| bodyHasOut(s.vec, want_int) or bodyHasOut(s.idx, want_int) or bodyHasOut(s.value, want_int),
        .simd_replace => |s| bodyHasOut(s.vec, want_int) or bodyHasOut(s.value, want_int),
        .simd_fma => |s| bodyHasOut(s.a, want_int) or bodyHasOut(s.b, want_int) or bodyHasOut(s.c, want_int),
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
        .foreign_call => |fc| blk: {
            for (fc.args) |a| if (bodyHasOut(a, want_int)) break :blk true;
            break :blk false;
        },
        .global_set => |gs| bodyHasOut(gs.value, want_int),
        .str_len => |s| bodyHasOut(s, want_int),
        .str_index => |si| bodyHasOut(si.str, want_int) or bodyHasOut(si.idx, want_int),
        .str_eq => |se| bodyHasOut(se.lhs, want_int) or bodyHasOut(se.rhs, want_int),
        .str_slice => |sl| bodyHasOut(sl.str, want_int) or bodyHasOut(sl.start, want_int) or bodyHasOut(sl.end, want_int),
        .str_index_of => |m| bodyHasOut(m.str, want_int) or bodyHasOut(m.byte, want_int),
        .str_starts_with => |m| bodyHasOut(m.str, want_int) or bodyHasOut(m.prefix, want_int),
        .str_contains => |m| bodyHasOut(m.str, want_int) or bodyHasOut(m.sub, want_int),
        .record_make => |rm| blk: {
            for (rm.inits) |fi| if (bodyHasOut(fi.value, want_int)) break :blk true;
            for (rm.str_inits) |si| if (bodyHasOut(si.value, want_int)) break :blk true;
            break :blk false;
        },
        .field_get => |fg| bodyHasOut(fg.base, want_int),
        .field_set => |fs| bodyHasOut(fs.base, want_int) or bodyHasOut(fs.value, want_int),
        .array_make => |am| blk: {
            for (am.inits) |iv| if (bodyHasOut(iv, want_int)) break :blk true;
            break :blk false;
        },
        .elem_ptr => |ep| bodyHasOut(ep.base, want_int) or bodyHasOut(ep.index, want_int),
        .bounds_check => |bc| bodyHasOut(bc.index, want_int) or bodyHasOut(bc.count, want_int),
        .host_exit => |he| bodyHasOut(he.code, want_int),
        .strlist_make => |inits| blk: {
            for (inits) |it| if (bodyHasOut(it, want_int)) break :blk true;
            break :blk false;
        },
        .strlist_get => |g| bodyHasOut(g.list, want_int) or bodyHasOut(g.idx, want_int),
        .host_args => false,
        .envvar_get => |eg| bodyHasOut(eg.key, want_int),
        .fs_read => |fr| bodyHasOut(fr.path, want_int),
        .kv_increment => |kv| bodyHasOut(kv.delta, want_int) or (kv.key != null and bodyHasOut(kv.key.?, want_int)),
        .kv_set => |kv| bodyHasOut(kv.key, want_int) or bodyHasOut(kv.value, want_int),
        .kv_get => |kv| bodyHasOut(kv.key, want_int),
        .blob_put => |bl| bodyHasOut(bl.key, want_int) or bodyHasOut(bl.value, want_int),
        .blob_get => |bl| bodyHasOut(bl.key, want_int),
        .blob_delete => |bl| bodyHasOut(bl.key, want_int),
        .db_execute => |db| bodyHasOut(db.sql, want_int),
        .db_query_value => |db| bodyHasOut(db.sql, want_int),
        .db_query_text => |db| bodyHasOut(db.sql, want_int),
        .db_query_one => |db| bodyHasOut(db.sql, want_int),
        .config_get => |cf| bodyHasOut(cf.key, want_int),
        .time_monotonic_ns, .time_resolution_ns, .time_unix_ns, .random_u64 => false,
        .time_sleep_ns => |ts| bodyHasOut(ts.ns, want_int),
        .chan_recv => |h| bodyHasOut(h, want_int),
        .chan_take => |h| bodyHasOut(h, want_int),
        .chan_open => false,
        .vec_new => false,
        .vec_push => |vp| bodyHasOut(vp.vec, want_int) or bodyHasOut(vp.value, want_int),
        .vec_len => |vl| bodyHasOut(vl.vec, want_int),
        .vec_ptr => |vp| bodyHasOut(vp.vec, want_int),
        .vec_get => |vg| bodyHasOut(vg.vec, want_int) or bodyHasOut(vg.idx, want_int),
        .vec_set => |vs| bodyHasOut(vs.vec, want_int) or bodyHasOut(vs.idx, want_int) or bodyHasOut(vs.value, want_int),
        .host_out_const, .const_i64, .const_i32, .const_f64, .local_get, .global_get, .str_const_val, .str_param, .str_binding, .br, .br_cont, .@"unreachable" => false,
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

/// True if any function calls `env.exit` (a `host_exit` node) — drives both the
/// `env.exit`/`proc_exit` import declaration and the component-emit decision to
/// route the qube down the preview1 → `wasi:cli/run` command path.
fn usesEnvExit(m: *const ir.mir.Module) bool {
    for (m.funcs) |f| switch (f.body) {
        .structured => |root| if (instUsesEnvExit(root)) return true,
        .cfg => {},
    };
    return false;
}

/// True if any function reaches `env.kv` (a `kv_increment` node). Reuses the
/// scratch scan that already detects `has_kv` for the import declaration.
fn usesEnvKv(m: *const ir.mir.Module) bool {
    for (m.funcs) |f| {
        const root = switch (f.body) {
            .structured => |x| x,
            .cfg => continue,
        };
        var sc = Scratch{};
        scanScratch(root, &sc);
        if (sc.has_kv) return true;
    }
    return false;
}

/// True if any function reaches `env.kv.set` (a `kv_set` node) — gates the
/// `[method]bucket.set` store import (declared only when used, so the
/// increment-only kv qube's component surface is unchanged).
fn usesKvSet(m: *const ir.mir.Module) bool {
    for (m.funcs) |f| {
        const root = switch (f.body) {
            .structured => |x| x,
            .cfg => continue,
        };
        var sc = Scratch{};
        scanScratch(root, &sc);
        if (sc.has_kv_set) return true;
    }
    return false;
}

/// True if any function reaches `env.kv.get` (a `kv_get` node) — gates the
/// `[method]bucket.get` store import.
fn usesKvGet(m: *const ir.mir.Module) bool {
    for (m.funcs) |f| {
        const root = switch (f.body) {
            .structured => |x| x,
            .cfg => continue,
        };
        var sc = Scratch{};
        scanScratch(root, &sc);
        if (sc.has_kv_get) return true;
    }
    return false;
}

/// True if any function reaches `env.blob` (any blob op) — gates the whole
/// `q64:blob/store` import block + the component (store) path.
fn usesEnvBlob(m: *const ir.mir.Module) bool {
    for (m.funcs) |f| {
        const root = switch (f.body) {
            .structured => |x| x,
            .cfg => continue,
        };
        var sc = Scratch{};
        scanScratch(root, &sc);
        if (sc.has_blob_put or sc.has_blob_get or sc.has_blob_delete) return true;
    }
    return false;
}

/// Per-op blob predicates — each gates its own `[method]bucket.*` import so a
/// qube declares exactly the object-store methods it reaches.
fn usesBlobPut(m: *const ir.mir.Module) bool {
    for (m.funcs) |f| {
        const root = switch (f.body) {
            .structured => |x| x,
            .cfg => continue,
        };
        var sc = Scratch{};
        scanScratch(root, &sc);
        if (sc.has_blob_put) return true;
    }
    return false;
}
fn usesBlobGet(m: *const ir.mir.Module) bool {
    for (m.funcs) |f| {
        const root = switch (f.body) {
            .structured => |x| x,
            .cfg => continue,
        };
        var sc = Scratch{};
        scanScratch(root, &sc);
        if (sc.has_blob_get) return true;
    }
    return false;
}
fn usesBlobDelete(m: *const ir.mir.Module) bool {
    for (m.funcs) |f| {
        const root = switch (f.body) {
            .structured => |x| x,
            .cfg => continue,
        };
        var sc = Scratch{};
        scanScratch(root, &sc);
        if (sc.has_blob_delete) return true;
    }
    return false;
}

/// True if any function reaches `env.db` (any db op) — gates the whole
/// `q64:db/sql` import block + the component (store) path.
fn usesEnvDb(m: *const ir.mir.Module) bool {
    for (m.funcs) |f| {
        const root = switch (f.body) {
            .structured => |x| x,
            .cfg => continue,
        };
        var sc = Scratch{};
        scanScratch(root, &sc);
        if (sc.has_db_execute or sc.has_db_query_value or sc.has_db_query_text or sc.has_db_query_one) return true;
    }
    return false;
}

/// True if any public function returns `str` — such a qube needs the component
/// (store) scaffolding (cm32p2 memory + `cabi_realloc`) so the `-> string`
/// export can go through the canonical-ABI return-area wrapper, even when it
/// touches no storage capability. This is what lets a pure `@http_handler`
/// (`serve(method, path, body) -> str`) emit a component.
fn usesStrExport(m: *const ir.mir.Module) bool {
    for (m.funcs) |f| {
        if (f.exported and f.ret == .str) return true;
    }
    return false;
}

/// True if any function reaches `env.config` (a `config_get` node) — gates the
/// `wasi:config/store` import + the component (store) path.
fn usesEnvConfig(m: *const ir.mir.Module) bool {
    for (m.funcs) |f| {
        const root = switch (f.body) {
            .structured => |x| x,
            .cfg => continue,
        };
        var sc = Scratch{};
        scanScratch(root, &sc);
        if (sc.has_config_get) return true;
    }
    return false;
}

/// True if any function reaches `env.time` at all — gates the component
/// (store) path + the preview1 timestamp cell.
fn usesEnvTime(m: *const ir.mir.Module) bool {
    return usesEnvTimeMono(m) or usesEnvTimeWall(m);
}

/// True if any function reaches `env.random.u64` — gates the preview1
/// `random_get` import and its 8-byte result cell.
fn usesEnvRandom(m: *const ir.mir.Module) bool {
    for (m.funcs) |f| {
        var sc = Scratch{};
        switch (f.body) {
            .structured => |inst| scanScratch(inst, &sc),
            .cfg => {},
        }
        if (sc.has_random) return true;
    }
    return false;
}

/// True if any function reaches the MONOTONIC clock (`monotonic_ns` /
/// `resolution_ns` / `sleep_ns` — the sleep subscribes on it) — gates the
/// `wasi:clocks/monotonic-clock` world import.
fn usesEnvTimeMono(m: *const ir.mir.Module) bool {
    for (m.funcs) |f| {
        const root = switch (f.body) {
            .structured => |x| x,
            .cfg => continue,
        };
        var sc = Scratch{};
        scanScratch(root, &sc);
        if (sc.has_time or sc.has_time_res or sc.has_time_sleep) return true;
    }
    return false;
}

/// True if any function reaches `env.time.sleep_ns` — gates the
/// `wasi:io/poll` world import + the poll_oneoff subscription scratch.
fn usesEnvTimeSleep(m: *const ir.mir.Module) bool {
    for (m.funcs) |f| {
        const root = switch (f.body) {
            .structured => |x| x,
            .cfg => continue,
        };
        var sc = Scratch{};
        scanScratch(root, &sc);
        if (sc.has_time_sleep) return true;
    }
    return false;
}

/// True if any function reaches the WALL clock (`unix_ns`) — gates the
/// `wasi:clocks/wall-clock` world import + the time return area.
fn usesEnvTimeWall(m: *const ir.mir.Module) bool {
    for (m.funcs) |f| {
        const root = switch (f.body) {
            .structured => |x| x,
            .cfg => continue,
        };
        var sc = Scratch{};
        scanScratch(root, &sc);
        if (sc.has_time_wall) return true;
    }
    return false;
}

/// Per-op db predicates — each gates its own `[method]connection.*` import.
fn usesDbExec(m: *const ir.mir.Module) bool {
    for (m.funcs) |f| {
        const root = switch (f.body) {
            .structured => |x| x,
            .cfg => continue,
        };
        var sc = Scratch{};
        scanScratch(root, &sc);
        if (sc.has_db_execute) return true;
    }
    return false;
}
fn usesDbQueryValue(m: *const ir.mir.Module) bool {
    for (m.funcs) |f| {
        const root = switch (f.body) {
            .structured => |x| x,
            .cfg => continue,
        };
        var sc = Scratch{};
        scanScratch(root, &sc);
        if (sc.has_db_query_value) return true;
    }
    return false;
}
fn usesDbQueryText(m: *const ir.mir.Module) bool {
    for (m.funcs) |f| {
        const root = switch (f.body) {
            .structured => |x| x,
            .cfg => continue,
        };
        var sc = Scratch{};
        scanScratch(root, &sc);
        if (sc.has_db_query_text) return true;
    }
    return false;
}
fn usesDbQueryOne(m: *const ir.mir.Module) bool {
    for (m.funcs) |f| {
        const root = switch (f.body) {
            .structured => |x| x,
            .cfg => continue,
        };
        var sc = Scratch{};
        scanScratch(root, &sc);
        if (sc.has_db_query_one) return true;
    }
    return false;
}

/// Slice B rung 3 — the async-export gate. Non-null when the module is a
/// single suspending pub fn eligible for the async lift: no entry, exactly
/// one exported i64 fn (all params/locals i64 — the memory frame is 8-byte
/// slots), at least one TOP-LEVEL sleep, no nested sleeps, no other
/// capability faces, tail-value form (no explicit `ret`). Everything the v0
/// slice can't lift falls through to the ordinary (blocking) store path.
fn asyncExportIndex(m: *const ir.mir.Module) ?usize {
    if (m.funcs.len != 1) return null;
    const f = m.funcs[0];
    if (!f.exported or f.ret != .i64) return null;
    for (f.params) |p| if (p != .i64) return null;
    for (f.locals) |l| if (l != .i64) return null;
    const root = switch (f.body) {
        .structured => |x| x,
        .cfg => return null,
    };
    const items = switch (root.op) {
        .block => |xs| xs,
        else => return null,
    };
    if (items.len == 0) return null;
    var top_sleeps: usize = 0;
    for (items) |it| {
        if (it.op == .time_sleep_ns) {
            top_sleeps += 1;
            continue;
        }
        if (it.op == .ret) return null; // tail-value form only (v0)
        var sc = Scratch{};
        scanScratch(it, &sc);
        if (sc.has_time_sleep) return null; // a suspend nested in control flow: not v0
        // Only the monotonic clock read may ride along; any other face (or
        // byte I/O) exits to the blocking path.
        if (sc.host_out or sc.has_kv or sc.has_kv_set or sc.has_kv_get or
            sc.has_blob_put or sc.has_blob_get or sc.has_blob_delete or
            sc.has_db_execute or sc.has_db_query_value or sc.has_db_query_text or sc.has_db_query_one or
            sc.has_config_get or sc.has_time_res or sc.has_time_wall or
            sc.has_fs or sc.has_args or sc.has_envvar or sc.has_vec or
            sc.has_chan or sc.has_take or sc.has_connect or sc.has_presses) return null;
    }
    if (top_sleeps == 0) return null;
    if (items[items.len - 1].ty != .i64) return null; // the tail is the value
    return 0;
}

/// Emit the async-lifted core module for the suspending export. The
/// pinned protocol (test/async-export-reference/): the body splits into
/// SEGMENTS at its top-level sleeps; a driver dispatches on a `state`
/// global inside a retry loop; each non-final segment ends by starting
/// `wait-for(ns)` as an async-lowered SUBTASK — completed-eagerly retries
/// the loop, otherwise the subtask joins the waitable-set and the driver
/// returns WAIT(set); the final segment `task.return`s the tail value and
/// EXITs. All q64 locals live in a memory frame (`frame_base + idx*8`) so
/// state survives the host's callback re-entries. LEGACY manglings
/// throughout (standard cm32p2 has no async yet).
fn emitAsyncCore(allocator: std.mem.Allocator, m: *const ir.mir.Module, fi: usize) ![]u8 {
    const f = m.funcs[fi];
    const module = c.BinaryenModuleCreate() orelse return Error.ModuleCreate;
    defer c.BinaryenModuleDispose(module);
    const i64_type = c.BinaryenTypeInt64();
    const i32_type = c.BinaryenTypeInt32();
    const none_type = c.BinaryenTypeNone();
    c.BinaryenSetMemory(module, 1, 1, "memory", null, null, null, null, null, 0, false, false, "0");

    // Imports — legacy manglings, per the pinned reference.
    c.BinaryenAddFunctionImport(module, "p3_now", clocks_p3_iface, "now", none_type, i64_type);
    c.BinaryenAddFunctionImport(module, "p3_wait_for", clocks_p3_iface, "[async-lower]wait-for", i64_type, i32_type);
    c.BinaryenAddFunctionImport(module, "ws_new", "$root", "[waitable-set-new]", none_type, i32_type);
    var jp = [_]c.BinaryenType{ i32_type, i32_type };
    c.BinaryenAddFunctionImport(module, "w_join", "$root", "[waitable-join]", c.BinaryenTypeCreate(&jp, jp.len), none_type);
    c.BinaryenAddFunctionImport(module, "subtask_drop", "$root", "[subtask-drop]", i32_type, none_type);
    const tr_name = try std.fmt.allocPrintSentinel(allocator, "[task-return]{s}", .{f.name}, 0);
    defer allocator.free(tr_name);
    c.BinaryenAddFunctionImport(module, "task_return", "[export]$root", tr_name.ptr, i64_type, none_type);

    // State that must survive re-entry: the segment index, the parked
    // subtask, the (lazily created) waitable-set.
    _ = c.BinaryenAddGlobal(module, "state", i32_type, true, c.BinaryenConst(module, c.BinaryenLiteralInt32(0)));
    _ = c.BinaryenAddGlobal(module, "subtask", i32_type, true, c.BinaryenConst(module, c.BinaryenLiteralInt32(0)));
    _ = c.BinaryenAddGlobal(module, "ws", i32_type, true, c.BinaryenConst(module, c.BinaryenLiteralInt32(-1)));

    // Split the body into segments at the top-level sleeps.
    const root_items = f.body.structured.op.block;
    const Seg = struct { items: []const *ir.mir.Inst, sleep: ?*ir.mir.Inst };
    var segs: std.ArrayList(Seg) = .empty;
    defer segs.deinit(allocator);
    var start: usize = 0;
    for (root_items, 0..) |it, i| {
        if (it.op == .time_sleep_ns) {
            try segs.append(allocator, .{ .items = root_items[start..i], .sleep = it.op.time_sleep_ns.ns });
            start = i + 1;
        }
    }
    try segs.append(allocator, .{ .items = root_items[start..], .sleep = null });

    var host_imports: std.StringHashMapUnmanaged([*:0]const u8) = .empty;
    defer host_imports.deinit(allocator);
    var foreign_imports: std.StringHashMapUnmanaged([*:0]const u8) = .empty;
    defer foreign_imports.deinit(allocator);
    var lw = Lowerer{
        .allocator = allocator,
        .module = module,
        .funcs = m.funcs,
        .i64_type = i64_type,
        .i32_type = i32_type,
        .ptr_type = i32_type,
        .none_type = none_type,
        .pair_type = none_type, // unused: the gate admits i64-only bodies
        .pair_idx = 0,
        .host_imports = &host_imports,
        .foreign_imports = &foreign_imports,
        .global_names = &.{},
        .frame_base = 0, // locals at memory 0.. (params first, then locals)
        .time_p3 = true,
    };
    defer lw.deinit();

    const i32c = struct {
        fn v(mod: c.BinaryenModuleRef, x: i32) c.BinaryenExpressionRef {
            return c.BinaryenConst(mod, c.BinaryenLiteralInt32(x));
        }
    }.v;

    // The driver: dispatch on `state` in a retry loop. Every arm terminates
    // (br to retry, or return), so the trailing unreachable never runs.
    var arms: std.ArrayList(c.BinaryenExpressionRef) = .empty;
    defer arms.deinit(allocator);
    for (segs.items, 0..) |seg, k| {
        var body: std.ArrayList(c.BinaryenExpressionRef) = .empty;
        defer body.deinit(allocator);
        const is_last = (k == segs.items.len - 1);
        const stmt_count = if (is_last) seg.items.len - 1 else seg.items.len;
        for (seg.items[0..stmt_count]) |it| {
            const e = try lw.inst(it);
            body.append(allocator, if (it.ty == .void) e else c.BinaryenDrop(module, e)) catch return Error.OutOfMemory;
        }
        if (seg.sleep) |ns_inst| {
            // st = wait-for(ns); state = k+1;
            // eager RETURNED (2) → retry the dispatch loop;
            // else park: subtask = st>>4; ws ||= new; join; return WAIT|ws<<4.
            var wf_args = [_]c.BinaryenExpressionRef{try lw.inst(ns_inst)};
            try body.append(allocator, c.BinaryenLocalSet(module, 0, c.BinaryenCall(module, "p3_wait_for", @ptrCast(&wf_args), wf_args.len, i32_type)));
            try body.append(allocator, c.BinaryenGlobalSet(module, "state", i32c(module, @intCast(k + 1))));
            try body.append(allocator, c.BinaryenIf(
                module,
                c.BinaryenBinary(module, c.BinaryenEqInt32(), c.BinaryenBinary(module, c.BinaryenAndInt32(), c.BinaryenLocalGet(module, 0, i32_type), i32c(module, 0xf)), i32c(module, 2)),
                c.BinaryenBreak(module, "again", null, null),
                null,
            ));
            try body.append(allocator, c.BinaryenGlobalSet(module, "subtask", c.BinaryenBinary(module, c.BinaryenShrUInt32(), c.BinaryenLocalGet(module, 0, i32_type), i32c(module, 4))));
            try body.append(allocator, c.BinaryenIf(
                module,
                c.BinaryenBinary(module, c.BinaryenLtSInt32(), c.BinaryenGlobalGet(module, "ws", i32_type), i32c(module, 0)),
                c.BinaryenGlobalSet(module, "ws", c.BinaryenCall(module, "ws_new", null, 0, i32_type)),
                null,
            ));
            var join_args = [_]c.BinaryenExpressionRef{ c.BinaryenGlobalGet(module, "subtask", i32_type), c.BinaryenGlobalGet(module, "ws", i32_type) };
            try body.append(allocator, c.BinaryenCall(module, "w_join", @ptrCast(&join_args), join_args.len, none_type));
            try body.append(allocator, c.BinaryenReturn(module, c.BinaryenBinary(module, c.BinaryenOrInt32(), i32c(module, 2), c.BinaryenBinary(module, c.BinaryenShlInt32(), c.BinaryenGlobalGet(module, "ws", i32_type), i32c(module, 4)))));
        } else {
            // The final segment: deliver the tail value, EXIT.
            var tr_args = [_]c.BinaryenExpressionRef{try lw.inst(seg.items[seg.items.len - 1])};
            try body.append(allocator, c.BinaryenCall(module, "task_return", @ptrCast(&tr_args), tr_args.len, none_type));
            try body.append(allocator, c.BinaryenReturn(module, i32c(module, 0)));
        }
        const arm_body = c.BinaryenBlock(module, null, @ptrCast(body.items.ptr), @intCast(body.items.len), c.BinaryenTypeAuto());
        try arms.append(allocator, c.BinaryenIf(
            module,
            c.BinaryenBinary(module, c.BinaryenEqInt32(), c.BinaryenGlobalGet(module, "state", i32_type), i32c(module, @intCast(k))),
            arm_body,
            null,
        ));
    }
    try arms.append(allocator, c.BinaryenUnreachable(module));
    const dispatch = c.BinaryenBlock(module, null, @ptrCast(arms.items.ptr), @intCast(arms.items.len), c.BinaryenTypeAuto());
    const drive_body = c.BinaryenLoop(module, "again", dispatch);
    var drive_vars = [_]c.BinaryenType{i32_type}; // local 0: the packed wait-for status
    _ = c.BinaryenAddFunction(module, "drive", none_type, i32_type, @ptrCast(&drive_vars), drive_vars.len, drive_body);

    // The lift: spill params into the frame, reset the re-entry state, drive.
    {
        var items: std.ArrayList(c.BinaryenExpressionRef) = .empty;
        defer items.deinit(allocator);
        for (0..f.params.len) |pi| {
            try items.append(allocator, c.BinaryenStore(module, 8, @intCast(pi * 8), 0, i32c(module, 0), c.BinaryenLocalGet(module, @intCast(pi), i64_type), i64_type, "0"));
        }
        try items.append(allocator, c.BinaryenGlobalSet(module, "state", i32c(module, 0)));
        try items.append(allocator, c.BinaryenGlobalSet(module, "ws", i32c(module, -1)));
        try items.append(allocator, c.BinaryenReturn(module, c.BinaryenCall(module, "drive", null, 0, i32_type)));
        const lift_body = c.BinaryenBlock(module, null, @ptrCast(items.items.ptr), @intCast(items.items.len), c.BinaryenTypeAuto());
        const ptypes = try allocator.alloc(c.BinaryenType, f.params.len);
        defer allocator.free(ptypes);
        for (ptypes) |*t| t.* = i64_type;
        const ptype = if (f.params.len > 0) c.BinaryenTypeCreate(ptypes.ptr, @intCast(ptypes.len)) else none_type;
        _ = c.BinaryenAddFunction(module, "lift", ptype, i32_type, null, 0, lift_body);
        const lift_export = try std.fmt.allocPrintSentinel(allocator, "[async-lift]{s}", .{f.name}, 0);
        defer allocator.free(lift_export);
        _ = c.BinaryenAddFunctionExport(module, "lift", lift_export.ptr);
    }

    // The callback: the parked subtask completed — drop it, drive on.
    {
        var items: std.ArrayList(c.BinaryenExpressionRef) = .empty;
        defer items.deinit(allocator);
        var drop_args = [_]c.BinaryenExpressionRef{c.BinaryenGlobalGet(module, "subtask", i32_type)};
        try items.append(allocator, c.BinaryenCall(module, "subtask_drop", @ptrCast(&drop_args), drop_args.len, none_type));
        try items.append(allocator, c.BinaryenReturn(module, c.BinaryenCall(module, "drive", null, 0, i32_type)));
        const cb_body = c.BinaryenBlock(module, null, @ptrCast(items.items.ptr), @intCast(items.items.len), c.BinaryenTypeAuto());
        var cbp = [_]c.BinaryenType{ i32_type, i32_type, i32_type };
        _ = c.BinaryenAddFunction(module, "callback", c.BinaryenTypeCreate(&cbp, cbp.len), i32_type, null, 0, cb_body);
        const cb_export = try std.fmt.allocPrintSentinel(allocator, "[callback][async-lift]{s}", .{f.name}, 0);
        defer allocator.free(cb_export);
        _ = c.BinaryenAddFunctionExport(module, "callback", cb_export.ptr);
    }

    if (!c.BinaryenModuleValidate(module)) return Error.ModuleInvalid;
    const result = c.BinaryenModuleAllocateAndWrite(module, null);
    defer if (result.binary) |bin| std.c.free(bin);
    defer if (result.sourceMap) |s| std.c.free(s);
    const binary_ptr = result.binary orelse return Error.ModuleInvalid;
    if (result.binaryBytes == 0) return Error.ModuleInvalid;
    const src: [*]const u8 = @ptrCast(binary_ptr);
    const out = try allocator.alloc(u8, result.binaryBytes);
    @memcpy(out, src[0..result.binaryBytes]);
    return out;
}

/// The synthesized world for an async-lifted export: the p3 clock import +
/// the one `async func` export. Caller owns the slice.
fn synthAsyncWorld(allocator: std.mem.Allocator, hmod: *const ir.hir.Module) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "// synthesized WIT world (async-lifted export — Slice B rung 3)\n");
    try out.appendSlice(allocator, "package q64:qube;\n\nworld qube {\n");
    try out.print(allocator, "  import {s};\n", .{clocks_p3_iface});
    for (hmod.funcs) |f| {
        if (f.visibility != .public) continue;
        try out.appendSlice(allocator, "  export ");
        try appendKebab(allocator, &out, f.name);
        try out.appendSlice(allocator, ": async func(");
        for (f.params, 0..) |p, i| {
            if (i > 0) try out.appendSlice(allocator, ", ");
            try appendKebab(allocator, &out, p.name);
            try out.appendSlice(allocator, ": ");
            try out.appendSlice(allocator, witType(p.ty));
        }
        try out.appendSlice(allocator, ")");
        if (f.ret != .void) try out.print(allocator, " -> {s}", .{witType(f.ret)});
        try out.appendSlice(allocator, ";\n");
    }
    try out.appendSlice(allocator, "}\n");
    return out.toOwnedSlice(allocator);
}

/// Synthesize the WIT world for a kv qube: it imports `wasi:keyvalue/store` +
/// `wasi:keyvalue/atomics` (the `env.kv` lowering) and exports each scalar `pub`
/// function. Named `qube` (the fixed world name the CLI passes to `component
/// embed --world`). Caller owns the slice.
fn synthStoreWorld(allocator: std.mem.Allocator, hmod: *const ir.hir.Module, use_kv: bool, use_blob: bool, use_db: bool, use_config: bool, use_time_mono: bool, use_time_wall: bool, use_time_sleep: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "// synthesized WIT world (q64 storage capabilities → host interfaces)\n");
    try out.appendSlice(allocator, "package q64:qube;\n\nworld qube {\n");
    if (use_kv) {
        try out.print(allocator, "  import {s};\n", .{kv_store_iface});
        try out.print(allocator, "  import {s};\n", .{kv_atomics_iface});
    }
    if (use_blob) {
        try out.print(allocator, "  import {s};\n", .{blob_store_iface});
    }
    if (use_db) {
        try out.print(allocator, "  import {s};\n", .{db_sql_iface});
    }
    if (use_config) {
        try out.print(allocator, "  import {s};\n", .{config_store_iface});
    }
    if (use_time_mono) {
        try out.print(allocator, "  import {s};\n", .{clocks_monotonic_iface});
    }
    if (use_time_wall) {
        try out.print(allocator, "  import {s};\n", .{clocks_wall_iface});
    }
    if (use_time_sleep) {
        // The blocking sleep chain crosses two interfaces: the subscription
        // lives on monotonic-clock (already imported via use_time_mono), the
        // pollable it returns on wasi:io/poll.
        try out.print(allocator, "  import {s};\n", .{io_poll_iface});
    }
    for (hmod.funcs) |f| {
        if (f.visibility != .public) continue;
        // A param/return is exportable if it's a component scalar OR a `str`
        // (lifted to `string`): scalars pass through directly; a `str` return
        // goes through the canonical-ABI return-area wrapper (see
        // `emitStrExportWrapper`). This is what lets an `@http_handler` function
        // — `serve(method: str, path: str, body: str) -> str` — export.
        const exportable = struct {
            fn f2(t: ir.hir.Type) bool {
                return t == .str or component.Scalar.fromHir(t) != null;
            }
        }.f2;
        var ok = true;
        for (f.params) |p| {
            if (!exportable(p.ty)) ok = false;
        }
        if (f.ret != .void and !exportable(f.ret)) ok = false;
        if (!ok) continue;
        try out.appendSlice(allocator, "  export ");
        try appendKebab(allocator, &out, f.name);
        try out.appendSlice(allocator, ": func(");
        for (f.params, 0..) |p, pi| {
            if (pi > 0) try out.appendSlice(allocator, ", ");
            try appendKebab(allocator, &out, p.name);
            try out.appendSlice(allocator, ": ");
            try out.appendSlice(allocator, witType(p.ty));
        }
        try out.appendSlice(allocator, ")");
        if (f.ret != .void) try out.print(allocator, " -> {s}", .{witType(f.ret)});
        try out.appendSlice(allocator, ";\n");
    }
    try out.appendSlice(allocator, "}\n");
    return out.toOwnedSlice(allocator);
}

fn instUsesEnvOut(inst: *const ir.mir.Inst) bool {
    switch (inst.op) {
        .host_out_const, .host_out_int, .host_out_str, .host_out_float => return true,
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

fn instUsesEnvExit(inst: *const ir.mir.Inst) bool {
    switch (inst.op) {
        .host_exit => return true,
        .block => |items| for (items) |ch| {
            if (instUsesEnvExit(ch)) return true;
        },
        .if_ => |iff| return instUsesEnvExit(iff.cond) or instUsesEnvExit(iff.then_) or
            (iff.else_ != null and instUsesEnvExit(iff.else_.?)),
        .while_ => |w| return instUsesEnvExit(w.cond) or instUsesEnvExit(w.body),
        .loop => |body| return instUsesEnvExit(body),
        .local_set => |ls| return instUsesEnvExit(ls.value),
        .ret => |v| if (v) |val| return instUsesEnvExit(val),
        else => {},
    }
    return false;
}

/// True if any function performs a host byte-write to `stream` (a `host_out*`
/// node tagged with it). Drives the per-stream raw-face import declaration so an
/// `env.err`-only (or `env.out`-only) module imports exactly the face it calls.
fn usesHostStream(m: *const ir.mir.Module, stream: ir.mir.Stream) bool {
    for (m.funcs) |f| switch (f.body) {
        .structured => |root| if (instUsesHostStream(root, stream)) return true,
        .cfg => {},
    };
    return false;
}

fn instUsesHostStream(inst: *const ir.mir.Inst, stream: ir.mir.Stream) bool {
    switch (inst.op) {
        .host_out_const => |hc| return hc.stream == stream,
        .host_out_int => |hi| return hi.stream == stream or instUsesHostStream(hi.value, stream),
        .host_out_float => |hf| return hf.stream == stream or instUsesHostStream(hf.value, stream),
        .host_out_str => |hs| return hs.stream == stream or instUsesHostStream(hs.value, stream),
        .str_concat => |pieces| for (pieces) |p| {
            if (instUsesHostStream(p, stream)) return true;
        },
        .fmt_int_to_str => |inner| return instUsesHostStream(inner, stream),
        .block => |items| for (items) |ch| {
            if (instUsesHostStream(ch, stream)) return true;
        },
        .local_set => |ls| return instUsesHostStream(ls.value, stream),
        .bin => |b| return instUsesHostStream(b.lhs, stream) or instUsesHostStream(b.rhs, stream),
        .un => |u| return instUsesHostStream(u.operand, stream),
        .call => |cl| for (cl.args) |a| {
            if (instUsesHostStream(a, stream)) return true;
        },
        .ret => |v| if (v) |val| return instUsesHostStream(val, stream),
        .if_ => |iff| return instUsesHostStream(iff.cond, stream) or instUsesHostStream(iff.then_, stream) or
            (iff.else_ != null and instUsesHostStream(iff.else_.?, stream)),
        .while_ => |w| return instUsesHostStream(w.cond, stream) or instUsesHostStream(w.body, stream),
        .loop => |body| return instUsesHostStream(body, stream),
        .host_call => |hc| for (hc.args) |a| {
            if (instUsesHostStream(a, stream)) return true;
        },
        .global_set => |gs| return instUsesHostStream(gs.value, stream),
        .str_bind => |sb| return instUsesHostStream(sb.value, stream),
        else => {},
    }
    return false;
}

const Scratch = struct {
    host_out: bool = false,
    has_concat: bool = false,
    max_tuples: u32 = 0,
    has_str_eq: bool = false,
    has_index_of: bool = false,
    has_starts_with: bool = false,
    has_contains: bool = false,
    /// Max nesting depth of `record_make` (a record literal inside another's
    /// field value, via a call argument): each level needs its own base-ptr
    /// scratch local so an inner alloc can't clobber the outer's base.
    rec_depth: u32 = 0,
    /// Formats an f64 (host_out_float / fmt_float_to_str) → needs the
    /// `__fmt_f64` helper + the arena.
    has_float_fmt: bool = false,
    /// Contains a bounds_check → needs the i64 index scratch local.
    has_bounds: bool = false,
    /// Contains an `env.fs.read` → declare the import + fs scratch.
    has_fs: bool = false,
    /// Contains an `env.args` → declare the `env.args` import + allow the host
    /// to grow guest memory for the materialized args.
    has_args: bool = false,
    /// Contains an `env.envvars.get` → declare the `env.envvar` import + use the
    /// fs dest/len scratch + allow memory growth (the value rides the arena).
    has_envvar: bool = false,
    /// Contains an `env.kv.increment` → declare the `env.kv_increment` import.
    has_kv: bool = false,
    /// Contains an `env.kv.set` → declare the `[method]bucket.set` store import.
    has_kv_set: bool = false,
    /// Contains an `env.kv.get` → declare the `[method]bucket.get` store import.
    has_kv_get: bool = false,
    /// Contains an `env.blob.{put,get,delete}` → declare the matching
    /// `q64:blob/store` bucket method import (only when reached).
    has_blob_put: bool = false,
    has_blob_get: bool = false,
    has_blob_delete: bool = false,
    /// Contains an `env.db.{execute,query_value,query_text,query_one}` → declare
    /// the matching `q64:db/sql` connection method import (only when reached).
    has_db_execute: bool = false,
    has_db_query_value: bool = false,
    has_db_query_text: bool = false,
    has_db_query_one: bool = false,
    /// Contains an `env.config.get` → declare the `wasi:config/store.get` import.
    has_config_get: bool = false,
    /// Contains an `env.time.monotonic_ns` → declare the clock import (the
    /// canonical `wasi:clocks` one in component mode, the raw `env.monotonic_ns`
    /// face locally). Scalar-only: needs neither the pair scratch nor the arena.
    has_time: bool = false,
    has_random: bool = false,
    /// Contains an `env.time.resolution_ns` → declare monotonic-clock.resolution
    /// (component) / clock_res_get (preview1) / env.resolution_ns (local).
    has_time_res: bool = false,
    /// Contains an `env.time.unix_ns` → declare wall-clock.now (component,
    /// via the small time return area) / clock_time_get with the realtime
    /// clockid (preview1) / env.unix_ns (local).
    has_time_wall: bool = false,
    /// Contains an `env.time.sleep_ns` → declare the blocking chain:
    /// subscribe-duration + pollable.block + resource-drop (component) /
    /// poll_oneoff + its 88-byte subscription scratch (preview1) /
    /// env.sleep_ns (local).
    has_time_sleep: bool = false,
    /// Contains a `chan_recv` → declare the `env.channel_recv` import.
    has_chan: bool = false,
    /// Contains a `chan_take` → declare the `env.channel_take` import.
    has_take: bool = false,
    /// Contains a `chan_open("channel_connect")` → declare `env.channel_connect`.
    has_connect: bool = false,
    /// Contains a `chan_open("presses")` → declare the `env.presses` import.
    has_presses: bool = false,
    /// Contains a Vec op → emit the __vec_* helpers (+ the arena).
    has_vec: bool = false,
    /// Max nesting depth of frame-reclamation regions (a `.call` or a host
    /// statement — spec/memory.md §"Frame reclamation"): each level needs
    /// its own watermark + result-stash scratch group, since a nested call
    /// in an argument saves its watermark while the outer's is live.
    region_depth: u32 = 0,
};

fn mergeScratch(s: *Scratch, sub: *const Scratch) void {
    s.host_out = s.host_out or sub.host_out;
    s.has_concat = s.has_concat or sub.has_concat;
    if (sub.max_tuples > s.max_tuples) s.max_tuples = sub.max_tuples;
    s.has_str_eq = s.has_str_eq or sub.has_str_eq;
    s.has_index_of = s.has_index_of or sub.has_index_of;
    s.has_starts_with = s.has_starts_with or sub.has_starts_with;
    s.has_contains = s.has_contains or sub.has_contains;
    s.has_float_fmt = s.has_float_fmt or sub.has_float_fmt;
    s.has_bounds = s.has_bounds or sub.has_bounds;
    s.has_vec = s.has_vec or sub.has_vec;
    s.has_fs = s.has_fs or sub.has_fs;
    s.has_args = s.has_args or sub.has_args;
    s.has_envvar = s.has_envvar or sub.has_envvar;
    s.has_kv = s.has_kv or sub.has_kv;
    s.has_kv_set = s.has_kv_set or sub.has_kv_set;
    s.has_kv_get = s.has_kv_get or sub.has_kv_get;
    s.has_blob_put = s.has_blob_put or sub.has_blob_put;
    s.has_blob_get = s.has_blob_get or sub.has_blob_get;
    s.has_blob_delete = s.has_blob_delete or sub.has_blob_delete;
    s.has_db_execute = s.has_db_execute or sub.has_db_execute;
    s.has_db_query_value = s.has_db_query_value or sub.has_db_query_value;
    s.has_db_query_text = s.has_db_query_text or sub.has_db_query_text;
    s.has_db_query_one = s.has_db_query_one or sub.has_db_query_one;
    s.has_config_get = s.has_config_get or sub.has_config_get;
    s.has_time = s.has_time or sub.has_time;
    s.has_random = s.has_random or sub.has_random;
    s.has_time_res = s.has_time_res or sub.has_time_res;
    s.has_time_wall = s.has_time_wall or sub.has_time_wall;
    s.has_time_sleep = s.has_time_sleep or sub.has_time_sleep;
    s.has_chan = s.has_chan or sub.has_chan;
    s.has_take = s.has_take or sub.has_take;
    s.has_connect = s.has_connect or sub.has_connect;
    s.has_presses = s.has_presses or sub.has_presses;
    if (sub.rec_depth > s.rec_depth) s.rec_depth = sub.rec_depth;
    if (sub.region_depth > s.region_depth) s.region_depth = sub.region_depth;
}

/// Fold one reclamation-wrapped child (a call's argument, a host
/// statement's value): the wrap occupies one region level around
/// whatever the child needs.
fn scanRegionChild(s: *Scratch, child: *const ir.mir.Inst) void {
    var sub = Scratch{};
    scanScratch(child, &sub);
    mergeScratch(s, &sub);
    if (1 + sub.region_depth > s.region_depth) s.region_depth = 1 + sub.region_depth;
}

fn scanScratch(inst: *const ir.mir.Inst, s: *Scratch) void {
    switch (inst.op) {
        .record_make => |rm| {
            // Depth = 1 + the deepest record_make inside a field value (an
            // inner literal evaluates while the outer's base is live).
            var inner: u32 = 0;
            for (rm.inits) |fi| {
                var sub = Scratch{};
                scanScratch(fi.value, &sub);
                if (sub.rec_depth > inner) inner = sub.rec_depth;
                mergeScratch(s, &sub);
            }
            for (rm.str_inits) |si| {
                s.host_out = true; // pair scratch for the (ptr, len) split
                var sub = Scratch{};
                scanScratch(si.value, &sub);
                if (sub.rec_depth > inner) inner = sub.rec_depth;
                mergeScratch(s, &sub);
            }
            if (inner + 1 > s.rec_depth) s.rec_depth = inner + 1;
        },
        .array_make => |am| {
            // An array literal holds its base live while element inits
            // (possibly record literals) evaluate — same depth discipline.
            var inner: u32 = 0;
            for (am.inits) |iv| {
                var sub = Scratch{};
                scanScratch(iv, &sub);
                if (sub.rec_depth > inner) inner = sub.rec_depth;
                mergeScratch(s, &sub);
            }
            if (inner + 1 > s.rec_depth) s.rec_depth = inner + 1;
        },
        .elem_ptr => |ep| {
            scanScratch(ep.base, s);
            scanScratch(ep.index, s);
        },
        .bounds_check => |bc| {
            s.has_bounds = true;
            scanScratch(bc.index, s);
            scanScratch(bc.count, s);
        },
        .field_get => |fg| scanScratch(fg.base, s),
        .field_set => |fs| {
            scanScratch(fs.base, s);
            scanScratch(fs.value, s);
        },
        .str_concat => |pieces| {
            s.has_concat = true;
            // A `call`, `fmt_int_to_str`, or `fmt_float_to_str` piece each
            // return a (ptr, len) tuple needing one tuple slot at the site.
            var tuples: u32 = 0;
            for (pieces) |p| {
                if (p.op == .call or p.op == .fmt_int_to_str or p.op == .fmt_float_to_str) tuples += 1;
                scanScratch(p, s);
            }
            if (tuples > s.max_tuples) s.max_tuples = tuples;
        },
        .fmt_int_to_str => |inner| scanScratch(inner, s),
        .fmt_float_to_str => |inner| {
            s.has_float_fmt = true;
            scanScratch(inner, s);
        },
        .num_cast => |src| scanScratch(src, s),
        .bitcast => |src| scanScratch(src, s),
        .host_out_float => |h| {
            s.host_out = true; // pair scratch for the (ptr, len) split
            s.has_float_fmt = true;
            scanRegionChild(s, h.value);
        },
        .host_out_int => |h| {
            s.host_out = true;
            scanRegionChild(s, h.value);
        },
        .host_out_str => |h| {
            s.host_out = true;
            scanRegionChild(s, h.value);
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
        .simd_splat => |sp| scanScratch(sp.operand, s),
        .simd_extract => |se| scanScratch(se.vec, s),
        .simd_bin => |sb2| {
            scanScratch(sb2.lhs, s);
            scanScratch(sb2.rhs, s);
        },
        .simd_un => |su| scanScratch(su.operand, s),
        .simd_load => |sl| {
            s.has_bounds = true; // inline group bounds check uses bounds_idx
            scanScratch(sl.vec, s);
            scanScratch(sl.idx, s);
        },
        .simd_store => |ss| {
            s.has_bounds = true;
            scanScratch(ss.vec, s);
            scanScratch(ss.idx, s);
            scanScratch(ss.value, s);
        },
        .simd_replace => |sr| {
            scanScratch(sr.vec, s);
            scanScratch(sr.value, s);
        },
        .simd_fma => |sf| {
            scanScratch(sf.a, s);
            scanScratch(sf.b, s);
            scanScratch(sf.c, s);
        },
        .call => |cl| {
            // The call wraps in a reclamation region around its args.
            var sub = Scratch{};
            for (cl.args) |a| scanScratch(a, &sub);
            mergeScratch(s, &sub);
            if (1 + sub.region_depth > s.region_depth) s.region_depth = 1 + sub.region_depth;
        },
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
        .host_call => |hc| {
            var sub = Scratch{};
            for (hc.args) |a| scanScratch(a, &sub);
            mergeScratch(s, &sub);
            if (1 + sub.region_depth > s.region_depth) s.region_depth = 1 + sub.region_depth;
        },
        .foreign_call => |fc| {
            // Like a call: wraps its args in a reclamation region.
            var sub = Scratch{};
            for (fc.args) |a| scanScratch(a, &sub);
            mergeScratch(s, &sub);
            if (1 + sub.region_depth > s.region_depth) s.region_depth = 1 + sub.region_depth;
        },
        .global_set => |gs| scanScratch(gs.value, s),
        .str_len => |inner| scanScratch(inner, s),
        .str_index => |si| {
            scanScratch(si.str, s);
            scanScratch(si.idx, s);
        },
        .str_eq => |se| {
            s.has_str_eq = true;
            scanScratch(se.lhs, s);
            scanScratch(se.rhs, s);
        },
        .str_slice => |sl| {
            scanScratch(sl.str, s);
            scanScratch(sl.start, s);
            scanScratch(sl.end, s);
        },
        .str_index_of => |m| {
            s.has_index_of = true;
            scanScratch(m.str, s);
            scanScratch(m.byte, s);
        },
        .str_starts_with => |m| {
            s.has_starts_with = true;
            scanScratch(m.str, s);
            scanScratch(m.prefix, s);
        },
        .str_contains => |m| {
            s.has_contains = true;
            scanScratch(m.str, s);
            scanScratch(m.sub, s);
        },
        .fs_read => |fr| {
            s.has_fs = true;
            s.host_out = true; // uses the pair scratch to split the path
            scanScratch(fr.path, s);
        },
        .kv_increment => |kv| {
            s.has_kv = true;
            if (kv.key) |k| {
                s.host_out = true; // the str key rides the pair scratch (ptr,len)
                scanScratch(k, s);
            }
            scanScratch(kv.delta, s);
        },
        .kv_set => |kv| {
            s.has_kv = true; // shares the lazy `store.open` + return-area scratch
            s.has_kv_set = true;
            s.host_out = true; // key + value ride the pair scratch (ptr,len)
            scanScratch(kv.key, s);
            scanScratch(kv.value, s);
        },
        .kv_get => |kv| {
            s.has_kv = true;
            s.has_kv_get = true;
            s.host_out = true; // key rides the pair scratch (ptr,len)
            scanScratch(kv.key, s);
        },
        .blob_put => |bl| {
            s.has_blob_put = true;
            s.host_out = true; // key + value ride the pair scratch (ptr,len)
            scanScratch(bl.key, s);
            scanScratch(bl.value, s);
        },
        .blob_get => |bl| {
            s.has_blob_get = true;
            s.host_out = true;
            scanScratch(bl.key, s);
        },
        .blob_delete => |bl| {
            s.has_blob_delete = true;
            s.host_out = true;
            scanScratch(bl.key, s);
        },
        .db_execute => |db| {
            s.has_db_execute = true;
            s.host_out = true; // sql str rides the pair scratch (ptr,len)
            scanScratch(db.sql, s);
        },
        .db_query_value => |db| {
            s.has_db_query_value = true;
            s.host_out = true;
            scanScratch(db.sql, s);
        },
        .db_query_text => |db| {
            s.has_db_query_text = true;
            s.host_out = true;
            scanScratch(db.sql, s);
        },
        .db_query_one => |db| {
            s.has_db_query_one = true;
            s.host_out = true;
            scanScratch(db.sql, s);
        },
        .config_get => |cf| {
            s.has_config_get = true;
            s.host_out = true; // key rides the pair scratch (ptr,len)
            scanScratch(cf.key, s);
        },
        .time_monotonic_ns => s.has_time = true,
        .random_u64 => s.has_random = true,
        .time_resolution_ns => s.has_time_res = true,
        .time_unix_ns => s.has_time_wall = true,
        .time_sleep_ns => |ts| {
            s.has_time_sleep = true;
            scanScratch(ts.ns, s);
        },
        .chan_recv => |h| {
            s.has_chan = true;
            scanScratch(h, s);
        },
        .chan_take => |h| {
            s.has_take = true;
            scanScratch(h, s);
        },
        .chan_open => |name| {
            if (std.mem.eql(u8, name, "presses")) s.has_presses = true else s.has_connect = true;
        },
        .vec_new => s.has_vec = true,
        .vec_push => |vp| {
            s.has_vec = true;
            scanScratch(vp.vec, s);
            scanScratch(vp.value, s);
        },
        .vec_len => |vl| {
            s.has_vec = true;
            scanScratch(vl.vec, s);
        },
        .vec_ptr => |vp| {
            s.has_vec = true;
            scanScratch(vp.vec, s);
        },
        .vec_get => |vg| {
            s.has_vec = true;
            scanScratch(vg.vec, s);
            scanScratch(vg.idx, s);
        },
        .vec_set => |vs| {
            s.has_vec = true;
            scanScratch(vs.vec, s);
            scanScratch(vs.idx, s);
            scanScratch(vs.value, s);
        },
        .host_exit => |he| scanScratch(he.code, s),
        .strlist_make => |inits| {
            // Like array_make: a base-ptr scratch (rec level) holds the block
            // while elements evaluate; the pair scratch splits each element.
            s.host_out = true;
            var inner: u32 = 0;
            for (inits) |it| {
                var sub = Scratch{};
                scanScratch(it, &sub);
                if (sub.rec_depth > inner) inner = sub.rec_depth;
                mergeScratch(s, &sub);
            }
            if (inner + 1 > s.rec_depth) s.rec_depth = inner + 1;
        },
        .strlist_get => |g| {
            s.host_out = true; // the list pair rides the pair scratch
            s.has_bounds = true; // the index rides the bounds scratch
            scanScratch(g.list, s);
            scanScratch(g.idx, s);
        },
        .host_args => {
            s.has_args = true; // declare the import + allow memory growth
            if (s.rec_depth < 1) s.rec_depth = 1; // a base-ptr scratch for `dest`
        },
        .envvar_get => |eg| {
            s.has_envvar = true; // import + fs-style dest/len scratch + growth
            s.host_out = true; // the key str rides the pair scratch
            scanScratch(eg.key, s);
        },
        .host_out_const, .const_i64, .const_i32, .const_f64, .local_get, .global_get, .str_const_val, .str_param, .str_binding, .br, .br_cont, .@"unreachable" => {},
    }
}

/// Collect distinct host-face call names (e.g. `qview.text`) and their arity, so
/// `lowerToWasm` can declare one wasm import per face. Host calls appear only at
/// statement positions; their i64 args never contain another host call.
// Collect each distinct host-import name → a representative argument list, so
// the import can be declared with the right per-arg wasm types (a `str` arg is
// two address-width params; any other is one i64). Call sites of the same
// import are assumed to share a signature (the last seen wins).
fn scanHostCalls(inst: *const ir.mir.Inst, out: *std.StringHashMapUnmanaged([]const *ir.mir.Inst), a: std.mem.Allocator) Error!void {
    switch (inst.op) {
        .block => |items| for (items) |ch| try scanHostCalls(ch, out, a),
        .if_ => |iff| {
            try scanHostCalls(iff.then_, out, a);
            if (iff.else_) |e| try scanHostCalls(e, out, a);
        },
        .while_ => |w| try scanHostCalls(w.body, out, a),
        .loop => |body| try scanHostCalls(body, out, a),
        .host_call => |hc| try out.put(a, hc.name, hc.args),
        else => {},
    }
}

/// Collect distinct foreign WIT imports (`<module>.<field>`) keyed by
/// `"<module>\x00<field>"`, each mapped to a representative call inst (so the
/// import can be declared with the right scalar param types and result type).
/// A foreign call's args may themselves contain nested foreign calls, so recurse
/// into them. Two sites of the same import are assumed to share a signature.
fn scanForeignCalls(inst: *const ir.mir.Inst, out: *std.StringHashMapUnmanaged(*const ir.mir.Inst), a: std.mem.Allocator) Error!void {
    switch (inst.op) {
        .block => |items| for (items) |ch| try scanForeignCalls(ch, out, a),
        .if_ => |iff| {
            try scanForeignCalls(iff.cond, out, a);
            try scanForeignCalls(iff.then_, out, a);
            if (iff.else_) |e| try scanForeignCalls(e, out, a);
        },
        .while_ => |w| {
            try scanForeignCalls(w.cond, out, a);
            try scanForeignCalls(w.body, out, a);
        },
        .loop => |body| try scanForeignCalls(body, out, a),
        .local_set => |ls| try scanForeignCalls(ls.value, out, a),
        .global_set => |gs| try scanForeignCalls(gs.value, out, a),
        .ret => |v| if (v) |val| try scanForeignCalls(val, out, a),
        .bin => |b| {
            try scanForeignCalls(b.lhs, out, a);
            try scanForeignCalls(b.rhs, out, a);
        },
        .un => |u| try scanForeignCalls(u.operand, out, a),
        .num_cast, .bitcast => |src| try scanForeignCalls(src, out, a),
        .call => |cl| for (cl.args) |arg| try scanForeignCalls(arg, out, a),
        .host_call => |hc| for (hc.args) |arg| try scanForeignCalls(arg, out, a),
        .foreign_call => |fc| {
            const key = try std.fmt.allocPrint(a, "{s}\x00{s}", .{ fc.module, fc.field });
            try out.put(a, key, inst);
            for (fc.args) |arg| try scanForeignCalls(arg, out, a);
        },
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
    /// First record base-ptr scratch local; `rec_base + rec_level` holds the
    /// base of the record currently being initialized at that nesting level.
    rec_base: c.BinaryenIndex = 0,
    rec_level: u32 = 0,
    /// The i64 scratch holding a bounds-checked index (the index expr is
    /// evaluated once, tested, then yielded).
    bounds_idx: c.BinaryenIndex = 0,
    /// Frame-reclamation scratch (spec/memory.md §"Frame reclamation"):
    /// per region-nesting level, an 8-local group
    /// [wm ptr, i64, i32, f64, f32, pair, ptr, v128] — the watermark plus a
    /// result stash of each value type. `region_lvl` tracks the current
    /// nesting depth while lowering (a nested call in an argument wraps
    /// one level deeper than its caller's wrap).
    region_base: c.BinaryenIndex = 0,
    region_lvl: u32 = 0,
    /// fs.read scratch: the dest pointer + the returned i64 length.
    fs_dest_idx: c.BinaryenIndex = 0,
    fs_len_idx: c.BinaryenIndex = 0,
    label_ctr: u32 = 0,
    loops: std.ArrayList(LoopLabels) = .empty,
    /// Dotted host-face name (`qview.text`) → the declared wasm import's internal
    /// name (`qview_text`, null-terminated), for lowering `host_call`.
    host_imports: *const std.StringHashMapUnmanaged([*:0]const u8) = undefined,
    /// `"<module>\x00<field>"` → the declared wasm import's internal name, for
    /// lowering `foreign_call` (a `--wit-import` interface function).
    foreign_imports: *const std.StringHashMapUnmanaged([*:0]const u8) = undefined,
    /// Wasm global names by index (`g0`, `g1`, …), for `global_get`/`global_set`.
    global_names: []const [*:0]const u8 = &.{},
    /// How a stdout write (`env.out`) lowers: q64's `env.out` host face, or a
    /// WASI preview1 `fd_write` to fd 1 (see `StdoutAbi`).
    stdout_abi: StdoutAbi = .env_out,
    /// Static address of the reserved iovec scratch (preview1 path only): the
    /// iovec lives at `[iovec_base, iovec_base+8)`, `nwritten` at `iovec_base+8`.
    iovec_base: u32 = 0,
    /// kv component lowering: `env.kv` lowers to the canonical `wasi:keyvalue`
    /// imports (lazy `store.open` into `kv_bucket`, `atomics.increment`) instead
    /// of the raw `env_kv_increment` host face. The two return areas the host
    /// writes results into are at `kv_open_ret` / `kv_inc_ret`.
    kv_component: bool = false,
    /// blob (object-store) component lowering: `env.blob` lowers to the q64-owned
    /// `q64:blob/store` imports (lazy `open` into `blob_bucket`, bucket methods).
    /// Reuses kv's return areas (`kv_open_ret`/`kv_inc_ret`) and scratch locals —
    /// only one store op is live per expression — so only the bucket handle
    /// global differs.
    blob_component: bool = false,
    /// db (SQL) component lowering: `env.db` lowers to the q64-owned `q64:db/sql`
    /// imports (lazy `open` into `db_connection`, connection methods). Reuses the
    /// shared store return areas + scratch locals; only the handle global differs.
    db_component: bool = false,
    /// config (wasi:config) component lowering: `env.config.get` lowers to the
    /// top-level `wasi:config/store.get` — no handle, no lazy-open. Reuses the
    /// shared store return area + box helpers.
    config_component: bool = false,
    /// time (wasi:clocks) component lowering: `env.time.monotonic_ns` lowers to
    /// the top-level `monotonic-clock.now` — a bare scalar call, no return
    /// area at all. When false, the raw local `env.monotonic_ns` face is used
    /// instead (unlike the storage faces, the local path is real, not a trap).
    time_component: bool = false,
    /// time preview1 lowering (an app that prints AND times): the clocks ride
    /// the preview1 syscalls `clock_time_get` / `clock_res_get`, their u64
    /// written into the reserved cell at `p1_ts_base` and loaded back.
    time_preview1: bool = false,
    rand_preview1: bool = false,
    p1_ts_base: u32 = 0,
    /// component-mode wall clock: `clocks_wall_now(time_ret)` writes the
    /// `datetime {u64 seconds @0, u32 nanoseconds @8}` record here; the
    /// emitted code folds it to i64 ns since the epoch.
    time_ret: u32 = 0,
    /// ASYNC-export frame mode (Slice B rung 3): when set, every q64 local
    /// is an 8-byte slot in linear memory at `frame_base + idx*8` instead of
    /// a wasm local — so state survives across callback re-entries. Only
    /// all-i64 bodies enter this mode (the async gate enforces it).
    frame_base: ?u32 = null,
    /// async-export clock: `env.time.monotonic_ns` calls the WASIp3 `now`
    /// import (`p3_now`) instead of the 0.2 cm32p2 one.
    time_p3: bool = false,
    kv_open_ret: u32 = 0,
    kv_inc_ret: u32 = 0,
    /// kv set/get scratch locals: `kv_hdr_idx` holds the boxed-Result header
    /// pointer while the result is decoded; `kv_a_idx`/`kv_b_idx` stash the key
    /// (ptr, len) across the value's evaluation in `set` (one pair local can't
    /// hold two live str pairs). Address-width; allocated only for set/get.
    kv_hdr_idx: c.BinaryenIndex = 0,
    kv_a_idx: c.BinaryenIndex = 0,
    kv_b_idx: c.BinaryenIndex = 0,

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
            .host_out_const => |hc| return self.envWrite(hc.stream, @intCast(hc.off), @intCast(hc.len)),
            .host_exit => |he| return self.envExit(try self.inst(he.code)),
            .const_i64 => |v| return c.BinaryenConst(module, c.BinaryenLiteralInt64(v)),
            .const_f64 => |v| return c.BinaryenConst(module, c.BinaryenLiteralFloat64(v)),
            .num_cast => |src| {
                // (source type, target type) → the wasm conversion. float→int
                // is the TRAPPING trunc per spec/types.md §Casts. An i64 →
                // .ptr cast narrows to address width (a boxed str payload
                // cell read).
                if (n.ty == .ptr) return self.toPtr(try self.inst(src));
                const x = try self.inst(src);
                const from = src.ty;
                const to = n.ty;
                if (from == to) return x;
                // An address-width pointer widening to the i64 cell of a str
                // channel box (identity on wasm64, zero-extend on wasm32).
                if (to == .i64 and from == .ptr) return self.toI64(x);
                const op: c.BinaryenOp = switch (to) {
                    .f64 => switch (from) {
                        .f32 => c.BinaryenPromoteFloat32(),
                        .i64 => c.BinaryenConvertSInt64ToFloat64(),
                        else => return Error.UnsupportedCall,
                    },
                    .f32 => switch (from) {
                        .f64 => c.BinaryenDemoteFloat64(),
                        .i64 => c.BinaryenConvertSInt64ToFloat32(),
                        else => return Error.UnsupportedCall,
                    },
                    .i64 => switch (from) {
                        .f64 => c.BinaryenTruncSFloat64ToInt64(),
                        .f32 => c.BinaryenTruncSFloat32ToInt64(),
                        // A boolean (i32 0/1) widening to a channel's i64 cell.
                        .i32 => c.BinaryenExtendUInt32(),
                        else => return Error.UnsupportedCall,
                    },
                    // Narrow an i64 to i32 (the low 32 bits) — reading a packed
                    // 4-byte `Vec<f32>` cell before reinterpreting to f32.
                    .i32 => switch (from) {
                        .i64 => c.BinaryenWrapInt64(),
                        else => return Error.UnsupportedCall,
                    },
                    else => return Error.UnsupportedCall,
                };
                return c.BinaryenUnary(module, op, x);
            },
            .bitcast => |src| {
                // Bit reinterpretation (raw bits kept), same width both ways:
                // f64↔i64 (an f64 channel/`Vec<f64>` cell) and f32↔i32 (a packed
                // `Vec<f32>` cell). The target type picks the direction.
                const x = try self.inst(src);
                if (src.ty == n.ty) return x;
                const op: c.BinaryenOp = switch (n.ty) {
                    .i64 => c.BinaryenReinterpretFloat64(),
                    .f64 => c.BinaryenReinterpretInt64(),
                    .i32 => c.BinaryenReinterpretFloat32(),
                    .f32 => c.BinaryenReinterpretInt32(),
                    else => return Error.UnsupportedCall,
                };
                return c.BinaryenUnary(module, op, x);
            },
            .const_i32 => |v| return c.BinaryenConst(module, c.BinaryenLiteralInt32(v)),
            .local_get => |idx| {
                if (self.frame_base) |fb| {
                    if (n.ty != .i64) return Error.UnsupportedCall; // async frame: i64 only
                    return c.BinaryenLoad(module, 8, false, fb + idx * 8, 0, self.i64_type, c.BinaryenConst(module, c.BinaryenLiteralInt32(0)), "0");
                }
                return c.BinaryenLocalGet(module, idx, self.wty(n.ty));
            },
            .local_set => |ls| {
                if (self.frame_base) |fb| {
                    if (ls.value.ty != .i64) return Error.UnsupportedCall;
                    return c.BinaryenStore(module, 8, fb + ls.idx * 8, 0, c.BinaryenConst(module, c.BinaryenLiteralInt32(0)), try self.inst(ls.value), self.i64_type, "0");
                }
                return c.BinaryenLocalSet(module, ls.idx, try self.inst(ls.value));
            },
            .bin => |b| {
                // Operand type picks the instruction family; the builder
                // guarantees both sides agree (no implicit conversion).
                const op = switch (b.lhs.ty) {
                    .f64 => binOpF64(b.kind) orelse return Error.UnsupportedCall,
                    .f32 => binOpF32(b.kind) orelse return Error.UnsupportedCall,
                    else => binOp(b.kind),
                };
                return c.BinaryenBinary(module, op, try self.inst(b.lhs), try self.inst(b.rhs));
            },
            .un => |u| {
                const x = try self.inst(u.operand);
                const is32 = u.operand.ty == .f32;
                if (u.kind == .neg and u.operand.ty == .f64) {
                    return c.BinaryenUnary(module, c.BinaryenNegFloat64(), x);
                }
                if (u.kind == .neg and u.operand.ty == .f32) {
                    return c.BinaryenUnary(module, c.BinaryenNegFloat32(), x);
                }
                return switch (u.kind) {
                    .neg => c.BinaryenBinary(module, c.BinaryenSubInt64(), c.BinaryenConst(module, c.BinaryenLiteralInt64(0)), x),
                    .bit_not => c.BinaryenBinary(module, c.BinaryenXorInt64(), x, c.BinaryenConst(module, c.BinaryenLiteralInt64(-1))),
                    // Logical not is truthiness: `x == 0 ? 1 : 0`. `eqz` already
                    // yields an i32 0/1; pick the width of the operand (a
                    // comparison is i32, any other integer expr is i64).
                    .not => c.BinaryenUnary(module, if (u.operand.ty == .i32) c.BinaryenEqZInt32() else c.BinaryenEqZInt64(), x),
                    // Native float-math builtins — one instruction, f32/f64 variant.
                    .fabs => c.BinaryenUnary(module, if (is32) c.BinaryenAbsFloat32() else c.BinaryenAbsFloat64(), x),
                    .fsqrt => c.BinaryenUnary(module, if (is32) c.BinaryenSqrtFloat32() else c.BinaryenSqrtFloat64(), x),
                    .ffloor => c.BinaryenUnary(module, if (is32) c.BinaryenFloorFloat32() else c.BinaryenFloorFloat64(), x),
                    .fceil => c.BinaryenUnary(module, if (is32) c.BinaryenCeilFloat32() else c.BinaryenCeilFloat64(), x),
                    .ftrunc => c.BinaryenUnary(module, if (is32) c.BinaryenTruncFloat32() else c.BinaryenTruncFloat64(), x),
                    .fnearest => c.BinaryenUnary(module, if (is32) c.BinaryenNearestFloat32() else c.BinaryenNearestFloat64(), x),
                };
            },
            // SIMD ops: the lane shape on the op (never the operand's `v128`
            // type, which cannot recover it) selects the instruction family.
            .simd_splat => |s| {
                const x = try self.inst(s.operand);
                return switch (s.shape) {
                    .f32x4 => c.BinaryenUnary(module, c.BinaryenSplatVecF32x4(), x),
                    // The i64 compute-floor operand wraps to the i32 lane.
                    .i32x4 => c.BinaryenUnary(module, c.BinaryenSplatVecI32x4(), c.BinaryenUnary(module, c.BinaryenWrapInt64(), x)),
                };
            },
            .simd_extract => |s| {
                const v = try self.inst(s.vec);
                return switch (s.shape) {
                    .f32x4 => c.BinaryenSIMDExtract(module, c.BinaryenExtractLaneVecF32x4(), v, s.lane),
                    // The i32 lane sign-extends back to the i64 compute floor.
                    .i32x4 => c.BinaryenUnary(module, c.BinaryenExtendSInt32(), c.BinaryenSIMDExtract(module, c.BinaryenExtractLaneVecI32x4(), v, s.lane)),
                };
            },
            .simd_bin => |s| {
                const op = switch (s.shape) {
                    .f32x4 => switch (s.kind) {
                        .add => c.BinaryenAddVecF32x4(),
                        .sub => c.BinaryenSubVecF32x4(),
                        .mul => c.BinaryenMulVecF32x4(),
                        .div => c.BinaryenDivVecF32x4(),
                        .fmin => c.BinaryenMinVecF32x4(),
                        .fmax => c.BinaryenMaxVecF32x4(),
                        else => return Error.UnsupportedCall,
                    },
                    .i32x4 => switch (s.kind) {
                        .add => c.BinaryenAddVecI32x4(),
                        .sub => c.BinaryenSubVecI32x4(),
                        .mul => c.BinaryenMulVecI32x4(),
                        else => return Error.UnsupportedCall,
                    },
                };
                return c.BinaryenBinary(module, op, try self.inst(s.lhs), try self.inst(s.rhs));
            },
            .simd_un => |s| {
                const op = switch (s.shape) {
                    .f32x4 => switch (s.kind) {
                        .neg => c.BinaryenNegVecF32x4(),
                        .fabs => c.BinaryenAbsVecF32x4(),
                        .fsqrt => c.BinaryenSqrtVecF32x4(),
                        else => return Error.UnsupportedCall,
                    },
                    .i32x4 => switch (s.kind) {
                        .neg => c.BinaryenNegVecI32x4(),
                        .fabs => c.BinaryenAbsVecI32x4(),
                        else => return Error.UnsupportedCall,
                    },
                };
                return c.BinaryenUnary(module, op, try self.inst(s.operand));
            },
            .simd_load => |s| {
                // Inline (not a __vec helper — the per-group call cost showed
                // up in the block-processing benchmarks): one bounds check for
                // the 4-lane group (`idx + 4 > len` traps), then an unaligned
                // 16-byte load at data + idx*4. The vec operand is always a
                // local, so re-reading it for the two header loads is free;
                // the index evaluates once into bounds_idx.
                const addr = try self.simdVecAddr(s.vec);
                var seq = [_]c.BinaryenExpressionRef{
                    c.BinaryenLocalSet(module, self.bounds_idx, try self.inst(s.idx)),
                    addr.check,
                    c.BinaryenLoad(module, 16, false, 0, 1, c.BinaryenTypeVec128(), addr.slot, "0"),
                };
                return c.BinaryenBlock(module, null, @ptrCast(&seq), seq.len, c.BinaryenTypeVec128());
            },
            .simd_store => |s| {
                // The write half — same inline shape; the stored value is a
                // local (the recognizer only accepts a Simd binding).
                const addr = try self.simdVecAddr(s.vec);
                var seq = [_]c.BinaryenExpressionRef{
                    c.BinaryenLocalSet(module, self.bounds_idx, try self.inst(s.idx)),
                    addr.check,
                    c.BinaryenStore(module, 16, 0, 1, addr.slot, try self.inst(s.value), c.BinaryenTypeVec128(), "0"),
                };
                return c.BinaryenBlock(module, null, @ptrCast(&seq), seq.len, self.none_type);
            },
            .simd_replace => |s| {
                // The value arrives at the compute width (i64 for i32x4
                // lanes) — wrap to the 32-bit lane before the replace.
                const raw = try self.inst(s.value);
                return switch (s.shape) {
                    .f32x4 => c.BinaryenSIMDReplace(module, c.BinaryenReplaceLaneVecF32x4(), try self.inst(s.vec), s.lane, raw),
                    .i32x4 => c.BinaryenSIMDReplace(module, c.BinaryenReplaceLaneVecI32x4(), try self.inst(s.vec), s.lane, c.BinaryenUnary(module, c.BinaryenWrapInt64(), raw)),
                };
            },
            .simd_fma => |s| {
                return c.BinaryenSIMDTernary(module, c.BinaryenRelaxedMaddVecF32x4(), try self.inst(s.a), try self.inst(s.b), try self.inst(s.c));
            },
            .call => |cl| {
                // Frame reclamation (spec/memory.md §"Frame reclamation"):
                // the call wraps in a region — watermark saved before the
                // arguments evaluate, the result slid down onto it after.
                // Nested calls in the arguments wrap one level deeper.
                const d = self.region_lvl;
                self.region_lvl += 1;
                defer self.region_lvl -= 1;
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
                const callee = self.funcs[cl.func];
                const callex = c.BinaryenCall(module, callee.name.ptr, if (operands.items.len > 0) operands.items.ptr else null, @intCast(operands.items.len), self.wty(n.ty));
                // A pointer-bearing aggregate return (a str enum payload)
                // cannot slide flat — skip reclamation entirely (the
                // spec's pinned interior-pointer boundary).
                if (callee.ret_ptr_bearing) return callex;
                return self.slideCall(d, n.ty, callee.ret_size, callex);
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
                // The statement's bytes are consumed by the host before it
                // completes, so the wrap resets `sp` afterwards.
                const d = self.region_lvl;
                self.region_lvl += 1;
                defer self.region_lvl -= 1;
                var fmt_args = [_]c.BinaryenExpressionRef{try self.inst(hi.value)};
                const fmt = c.BinaryenCall(module, "__fmt_i64", @ptrCast(&fmt_args), fmt_args.len, self.pair_type);
                return self.resetAfter(d, self.hostWritePair(hi.stream, fmt, @intCast(hi.nl_off)));
            },
            .host_out_float => |hf| {
                // __fmt_f64(value) → (ptr, len), then write it + the newline.
                const d = self.region_lvl;
                self.region_lvl += 1;
                defer self.region_lvl -= 1;
                var fmt_args = [_]c.BinaryenExpressionRef{try self.inst(hf.value)};
                const fmt = c.BinaryenCall(module, "__fmt_f64", @ptrCast(&fmt_args), fmt_args.len, self.pair_type);
                return self.resetAfter(d, self.hostWritePair(hf.stream, fmt, @intCast(hf.nl_off)));
            },
            .host_out_str => |hs| {
                const d = self.region_lvl;
                self.region_lvl += 1;
                defer self.region_lvl -= 1;
                return self.resetAfter(d, self.hostWritePair(hs.stream, try self.inst(hs.value), @intCast(hs.nl_off)));
            },
            .host_call => |hc| {
                // A `str` argument expands to two operands (ptr, len), exactly
                // like a regular `.call`; any other arg is one i64 value. The
                // host consumes the bytes within the statement → reset after.
                const d = self.region_lvl;
                self.region_lvl += 1;
                defer self.region_lvl -= 1;
                var operands: std.ArrayList(c.BinaryenExpressionRef) = .empty;
                defer operands.deinit(self.allocator);
                for (hc.args) |a| {
                    if (a.ty == .str) {
                        try self.strOperands(a, &operands);
                    } else {
                        try operands.append(self.allocator, try self.inst(a));
                    }
                }
                const name = self.host_imports.get(hc.name) orelse return Error.UnsupportedCall;
                return self.resetAfter(d, c.BinaryenCall(module, name, if (operands.items.len > 0) operands.items.ptr else null, @intCast(operands.items.len), self.none_type));
            },
            .foreign_call => |fc| {
                // A foreign WIT import: scalar args (one operand each), a scalar
                // result. Wraps in a reclamation region like a call, then slides
                // the (scalar) result down onto the watermark.
                const d = self.region_lvl;
                self.region_lvl += 1;
                defer self.region_lvl -= 1;
                var operands: std.ArrayList(c.BinaryenExpressionRef) = .empty;
                defer operands.deinit(self.allocator);
                for (fc.args) |a| try operands.append(self.allocator, try self.inst(a));
                var key_buf: std.ArrayList(u8) = .empty;
                defer key_buf.deinit(self.allocator);
                try key_buf.appendSlice(self.allocator, fc.module);
                try key_buf.append(self.allocator, 0);
                try key_buf.appendSlice(self.allocator, fc.field);
                const name = self.foreign_imports.get(key_buf.items) orelse return Error.UnsupportedCall;
                const callex = c.BinaryenCall(module, name, if (operands.items.len > 0) operands.items.ptr else null, @intCast(operands.items.len), self.wty(n.ty));
                return self.slideCall(d, n.ty, 0, callex);
            },
            .global_get => |idx| return c.BinaryenGlobalGet(module, self.global_names[idx], self.i64_type),
            .fs_read => |fr| {
                // A boxed Result<str, i64> (spec/env.md §"Wire ABI: fs.read"):
                // hdr = align8(sp); sp = hdr+24; dest = sp;
                // len = env.fs_read(dest, path…);
                // len < 0 → {tag=Err, cell8 = -len}; else sp = dest+len,
                // {tag=Ok, cell8 = dest, cell16 = len}. Yields hdr.
                const hdr = self.fs_dest_idx; // reuse: hdr ptr scratch
                const lenl = self.fs_len_idx;
                const i64c0 = c.BinaryenConst(module, c.BinaryenLiteralInt64(0));
                const pget = c.BinaryenLocalGet(module, self.pair_idx, self.pair_type);
                var call_args = [_]c.BinaryenExpressionRef{
                    c.BinaryenGlobalGet(module, "sp", self.ptr_type),
                    c.BinaryenTupleExtract(module, pget, 0),
                    c.BinaryenTupleExtract(module, c.BinaryenLocalGet(module, self.pair_idx, self.pair_type), 1),
                };
                const lget = c.BinaryenLocalGet(module, lenl, self.i64_type);
                // Err branch: tag=1, cell8 = -len.
                var errseq = [_]c.BinaryenExpressionRef{
                    c.BinaryenStore(module, 8, 0, 0, self.ptrGet(hdr), c.BinaryenConst(module, c.BinaryenLiteralInt64(1)), self.i64_type, "0"),
                    c.BinaryenStore(module, 8, 8, 0, self.ptrGet(hdr), c.BinaryenBinary(module, c.BinaryenSubInt64(), i64c0, lget), self.i64_type, "0"),
                };
                // Ok branch: sp = dest+len; tag=0; cell8 = dest; cell16 = len.
                var okseq = [_]c.BinaryenExpressionRef{
                    c.BinaryenGlobalSet(module, "sp", self.ptrAdd(c.BinaryenGlobalGet(module, "sp", self.ptr_type), self.toPtr(lget))),
                    c.BinaryenStore(module, 8, 0, 0, self.ptrGet(hdr), i64c0, self.i64_type, "0"),
                    c.BinaryenStore(module, 8, 8, 0, self.ptrGet(hdr), self.toI64(self.ptrAdd(self.ptrGet(hdr), self.ptrConst(24))), self.i64_type, "0"),
                    c.BinaryenStore(module, 8, 16, 0, self.ptrGet(hdr), lget, self.i64_type, "0"),
                };
                var seq = [_]c.BinaryenExpressionRef{
                    c.BinaryenLocalSet(module, self.pair_idx, try self.inst(fr.path)),
                    c.BinaryenLocalSet(module, hdr, self.ptrAnd(self.ptrAdd(c.BinaryenGlobalGet(module, "sp", self.ptr_type), self.ptrConst(7)), self.ptrConst(-8))),
                    c.BinaryenGlobalSet(module, "sp", self.ptrAdd(self.ptrGet(hdr), self.ptrConst(24))),
                    c.BinaryenLocalSet(module, lenl, c.BinaryenCall(module, "env_fs_read", @ptrCast(&call_args), call_args.len, self.i64_type)),
                    c.BinaryenIf(
                        module,
                        c.BinaryenBinary(module, c.BinaryenLtSInt64(), lget, i64c0),
                        c.BinaryenBlock(module, null, @ptrCast(&errseq), errseq.len, self.none_type),
                        c.BinaryenBlock(module, null, @ptrCast(&okseq), okseq.len, self.none_type),
                    ),
                    self.ptrGet(hdr),
                };
                return c.BinaryenBlock(module, null, @ptrCast(&seq), seq.len, self.ptr_type);
            },
            .kv_increment => |kv| {
                // Component lowering: the canonical `wasi:keyvalue` lazy-open +
                // increment + result unwrap (see `kvComponentIncrement`).
                if (self.kv_component) return try self.kvComponentIncrement(kv);
                // n = env.kv_increment(key_ptr, key_len, delta), i64 result.
                if (kv.key) |key| {
                    // Evaluate the str key into the pair scratch, then pass its
                    // (ptr, len) plus delta. A block sequences the set before
                    // the call so the extracts read the populated pair.
                    const set_pair = c.BinaryenLocalSet(module, self.pair_idx, try self.inst(key));
                    const pget = c.BinaryenLocalGet(module, self.pair_idx, self.pair_type);
                    var call_args = [_]c.BinaryenExpressionRef{
                        c.BinaryenTupleExtract(module, pget, 0),
                        c.BinaryenTupleExtract(module, c.BinaryenLocalGet(module, self.pair_idx, self.pair_type), 1),
                        try self.inst(kv.delta),
                    };
                    const callex = c.BinaryenCall(module, "env_kv_increment", @ptrCast(&call_args), call_args.len, self.i64_type);
                    var seq = [_]c.BinaryenExpressionRef{ set_pair, callex };
                    return c.BinaryenBlock(module, null, @ptrCast(&seq), seq.len, self.i64_type);
                }
                // Keyless: the empty key (ptr=0, len=0) — the host's single counter.
                var call_args = [_]c.BinaryenExpressionRef{
                    self.ptrConst(0),
                    self.ptrConst(0),
                    try self.inst(kv.delta),
                };
                return c.BinaryenCall(module, "env_kv_increment", @ptrCast(&call_args), call_args.len, self.i64_type);
            },
            .kv_set => |kv| {
                // env.kv.set exists only on the component (`wasi:keyvalue`) path;
                // the local `qube run` host face has no set/get. Trap if reached
                // without --component (the CLI only lowers set/get for wants_kv).
                if (!self.kv_component) return c.BinaryenUnreachable(module);
                return try self.storeComponentSet(kv.key, kv.value, "kv_bucket_set", "kv_bucket", "kv_store_open");
            },
            .kv_get => |kv| {
                if (!self.kv_component) return c.BinaryenUnreachable(module);
                return try self.storeComponentGet(kv.key, "kv_bucket_get", "kv_bucket", "kv_store_open");
            },
            .blob_put => |bl| {
                if (!self.blob_component) return c.BinaryenUnreachable(module);
                return try self.storeComponentSet(bl.key, bl.value, "blob_bucket_put", "blob_bucket", "blob_store_open");
            },
            .blob_get => |bl| {
                if (!self.blob_component) return c.BinaryenUnreachable(module);
                return try self.storeComponentGet(bl.key, "blob_bucket_get", "blob_bucket", "blob_store_open");
            },
            .blob_delete => |bl| {
                if (!self.blob_component) return c.BinaryenUnreachable(module);
                return try self.storeComponentDelete(bl.key, "blob_bucket_delete", "blob_bucket", "blob_store_open");
            },
            .db_execute => |db| {
                if (!self.db_component) return c.BinaryenUnreachable(module);
                return try self.storeComponentExec(db.sql, "db_conn_exec", "db_connection", "db_conn_open");
            },
            .db_query_text => |db| {
                if (!self.db_component) return c.BinaryenUnreachable(module);
                // query-text's result<option<string>,error> has the identical
                // return-area layout as a store bucket.get — reuse it verbatim.
                return try self.storeComponentGet(db.sql, "db_conn_query_text", "db_connection", "db_conn_open");
            },
            .db_query_value => |db| {
                if (!self.db_component) return c.BinaryenUnreachable(module);
                return try self.storeComponentQueryValue(db.sql, "db_conn_query_value", "db_connection", "db_conn_open");
            },
            .db_query_one => |db| {
                if (!self.db_component) return c.BinaryenUnreachable(module);
                return try self.storeComponentQueryOne(db.sql, "db_conn_query_one", "db_connection", "db_conn_open");
            },
            .config_get => |cf| {
                if (!self.config_component) return c.BinaryenUnreachable(module);
                // wasi:config/store.get is a top-level function — no handle,
                // no lazy-open; reuse the get-decode with null handle/open.
                return try self.storeComponentGet(cf.key, "config_store_get", null, null);
            },
            .random_u64 => {
                // env.random.u64() — preview1 apps call random_get(cell, 8)
                // and load the i64 back; local mode calls the raw face. The
                // host owns the entropy-vs-seeded policy.
                if (self.rand_preview1) {
                    const i32c = struct {
                        fn f(mod: c.BinaryenModuleRef, v: i32) c.BinaryenExpressionRef {
                            return c.BinaryenConst(mod, c.BinaryenLiteralInt32(v));
                        }
                    }.f;
                    var call_args = [_]c.BinaryenExpressionRef{
                        i32c(module, @intCast(self.p1_ts_base)),
                        i32c(module, 8),
                    };
                    var seq = [_]c.BinaryenExpressionRef{
                        c.BinaryenDrop(module, c.BinaryenCall(module, "random_get", @ptrCast(&call_args), call_args.len, self.i32_type)),
                        c.BinaryenLoad(module, 8, false, 0, 0, self.i64_type, i32c(module, @intCast(self.p1_ts_base)), "0"),
                    };
                    return c.BinaryenBlock(module, null, @ptrCast(&seq), seq.len, self.i64_type);
                }
                return c.BinaryenCall(module, "env_random_u64", null, 0, self.i64_type);
            },
            .time_monotonic_ns => {
                // env.time.monotonic_ns() — three lowerings, one face:
                // component mode calls the canonical wasi:clocks import;
                // preview1 apps call the clock_time_get syscall (u64 written
                // through the reserved cell, loaded back); local mode calls
                // the raw `env.monotonic_ns` host face. No Result box ever.
                if (self.time_preview1) return self.p1ClockTime(1);
                const name: [*:0]const u8 = if (self.time_p3) "p3_now" else if (self.time_component) "clocks_monotonic_now" else "env_monotonic_ns";
                return c.BinaryenCall(module, name, null, 0, self.i64_type);
            },
            .time_resolution_ns => {
                // env.time.resolution_ns() — the monotonic clock's tick size.
                // Same bare-scalar shape; preview1 rides clock_res_get.
                if (self.time_preview1) {
                    const i32c = struct {
                        fn f(mod: c.BinaryenModuleRef, v: i32) c.BinaryenExpressionRef {
                            return c.BinaryenConst(mod, c.BinaryenLiteralInt32(v));
                        }
                    }.f;
                    var call_args = [_]c.BinaryenExpressionRef{
                        i32c(module, 1), // clockid 1 = monotonic
                        i32c(module, @intCast(self.p1_ts_base)),
                    };
                    var seq = [_]c.BinaryenExpressionRef{
                        c.BinaryenDrop(module, c.BinaryenCall(module, "clock_res_get", @ptrCast(&call_args), call_args.len, self.i32_type)),
                        c.BinaryenLoad(module, 8, false, 0, 0, self.i64_type, i32c(module, @intCast(self.p1_ts_base)), "0"),
                    };
                    return c.BinaryenBlock(module, null, @ptrCast(&seq), seq.len, self.i64_type);
                }
                const name: [*:0]const u8 = if (self.time_component) "clocks_monotonic_resolution" else "env_resolution_ns";
                return c.BinaryenCall(module, name, null, 0, self.i64_type);
            },
            .time_unix_ns => {
                // env.time.unix_ns() — wall-clock time as ns since the Unix
                // epoch. Preview1's realtime clock (clockid 0) already returns
                // epoch-ns; the component import returns a datetime record
                // {u64 seconds @0, u32 nanoseconds @8} through `time_ret`,
                // folded here as seconds * 1e9 + nanoseconds.
                if (self.time_preview1) return self.p1ClockTime(0);
                if (self.time_component) {
                    const i32c = struct {
                        fn f(mod: c.BinaryenModuleRef, v: i32) c.BinaryenExpressionRef {
                            return c.BinaryenConst(mod, c.BinaryenLiteralInt32(v));
                        }
                    }.f;
                    var call_args = [_]c.BinaryenExpressionRef{i32c(module, @intCast(self.time_ret))};
                    const seconds = c.BinaryenLoad(module, 8, false, 0, 0, self.i64_type, i32c(module, @intCast(self.time_ret)), "0");
                    const sec_ns = c.BinaryenBinary(module, c.BinaryenMulInt64(), seconds, c.BinaryenConst(module, c.BinaryenLiteralInt64(1_000_000_000)));
                    const nanos = c.BinaryenLoad(module, 4, false, 8, 0, self.i64_type, i32c(module, @intCast(self.time_ret)), "0");
                    var seq = [_]c.BinaryenExpressionRef{
                        c.BinaryenCall(module, "clocks_wall_now", @ptrCast(&call_args), call_args.len, self.none_type),
                        c.BinaryenBinary(module, c.BinaryenAddInt64(), sec_ns, nanos),
                    };
                    return c.BinaryenBlock(module, null, @ptrCast(&seq), seq.len, self.i64_type);
                }
                return c.BinaryenCall(module, "env_unix_ns", null, 0, self.i64_type);
            },
            .time_sleep_ns => |ts| {
                // env.time.sleep_ns(ns) — the BLOCKING wait, void. Three
                // lowerings like the read faces:
                //   component: h = subscribe-duration(ns); pollable.block(h);
                //              resource-drop(h) — h parks in `sleep_pollable`
                //              (sleeps never nest; no local plumbing).
                //   preview1:  poll_oneoff with ONE monotonic-clock
                //              subscription written at the shared cell.
                //   local:     the raw env.sleep_ns(ns) host face.
                const ns_val = try self.inst(ts.ns);
                const i32c = struct {
                    fn f(mod: c.BinaryenModuleRef, v: i32) c.BinaryenExpressionRef {
                        return c.BinaryenConst(mod, c.BinaryenLiteralInt32(v));
                    }
                }.f;
                const i64c = struct {
                    fn f(mod: c.BinaryenModuleRef, v: i64) c.BinaryenExpressionRef {
                        return c.BinaryenConst(mod, c.BinaryenLiteralInt64(v));
                    }
                }.f;
                if (self.time_preview1) {
                    const base: i32 = @intCast(self.p1_ts_base);
                    // subscription (48 bytes): userdata u64 @0; tag u8 @8
                    // (0 = clock; the wide zero store covers its padding);
                    // clockid u32 @16 (1 = monotonic); timeout u64 @24
                    // (relative — flags stay 0); precision u64 @32; flags
                    // u16 @40 (zero store covers padding). Event out @48,
                    // nevents @80.
                    var po_args = [_]c.BinaryenExpressionRef{
                        i32c(module, base),
                        i32c(module, base + 48),
                        i32c(module, 1),
                        i32c(module, base + 80),
                    };
                    var seq = [_]c.BinaryenExpressionRef{
                        c.BinaryenStore(module, 8, 0, 0, i32c(module, base), i64c(module, 0), self.i64_type, "0"),
                        c.BinaryenStore(module, 8, 8, 0, i32c(module, base), i64c(module, 0), self.i64_type, "0"),
                        c.BinaryenStore(module, 4, 16, 0, i32c(module, base), i32c(module, 1), self.i32_type, "0"),
                        c.BinaryenStore(module, 8, 24, 0, i32c(module, base), ns_val, self.i64_type, "0"),
                        c.BinaryenStore(module, 8, 32, 0, i32c(module, base), i64c(module, 1), self.i64_type, "0"),
                        c.BinaryenStore(module, 8, 40, 0, i32c(module, base), i64c(module, 0), self.i64_type, "0"),
                        c.BinaryenDrop(module, c.BinaryenCall(module, "poll_oneoff", @ptrCast(&po_args), po_args.len, self.i32_type)),
                    };
                    return c.BinaryenBlock(module, null, @ptrCast(&seq), seq.len, self.none_type);
                }
                if (self.time_component) {
                    var sub_args = [_]c.BinaryenExpressionRef{ns_val};
                    var blk_args = [_]c.BinaryenExpressionRef{c.BinaryenGlobalGet(module, "sleep_pollable", self.i32_type)};
                    var drop_args = [_]c.BinaryenExpressionRef{c.BinaryenGlobalGet(module, "sleep_pollable", self.i32_type)};
                    var seq = [_]c.BinaryenExpressionRef{
                        c.BinaryenGlobalSet(module, "sleep_pollable", c.BinaryenCall(module, "clocks_subscribe_duration", @ptrCast(&sub_args), sub_args.len, self.i32_type)),
                        c.BinaryenCall(module, "io_pollable_block", @ptrCast(&blk_args), blk_args.len, self.none_type),
                        c.BinaryenCall(module, "io_pollable_drop", @ptrCast(&drop_args), drop_args.len, self.none_type),
                    };
                    return c.BinaryenBlock(module, null, @ptrCast(&seq), seq.len, self.none_type);
                }
                var call_args = [_]c.BinaryenExpressionRef{ns_val};
                return c.BinaryenCall(module, "env_sleep_ns", @ptrCast(&call_args), call_args.len, self.none_type);
            },
            .chan_recv => |h| {
                // got = env.channel_recv(session) — 1 (message) or 0 (closed).
                var call_args = [_]c.BinaryenExpressionRef{try self.inst(h)};
                return c.BinaryenCall(module, "env_channel_recv", @ptrCast(&call_args), call_args.len, self.i64_type);
            },
            .chan_take => |h| {
                // n = env.channel_take(session) — the reported message's payload.
                var call_args = [_]c.BinaryenExpressionRef{try self.inst(h)};
                return c.BinaryenCall(module, "env_channel_take", @ptrCast(&call_args), call_args.len, self.i64_type);
            },
            .chan_open => |name| {
                // env.<name>() -> i64 — open a host stream (channel_connect / presses).
                const internal = std.fmt.allocPrintSentinel(self.allocator, "env_{s}", .{name}, 0) catch return Error.OutOfMemory;
                defer self.allocator.free(internal);
                return c.BinaryenCall(module, internal.ptr, null, 0, self.i64_type);
            },
            .vec_new => return c.BinaryenCall(module, "__vec_new", null, 0, self.ptr_type),
            .vec_push => |vp| {
                var args = [_]c.BinaryenExpressionRef{ try self.inst(vp.vec), try self.inst(vp.value) };
                return c.BinaryenCall(module, if (vp.cell4) "__vec_push_f32" else "__vec_push", @ptrCast(&args), args.len, self.none_type);
            },
            .vec_len => |vl| {
                var args = [_]c.BinaryenExpressionRef{try self.inst(vl.vec)};
                return c.BinaryenCall(module, "__vec_len", @ptrCast(&args), args.len, self.i64_type);
            },
            .vec_ptr => |vp| {
                var args = [_]c.BinaryenExpressionRef{try self.inst(vp.vec)};
                return c.BinaryenCall(module, "__vec_ptr", @ptrCast(&args), args.len, self.i64_type);
            },
            .vec_get => |vg| {
                var args = [_]c.BinaryenExpressionRef{ try self.inst(vg.vec), try self.inst(vg.idx) };
                return c.BinaryenCall(module, if (vg.cell4) "__vec_get_f32" else "__vec_get", @ptrCast(&args), args.len, if (vg.cell4) c.BinaryenTypeFloat32() else self.i64_type);
            },
            .vec_set => |vs| {
                var args = [_]c.BinaryenExpressionRef{ try self.inst(vs.vec), try self.inst(vs.idx), try self.inst(vs.value) };
                return c.BinaryenCall(module, if (vs.cell4) "__vec_set_f32" else "__vec_set", @ptrCast(&args), args.len, self.none_type);
            },
            .global_set => |gs| return c.BinaryenGlobalSet(module, self.global_names[gs.idx], try self.inst(gs.value)),
            .fmt_int_to_str => |inner| {
                // __fmt_i64(value) → (ptr, len). The (pair) result is the str
                // value; the caller consumes it just like any str-typed inst.
                var fmt_args = [_]c.BinaryenExpressionRef{try self.inst(inner)};
                return c.BinaryenCall(module, "__fmt_i64", @ptrCast(&fmt_args), fmt_args.len, self.pair_type);
            },
            .fmt_float_to_str => |inner| {
                var fmt_args = [_]c.BinaryenExpressionRef{try self.inst(inner)};
                return c.BinaryenCall(module, "__fmt_f64", @ptrCast(&fmt_args), fmt_args.len, self.pair_type);
            },
            .str_len => |s| {
                // The str value's (ptr, len) pair; take element 1 (len). q64 ints
                // are i64, so zero-extend the address-width len on wasm32.
                const len = c.BinaryenTupleExtract(module, try self.inst(s), 1);
                return if (self.ptr_type == self.i64_type) len else c.BinaryenUnary(module, c.BinaryenExtendUInt32(), len);
            },
            .str_index => |si| {
                // ptr (element 0) + idx → load one unsigned byte → i64. idx is
                // i64; on wasm32 wrap it to the i32 address width for the add.
                const base = c.BinaryenTupleExtract(module, try self.inst(si.str), 0);
                const idx64 = try self.inst(si.idx);
                const idxp = if (self.ptr_type == self.i64_type) idx64 else c.BinaryenUnary(module, c.BinaryenWrapInt64(), idx64);
                const addr = self.ptrAdd(base, idxp);
                const byte = c.BinaryenLoad(module, 1, false, 0, 1, self.i32_type, addr, "0");
                return c.BinaryenUnary(module, c.BinaryenExtendUInt32(), byte);
            },
            .str_eq => |se| {
                // __str_eq(pa, la, pb, lb) -> i32 (0/1). Each str expands to its
                // (ptr, len) operands, exactly like a call/host-call str arg.
                var operands: std.ArrayList(c.BinaryenExpressionRef) = .empty;
                defer operands.deinit(self.allocator);
                try self.strOperands(se.lhs, &operands);
                try self.strOperands(se.rhs, &operands);
                return c.BinaryenCall(module, "__str_eq", operands.items.ptr, @intCast(operands.items.len), self.i32_type);
            },
            .str_slice => |sl| {
                // (ptr + start, end - start). start/end are i64; wrap to the
                // address width on wasm32. No bounds check (caller guards). Each
                // operand is built as its own expr tree (Binaryen refs aren't
                // shared), so `start` is emitted fresh in both halves.
                const base = c.BinaryenTupleExtract(module, try self.inst(sl.str), 0);
                const sub = if (self.ptr_type == self.i64_type) c.BinaryenSubInt64() else c.BinaryenSubInt32();
                var elems = [_]c.BinaryenExpressionRef{
                    self.ptrAdd(base, self.toPtr(try self.inst(sl.start))),
                    c.BinaryenBinary(module, sub, self.toPtr(try self.inst(sl.end)), self.toPtr(try self.inst(sl.start))),
                };
                return c.BinaryenTupleMake(module, @ptrCast(&elems), elems.len);
            },
            .str_index_of => |m| {
                // __str_index_of(ps, ls, byte) -> i64 (index or -1).
                var operands: std.ArrayList(c.BinaryenExpressionRef) = .empty;
                defer operands.deinit(self.allocator);
                try self.strOperands(m.str, &operands);
                try operands.append(self.allocator, try self.inst(m.byte));
                return c.BinaryenCall(module, "__str_index_of", operands.items.ptr, @intCast(operands.items.len), self.i64_type);
            },
            .str_starts_with => |m| {
                var operands: std.ArrayList(c.BinaryenExpressionRef) = .empty;
                defer operands.deinit(self.allocator);
                try self.strOperands(m.str, &operands);
                try self.strOperands(m.prefix, &operands);
                return c.BinaryenCall(module, "__str_starts_with", operands.items.ptr, @intCast(operands.items.len), self.i32_type);
            },
            .str_contains => |m| {
                var operands: std.ArrayList(c.BinaryenExpressionRef) = .empty;
                defer operands.deinit(self.allocator);
                try self.strOperands(m.str, &operands);
                try self.strOperands(m.sub, &operands);
                return c.BinaryenCall(module, "__str_contains", operands.items.ptr, @intCast(operands.items.len), self.i32_type);
            },
            .record_make => |rm| return self.emitRecordMake(rm),
            .array_make => |am| return self.emitArrayMake(am),
            .strlist_make => |inits| return self.emitStrlistMake(inits),
            .strlist_get => |g| return self.emitStrlistGet(g),
            .host_args => return self.emitHostArgs(),
            .envvar_get => |eg| return self.emitEnvvarGet(eg),
            .elem_ptr => |ep| {
                // base + index·stride (index is i64; narrow to the address
                // width on wasm32).
                const base = try self.inst(ep.base);
                const idx = self.toPtr(try self.inst(ep.index));
                const mul = if (self.ptr_type == self.i32_type) c.BinaryenMulInt32() else c.BinaryenMulInt64();
                const off = c.BinaryenBinary(module, mul, idx, self.ptrConst(ep.stride));
                return self.ptrAdd(base, off);
            },
            .bounds_check => |bc| {
                // Pass the index through; trap unless 0 ≤ index < count.
                // The unsigned compare catches negatives in one test.
                var seq = [_]c.BinaryenExpressionRef{
                    c.BinaryenLocalSet(module, self.bounds_idx, try self.inst(bc.index)),
                    c.BinaryenIf(
                        module,
                        c.BinaryenBinary(module, c.BinaryenGeUInt64(), c.BinaryenLocalGet(module, self.bounds_idx, self.i64_type), try self.inst(bc.count)),
                        c.BinaryenUnreachable(module),
                        null,
                    ),
                    c.BinaryenLocalGet(module, self.bounds_idx, self.i64_type),
                };
                return c.BinaryenBlock(module, null, @ptrCast(&seq), seq.len, self.i64_type);
            },
            .field_get => |fg| {
                // The loaded width follows the result type (spec/memory.md
                // §"Linear struct layout"): i64 → an 8-byte load; i32 (a bool
                // field) → a 1-byte zero-extending load.
                const base = try self.inst(fg.base);
                return switch (n.ty) {
                    // Integer loads honor the field's storage width and
                    // signedness (i64.load8_u … i64.load), widening into i64.
                    .i64 => c.BinaryenLoad(module, fg.width, fg.signed, fg.offset, 0, self.i64_type, base, "0"),
                    .f64 => c.BinaryenLoad(module, 8, true, fg.offset, 0, c.BinaryenTypeFloat64(), base, "0"),
                    .f32 => c.BinaryenLoad(module, 4, true, fg.offset, 0, c.BinaryenTypeFloat32(), base, "0"),
                    .i32 => c.BinaryenLoad(module, 1, false, fg.offset, 0, self.i32_type, base, "0"),
                    else => Error.UnsupportedCall,
                };
            },
            .field_set => |fs| {
                const base = try self.inst(fs.base);
                const value = try self.inst(fs.value);
                return switch (fs.value.ty) {
                    // An i64 value stores at the field's width (i64.store8 …
                    // i64.store — narrow stores truncate); floats and bool
                    // at their natural widths.
                    .i64 => c.BinaryenStore(module, fs.width, fs.offset, 0, base, value, self.i64_type, "0"),
                    .f64 => c.BinaryenStore(module, 8, fs.offset, 0, base, value, c.BinaryenTypeFloat64(), "0"),
                    .f32 => c.BinaryenStore(module, 4, fs.offset, 0, base, value, c.BinaryenTypeFloat32(), "0"),
                    .i32 => c.BinaryenStore(module, 1, fs.offset, 0, base, value, self.i32_type, "0"),
                    else => Error.UnsupportedCall,
                };
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

    /// Write `[off, off+len)` of linear memory to `stream` — `host_out_const`
    /// and the trailing newline of `host_out_*` go through here.
    fn envWrite(self: *Lowerer, stream: ir.mir.Stream, off: i64, len: i64) c.BinaryenExpressionRef {
        return self.writeStream(stream, self.ptrConst(off), self.ptrConst(len));
    }

    /// `env.kv.increment` lowered to the canonical `wasi:keyvalue` ABI. Lazily
    /// opens the adapter-held bucket (empty identifier; host pins identity) into
    /// `kv_bucket`, calls `atomics.increment`, and unwraps the
    /// `result<s64, error>` the host wrote into the return area: `ok` → the new
    /// total, `err` → 0 (the source always boxes the call as `Ok(n)`; v0 host
    /// always succeeds — see `test/kv-component-reference/`). i32 addresses
    /// (cm32p2 is 32-bit). Returns an i64.
    fn kvComponentIncrement(self: *Lowerer, kv: anytype) Error!c.BinaryenExpressionRef {
        const m = self.module;
        const inc_ret: i32 = @intCast(self.kv_inc_ret);

        // key (ptr,len): a str pair for the keyed form, (0,0) for the keyless one.
        // The keyed form sequences the pair eval before the call reads its extracts.
        var pre: std.ArrayList(c.BinaryenExpressionRef) = .empty;
        defer pre.deinit(self.allocator);
        try pre.append(self.allocator, self.storeLazyOpen("kv_store_open", "kv_bucket"));
        var key_ptr: c.BinaryenExpressionRef = self.kvI32(0);
        var key_len: c.BinaryenExpressionRef = self.kvI32(0);
        if (kv.key) |key| {
            try pre.append(self.allocator, c.BinaryenLocalSet(m, self.pair_idx, try self.inst(key)));
            key_ptr = c.BinaryenTupleExtract(m, c.BinaryenLocalGet(m, self.pair_idx, self.pair_type), 0);
            key_len = c.BinaryenTupleExtract(m, c.BinaryenLocalGet(m, self.pair_idx, self.pair_type), 1);
        }

        // increment(kv_bucket, key_ptr, key_len, delta, inc_ret)
        var inc_args = [_]c.BinaryenExpressionRef{
            c.BinaryenGlobalGet(m, "kv_bucket", self.i32_type),
            key_ptr,
            key_len,
            try self.inst(kv.delta),
            self.kvI32(inc_ret),
        };
        try pre.append(self.allocator, c.BinaryenCall(m, "kv_atomics_increment", @ptrCast(&inc_args), inc_args.len, self.none_type));

        // result: (load8_u(inc_ret) == 0) ? load_i64(inc_ret+8) : 0
        const ok = c.BinaryenBinary(m, c.BinaryenEqInt32(), c.BinaryenLoad(m, 1, false, 0, 1, self.i32_type, self.kvI32(inc_ret), "0"), self.kvI32(0));
        const total = c.BinaryenLoad(m, 8, false, 8, 8, self.i64_type, self.kvI32(inc_ret), "0");
        try pre.append(self.allocator, c.BinaryenSelect(m, ok, total, c.BinaryenConst(m, c.BinaryenLiteralInt64(0))));
        return c.BinaryenBlock(m, null, @ptrCast(pre.items.ptr), @intCast(pre.items.len), self.i64_type);
    }

    /// An i32 constant — the cm32p2 keyvalue ABI is 32-bit, so bucket handles,
    /// return-area addresses, and discriminants are all i32.
    fn kvI32(self: *Lowerer, v: i32) c.BinaryenExpressionRef {
        return c.BinaryenConst(self.module, c.BinaryenLiteralInt32(v));
    }

    /// The lazy `store.open` guard shared by every bucket-store op (`env.kv` and
    /// `env.blob`). On first use it opens the identity-pinned bucket (empty
    /// identifier — the host pins it to the qube's identity) via `open_import`
    /// and caches the handle in `bucket_global`; later ops reuse it
    /// (`== -1` means unopened). `open` writes `result<bucket, error>` into
    /// `kv_open_ret`; the handle is at +4.
    fn storeLazyOpen(self: *Lowerer, open_import: [*:0]const u8, bucket_global: [*:0]const u8) c.BinaryenExpressionRef {
        const m = self.module;
        const open_ret: i32 = @intCast(self.kv_open_ret);
        var open_args = [_]c.BinaryenExpressionRef{ self.kvI32(0), self.kvI32(0), self.kvI32(open_ret) };
        var open_then = [_]c.BinaryenExpressionRef{
            c.BinaryenCall(m, open_import, @ptrCast(&open_args), open_args.len, self.none_type),
            c.BinaryenGlobalSet(m, bucket_global, c.BinaryenLoad(m, 4, false, 4, 4, self.i32_type, self.kvI32(open_ret), "0")),
        };
        return c.BinaryenIf(
            m,
            c.BinaryenBinary(m, c.BinaryenEqInt32(), c.BinaryenGlobalGet(m, bucket_global, self.i32_type), self.kvI32(-1)),
            c.BinaryenBlock(m, null, @ptrCast(&open_then), open_then.len, self.none_type),
            null,
        );
    }

    /// Reserve an 8-aligned, `cells`×8-byte boxed-enum header in the scope arena
    /// (`sp` bump), leaving its address in `kv_hdr_idx`. Mirrors `fs_read`'s box
    /// discipline: `hdr = align8(sp); sp = hdr + cells*8`.
    fn kvBoxAlloc(self: *Lowerer, cells: u32) [2]c.BinaryenExpressionRef {
        const m = self.module;
        const set_hdr = c.BinaryenLocalSet(m, self.kv_hdr_idx, self.ptrAnd(self.ptrAdd(c.BinaryenGlobalGet(m, "sp", self.ptr_type), self.ptrConst(7)), self.ptrConst(-8)));
        const bump = c.BinaryenGlobalSet(m, "sp", self.ptrAdd(self.ptrGet(self.kv_hdr_idx), self.ptrConst(@intCast(cells * 8))));
        return .{ set_hdr, bump };
    }

    /// A keyed store write (`env.kv.set` / `env.blob.put`) lowered to the
    /// canonical bucket ABI: lazy-open the bucket, call `put_import(bucket, key,
    /// value, ret)`, and box the host's `result<_, error>` as a
    /// `Result<(), IoError>` (`{ #tag, #p0 }`, 2 cells): tag = the result
    /// discriminant (0 = `Ok(())`, 1 = `Err`); the payload cell is unused.
    /// Yields the box pointer. Shared by kv + blob — only the import + bucket
    /// global differ.
    fn storeComponentSet(self: *Lowerer, key: *const ir.mir.Inst, value: *const ir.mir.Inst, put_import: [*:0]const u8, bucket_global: [*:0]const u8, open_import: [*:0]const u8) Error!c.BinaryenExpressionRef {
        const m = self.module;
        const set_ret: i32 = @intCast(self.kv_inc_ret); // shared op return area (16B)

        var pre: std.ArrayList(c.BinaryenExpressionRef) = .empty;
        defer pre.deinit(self.allocator);
        try pre.append(self.allocator, self.storeLazyOpen(open_import, bucket_global));

        // Evaluate key → stash (ptr, len) in kv_a/kv_b (one pair local can't hold
        // two live str pairs), then evaluate value into the pair local.
        try pre.append(self.allocator, c.BinaryenLocalSet(m, self.pair_idx, try self.inst(key)));
        try pre.append(self.allocator, c.BinaryenLocalSet(m, self.kv_a_idx, c.BinaryenTupleExtract(m, c.BinaryenLocalGet(m, self.pair_idx, self.pair_type), 0)));
        try pre.append(self.allocator, c.BinaryenLocalSet(m, self.kv_b_idx, c.BinaryenTupleExtract(m, c.BinaryenLocalGet(m, self.pair_idx, self.pair_type), 1)));
        try pre.append(self.allocator, c.BinaryenLocalSet(m, self.pair_idx, try self.inst(value)));
        const val_ptr = c.BinaryenTupleExtract(m, c.BinaryenLocalGet(m, self.pair_idx, self.pair_type), 0);
        const val_len = c.BinaryenTupleExtract(m, c.BinaryenLocalGet(m, self.pair_idx, self.pair_type), 1);

        // Reserve the box AFTER operands (a concat value may bump `sp` first).
        const box = self.kvBoxAlloc(2);
        try pre.append(self.allocator, box[0]);
        try pre.append(self.allocator, box[1]);

        // put(bucket, key_ptr, key_len, val_ptr, val_len, set_ret)
        var set_args = [_]c.BinaryenExpressionRef{
            c.BinaryenGlobalGet(m, bucket_global, self.i32_type),
            self.ptrGet(self.kv_a_idx),
            self.ptrGet(self.kv_b_idx),
            val_ptr,
            val_len,
            self.kvI32(set_ret),
        };
        try pre.append(self.allocator, c.BinaryenCall(m, put_import, @ptrCast(&set_args), set_args.len, self.none_type));

        // Box: #tag = (i64) result-disc (0 = Ok, 1 = Err); #p0 unused.
        const disc = c.BinaryenUnary(m, c.BinaryenExtendUInt32(), c.BinaryenLoad(m, 1, false, 0, 1, self.i32_type, self.kvI32(set_ret), "0"));
        try pre.append(self.allocator, c.BinaryenStore(m, 8, 0, 0, self.ptrGet(self.kv_hdr_idx), disc, self.i64_type, "0"));
        try pre.append(self.allocator, c.BinaryenStore(m, 8, 8, 0, self.ptrGet(self.kv_hdr_idx), c.BinaryenConst(m, c.BinaryenLiteralInt64(0)), self.i64_type, "0"));
        try pre.append(self.allocator, self.ptrGet(self.kv_hdr_idx));
        return c.BinaryenBlock(m, null, @ptrCast(pre.items.ptr), @intCast(pre.items.len), self.ptr_type);
    }

    /// A keyed store delete (`env.blob.delete`) lowered to the canonical bucket
    /// ABI: lazy-open, call `delete_import(bucket, key, ret)`, box the host's
    /// `result<_, error>` as `Result<(), IoError>` (tag = result disc). Yields
    /// the box pointer. (kv has no delete op yet; the lowering is generic.)
    fn storeComponentDelete(self: *Lowerer, key: *const ir.mir.Inst, delete_import: [*:0]const u8, bucket_global: [*:0]const u8, open_import: [*:0]const u8) Error!c.BinaryenExpressionRef {
        const m = self.module;
        const del_ret: i32 = @intCast(self.kv_inc_ret);

        var pre: std.ArrayList(c.BinaryenExpressionRef) = .empty;
        defer pre.deinit(self.allocator);
        try pre.append(self.allocator, self.storeLazyOpen(open_import, bucket_global));

        try pre.append(self.allocator, c.BinaryenLocalSet(m, self.pair_idx, try self.inst(key)));
        try pre.append(self.allocator, c.BinaryenLocalSet(m, self.kv_a_idx, c.BinaryenTupleExtract(m, c.BinaryenLocalGet(m, self.pair_idx, self.pair_type), 0)));
        try pre.append(self.allocator, c.BinaryenLocalSet(m, self.kv_b_idx, c.BinaryenTupleExtract(m, c.BinaryenLocalGet(m, self.pair_idx, self.pair_type), 1)));

        const box = self.kvBoxAlloc(2);
        try pre.append(self.allocator, box[0]);
        try pre.append(self.allocator, box[1]);

        // delete(bucket, key_ptr, key_len, del_ret)
        var del_args = [_]c.BinaryenExpressionRef{
            c.BinaryenGlobalGet(m, bucket_global, self.i32_type),
            self.ptrGet(self.kv_a_idx),
            self.ptrGet(self.kv_b_idx),
            self.kvI32(del_ret),
        };
        try pre.append(self.allocator, c.BinaryenCall(m, delete_import, @ptrCast(&del_args), del_args.len, self.none_type));

        const disc = c.BinaryenUnary(m, c.BinaryenExtendUInt32(), c.BinaryenLoad(m, 1, false, 0, 1, self.i32_type, self.kvI32(del_ret), "0"));
        try pre.append(self.allocator, c.BinaryenStore(m, 8, 0, 0, self.ptrGet(self.kv_hdr_idx), disc, self.i64_type, "0"));
        try pre.append(self.allocator, c.BinaryenStore(m, 8, 8, 0, self.ptrGet(self.kv_hdr_idx), c.BinaryenConst(m, c.BinaryenLiteralInt64(0)), self.i64_type, "0"));
        try pre.append(self.allocator, self.ptrGet(self.kv_hdr_idx));
        return c.BinaryenBlock(m, null, @ptrCast(pre.items.ptr), @intCast(pre.items.len), self.ptr_type);
    }

    /// `env.kv.get(key)` lowered to the canonical `wasi:keyvalue` ABI: lazy-open
    /// the bucket, call `[method]bucket.get(bucket, key, ret)`, and box the
    /// host's `result<option<list<u8>>, error>` as a nested
    /// `Result<Option<Bytes>, IoError>`. The return area (16B) holds: result
    /// disc @0, option disc @4, list ptr @8, list len @12. Outer box (Result,
    /// `{ #tag, #p0 }`): tag 0 = `Ok`, #p0 = pointer to the inner Option box;
    /// tag 1 = `Err`. Inner box (Option<Bytes>, `{ #tag, #p0, #p1 }`): tag 0 =
    /// `Some`, #p0/#p1 = the value (ptr, len); tag 1 = `None`. Yields the outer
    /// box pointer. (Consumed by nested `Ok(Some(v))` / `Ok(None)` matching.)
    fn storeComponentGet(self: *Lowerer, key: *const ir.mir.Inst, get_import: [*:0]const u8, handle_global: ?[*:0]const u8, open_import: ?[*:0]const u8) Error!c.BinaryenExpressionRef {
        const m = self.module;
        const get_ret: i32 = @intCast(self.kv_inc_ret);

        var pre: std.ArrayList(c.BinaryenExpressionRef) = .empty;
        defer pre.deinit(self.allocator);
        // Handle-backed stores (kv/blob/db) lazily open a handle; a top-level
        // interface function (env.config.get) has no handle — skip the open.
        if (handle_global) |hg| try pre.append(self.allocator, self.storeLazyOpen(open_import.?, hg));

        // key → pair; stash (ptr,len) in kv_a/kv_b so the arena bump for the two
        // boxes below can't clobber a pair-local read.
        try pre.append(self.allocator, c.BinaryenLocalSet(m, self.pair_idx, try self.inst(key)));
        try pre.append(self.allocator, c.BinaryenLocalSet(m, self.kv_a_idx, c.BinaryenTupleExtract(m, c.BinaryenLocalGet(m, self.pair_idx, self.pair_type), 0)));
        try pre.append(self.allocator, c.BinaryenLocalSet(m, self.kv_b_idx, c.BinaryenTupleExtract(m, c.BinaryenLocalGet(m, self.pair_idx, self.pair_type), 1)));

        // get([handle,] key_ptr, key_len, get_ret) — handle omitted for config.
        if (handle_global) |hg| {
            var get_args = [_]c.BinaryenExpressionRef{
                c.BinaryenGlobalGet(m, hg, self.i32_type),
                self.ptrGet(self.kv_a_idx),
                self.ptrGet(self.kv_b_idx),
                self.kvI32(get_ret),
            };
            try pre.append(self.allocator, c.BinaryenCall(m, get_import, @ptrCast(&get_args), get_args.len, self.none_type));
        } else {
            var get_args = [_]c.BinaryenExpressionRef{
                self.ptrGet(self.kv_a_idx),
                self.ptrGet(self.kv_b_idx),
                self.kvI32(get_ret),
            };
            try pre.append(self.allocator, c.BinaryenCall(m, get_import, @ptrCast(&get_args), get_args.len, self.none_type));
        }

        // Inner Option box (3 cells) at kv_hdr; stash its address in kv_a.
        const inner = self.kvBoxAlloc(3);
        try pre.append(self.allocator, inner[0]);
        try pre.append(self.allocator, inner[1]);
        try pre.append(self.allocator, c.BinaryenLocalSet(m, self.kv_a_idx, self.ptrGet(self.kv_hdr_idx)));
        // option disc @4 == 1 → Some(ptr@8, len@12); else None.
        const some = c.BinaryenBinary(m, c.BinaryenEqInt32(), c.BinaryenLoad(m, 1, false, 4, 1, self.i32_type, self.kvI32(get_ret), "0"), self.kvI32(1));
        var some_seq = [_]c.BinaryenExpressionRef{
            c.BinaryenStore(m, 8, 0, 0, self.ptrGet(self.kv_a_idx), c.BinaryenConst(m, c.BinaryenLiteralInt64(0)), self.i64_type, "0"),
            c.BinaryenStore(m, 8, 8, 0, self.ptrGet(self.kv_a_idx), self.toI64(c.BinaryenLoad(m, 4, false, 8, 4, self.i32_type, self.kvI32(get_ret), "0")), self.i64_type, "0"),
            c.BinaryenStore(m, 8, 16, 0, self.ptrGet(self.kv_a_idx), self.toI64(c.BinaryenLoad(m, 4, false, 12, 4, self.i32_type, self.kvI32(get_ret), "0")), self.i64_type, "0"),
        };
        var none_seq = [_]c.BinaryenExpressionRef{
            c.BinaryenStore(m, 8, 0, 0, self.ptrGet(self.kv_a_idx), c.BinaryenConst(m, c.BinaryenLiteralInt64(1)), self.i64_type, "0"),
        };
        try pre.append(self.allocator, c.BinaryenIf(
            m,
            some,
            c.BinaryenBlock(m, null, @ptrCast(&some_seq), some_seq.len, self.none_type),
            c.BinaryenBlock(m, null, @ptrCast(&none_seq), none_seq.len, self.none_type),
        ));

        // Outer Result box (2 cells) at kv_hdr; stash its address in kv_b.
        const outer = self.kvBoxAlloc(2);
        try pre.append(self.allocator, outer[0]);
        try pre.append(self.allocator, outer[1]);
        try pre.append(self.allocator, c.BinaryenLocalSet(m, self.kv_b_idx, self.ptrGet(self.kv_hdr_idx)));
        // result disc @0 == 0 → Ok(inner ptr); else Err (code 0, unread).
        const ok = c.BinaryenBinary(m, c.BinaryenEqInt32(), c.BinaryenLoad(m, 1, false, 0, 1, self.i32_type, self.kvI32(get_ret), "0"), self.kvI32(0));
        var ok_seq = [_]c.BinaryenExpressionRef{
            c.BinaryenStore(m, 8, 0, 0, self.ptrGet(self.kv_b_idx), c.BinaryenConst(m, c.BinaryenLiteralInt64(0)), self.i64_type, "0"),
            c.BinaryenStore(m, 8, 8, 0, self.ptrGet(self.kv_b_idx), self.toI64(self.ptrGet(self.kv_a_idx)), self.i64_type, "0"),
        };
        var err_seq = [_]c.BinaryenExpressionRef{
            c.BinaryenStore(m, 8, 0, 0, self.ptrGet(self.kv_b_idx), c.BinaryenConst(m, c.BinaryenLiteralInt64(1)), self.i64_type, "0"),
            c.BinaryenStore(m, 8, 8, 0, self.ptrGet(self.kv_b_idx), c.BinaryenConst(m, c.BinaryenLiteralInt64(0)), self.i64_type, "0"),
        };
        try pre.append(self.allocator, c.BinaryenIf(
            m,
            ok,
            c.BinaryenBlock(m, null, @ptrCast(&ok_seq), ok_seq.len, self.none_type),
            c.BinaryenBlock(m, null, @ptrCast(&err_seq), err_seq.len, self.none_type),
        ));
        try pre.append(self.allocator, self.ptrGet(self.kv_b_idx));
        return c.BinaryenBlock(m, null, @ptrCast(pre.items.ptr), @intCast(pre.items.len), self.ptr_type);
    }

    /// `env.db.execute(sql)` lowered to the q64:db ABI: lazy-open the connection,
    /// call `exec_import(conn, sql, ret)`, and box the host's `result<u64, error>`
    /// as `Result<u64, IoError>` (`{ #tag, #p0 }`, 2 cells): #tag = result disc
    /// (0 = Ok, 1 = Err), #p0 = the rows-affected u64 (the `Ok(rows)` payload;
    /// the Err arm ignores it). Yields the box pointer.
    fn storeComponentExec(self: *Lowerer, sql: *const ir.mir.Inst, exec_import: [*:0]const u8, conn_global: [*:0]const u8, open_import: [*:0]const u8) Error!c.BinaryenExpressionRef {
        const m = self.module;
        const exec_ret: i32 = @intCast(self.kv_inc_ret);

        var pre: std.ArrayList(c.BinaryenExpressionRef) = .empty;
        defer pre.deinit(self.allocator);
        try pre.append(self.allocator, self.storeLazyOpen(open_import, conn_global));

        // sql → stash (ptr, len) in kv_a/kv_b before reserving the box.
        try pre.append(self.allocator, c.BinaryenLocalSet(m, self.pair_idx, try self.inst(sql)));
        try pre.append(self.allocator, c.BinaryenLocalSet(m, self.kv_a_idx, c.BinaryenTupleExtract(m, c.BinaryenLocalGet(m, self.pair_idx, self.pair_type), 0)));
        try pre.append(self.allocator, c.BinaryenLocalSet(m, self.kv_b_idx, c.BinaryenTupleExtract(m, c.BinaryenLocalGet(m, self.pair_idx, self.pair_type), 1)));

        const box = self.kvBoxAlloc(2);
        try pre.append(self.allocator, box[0]);
        try pre.append(self.allocator, box[1]);

        // exec(conn, sql_ptr, sql_len, exec_ret)
        var exec_args = [_]c.BinaryenExpressionRef{
            c.BinaryenGlobalGet(m, conn_global, self.i32_type),
            self.ptrGet(self.kv_a_idx),
            self.ptrGet(self.kv_b_idx),
            self.kvI32(exec_ret),
        };
        try pre.append(self.allocator, c.BinaryenCall(m, exec_import, @ptrCast(&exec_args), exec_args.len, self.none_type));

        // Box: #tag = (i64) result-disc; #p0 = the u64 rows-affected (Ok payload).
        // result<u64,error> is 8-aligned, so the u64 lands at ret+8.
        const disc = c.BinaryenUnary(m, c.BinaryenExtendUInt32(), c.BinaryenLoad(m, 1, false, 0, 1, self.i32_type, self.kvI32(exec_ret), "0"));
        try pre.append(self.allocator, c.BinaryenStore(m, 8, 0, 0, self.ptrGet(self.kv_hdr_idx), disc, self.i64_type, "0"));
        try pre.append(self.allocator, c.BinaryenStore(m, 8, 8, 0, self.ptrGet(self.kv_hdr_idx), c.BinaryenLoad(m, 8, false, 8, 8, self.i64_type, self.kvI32(exec_ret), "0"), self.i64_type, "0"));
        try pre.append(self.allocator, self.ptrGet(self.kv_hdr_idx));
        return c.BinaryenBlock(m, null, @ptrCast(pre.items.ptr), @intCast(pre.items.len), self.ptr_type);
    }

    /// `env.db.query_value(sql)` lowered to the q64:db ABI: lazy-open, call
    /// `qv_import(conn, sql, ret)`, and box the host's `result<option<s64>,
    /// error>` as a nested `Result<Option<i64>, IoError>`. Unlike `query_text` /
    /// bucket.get (whose `option<list<u8>>` is 4-aligned → option-disc @4, ptr@8,
    /// len@12), `option<s64>` is 8-ALIGNED, so the return area is: result-disc
    /// @0, option-disc @8, s64 @16 (24 bytes). Inner Option box is 2 cells
    /// (`{ #tag, #p0=value }`); outer Result box 2 cells. Consumed by nested
    /// `Ok(Some(n))` / `Ok(None)` matching (n is an i64).
    fn storeComponentQueryValue(self: *Lowerer, sql: *const ir.mir.Inst, qv_import: [*:0]const u8, conn_global: [*:0]const u8, open_import: [*:0]const u8) Error!c.BinaryenExpressionRef {
        const m = self.module;
        const qv_ret: i32 = @intCast(self.kv_inc_ret);

        var pre: std.ArrayList(c.BinaryenExpressionRef) = .empty;
        defer pre.deinit(self.allocator);
        try pre.append(self.allocator, self.storeLazyOpen(open_import, conn_global));

        try pre.append(self.allocator, c.BinaryenLocalSet(m, self.pair_idx, try self.inst(sql)));
        try pre.append(self.allocator, c.BinaryenLocalSet(m, self.kv_a_idx, c.BinaryenTupleExtract(m, c.BinaryenLocalGet(m, self.pair_idx, self.pair_type), 0)));
        try pre.append(self.allocator, c.BinaryenLocalSet(m, self.kv_b_idx, c.BinaryenTupleExtract(m, c.BinaryenLocalGet(m, self.pair_idx, self.pair_type), 1)));

        // query-value(conn, sql_ptr, sql_len, qv_ret)
        var qv_args = [_]c.BinaryenExpressionRef{
            c.BinaryenGlobalGet(m, conn_global, self.i32_type),
            self.ptrGet(self.kv_a_idx),
            self.ptrGet(self.kv_b_idx),
            self.kvI32(qv_ret),
        };
        try pre.append(self.allocator, c.BinaryenCall(m, qv_import, @ptrCast(&qv_args), qv_args.len, self.none_type));

        // Inner Option box (2 cells) at kv_hdr; stash its address in kv_a.
        const inner = self.kvBoxAlloc(2);
        try pre.append(self.allocator, inner[0]);
        try pre.append(self.allocator, inner[1]);
        try pre.append(self.allocator, c.BinaryenLocalSet(m, self.kv_a_idx, self.ptrGet(self.kv_hdr_idx)));
        // option disc @8 == 1 → Some(s64 @16); else None. (8-aligned option.)
        const some = c.BinaryenBinary(m, c.BinaryenEqInt32(), c.BinaryenLoad(m, 1, false, 8, 1, self.i32_type, self.kvI32(qv_ret), "0"), self.kvI32(1));
        var some_seq = [_]c.BinaryenExpressionRef{
            c.BinaryenStore(m, 8, 0, 0, self.ptrGet(self.kv_a_idx), c.BinaryenConst(m, c.BinaryenLiteralInt64(0)), self.i64_type, "0"),
            c.BinaryenStore(m, 8, 8, 0, self.ptrGet(self.kv_a_idx), c.BinaryenLoad(m, 8, false, 16, 8, self.i64_type, self.kvI32(qv_ret), "0"), self.i64_type, "0"),
        };
        var none_seq = [_]c.BinaryenExpressionRef{
            c.BinaryenStore(m, 8, 0, 0, self.ptrGet(self.kv_a_idx), c.BinaryenConst(m, c.BinaryenLiteralInt64(1)), self.i64_type, "0"),
        };
        try pre.append(self.allocator, c.BinaryenIf(
            m,
            some,
            c.BinaryenBlock(m, null, @ptrCast(&some_seq), some_seq.len, self.none_type),
            c.BinaryenBlock(m, null, @ptrCast(&none_seq), none_seq.len, self.none_type),
        ));

        // Outer Result box (2 cells) at kv_hdr; stash its address in kv_b.
        const outer = self.kvBoxAlloc(2);
        try pre.append(self.allocator, outer[0]);
        try pre.append(self.allocator, outer[1]);
        try pre.append(self.allocator, c.BinaryenLocalSet(m, self.kv_b_idx, self.ptrGet(self.kv_hdr_idx)));
        // result disc @0 == 0 → Ok(inner ptr); else Err.
        const ok = c.BinaryenBinary(m, c.BinaryenEqInt32(), c.BinaryenLoad(m, 1, false, 0, 1, self.i32_type, self.kvI32(qv_ret), "0"), self.kvI32(0));
        var ok_seq = [_]c.BinaryenExpressionRef{
            c.BinaryenStore(m, 8, 0, 0, self.ptrGet(self.kv_b_idx), c.BinaryenConst(m, c.BinaryenLiteralInt64(0)), self.i64_type, "0"),
            c.BinaryenStore(m, 8, 8, 0, self.ptrGet(self.kv_b_idx), self.toI64(self.ptrGet(self.kv_a_idx)), self.i64_type, "0"),
        };
        var err_seq = [_]c.BinaryenExpressionRef{
            c.BinaryenStore(m, 8, 0, 0, self.ptrGet(self.kv_b_idx), c.BinaryenConst(m, c.BinaryenLiteralInt64(1)), self.i64_type, "0"),
            c.BinaryenStore(m, 8, 8, 0, self.ptrGet(self.kv_b_idx), c.BinaryenConst(m, c.BinaryenLiteralInt64(0)), self.i64_type, "0"),
        };
        try pre.append(self.allocator, c.BinaryenIf(
            m,
            ok,
            c.BinaryenBlock(m, null, @ptrCast(&ok_seq), ok_seq.len, self.none_type),
            c.BinaryenBlock(m, null, @ptrCast(&err_seq), err_seq.len, self.none_type),
        ));
        try pre.append(self.allocator, self.ptrGet(self.kv_b_idx));
        return c.BinaryenBlock(m, null, @ptrCast(pre.items.ptr), @intCast(pre.items.len), self.ptr_type);
    }

    /// `env.db.query_one<Row>(sql)` lowered to the q64:db ABI: lazy-open, call
    /// `qo_import(conn, sql, ret)`, and box the host's `result<option<list<s64>>,
    /// error>` as a nested `Result<Option<Row>, IoError>`. The canonical return
    /// layout is result-disc @0, option-disc @4, list-ptr @8, list-len @12 —
    /// identical to a store `bucket.get` (`list<s64>` and `list<u8>` share the
    /// `{ptr,len}` shape). The row decodes ZERO-COPY: the inner `Some`'s single
    /// payload cell holds the list POINTER, and the contiguous `s64`s at it ARE
    /// the all-`i64` record's fields, so `resolveRecArm` reads `#p0` as the
    /// record base. `list-len` (the column count) is unread — the guest trusts
    /// the row struct's field count (the WIT contract binds the SELECT to it).
    /// Inner Option box 2 cells (`{ #tag, #p0=record-ptr }`); outer Result box 2
    /// cells. Consumed by nested `Ok(Some(row))` / `Ok(None)` matching.
    fn storeComponentQueryOne(self: *Lowerer, sql: *const ir.mir.Inst, qo_import: [*:0]const u8, conn_global: [*:0]const u8, open_import: [*:0]const u8) Error!c.BinaryenExpressionRef {
        const m = self.module;
        const qo_ret: i32 = @intCast(self.kv_inc_ret);

        var pre: std.ArrayList(c.BinaryenExpressionRef) = .empty;
        defer pre.deinit(self.allocator);
        try pre.append(self.allocator, self.storeLazyOpen(open_import, conn_global));

        try pre.append(self.allocator, c.BinaryenLocalSet(m, self.pair_idx, try self.inst(sql)));
        try pre.append(self.allocator, c.BinaryenLocalSet(m, self.kv_a_idx, c.BinaryenTupleExtract(m, c.BinaryenLocalGet(m, self.pair_idx, self.pair_type), 0)));
        try pre.append(self.allocator, c.BinaryenLocalSet(m, self.kv_b_idx, c.BinaryenTupleExtract(m, c.BinaryenLocalGet(m, self.pair_idx, self.pair_type), 1)));

        // query-one(conn, sql_ptr, sql_len, qo_ret)
        var qo_args = [_]c.BinaryenExpressionRef{
            c.BinaryenGlobalGet(m, conn_global, self.i32_type),
            self.ptrGet(self.kv_a_idx),
            self.ptrGet(self.kv_b_idx),
            self.kvI32(qo_ret),
        };
        try pre.append(self.allocator, c.BinaryenCall(m, qo_import, @ptrCast(&qo_args), qo_args.len, self.none_type));

        // Inner Option box (2 cells) at kv_hdr; stash its address in kv_a.
        const inner = self.kvBoxAlloc(2);
        try pre.append(self.allocator, inner[0]);
        try pre.append(self.allocator, inner[1]);
        try pre.append(self.allocator, c.BinaryenLocalSet(m, self.kv_a_idx, self.ptrGet(self.kv_hdr_idx)));
        // option disc @4 == 1 → Some(#p0 = record ptr = list ptr @8); else None.
        // (4-aligned option, like bucket.get — NOT query_value's 8-aligned option.)
        const some = c.BinaryenBinary(m, c.BinaryenEqInt32(), c.BinaryenLoad(m, 1, false, 4, 1, self.i32_type, self.kvI32(qo_ret), "0"), self.kvI32(1));
        var some_seq = [_]c.BinaryenExpressionRef{
            c.BinaryenStore(m, 8, 0, 0, self.ptrGet(self.kv_a_idx), c.BinaryenConst(m, c.BinaryenLiteralInt64(0)), self.i64_type, "0"),
            c.BinaryenStore(m, 8, 8, 0, self.ptrGet(self.kv_a_idx), self.toI64(c.BinaryenLoad(m, 4, false, 8, 4, self.i32_type, self.kvI32(qo_ret), "0")), self.i64_type, "0"),
        };
        var none_seq = [_]c.BinaryenExpressionRef{
            c.BinaryenStore(m, 8, 0, 0, self.ptrGet(self.kv_a_idx), c.BinaryenConst(m, c.BinaryenLiteralInt64(1)), self.i64_type, "0"),
        };
        try pre.append(self.allocator, c.BinaryenIf(
            m,
            some,
            c.BinaryenBlock(m, null, @ptrCast(&some_seq), some_seq.len, self.none_type),
            c.BinaryenBlock(m, null, @ptrCast(&none_seq), none_seq.len, self.none_type),
        ));

        // Outer Result box (2 cells) at kv_hdr; stash its address in kv_b.
        const outer = self.kvBoxAlloc(2);
        try pre.append(self.allocator, outer[0]);
        try pre.append(self.allocator, outer[1]);
        try pre.append(self.allocator, c.BinaryenLocalSet(m, self.kv_b_idx, self.ptrGet(self.kv_hdr_idx)));
        // result disc @0 == 0 → Ok(inner option ptr); else Err.
        const ok = c.BinaryenBinary(m, c.BinaryenEqInt32(), c.BinaryenLoad(m, 1, false, 0, 1, self.i32_type, self.kvI32(qo_ret), "0"), self.kvI32(0));
        var ok_seq = [_]c.BinaryenExpressionRef{
            c.BinaryenStore(m, 8, 0, 0, self.ptrGet(self.kv_b_idx), c.BinaryenConst(m, c.BinaryenLiteralInt64(0)), self.i64_type, "0"),
            c.BinaryenStore(m, 8, 8, 0, self.ptrGet(self.kv_b_idx), self.toI64(self.ptrGet(self.kv_a_idx)), self.i64_type, "0"),
        };
        var err_seq = [_]c.BinaryenExpressionRef{
            c.BinaryenStore(m, 8, 0, 0, self.ptrGet(self.kv_b_idx), c.BinaryenConst(m, c.BinaryenLiteralInt64(1)), self.i64_type, "0"),
            c.BinaryenStore(m, 8, 8, 0, self.ptrGet(self.kv_b_idx), c.BinaryenConst(m, c.BinaryenLiteralInt64(0)), self.i64_type, "0"),
        };
        try pre.append(self.allocator, c.BinaryenIf(
            m,
            ok,
            c.BinaryenBlock(m, null, @ptrCast(&ok_seq), ok_seq.len, self.none_type),
            c.BinaryenBlock(m, null, @ptrCast(&err_seq), err_seq.len, self.none_type),
        ));
        try pre.append(self.allocator, self.ptrGet(self.kv_b_idx));
        return c.BinaryenBlock(m, null, @ptrCast(pre.items.ptr), @intCast(pre.items.len), self.ptr_type);
    }

    /// `env.exit(code)` lowered per the build's host ABI: a raw `env.exit(code)`
    /// call (the i64 code), or WASI preview1 `proc_exit(code)` with the code
    /// wrapped to i32. Void — the host terminates the instance.
    fn envExit(self: *Lowerer, code_expr: c.BinaryenExpressionRef) c.BinaryenExpressionRef {
        const m = self.module;
        return switch (self.stdout_abi) {
            .env_out => blk: {
                var args = [_]c.BinaryenExpressionRef{code_expr};
                break :blk c.BinaryenCall(m, "env_exit", @ptrCast(&args), args.len, self.none_type);
            },
            .wasi_preview1 => blk: {
                // proc_exit takes an i32 code; the source value is i64.
                const code32 = c.BinaryenUnary(m, c.BinaryenWrapInt64(), code_expr);
                var args = [_]c.BinaryenExpressionRef{code32};
                break :blk c.BinaryenCall(m, "proc_exit", @ptrCast(&args), args.len, self.none_type);
            },
        };
    }

    /// Emit a single write of the `(ptr, len)` pair to `stream`, lowered per the
    /// build's `StdoutAbi`: a direct `env.out`/`env.err(ptr, len)` call, or a
    /// WASI `fd_write` of one iovec to fd 1 (stdout) / fd 2 (stderr).
    fn writeStream(self: *Lowerer, stream: ir.mir.Stream, ptr_expr: c.BinaryenExpressionRef, len_expr: c.BinaryenExpressionRef) c.BinaryenExpressionRef {
        return switch (self.stdout_abi) {
            .env_out => blk: {
                var args = [_]c.BinaryenExpressionRef{ ptr_expr, len_expr };
                const face = switch (stream) {
                    .out => "env_out",
                    .err => "env_err",
                };
                break :blk c.BinaryenCall(self.module, face, @ptrCast(&args), args.len, self.none_type);
            },
            .wasi_preview1 => self.fdWrite(stream, ptr_expr, len_expr),
        };
    }

    /// WASI preview1 byte write: assemble an iovec `{buf: ptr, len}` at the
    /// reserved scratch address and `fd_write(fd, iovec, 1, nwritten)`, dropping
    /// the errno. `fd` is 1 (stdout) or 2 (stderr). The preview1 ABI is 32-bit,
    /// so addresses/values are i32.
    fn fdWrite(self: *Lowerer, stream: ir.mir.Stream, ptr_expr: c.BinaryenExpressionRef, len_expr: c.BinaryenExpressionRef) c.BinaryenExpressionRef {
        const m = self.module;
        const i32c = struct {
            fn f(mod: c.BinaryenModuleRef, v: i32) c.BinaryenExpressionRef {
                return c.BinaryenConst(mod, c.BinaryenLiteralInt32(v));
            }
        }.f;
        const fd: i32 = switch (stream) {
            .out => 1,
            .err => 2,
        };
        const base: i32 = @intCast(self.iovec_base);
        var call_args = [_]c.BinaryenExpressionRef{
            i32c(m, fd), // fd 1 = stdout, fd 2 = stderr
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

    /// Preview1 clock read: `clock_time_get(clockid, 1, p1_ts_base)`, errno
    /// dropped, then load the u64 the host wrote into the shared cell.
    /// clockid 1 = monotonic (`monotonic_ns`), 0 = realtime (`unix_ns` —
    /// preview1's realtime clock is already ns since the Unix epoch).
    fn p1ClockTime(self: *Lowerer, clockid: i32) c.BinaryenExpressionRef {
        const m = self.module;
        const i32c = struct {
            fn f(mod: c.BinaryenModuleRef, v: i32) c.BinaryenExpressionRef {
                return c.BinaryenConst(mod, c.BinaryenLiteralInt32(v));
            }
        }.f;
        var call_args = [_]c.BinaryenExpressionRef{
            i32c(m, clockid),
            c.BinaryenConst(m, c.BinaryenLiteralInt64(1)), // precision hint: 1 ns
            i32c(m, @intCast(self.p1_ts_base)),
        };
        var seq = [_]c.BinaryenExpressionRef{
            c.BinaryenDrop(m, c.BinaryenCall(m, "clock_time_get", @ptrCast(&call_args), call_args.len, self.i32_type)),
            c.BinaryenLoad(m, 8, false, 0, 0, self.i64_type, i32c(m, @intCast(self.p1_ts_base)), "0"),
        };
        return c.BinaryenBlock(m, null, @ptrCast(&seq), seq.len, self.i64_type);
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
    // Narrow an i64 value to the address width (identity on wasm64, wrap on
    // wasm32) — for using an i64 index/bound in pointer arithmetic.
    fn toPtr(self: *Lowerer, v: c.BinaryenExpressionRef) c.BinaryenExpressionRef {
        return if (self.ptr_type == self.i64_type) v else c.BinaryenUnary(self.module, c.BinaryenWrapInt64(), v);
    }

    /// The group bounds check + element address for an inline v128 vec
    /// access: `check` traps when `bounds_idx + 4 > len` (unsigned — a
    /// negative index also traps), `slot` is `data + bounds_idx * 4`.
    /// Caller must have stored the index into `bounds_idx` first; `vec`
    /// must be a local (re-evaluated for the two header loads).
    fn simdVecAddr(self: *Lowerer, vec: *const ir.mir.Inst) !struct { check: c.BinaryenExpressionRef, slot: c.BinaryenExpressionRef } {
        const m = self.module;
        const W: u32 = if (self.ptr_type == self.i64_type) 8 else 4;
        const shl = if (self.ptr_type == self.i64_type) c.BinaryenShlInt64() else c.BinaryenShlInt32();
        const len = self.toI64(c.BinaryenLoad(m, W, false, W, 0, self.ptr_type, try self.inst(vec), "0"));
        const end = c.BinaryenBinary(m, c.BinaryenAddInt64(), c.BinaryenLocalGet(m, self.bounds_idx, self.i64_type), c.BinaryenConst(m, c.BinaryenLiteralInt64(4)));
        const check = c.BinaryenIf(m, c.BinaryenBinary(m, c.BinaryenGtUInt64(), end, len), c.BinaryenUnreachable(m), null);
        const data = c.BinaryenLoad(m, W, false, 0, 0, self.ptr_type, try self.inst(vec), "0");
        const slot = self.ptrAdd(data, c.BinaryenBinary(m, shl, self.toPtr(c.BinaryenLocalGet(m, self.bounds_idx, self.i64_type)), self.ptrConst(2)));
        return .{ .check = check, .slot = slot };
    }

    // ---- Frame reclamation (spec/memory.md §"Frame reclamation") ----

    /// The watermark local for region-nesting level `d`.
    fn wmIdx(self: *const Lowerer, d: u32) c.BinaryenIndex {
        return self.region_base + d * 8;
    }
    /// The result-stash local of value type `t` at level `d`.
    fn stashIdx(self: *const Lowerer, d: u32, t: ir.mir.ValueType) c.BinaryenIndex {
        const off: c.BinaryenIndex = switch (t) {
            .i64 => 1,
            .i32 => 2,
            .f64 => 3,
            .f32 => 4,
            .str => 5,
            .ptr => 6,
            .v128 => 7,
            .void => unreachable,
        };
        return self.region_base + d * 8 + off;
    }

    /// Wrap a host statement: save the watermark, run it, restore `sp` —
    /// the host consumed the bytes within the statement.
    fn resetAfter(self: *Lowerer, d: u32, inner: c.BinaryenExpressionRef) c.BinaryenExpressionRef {
        const m = self.module;
        var seq = [_]c.BinaryenExpressionRef{
            c.BinaryenLocalSet(m, self.wmIdx(d), c.BinaryenGlobalGet(m, "sp", self.ptr_type)),
            inner,
            c.BinaryenGlobalSet(m, "sp", self.ptrGet(self.wmIdx(d))),
        };
        return c.BinaryenBlock(m, null, @ptrCast(&seq), seq.len, self.none_type);
    }

    /// Wrap a call: watermark before the arguments evaluate (the save is
    /// the block's first child; the operands evaluate inside `callex`),
    /// then slide the result down onto it. A scalar result lives in a
    /// wasm local, so the frame just restores; an aggregate's bytes are
    /// copied down (memory.copy is memmove — the overlapping downward
    /// slide is safe) and `sp` advances past exactly the result.
    fn slideCall(self: *Lowerer, d: u32, ty: ir.mir.ValueType, ret_size: u32, callex: c.BinaryenExpressionRef) c.BinaryenExpressionRef {
        const m = self.module;
        const wm = self.wmIdx(d);
        const sp_now = c.BinaryenGlobalGet(m, "sp", self.ptr_type);
        switch (ty) {
            .void => {
                var seq = [_]c.BinaryenExpressionRef{
                    c.BinaryenLocalSet(m, wm, sp_now),
                    callex,
                    c.BinaryenGlobalSet(m, "sp", self.ptrGet(wm)),
                };
                return c.BinaryenBlock(m, null, @ptrCast(&seq), seq.len, self.none_type);
            },
            .str => {
                // (ptr, len) → copy len bytes to the watermark, rebase.
                const stash = self.stashIdx(d, .str);
                const pget = c.BinaryenLocalGet(m, stash, self.pair_type);
                var seq = [_]c.BinaryenExpressionRef{
                    c.BinaryenLocalSet(m, wm, sp_now),
                    c.BinaryenLocalSet(m, stash, callex),
                    c.BinaryenMemoryCopy(m, self.ptrGet(wm), c.BinaryenTupleExtract(m, pget, 0), c.BinaryenTupleExtract(m, c.BinaryenLocalGet(m, stash, self.pair_type), 1), "0", "0"),
                    c.BinaryenGlobalSet(m, "sp", self.ptrAdd(self.ptrGet(wm), c.BinaryenTupleExtract(m, c.BinaryenLocalGet(m, stash, self.pair_type), 1))),
                    blk: {
                        var elems = [_]c.BinaryenExpressionRef{
                            self.ptrGet(wm),
                            c.BinaryenTupleExtract(m, c.BinaryenLocalGet(m, stash, self.pair_type), 1),
                        };
                        break :blk c.BinaryenTupleMake(m, @ptrCast(&elems), elems.len);
                    },
                };
                return c.BinaryenBlock(m, null, @ptrCast(&seq), seq.len, self.pair_type);
            },
            .ptr => {
                // A record/boxed-enum base pointer: copy `ret_size` bytes to
                // the 8-aligned watermark (≥ any v0 struct alignment).
                if (ret_size == 0) {
                    // No size known (shouldn't happen for a ptr return):
                    // restore only, keeping the result above sp is unsound —
                    // so don't reclaim at all.
                    return callex;
                }
                const stash = self.stashIdx(d, .ptr);
                var seq = [_]c.BinaryenExpressionRef{
                    c.BinaryenLocalSet(m, wm, self.ptrAnd(self.ptrAdd(sp_now, self.ptrConst(7)), self.ptrConst(-8))),
                    c.BinaryenLocalSet(m, stash, callex),
                    c.BinaryenMemoryCopy(m, self.ptrGet(wm), self.ptrGet(stash), self.ptrConst(ret_size), "0", "0"),
                    c.BinaryenGlobalSet(m, "sp", self.ptrAdd(self.ptrGet(wm), self.ptrConst(ret_size))),
                    self.ptrGet(wm),
                };
                return c.BinaryenBlock(m, null, @ptrCast(&seq), seq.len, self.ptr_type);
            },
            else => {
                // A scalar result: stash it, restore, yield.
                const stash = self.stashIdx(d, ty);
                var seq = [_]c.BinaryenExpressionRef{
                    c.BinaryenLocalSet(m, wm, sp_now),
                    c.BinaryenLocalSet(m, stash, callex),
                    c.BinaryenGlobalSet(m, "sp", self.ptrGet(wm)),
                    c.BinaryenLocalGet(m, stash, self.wty(ty)),
                };
                return c.BinaryenBlock(m, null, @ptrCast(&seq), seq.len, self.wty(ty));
            },
        }
    }

    /// Write a `(ptr, len)` pair value to `stream`, then the newline byte: stash
    /// the pair in the scratch local, extract both halves, write them, then
    /// write `(nl, 1)`. The value and its newline go to the same stream.
    fn hostWritePair(self: *Lowerer, stream: ir.mir.Stream, pair: c.BinaryenExpressionRef, nl_off: i64) c.BinaryenExpressionRef {
        const module = self.module;
        var seq = [_]c.BinaryenExpressionRef{
            c.BinaryenLocalSet(module, self.pair_idx, pair),
            self.writeStream(
                stream,
                c.BinaryenTupleExtract(module, c.BinaryenLocalGet(module, self.pair_idx, self.pair_type), 0),
                c.BinaryenTupleExtract(module, c.BinaryenLocalGet(module, self.pair_idx, self.pair_type), 1),
            ),
            self.envWrite(stream, nl_off, 1),
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
            .call, .fmt_int_to_str, .fmt_float_to_str => {
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
            .call, .fmt_int_to_str, .fmt_float_to_str => {
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
                .call, .fmt_int_to_str, .fmt_float_to_str => {
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

    /// Materialize a record in the scope arena (spec/memory.md §"Linear
    /// struct layout"): align `sp` up to the struct alignment, bump-allocate
    /// `size` bytes with the base in this nesting level's scratch local,
    /// store each field at its offset, and yield the base pointer. Field
    /// values are emitted one level deeper so an inner record literal (via a
    /// call argument) gets its own base scratch.
    fn emitRecordMake(self: *Lowerer, rm: anytype) Error!c.BinaryenExpressionRef {
        const m = self.module;
        const ridx = self.rec_base + self.rec_level;
        var stmts: std.ArrayList(c.BinaryenExpressionRef) = .empty;
        defer stmts.deinit(self.allocator);

        // sp = (sp + align-1) & -align — concat allocations are unaligned, so
        // every record alloc re-aligns the bump pointer first.
        if (rm.alignment > 1) {
            const bumped = self.ptrAdd(c.BinaryenGlobalGet(m, "sp", self.ptr_type), self.ptrConst(rm.alignment - 1));
            const mask = self.ptrConst(-@as(i64, rm.alignment));
            try stmts.append(self.allocator, c.BinaryenGlobalSet(m, "sp", self.ptrAnd(bumped, mask)));
        }
        // base = sp; sp += size.
        try stmts.append(self.allocator, c.BinaryenLocalSet(m, ridx, c.BinaryenGlobalGet(m, "sp", self.ptr_type)));
        try stmts.append(self.allocator, c.BinaryenGlobalSet(m, "sp", self.ptrAdd(self.ptrGet(ridx), self.ptrConst(rm.size))));

        // Store each field (width per the value's type, like field_set).
        for (rm.inits) |fi| {
            self.rec_level += 1;
            const value = try self.inst(fi.value);
            self.rec_level -= 1;
            const store = switch (fi.value.ty) {
                .i64 => c.BinaryenStore(m, fi.width, fi.offset, 0, self.ptrGet(ridx), value, self.i64_type, "0"),
                // A record-payload cell: the base pointer, widened.
                .ptr => c.BinaryenStore(m, 8, fi.offset, 0, self.ptrGet(ridx), self.toI64(value), self.i64_type, "0"),
                .f64 => c.BinaryenStore(m, 8, fi.offset, 0, self.ptrGet(ridx), value, c.BinaryenTypeFloat64(), "0"),
                .f32 => c.BinaryenStore(m, 4, fi.offset, 0, self.ptrGet(ridx), value, c.BinaryenTypeFloat32(), "0"),
                .i32 => c.BinaryenStore(m, 1, fi.offset, 0, self.ptrGet(ridx), value, self.i32_type, "0"),
                else => return Error.UnsupportedCall,
            };
            try stmts.append(self.allocator, store);
        }

        // str payload cells: stash the (ptr, len) pair, store each half
        // widened to an 8-byte cell at offset / offset+8.
        for (rm.str_inits) |si| {
            self.rec_level += 1;
            const value = try self.inst(si.value);
            self.rec_level -= 1;
            try stmts.append(self.allocator, c.BinaryenLocalSet(m, self.pair_idx, value));
            const pp = c.BinaryenTupleExtract(m, c.BinaryenLocalGet(m, self.pair_idx, self.pair_type), 0);
            const ll = c.BinaryenTupleExtract(m, c.BinaryenLocalGet(m, self.pair_idx, self.pair_type), 1);
            try stmts.append(self.allocator, c.BinaryenStore(m, 8, si.offset, 0, self.ptrGet(ridx), self.toI64(pp), self.i64_type, "0"));
            try stmts.append(self.allocator, c.BinaryenStore(m, 8, si.offset + 8, 0, self.ptrGet(ridx), self.toI64(ll), self.i64_type, "0"));
        }

        try stmts.append(self.allocator, self.ptrGet(ridx));
        return c.BinaryenBlock(m, null, @ptrCast(stmts.items.ptr), @intCast(stmts.items.len), self.ptr_type);
    }

    /// Widen an address-width value to i64 (identity on wasm64).
    fn toI64(self: *Lowerer, v: c.BinaryenExpressionRef) c.BinaryenExpressionRef {
        return if (self.ptr_type == self.i64_type) v else c.BinaryenUnary(self.module, c.BinaryenExtendUInt32(), v);
    }

    /// Materialize an array literal in the scope arena (mirrors
    /// `emitRecordMake`, one slot per element): align `sp`, bump
    /// `count·stride` bytes with the base in this nesting level's scratch,
    /// then fill each slot — a scalar stores at its width, a record init
    /// (`copy_bytes`) memory.copys its bytes inline. Yields the base.
    fn emitArrayMake(self: *Lowerer, am: anytype) Error!c.BinaryenExpressionRef {
        const m = self.module;
        const ridx = self.rec_base + self.rec_level;
        var stmts: std.ArrayList(c.BinaryenExpressionRef) = .empty;
        defer stmts.deinit(self.allocator);

        if (am.alignment > 1) {
            const bumped = self.ptrAdd(c.BinaryenGlobalGet(m, "sp", self.ptr_type), self.ptrConst(am.alignment - 1));
            const mask = self.ptrConst(-@as(i64, am.alignment));
            try stmts.append(self.allocator, c.BinaryenGlobalSet(m, "sp", self.ptrAnd(bumped, mask)));
        }
        try stmts.append(self.allocator, c.BinaryenLocalSet(m, ridx, c.BinaryenGlobalGet(m, "sp", self.ptr_type)));
        const total: i64 = @as(i64, am.stride) * @as(i64, @intCast(am.inits.len));
        try stmts.append(self.allocator, c.BinaryenGlobalSet(m, "sp", self.ptrAdd(self.ptrGet(ridx), self.ptrConst(total))));

        for (am.inits, 0..) |init_v, i| {
            const slot_off: u32 = @intCast(@as(u64, am.stride) * i);
            self.rec_level += 1;
            const value = try self.inst(init_v);
            self.rec_level -= 1;
            if (am.copy_bytes) |nbytes| {
                // A record element: copy its bytes inline into the slot.
                const dest = self.ptrAdd(self.ptrGet(ridx), self.ptrConst(slot_off));
                try stmts.append(self.allocator, c.BinaryenMemoryCopy(m, dest, value, self.ptrConst(nbytes), "0", "0"));
            } else {
                const store = switch (init_v.ty) {
                    .i64 => c.BinaryenStore(m, am.elem_width, slot_off, 0, self.ptrGet(ridx), value, self.i64_type, "0"),
                    .f64 => c.BinaryenStore(m, 8, slot_off, 0, self.ptrGet(ridx), value, c.BinaryenTypeFloat64(), "0"),
                    .f32 => c.BinaryenStore(m, 4, slot_off, 0, self.ptrGet(ridx), value, c.BinaryenTypeFloat32(), "0"),
                    else => return Error.UnsupportedCall,
                };
                try stmts.append(self.allocator, store);
            }
        }

        try stmts.append(self.allocator, self.ptrGet(ridx));
        return c.BinaryenBlock(m, null, @ptrCast(stmts.items.ptr), @intCast(stmts.items.len), self.ptr_type);
    }

    /// A `[str]` literal: bump-allocate `count` consecutive `(ptr, len)` str
    /// cells (stride = two address-width words) in the scope arena, store each
    /// element's pair, and yield the `(base, count)` pair — the str-list value.
    /// `base` rides the rec-base scratch (like `emitArrayMake`); each element is
    /// stashed in the pair scratch so its two halves can be split out.
    fn emitStrlistMake(self: *Lowerer, inits: []const *const ir.mir.Inst) Error!c.BinaryenExpressionRef {
        const m = self.module;
        const w: u32 = if (self.ptr_type == self.i32_type) 4 else 8; // address width
        const stride: u32 = 2 * w; // (ptr, len) per element
        const ridx = self.rec_base + self.rec_level;
        var stmts: std.ArrayList(c.BinaryenExpressionRef) = .empty;
        defer stmts.deinit(self.allocator);

        // Align the bump pointer to the address width, then carve count·stride.
        const bumped = self.ptrAdd(c.BinaryenGlobalGet(m, "sp", self.ptr_type), self.ptrConst(@intCast(w - 1)));
        try stmts.append(self.allocator, c.BinaryenGlobalSet(m, "sp", self.ptrAnd(bumped, self.ptrConst(-@as(i64, w)))));
        try stmts.append(self.allocator, c.BinaryenLocalSet(m, ridx, c.BinaryenGlobalGet(m, "sp", self.ptr_type)));
        const total: i64 = @as(i64, stride) * @as(i64, @intCast(inits.len));
        try stmts.append(self.allocator, c.BinaryenGlobalSet(m, "sp", self.ptrAdd(self.ptrGet(ridx), self.ptrConst(total))));

        for (inits, 0..) |init_v, i| {
            const slot_off: u32 = @intCast(@as(u64, stride) * i);
            self.rec_level += 1;
            const pair = try self.inst(init_v);
            self.rec_level -= 1;
            // Stash the element's (ptr, len) pair, then store each half.
            try stmts.append(self.allocator, c.BinaryenLocalSet(m, self.pair_idx, pair));
            const eptr = c.BinaryenTupleExtract(m, c.BinaryenLocalGet(m, self.pair_idx, self.pair_type), 0);
            const elen = c.BinaryenTupleExtract(m, c.BinaryenLocalGet(m, self.pair_idx, self.pair_type), 1);
            try stmts.append(self.allocator, c.BinaryenStore(m, w, slot_off, 0, self.ptrGet(ridx), eptr, self.ptr_type, "0"));
            try stmts.append(self.allocator, c.BinaryenStore(m, w, slot_off + w, 0, self.ptrGet(ridx), elen, self.ptr_type, "0"));
        }

        // Yield the (data_ptr, count) pair.
        var elems = [_]c.BinaryenExpressionRef{ self.ptrGet(ridx), self.ptrConst(@intCast(inits.len)) };
        try stmts.append(self.allocator, c.BinaryenTupleMake(m, @ptrCast(&elems), elems.len));
        return c.BinaryenBlock(m, null, @ptrCast(stmts.items.ptr), @intCast(stmts.items.len), self.pair_type);
    }

    /// `xs[i]` on a `[str]` value: stash the `(data_ptr, count)` list pair and
    /// the index, trap unless `0 <= i < count` (unsigned compare), then load the
    /// i-th `(ptr, len)` cell as a str pair. Binaryen needs a tree (no shared
    /// refs), so each `data_ptr`/index read is rebuilt fresh from its local.
    fn emitStrlistGet(self: *Lowerer, g: anytype) Error!c.BinaryenExpressionRef {
        const m = self.module;
        const w: u32 = if (self.ptr_type == self.i32_type) 4 else 8;
        const stride: u32 = 2 * w;
        const mul = if (self.ptr_type == self.i32_type) c.BinaryenMulInt32() else c.BinaryenMulInt64();
        // Fresh `data_ptr + i·stride` each call (the list pair lives in pair_idx,
        // the index in bounds_idx).
        const elemAddr = struct {
            fn f(s: *Lowerer, mm: c.BinaryenModuleRef, st: u32, mulop: c.BinaryenOp) c.BinaryenExpressionRef {
                const dp = c.BinaryenTupleExtract(mm, c.BinaryenLocalGet(mm, s.pair_idx, s.pair_type), 0);
                const off = c.BinaryenBinary(mm, mulop, s.toPtr(c.BinaryenLocalGet(mm, s.bounds_idx, s.i64_type)), s.ptrConst(@intCast(st)));
                return s.ptrAdd(dp, off);
            }
        }.f;
        var elems = [_]c.BinaryenExpressionRef{
            c.BinaryenLoad(m, w, false, 0, 0, self.ptr_type, elemAddr(self, m, stride, mul), "0"),
            c.BinaryenLoad(m, w, false, w, 0, self.ptr_type, elemAddr(self, m, stride, mul), "0"),
        };
        var seq = [_]c.BinaryenExpressionRef{
            c.BinaryenLocalSet(m, self.pair_idx, try self.inst(g.list)),
            c.BinaryenLocalSet(m, self.bounds_idx, try self.inst(g.idx)),
            c.BinaryenIf(
                m,
                c.BinaryenBinary(m, c.BinaryenGeUInt64(), c.BinaryenLocalGet(m, self.bounds_idx, self.i64_type), self.toI64(c.BinaryenTupleExtract(m, c.BinaryenLocalGet(m, self.pair_idx, self.pair_type), 1))),
                c.BinaryenUnreachable(m),
                null,
            ),
            c.BinaryenTupleMake(m, @ptrCast(&elems), elems.len),
        };
        return c.BinaryenBlock(m, null, @ptrCast(&seq), seq.len, self.pair_type);
    }

    /// `env.envvars.get(key)` → the variable's value as a str. Stash the key
    /// pair, record `dest = sp`, call `env.envvar(dest, key…)` (the host writes
    /// the value at dest, returns its length), bump `sp` past it, and yield
    /// `(dest, len)`. A length of 0 (unset/empty) yields the empty str.
    fn emitEnvvarGet(self: *Lowerer, eg: anytype) Error!c.BinaryenExpressionRef {
        const m = self.module;
        const dest = self.fs_dest_idx;
        const lenl = self.fs_len_idx;
        const pget = c.BinaryenLocalGet(m, self.pair_idx, self.pair_type);
        var call_args = [_]c.BinaryenExpressionRef{
            self.ptrGet(dest),
            c.BinaryenTupleExtract(m, pget, 0),
            c.BinaryenTupleExtract(m, c.BinaryenLocalGet(m, self.pair_idx, self.pair_type), 1),
        };
        var result = [_]c.BinaryenExpressionRef{
            self.ptrGet(dest),
            self.toPtr(c.BinaryenLocalGet(m, lenl, self.i64_type)),
        };
        var seq = [_]c.BinaryenExpressionRef{
            c.BinaryenLocalSet(m, self.pair_idx, try self.inst(eg.key)),
            c.BinaryenLocalSet(m, dest, c.BinaryenGlobalGet(m, "sp", self.ptr_type)),
            c.BinaryenLocalSet(m, lenl, c.BinaryenCall(m, "env_envvar", @ptrCast(&call_args), call_args.len, self.i64_type)),
            // sp = dest + len (len >= 0; the host clamps "unset" to 0).
            c.BinaryenGlobalSet(m, "sp", self.ptrAdd(self.ptrGet(dest), self.toPtr(c.BinaryenLocalGet(m, lenl, self.i64_type)))),
            c.BinaryenTupleMake(m, @ptrCast(&result), result.len),
        };
        return c.BinaryenBlock(m, null, @ptrCast(&seq), seq.len, self.pair_type);
    }

    /// `env.args` → materialize the args as a `[str]` value. Hand the host the
    /// current arena pointer (`dest`); it writes `[count][cells…][bytes…]`
    /// there (growing guest memory if needed) and returns the total bytes. The
    /// guest bumps `sp` past the written region and yields `(dest+W, count)` —
    /// the cells start one address-word past the count header.
    fn emitHostArgs(self: *Lowerer) Error!c.BinaryenExpressionRef {
        const m = self.module;
        const w: u32 = if (self.ptr_type == self.i32_type) 4 else 8;
        const ridx = self.rec_base + self.rec_level;
        // sp is address-width; env.args returns total bytes as i64.
        var call_args = [_]c.BinaryenExpressionRef{self.ptrGet(ridx)};
        var seq = [_]c.BinaryenExpressionRef{
            // dest = sp.
            c.BinaryenLocalSet(m, ridx, c.BinaryenGlobalGet(m, "sp", self.ptr_type)),
            // sp = dest + total (the host wrote `total` bytes at dest).
            c.BinaryenGlobalSet(m, "sp", self.ptrAdd(self.ptrGet(ridx), self.toPtr(c.BinaryenCall(m, "env_args", @ptrCast(&call_args), call_args.len, self.i64_type)))),
            // yield (data_ptr = dest + W, count = load_uW(dest)).
            blk: {
                var elems = [_]c.BinaryenExpressionRef{
                    self.ptrAdd(self.ptrGet(ridx), self.ptrConst(@intCast(w))),
                    c.BinaryenLoad(m, w, false, 0, 0, self.ptr_type, self.ptrGet(ridx), "0"),
                };
                break :blk c.BinaryenTupleMake(m, @ptrCast(&elems), elems.len);
            },
        };
        return c.BinaryenBlock(m, null, @ptrCast(&seq), seq.len, self.pair_type);
    }

    /// Pointer-width bitwise AND — for aligning the arena bump pointer.
    fn ptrAnd(self: *Lowerer, a: c.BinaryenExpressionRef, b: c.BinaryenExpressionRef) c.BinaryenExpressionRef {
        const op = if (self.ptr_type == self.i32_type) c.BinaryenAndInt32() else c.BinaryenAndInt64();
        return c.BinaryenBinary(self.module, op, a, b);
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
            .str_slice => |sl| {
                // ptr = base.ptr + start; len = end - start. Built as two fresh
                // trees (no shared refs); `start` is emitted once per half.
                const base = c.BinaryenTupleExtract(self.module, try self.inst(sl.str), 0);
                const sub = if (self.ptr_type == self.i64_type) c.BinaryenSubInt64() else c.BinaryenSubInt32();
                try out.append(self.allocator, self.ptrAdd(base, self.toPtr(try self.inst(sl.start))));
                try out.append(self.allocator, c.BinaryenBinary(self.module, sub, self.toPtr(try self.inst(sl.end)), self.toPtr(try self.inst(sl.start))));
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
        // Float-only builtins never reach the int family (the builder emits
        // them only on float operands).
        .fmin, .fmax, .fcopysign => unreachable,
    };
}

/// The f64 instruction for a binary op, or null for ops wasm has no
/// float form of (`%`, bitwise, shifts) — the builder rejects those
/// before lowering; this is the backstop.
fn binOpF64(kind: ir.ops.BinKind) ?c.BinaryenOp {
    return switch (kind) {
        .add => c.BinaryenAddFloat64(),
        .sub => c.BinaryenSubFloat64(),
        .mul => c.BinaryenMulFloat64(),
        .div => c.BinaryenDivFloat64(),
        .eq => c.BinaryenEqFloat64(),
        .ne => c.BinaryenNeFloat64(),
        .lt => c.BinaryenLtFloat64(),
        .le => c.BinaryenLeFloat64(),
        .gt => c.BinaryenGtFloat64(),
        .ge => c.BinaryenGeFloat64(),
        .fmin => c.BinaryenMinFloat64(),
        .fmax => c.BinaryenMaxFloat64(),
        .fcopysign => c.BinaryenCopySignFloat64(),
        .rem, .bit_and, .bit_or, .bit_xor, .shl, .shr => null,
    };
}

/// The f32 instruction family (mirrors `binOpF64`).
fn binOpF32(kind: ir.ops.BinKind) ?c.BinaryenOp {
    return switch (kind) {
        .add => c.BinaryenAddFloat32(),
        .sub => c.BinaryenSubFloat32(),
        .mul => c.BinaryenMulFloat32(),
        .div => c.BinaryenDivFloat32(),
        .eq => c.BinaryenEqFloat32(),
        .ne => c.BinaryenNeFloat32(),
        .lt => c.BinaryenLtFloat32(),
        .le => c.BinaryenLeFloat32(),
        .gt => c.BinaryenGtFloat32(),
        .ge => c.BinaryenGeFloat32(),
        .fmin => c.BinaryenMinFloat32(),
        .fmax => c.BinaryenMaxFloat32(),
        .fcopysign => c.BinaryenCopySignFloat32(),
        .rem, .bit_and, .bit_or, .bit_xor, .shl, .shr => null,
    };
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

/// Emit `__fmt_f64(x: f64) -> (ptr, len)`: decimal text in the scope
/// arena — sign, integer part, `.`, then up to 6 fractional digits with
/// trailing zeros trimmed (at least one digit: `1.0` prints "1.0",
/// `0.25` prints "0.25"). The fraction is scaled by 1e6 and rounded
/// half-up, with a carry into the integer part (0.9999995 → "1.0").
/// v0 boundaries: NaN prints "0.0"; magnitudes beyond i64 saturate
/// (the trunc is the saturating form, so nothing traps).
fn emitFmtF64(module: c.BinaryenModuleRef, allocator: std.mem.Allocator, i64_type: c.BinaryenType, pair_type: c.BinaryenType, ptr_type: c.BinaryenType, mem64: bool) !void {
    const i32_type = c.BinaryenTypeInt32();
    const f64_type = c.BinaryenTypeFloat64();
    const none = c.BinaryenTypeNone();
    // Locals: 0=x (param f64), 1=a (|x|, f64), 2=ip (i64), 3=fr (i64,
    // the 1e6-scaled fraction), 4=p, 5=end (ptr cursors), 6=neg (i32),
    // 7=started (i32, a fractional digit has been written).
    const X: c.BinaryenIndex = 0;
    const A: c.BinaryenIndex = 1;
    const IP: c.BinaryenIndex = 2;
    const FR: c.BinaryenIndex = 3;
    const P: c.BinaryenIndex = 4;
    const END: c.BinaryenIndex = 5;
    const NEG: c.BinaryenIndex = 6;
    const STARTED: c.BinaryenIndex = 7;
    const add_p = if (mem64) c.BinaryenAddInt64() else c.BinaryenAddInt32();
    const sub_p = if (mem64) c.BinaryenSubInt64() else c.BinaryenSubInt32();
    const k = struct {
        fn i64c(m: c.BinaryenModuleRef, v: i64) c.BinaryenExpressionRef {
            return c.BinaryenConst(m, c.BinaryenLiteralInt64(v));
        }
        fn f64c(m: c.BinaryenModuleRef, v: f64) c.BinaryenExpressionRef {
            return c.BinaryenConst(m, c.BinaryenLiteralFloat64(v));
        }
        fn ptrc(m: c.BinaryenModuleRef, m64: bool, v: i64) c.BinaryenExpressionRef {
            return if (m64) c.BinaryenConst(m, c.BinaryenLiteralInt64(v)) else c.BinaryenConst(m, c.BinaryenLiteralInt32(@intCast(v)));
        }
        fn get(m: c.BinaryenModuleRef, idx: c.BinaryenIndex, t: c.BinaryenType) c.BinaryenExpressionRef {
            return c.BinaryenLocalGet(m, idx, t);
        }
        // p--; mem[p] = byte (an i64 i64.store8)
        fn putc(m: c.BinaryenModuleRef, m64: bool, byte: c.BinaryenExpressionRef, pt: c.BinaryenType) [2]c.BinaryenExpressionRef {
            const subp = if (m64) c.BinaryenSubInt64() else c.BinaryenSubInt32();
            return .{
                c.BinaryenLocalSet(m, P, c.BinaryenBinary(m, subp, c.BinaryenLocalGet(m, P, pt), ptrc(m, m64, 1))),
                c.BinaryenStore(m, 1, 0, 0, c.BinaryenLocalGet(m, P, pt), byte, c.BinaryenTypeInt64(), "0"),
            };
        }
    };

    var stmts: std.ArrayList(c.BinaryenExpressionRef) = .empty;
    defer stmts.deinit(allocator);

    // neg = x < 0.0; a = |x|
    try stmts.append(allocator, c.BinaryenLocalSet(module, NEG, c.BinaryenBinary(module, c.BinaryenLtFloat64(), k.get(module, X, f64_type), k.f64c(module, 0.0))));
    try stmts.append(allocator, c.BinaryenLocalSet(module, A, c.BinaryenUnary(module, c.BinaryenAbsFloat64(), k.get(module, X, f64_type))));
    // ip = trunc_sat_u(a); fr = trunc_sat_u((a - convert(ip)) * 1e6 + 0.5)
    try stmts.append(allocator, c.BinaryenLocalSet(module, IP, c.BinaryenUnary(module, c.BinaryenTruncSatUFloat64ToInt64(), k.get(module, A, f64_type))));
    const frac = c.BinaryenBinary(module, c.BinaryenSubFloat64(), k.get(module, A, f64_type), c.BinaryenUnary(module, c.BinaryenConvertUInt64ToFloat64(), k.get(module, IP, i64_type)));
    const scaled = c.BinaryenBinary(module, c.BinaryenAddFloat64(), c.BinaryenBinary(module, c.BinaryenMulFloat64(), frac, k.f64c(module, 1_000_000.0)), k.f64c(module, 0.5));
    try stmts.append(allocator, c.BinaryenLocalSet(module, FR, c.BinaryenUnary(module, c.BinaryenTruncSatUFloat64ToInt64(), scaled)));
    // rounding carry: fr == 1_000_000 → ip += 1, fr = 0
    var carry_body = [_]c.BinaryenExpressionRef{
        c.BinaryenLocalSet(module, IP, c.BinaryenBinary(module, c.BinaryenAddInt64(), k.get(module, IP, i64_type), k.i64c(module, 1))),
        c.BinaryenLocalSet(module, FR, k.i64c(module, 0)),
    };
    const carry_block = c.BinaryenBlock(module, null, @ptrCast(&carry_body), carry_body.len, none);
    try stmts.append(allocator, c.BinaryenIf(module, c.BinaryenBinary(module, c.BinaryenGeUInt64(), k.get(module, FR, i64_type), k.i64c(module, 1_000_000)), carry_block, null));

    // end = sp + 40; sp = end; p = end (backward writer, like __fmt_i64)
    try stmts.append(allocator, c.BinaryenLocalSet(module, END, c.BinaryenBinary(module, add_p, c.BinaryenGlobalGet(module, "sp", ptr_type), k.ptrc(module, mem64, 40))));
    try stmts.append(allocator, c.BinaryenGlobalSet(module, "sp", k.get(module, END, ptr_type)));
    try stmts.append(allocator, c.BinaryenLocalSet(module, P, k.get(module, END, ptr_type)));
    try stmts.append(allocator, c.BinaryenLocalSet(module, STARTED, c.BinaryenConst(module, c.BinaryenLiteralInt32(0))));

    // 6 fractional digits, written backward, trailing zeros skipped until
    // the first nonzero: for i in 0..6 { d = fr%10; fr/=10; if (d!=0 or
    // started) { putc('0'+d); started=1 } }
    {
        var loop_body: std.ArrayList(c.BinaryenExpressionRef) = .empty;
        defer loop_body.deinit(allocator);
        const digit = c.BinaryenBinary(module, c.BinaryenRemUInt64(), k.get(module, FR, i64_type), k.i64c(module, 10));
        const cond = c.BinaryenBinary(module, c.BinaryenOrInt32(), c.BinaryenUnary(
            module,
            c.BinaryenWrapInt64(),
            c.BinaryenBinary(module, c.BinaryenNeInt64(), digit, k.i64c(module, 0)),
        ), k.get(module, STARTED, i32_type));
        _ = cond;
        // (cond rebuilt inline below — Binaryen refs aren't shareable.)
        const digit2 = c.BinaryenBinary(module, c.BinaryenRemUInt64(), k.get(module, FR, i64_type), k.i64c(module, 10));
        const ne0 = c.BinaryenBinary(module, c.BinaryenNeInt64(), digit2, k.i64c(module, 0)); // already i32
        const cond2 = c.BinaryenBinary(module, c.BinaryenOrInt32(), ne0, k.get(module, STARTED, i32_type));
        const putd = k.putc(module, mem64, c.BinaryenBinary(module, c.BinaryenAddInt64(), k.i64c(module, '0'), c.BinaryenBinary(module, c.BinaryenRemUInt64(), k.get(module, FR, i64_type), k.i64c(module, 10))), ptr_type);
        var then_body = [_]c.BinaryenExpressionRef{
            putd[0],
            putd[1],
            c.BinaryenLocalSet(module, STARTED, c.BinaryenConst(module, c.BinaryenLiteralInt32(1))),
        };
        const then_block = c.BinaryenBlock(module, null, @ptrCast(&then_body), then_body.len, none);
        try loop_body.append(allocator, c.BinaryenIf(module, cond2, then_block, null));
        try loop_body.append(allocator, c.BinaryenLocalSet(module, FR, c.BinaryenBinary(module, c.BinaryenDivUInt64(), k.get(module, FR, i64_type), k.i64c(module, 10))));
        // Reuse FR's exhaustion as the loop bound: exactly 6 iterations via
        // a counter in IP's spare bits would need another local — instead
        // loop while the digit budget remains, tracked in local A reused as
        // an i64 counter? A is f64. Add a dedicated counter local: index 8.
        const I: c.BinaryenIndex = 8;
        try loop_body.append(allocator, c.BinaryenLocalSet(module, I, c.BinaryenBinary(module, c.BinaryenAddInt64(), c.BinaryenLocalGet(module, I, i64_type), k.i64c(module, 1))));
        try loop_body.append(allocator, c.BinaryenBreak(module, "ffrac", c.BinaryenBinary(module, c.BinaryenLtUInt64(), c.BinaryenLocalGet(module, I, i64_type), k.i64c(module, 6)), null));
        const loop_block = c.BinaryenBlock(module, null, @ptrCast(loop_body.items.ptr), @intCast(loop_body.items.len), none);
        try stmts.append(allocator, c.BinaryenLoop(module, "ffrac", loop_block));
    }
    // no fractional digit written → a single '0'
    {
        const putz = k.putc(module, mem64, k.i64c(module, '0'), ptr_type);
        var z_body = [_]c.BinaryenExpressionRef{ putz[0], putz[1] };
        const z_block = c.BinaryenBlock(module, null, @ptrCast(&z_body), z_body.len, none);
        try stmts.append(allocator, c.BinaryenIf(module, c.BinaryenUnary(module, c.BinaryenEqZInt32(), c.BinaryenLocalGet(module, STARTED, i32_type)), z_block, null));
    }
    // '.'
    {
        const putdot = k.putc(module, mem64, k.i64c(module, '.'), ptr_type);
        try stmts.append(allocator, putdot[0]);
        try stmts.append(allocator, putdot[1]);
    }
    // integer digits: do { putc('0' + ip%10); ip /= 10 } while (ip != 0)
    {
        var loop_body: std.ArrayList(c.BinaryenExpressionRef) = .empty;
        defer loop_body.deinit(allocator);
        const putd = k.putc(module, mem64, c.BinaryenBinary(module, c.BinaryenAddInt64(), k.i64c(module, '0'), c.BinaryenBinary(module, c.BinaryenRemUInt64(), k.get(module, IP, i64_type), k.i64c(module, 10))), ptr_type);
        try loop_body.append(allocator, putd[0]);
        try loop_body.append(allocator, putd[1]);
        try loop_body.append(allocator, c.BinaryenLocalSet(module, IP, c.BinaryenBinary(module, c.BinaryenDivUInt64(), k.get(module, IP, i64_type), k.i64c(module, 10))));
        try loop_body.append(allocator, c.BinaryenBreak(module, "fint", c.BinaryenBinary(module, c.BinaryenNeInt64(), k.get(module, IP, i64_type), k.i64c(module, 0)), null));
        const loop_block = c.BinaryenBlock(module, null, @ptrCast(loop_body.items.ptr), @intCast(loop_body.items.len), none);
        try stmts.append(allocator, c.BinaryenLoop(module, "fint", loop_block));
    }
    // sign
    {
        const putm = k.putc(module, mem64, k.i64c(module, '-'), ptr_type);
        var sign_body = [_]c.BinaryenExpressionRef{ putm[0], putm[1] };
        const sign_block = c.BinaryenBlock(module, null, @ptrCast(&sign_body), sign_body.len, none);
        try stmts.append(allocator, c.BinaryenIf(module, c.BinaryenLocalGet(module, NEG, i32_type), sign_block, null));
    }
    // (p, end - p)
    var ret = [_]c.BinaryenExpressionRef{
        c.BinaryenLocalGet(module, P, ptr_type),
        c.BinaryenBinary(module, sub_p, c.BinaryenLocalGet(module, END, ptr_type), c.BinaryenLocalGet(module, P, ptr_type)),
    };
    try stmts.append(allocator, c.BinaryenTupleMake(module, @ptrCast(&ret), ret.len));

    const body = c.BinaryenBlock(module, null, @ptrCast(stmts.items.ptr), @intCast(stmts.items.len), pair_type);
    // locals beyond the param: a(f64) ip fr (i64) p end (ptr) neg started (i32) i(i64)
    var var_types = [_]c.BinaryenType{ f64_type, i64_type, i64_type, ptr_type, ptr_type, i32_type, i32_type, i64_type };
    _ = c.BinaryenAddFunction(module, "__fmt_f64", f64_type, pair_type, @ptrCast(&var_types), var_types.len, body);
}

/// Emit `__str_eq(pa, la, pb, lb) -> i32`: byte-wise equality of two strings.
/// Params are address-width (ptr, len, ptr, len); the result is i32 0/1. Lengths
/// differ → 0; otherwise compare bytes until the end → 1, or a mismatch → 0.
/// The canonical-ABI `cabi_realloc(old_ptr, old_size, align, new_size) -> ptr`,
/// exported as `cm32p2_realloc` for the kv component lift. A bump allocator over
/// the `cabi_heap` global (the component model only requires it exist + return
/// aligned space; the kv calls trigger it only for an error variant's string).
/// align-up: `p = (heap + align-1) & -align` (align is a power of two).
/// Emit a canonical-ABI wrapper for a **str-returning** component export and
/// export it as `ext_name`. q64 returns a `str` as a `(ptr, len)` multivalue
/// (its normal ABI), but a component export `-> string` must return an i32
/// pointer to a `{ptr, len}` return-area the host reads. The wrapper calls the
/// internal function, allocates 8 bytes via `cabi_realloc`, writes the pair, and
/// returns the pointer — the shape validated against `wasm-tools component new`
/// + jco. `flat_params` are the internal function's flattened wasm param types
/// (a `str` param is two ptr-width slots); the wrapper forwards them verbatim.
/// Used by the store-component export path so a qube can export a `-> str`
/// function (the `@http_handler` HTTP entry, or any string-returning API).
fn emitStrExportWrapper(
    module: c.BinaryenModuleRef,
    allocator: std.mem.Allocator,
    internal_name: [*:0]const u8,
    wrapper_name: [*:0]const u8,
    ext_name: [*:0]const u8,
    flat_params: []const c.BinaryenType,
    i32_type: c.BinaryenType,
    pair_type: c.BinaryenType,
) !void {
    const i32c = struct {
        fn f(m: c.BinaryenModuleRef, v: i32) c.BinaryenExpressionRef {
            return c.BinaryenConst(m, c.BinaryenLiteralInt32(v));
        }
    }.f;
    // Forward every param slot to the internal function (str → two slots).
    const args = try allocator.alloc(c.BinaryenExpressionRef, flat_params.len);
    defer allocator.free(args);
    for (flat_params, 0..) |pt, i| args[i] = c.BinaryenLocalGet(module, @intCast(i), pt);
    const call = c.BinaryenCall(module, internal_name, @ptrCast(args.ptr), @intCast(args.len), pair_type);
    const res_idx: c.BinaryenIndex = @intCast(flat_params.len); // pair result
    const ra_idx: c.BinaryenIndex = @intCast(flat_params.len + 1); // return-area ptr
    var realloc_args = [_]c.BinaryenExpressionRef{ i32c(module, 0), i32c(module, 0), i32c(module, 4), i32c(module, 8) };
    var stmts = [_]c.BinaryenExpressionRef{
        c.BinaryenLocalSet(module, res_idx, call),
        c.BinaryenLocalSet(module, ra_idx, c.BinaryenCall(module, "cabi_realloc", @ptrCast(&realloc_args), realloc_args.len, i32_type)),
        c.BinaryenStore(module, 4, 0, 0, c.BinaryenLocalGet(module, ra_idx, i32_type), c.BinaryenTupleExtract(module, c.BinaryenLocalGet(module, res_idx, pair_type), 0), i32_type, "0"),
        c.BinaryenStore(module, 4, 4, 0, c.BinaryenLocalGet(module, ra_idx, i32_type), c.BinaryenTupleExtract(module, c.BinaryenLocalGet(module, res_idx, pair_type), 1), i32_type, "0"),
        c.BinaryenReturn(module, c.BinaryenLocalGet(module, ra_idx, i32_type)),
    };
    const body = c.BinaryenBlock(module, null, @ptrCast(&stmts), stmts.len, i32_type);
    const ptype = c.BinaryenTypeCreate(@constCast(flat_params.ptr), @intCast(flat_params.len));
    var vts = [_]c.BinaryenType{ pair_type, i32_type };
    _ = c.BinaryenAddFunction(module, wrapper_name, ptype, i32_type, @ptrCast(&vts), vts.len, body);
    _ = c.BinaryenAddFunctionExport(module, wrapper_name, ext_name);
}

fn emitCabiRealloc(module: c.BinaryenModuleRef, i32_type: c.BinaryenType) !void {
    const OLD_P: c.BinaryenIndex = 0;
    const OLD_S: c.BinaryenIndex = 1;
    const ALIGN: c.BinaryenIndex = 2;
    const NEW_S: c.BinaryenIndex = 3;
    const P: c.BinaryenIndex = 4; // the aligned result pointer
    _ = OLD_P;
    _ = OLD_S;
    const i32c = struct {
        fn f(m: c.BinaryenModuleRef, v: i32) c.BinaryenExpressionRef {
            return c.BinaryenConst(m, c.BinaryenLiteralInt32(v));
        }
    }.f;
    const get = struct {
        fn f(m: c.BinaryenModuleRef, idx: c.BinaryenIndex, t: c.BinaryenType) c.BinaryenExpressionRef {
            return c.BinaryenLocalGet(m, idx, t);
        }
    }.f;
    // p = (cabi_heap + (align - 1)) & (0 - align)
    const heap_plus = c.BinaryenBinary(module, c.BinaryenAddInt32(), c.BinaryenGlobalGet(module, "cabi_heap", i32_type), c.BinaryenBinary(module, c.BinaryenSubInt32(), get(module, ALIGN, i32_type), i32c(module, 1)));
    const neg_align = c.BinaryenBinary(module, c.BinaryenSubInt32(), i32c(module, 0), get(module, ALIGN, i32_type));
    const aligned = c.BinaryenBinary(module, c.BinaryenAndInt32(), heap_plus, neg_align);
    var stmts = [_]c.BinaryenExpressionRef{
        c.BinaryenLocalSet(module, P, aligned),
        // cabi_heap = p + new_size
        c.BinaryenGlobalSet(module, "cabi_heap", c.BinaryenBinary(module, c.BinaryenAddInt32(), get(module, P, i32_type), get(module, NEW_S, i32_type))),
        c.BinaryenReturn(module, get(module, P, i32_type)),
    };
    const body = c.BinaryenBlock(module, null, @ptrCast(&stmts), stmts.len, i32_type);
    var params = [_]c.BinaryenType{ i32_type, i32_type, i32_type, i32_type };
    const ptype = c.BinaryenTypeCreate(&params, params.len);
    var var_types = [_]c.BinaryenType{i32_type}; // P
    const fref = c.BinaryenAddFunction(module, "cabi_realloc", ptype, i32_type, @ptrCast(&var_types), var_types.len, body);
    _ = fref;
    _ = c.BinaryenAddFunctionExport(module, "cabi_realloc", "cm32p2_realloc");
}

fn emitStrEq(module: c.BinaryenModuleRef, allocator: std.mem.Allocator, i32_type: c.BinaryenType, ptr_type: c.BinaryenType, mem64: bool) !void {
    const none = c.BinaryenTypeNone();
    const PA: c.BinaryenIndex = 0;
    const LA: c.BinaryenIndex = 1;
    const PB: c.BinaryenIndex = 2;
    const LB: c.BinaryenIndex = 3;
    const I: c.BinaryenIndex = 4; // loop cursor (address-width)
    const add_p = if (mem64) c.BinaryenAddInt64() else c.BinaryenAddInt32();
    const ne_p = if (mem64) c.BinaryenNeInt64() else c.BinaryenNeInt32();
    const geu_p = if (mem64) c.BinaryenGeUInt64() else c.BinaryenGeUInt32();
    const k = struct {
        fn get(m: c.BinaryenModuleRef, idx: c.BinaryenIndex, t: c.BinaryenType) c.BinaryenExpressionRef {
            return c.BinaryenLocalGet(m, idx, t);
        }
        fn ptrc(m: c.BinaryenModuleRef, m64: bool, v: i64) c.BinaryenExpressionRef {
            return if (m64) c.BinaryenConst(m, c.BinaryenLiteralInt64(v)) else c.BinaryenConst(m, c.BinaryenLiteralInt32(@intCast(v)));
        }
        fn i32c(m: c.BinaryenModuleRef, v: i32) c.BinaryenExpressionRef {
            return c.BinaryenConst(m, c.BinaryenLiteralInt32(v));
        }
    };

    var stmts: std.ArrayList(c.BinaryenExpressionRef) = .empty;
    defer stmts.deinit(allocator);

    // if la != lb: return 0
    try stmts.append(allocator, c.BinaryenIf(module, c.BinaryenBinary(module, ne_p, k.get(module, LA, ptr_type), k.get(module, LB, ptr_type)), c.BinaryenReturn(module, k.i32c(module, 0)), null));
    // I = 0
    try stmts.append(allocator, c.BinaryenLocalSet(module, I, k.ptrc(module, mem64, 0)));

    // loop $streq { if I>=la return 1; if mem[pa+I]!=mem[pb+I] return 0; I++; br }
    var lp: std.ArrayList(c.BinaryenExpressionRef) = .empty;
    defer lp.deinit(allocator);
    try lp.append(allocator, c.BinaryenIf(module, c.BinaryenBinary(module, geu_p, k.get(module, I, ptr_type), k.get(module, LA, ptr_type)), c.BinaryenReturn(module, k.i32c(module, 1)), null));
    const byte_a = c.BinaryenLoad(module, 1, false, 0, 1, i32_type, c.BinaryenBinary(module, add_p, k.get(module, PA, ptr_type), k.get(module, I, ptr_type)), "0");
    const byte_b = c.BinaryenLoad(module, 1, false, 0, 1, i32_type, c.BinaryenBinary(module, add_p, k.get(module, PB, ptr_type), k.get(module, I, ptr_type)), "0");
    try lp.append(allocator, c.BinaryenIf(module, c.BinaryenBinary(module, c.BinaryenNeInt32(), byte_a, byte_b), c.BinaryenReturn(module, k.i32c(module, 0)), null));
    try lp.append(allocator, c.BinaryenLocalSet(module, I, c.BinaryenBinary(module, add_p, k.get(module, I, ptr_type), k.ptrc(module, mem64, 1))));
    try lp.append(allocator, c.BinaryenBreak(module, "streq", null, null));
    const lp_block = c.BinaryenBlock(module, null, @ptrCast(lp.items.ptr), @intCast(lp.items.len), none);
    try stmts.append(allocator, c.BinaryenLoop(module, "streq", lp_block));
    // The loop only exits via `return`; this satisfies the i32 result type.
    try stmts.append(allocator, c.BinaryenUnreachable(module));

    const body = c.BinaryenBlock(module, null, @ptrCast(stmts.items.ptr), @intCast(stmts.items.len), i32_type);
    var params = [_]c.BinaryenType{ ptr_type, ptr_type, ptr_type, ptr_type };
    const ptype = c.BinaryenTypeCreate(&params, params.len);
    var var_types = [_]c.BinaryenType{ptr_type}; // I
    _ = c.BinaryenAddFunction(module, "__str_eq", ptype, i32_type, @ptrCast(&var_types), var_types.len, body);
}

// Shared little const/get helpers for the str runtime helpers below.
const K = struct {
    fn get(m: c.BinaryenModuleRef, idx: c.BinaryenIndex, t: c.BinaryenType) c.BinaryenExpressionRef {
        return c.BinaryenLocalGet(m, idx, t);
    }
    fn ptrc(m: c.BinaryenModuleRef, m64: bool, v: i64) c.BinaryenExpressionRef {
        return if (m64) c.BinaryenConst(m, c.BinaryenLiteralInt64(v)) else c.BinaryenConst(m, c.BinaryenLiteralInt32(@intCast(v)));
    }
    fn i64c(m: c.BinaryenModuleRef, v: i64) c.BinaryenExpressionRef {
        return c.BinaryenConst(m, c.BinaryenLiteralInt64(v));
    }
    fn i32c(m: c.BinaryenModuleRef, v: i32) c.BinaryenExpressionRef {
        return c.BinaryenConst(m, c.BinaryenLiteralInt32(v));
    }
    fn load8(m: c.BinaryenModuleRef, i32_type: c.BinaryenType, addr: c.BinaryenExpressionRef) c.BinaryenExpressionRef {
        return c.BinaryenLoad(m, 1, false, 0, 1, i32_type, addr, "0");
    }
};

/// `__str_index_of(ps, ls, byte) -> i64`: the index of the first byte equal to
/// `byte` (low 8 bits), or -1. Params: ptr, len (address-width), byte (i64).
fn emitStrIndexOf(module: c.BinaryenModuleRef, allocator: std.mem.Allocator, i64_type: c.BinaryenType, i32_type: c.BinaryenType, ptr_type: c.BinaryenType, mem64: bool) !void {
    const none = c.BinaryenTypeNone();
    const PS: c.BinaryenIndex = 0;
    const LS: c.BinaryenIndex = 1;
    const BYTE: c.BinaryenIndex = 2;
    const I: c.BinaryenIndex = 3;
    const add_p = if (mem64) c.BinaryenAddInt64() else c.BinaryenAddInt32();
    const geu_p = if (mem64) c.BinaryenGeUInt64() else c.BinaryenGeUInt32();

    var stmts: std.ArrayList(c.BinaryenExpressionRef) = .empty;
    defer stmts.deinit(allocator);
    try stmts.append(allocator, c.BinaryenLocalSet(module, I, K.ptrc(module, mem64, 0)));

    var lp: std.ArrayList(c.BinaryenExpressionRef) = .empty;
    defer lp.deinit(allocator);
    // if I >= ls: return -1
    try lp.append(allocator, c.BinaryenIf(module, c.BinaryenBinary(module, geu_p, K.get(module, I, ptr_type), K.get(module, LS, ptr_type)), c.BinaryenReturn(module, K.i64c(module, -1)), null));
    // if mem[ps+I] == (byte as i32): return I (as i64)
    const byte_at = K.load8(module, i32_type, c.BinaryenBinary(module, add_p, K.get(module, PS, ptr_type), K.get(module, I, ptr_type)));
    const want = c.BinaryenUnary(module, c.BinaryenWrapInt64(), K.get(module, BYTE, i64_type));
    const idx_i64 = if (mem64) K.get(module, I, ptr_type) else c.BinaryenUnary(module, c.BinaryenExtendUInt32(), K.get(module, I, ptr_type));
    try lp.append(allocator, c.BinaryenIf(module, c.BinaryenBinary(module, c.BinaryenEqInt32(), byte_at, want), c.BinaryenReturn(module, idx_i64), null));
    try lp.append(allocator, c.BinaryenLocalSet(module, I, c.BinaryenBinary(module, add_p, K.get(module, I, ptr_type), K.ptrc(module, mem64, 1))));
    try lp.append(allocator, c.BinaryenBreak(module, "iol", null, null));
    try stmts.append(allocator, c.BinaryenLoop(module, "iol", c.BinaryenBlock(module, null, @ptrCast(lp.items.ptr), @intCast(lp.items.len), none)));
    try stmts.append(allocator, c.BinaryenUnreachable(module));

    const body = c.BinaryenBlock(module, null, @ptrCast(stmts.items.ptr), @intCast(stmts.items.len), i64_type);
    var params = [_]c.BinaryenType{ ptr_type, ptr_type, i64_type };
    const ptype = c.BinaryenTypeCreate(&params, params.len);
    var var_types = [_]c.BinaryenType{ptr_type};
    _ = c.BinaryenAddFunction(module, "__str_index_of", ptype, i64_type, @ptrCast(&var_types), var_types.len, body);
}

/// `__str_starts_with(ps, ls, pp, lp) -> i32`: does s begin with the prefix?
fn emitStrStartsWith(module: c.BinaryenModuleRef, allocator: std.mem.Allocator, i32_type: c.BinaryenType, ptr_type: c.BinaryenType, mem64: bool) !void {
    const none = c.BinaryenTypeNone();
    const PS: c.BinaryenIndex = 0;
    const LS: c.BinaryenIndex = 1;
    const PP: c.BinaryenIndex = 2;
    const LP: c.BinaryenIndex = 3;
    const I: c.BinaryenIndex = 4;
    const add_p = if (mem64) c.BinaryenAddInt64() else c.BinaryenAddInt32();
    const gtu_p = if (mem64) c.BinaryenGtUInt64() else c.BinaryenGtUInt32();
    const geu_p = if (mem64) c.BinaryenGeUInt64() else c.BinaryenGeUInt32();

    var stmts: std.ArrayList(c.BinaryenExpressionRef) = .empty;
    defer stmts.deinit(allocator);
    // if lp > ls: return 0 (prefix can't fit)
    try stmts.append(allocator, c.BinaryenIf(module, c.BinaryenBinary(module, gtu_p, K.get(module, LP, ptr_type), K.get(module, LS, ptr_type)), c.BinaryenReturn(module, K.i32c(module, 0)), null));
    try stmts.append(allocator, c.BinaryenLocalSet(module, I, K.ptrc(module, mem64, 0)));

    var lp: std.ArrayList(c.BinaryenExpressionRef) = .empty;
    defer lp.deinit(allocator);
    try lp.append(allocator, c.BinaryenIf(module, c.BinaryenBinary(module, geu_p, K.get(module, I, ptr_type), K.get(module, LP, ptr_type)), c.BinaryenReturn(module, K.i32c(module, 1)), null));
    const a = K.load8(module, i32_type, c.BinaryenBinary(module, add_p, K.get(module, PS, ptr_type), K.get(module, I, ptr_type)));
    const b = K.load8(module, i32_type, c.BinaryenBinary(module, add_p, K.get(module, PP, ptr_type), K.get(module, I, ptr_type)));
    try lp.append(allocator, c.BinaryenIf(module, c.BinaryenBinary(module, c.BinaryenNeInt32(), a, b), c.BinaryenReturn(module, K.i32c(module, 0)), null));
    try lp.append(allocator, c.BinaryenLocalSet(module, I, c.BinaryenBinary(module, add_p, K.get(module, I, ptr_type), K.ptrc(module, mem64, 1))));
    try lp.append(allocator, c.BinaryenBreak(module, "swl", null, null));
    try stmts.append(allocator, c.BinaryenLoop(module, "swl", c.BinaryenBlock(module, null, @ptrCast(lp.items.ptr), @intCast(lp.items.len), none)));
    try stmts.append(allocator, c.BinaryenUnreachable(module));

    const body = c.BinaryenBlock(module, null, @ptrCast(stmts.items.ptr), @intCast(stmts.items.len), i32_type);
    var params = [_]c.BinaryenType{ ptr_type, ptr_type, ptr_type, ptr_type };
    const ptype = c.BinaryenTypeCreate(&params, params.len);
    var var_types = [_]c.BinaryenType{ptr_type};
    _ = c.BinaryenAddFunction(module, "__str_starts_with", ptype, i32_type, @ptrCast(&var_types), var_types.len, body);
}

/// `__str_contains(ps, ls, pp, lp) -> i32`: does sub occur in s? Tries each
/// start offset via `__str_starts_with`. Empty sub matches.
fn emitStrContains(module: c.BinaryenModuleRef, allocator: std.mem.Allocator, i32_type: c.BinaryenType, ptr_type: c.BinaryenType, mem64: bool) !void {
    const none = c.BinaryenTypeNone();
    const PS: c.BinaryenIndex = 0;
    const LS: c.BinaryenIndex = 1;
    const PP: c.BinaryenIndex = 2;
    const LP: c.BinaryenIndex = 3;
    const I: c.BinaryenIndex = 4;
    const add_p = if (mem64) c.BinaryenAddInt64() else c.BinaryenAddInt32();
    const sub_p = if (mem64) c.BinaryenSubInt64() else c.BinaryenSubInt32();
    const gtu_p = if (mem64) c.BinaryenGtUInt64() else c.BinaryenGtUInt32();
    const eq_p = if (mem64) c.BinaryenEqInt64() else c.BinaryenEqInt32();

    var stmts: std.ArrayList(c.BinaryenExpressionRef) = .empty;
    defer stmts.deinit(allocator);
    // if lp == 0: return 1 (empty substring)
    try stmts.append(allocator, c.BinaryenIf(module, c.BinaryenBinary(module, eq_p, K.get(module, LP, ptr_type), K.ptrc(module, mem64, 0)), c.BinaryenReturn(module, K.i32c(module, 1)), null));
    // if lp > ls: return 0
    try stmts.append(allocator, c.BinaryenIf(module, c.BinaryenBinary(module, gtu_p, K.get(module, LP, ptr_type), K.get(module, LS, ptr_type)), c.BinaryenReturn(module, K.i32c(module, 0)), null));
    try stmts.append(allocator, c.BinaryenLocalSet(module, I, K.ptrc(module, mem64, 0)));

    var lp: std.ArrayList(c.BinaryenExpressionRef) = .empty;
    defer lp.deinit(allocator);
    // if I + lp > ls: return 0 (no room left)
    try lp.append(allocator, c.BinaryenIf(module, c.BinaryenBinary(module, gtu_p, c.BinaryenBinary(module, add_p, K.get(module, I, ptr_type), K.get(module, LP, ptr_type)), K.get(module, LS, ptr_type)), c.BinaryenReturn(module, K.i32c(module, 0)), null));
    // if __str_starts_with(ps+I, ls-I, pp, lp): return 1
    var sw_args = [_]c.BinaryenExpressionRef{
        c.BinaryenBinary(module, add_p, K.get(module, PS, ptr_type), K.get(module, I, ptr_type)),
        c.BinaryenBinary(module, sub_p, K.get(module, LS, ptr_type), K.get(module, I, ptr_type)),
        K.get(module, PP, ptr_type),
        K.get(module, LP, ptr_type),
    };
    const sw = c.BinaryenCall(module, "__str_starts_with", @ptrCast(&sw_args), sw_args.len, i32_type);
    try lp.append(allocator, c.BinaryenIf(module, sw, c.BinaryenReturn(module, K.i32c(module, 1)), null));
    try lp.append(allocator, c.BinaryenLocalSet(module, I, c.BinaryenBinary(module, add_p, K.get(module, I, ptr_type), K.ptrc(module, mem64, 1))));
    try lp.append(allocator, c.BinaryenBreak(module, "cnl", null, null));
    try stmts.append(allocator, c.BinaryenLoop(module, "cnl", c.BinaryenBlock(module, null, @ptrCast(lp.items.ptr), @intCast(lp.items.len), none)));
    try stmts.append(allocator, c.BinaryenUnreachable(module));

    const body = c.BinaryenBlock(module, null, @ptrCast(stmts.items.ptr), @intCast(stmts.items.len), i32_type);
    var params = [_]c.BinaryenType{ ptr_type, ptr_type, ptr_type, ptr_type };
    const ptype = c.BinaryenTypeCreate(&params, params.len);
    var var_types = [_]c.BinaryenType{ptr_type};
    _ = c.BinaryenAddFunction(module, "__str_contains", ptype, i32_type, @ptrCast(&var_types), var_types.len, body);
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

// --- foreign WIT imports (`--wit-import`, WIT rung 5: the source-level call) ---

const test_math_iface = blk: {
    const iparams = [_]component.Scalar{ .s64, .s64 };
    const inames = [_][]const u8{ "a", "b" };
    const ifuncs = [_]component.ImportFunc{.{ .name = "add", .params = &iparams, .param_names = &inames, .ret = .s64 }};
    break :blk [_]component.ImportIface{.{ .wit_name = "acme:mathlib/math", .funcs = &ifuncs }};
};

test "emitFromSourceWithImports: a foreign call emits a core import + a call" {
    // `math.add(x, 100)` lowers to `(import "acme:mathlib/math" "add" …)` + a
    // call to it — the core module genuinely imports the foreign func.
    const src = "pub fn compute(x: i64) -> i64 { math.add(x, 100) }\n";
    const core = try emitFromSourceWithImports(testing.allocator, src, "c.q", &.{}, .wasm32, &test_math_iface);
    defer testing.allocator.free(core);
    // The core has an import section (id 2) — i.e. it really imports something.
    try testing.expect(coreHasImports(core));
    // The import module id + field survive verbatim in the import section.
    try testing.expect(std.mem.indexOf(u8, core, "acme:mathlib/math") != null);
    try testing.expect(std.mem.indexOf(u8, core, "add") != null);
}

test "emitFromSourceWithImports: an unknown foreign func is NameNotFound" {
    // The interface is imported but `mul` isn't one of its funcs.
    const src = "pub fn compute(x: i64) -> i64 { math.mul(x, 100) }\n";
    try testing.expectError(
        Error.NameNotFound,
        emitFromSourceWithImports(testing.allocator, src, "c.q", &.{}, .wasm32, &test_math_iface),
    );
}

test "emitFromSource: a foreign-looking call without the import table is unresolved" {
    // With no `--wit-import`, `math.add` is just an unknown name — the
    // recognition is inert, so existing programs are unaffected.
    const src = "pub fn compute(x: i64) -> i64 { math.add(x, 100) }\n";
    try testing.expectError(
        Error.NameNotFound,
        emitFromSource(testing.allocator, src, "c.q", &.{}, .wasm32),
    );
}

test "emitComponent: a foreign call wires the import into a valid component" {
    const src = "pub fn compute(x: i64) -> i64 { math.add(x, 100) }\n";
    const artifact = try emitComponent(testing.allocator, src, "c.q", &.{}, .wasm32, &test_math_iface, null);
    switch (artifact) {
        .component => |bytes| {
            defer testing.allocator.free(bytes);
            // Component layer (0x01) preamble, the import section (id 0x0a), the
            // instance-type tag (0x42), and the interface id + names all present.
            try testing.expectEqualSlices(u8, &.{ 0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00 }, bytes[0..8]);
            try testing.expect(std.mem.indexOfScalar(u8, bytes, 0x0a) != null);
            try testing.expect(std.mem.indexOfScalar(u8, bytes, 0x42) != null);
            try testing.expect(std.mem.indexOf(u8, bytes, "acme:mathlib/math") != null);
            try testing.expect(std.mem.indexOf(u8, bytes, "compute") != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "emitComponent: a declared-but-uncalled import is declared in the world but not wired" {
    // The qube declares the import but never calls it. The world still
    // imports the interface — spec/qube.json5.md §wit: `wit.imports` are
    // declared in the emitted component's world even when unused, so `wac`
    // can link a socket before its first call site lands — but the core has
    // no import, so the encoder wires nothing: the id appears exactly once
    // (the §0a import), never as a core-instantiation arg.
    const src = "pub fn compute(x: i64) -> i64 { x + 1 }\n";
    const artifact = try emitComponent(testing.allocator, src, "c.q", &.{}, .wasm32, &test_math_iface, null);
    switch (artifact) {
        .component => |bytes| {
            defer testing.allocator.free(bytes);
            const id = "acme:mathlib/math";
            const first = std.mem.indexOf(u8, bytes, id) orelse return error.TestUnexpectedResult;
            try testing.expect(std.mem.indexOfPos(u8, bytes, first + 1, id) == null);
            try testing.expect(std.mem.indexOf(u8, bytes, "compute") != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "emitFromSource: env.err declares the raw env.err face; out+err declares both" {
    // An err-only program imports `(import "env" "err")` and NOT `env.out`
    // (the raw-face declaration is stream-precise).
    const err_only = "fn main { env.err(\"oops\") }\n";
    const eo = try emitFromSource(testing.allocator, err_only, "main.q", &.{}, .wasm32);
    defer testing.allocator.free(eo);
    try testing.expectEqualSlices(u8, "\x00asm", eo[0..4]);
    try testing.expect(std.mem.indexOf(u8, eo, "err") != null);

    // out + err (newline-separated statements) → both faces declared.
    const both = "fn main {\n    env.out(\"a\")\n    env.err(\"b\")\n}\n";
    const b = try emitFromSource(testing.allocator, both, "main.q", &.{}, .wasm32);
    defer testing.allocator.free(b);
    try testing.expect(std.mem.indexOf(u8, b, "out") != null);
    try testing.expect(std.mem.indexOf(u8, b, "err") != null);
}

test "emitFromSource: env.exit declares the raw env.exit host face import" {
    // The raw (non-component) path imports q64's `env.exit` face directly —
    // satisfied by runtime/wasmtime + runtime/browser. No preview1 proc_exit here.
    const app = "fn main { env.exit(1) }\n";
    const bytes = try emitFromSource(testing.allocator, app, "main.q", &.{}, .wasm32);
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, "\x00asm", bytes[0..4]);
    try testing.expect(std.mem.indexOf(u8, bytes, "exit") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "proc_exit") == null);
}

test "emitComponent: env.exit lowers to a preview1 proc_exit app (→ wasi:cli/exit)" {
    // An app reaching `@exit` (even without stdout) routes down the preview1
    // path: the core imports `wasi_snapshot_preview1.proc_exit`, which the WASI
    // adapter lifts to a `wasi:cli/run` command importing `wasi:cli/exit`.
    const app = "fn main { env.exit(2) }\n";
    const artifact = try emitComponent(testing.allocator, app, "exit.q", &.{}, .wasm32, &.{}, null);
    switch (artifact) {
        .preview1_app => |core| {
            defer testing.allocator.free(core);
            try testing.expectEqualSlices(u8, "\x00asm", core[0..4]);
            try testing.expect(std.mem.indexOf(u8, core, "proc_exit") != null);
            try testing.expect(std.mem.indexOf(u8, core, "wasi_snapshot_preview1") != null);
            // No raw env.exit face leaks into the preview1 core.
            try testing.expect(std.mem.indexOf(u8, core, "env_exit") == null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "emitComponent: a printing main that reads the clock lowers time to preview1 clock_time_get" {
    // An app that both prints (`env.out` → fd_write) and times routes down the
    // preview1 path; the clock rides the `clock_time_get` syscall (the adapter
    // lifts it to wasi:clocks/monotonic-clock), not the cm32p2 import and not
    // the raw local face.
    const app =
        \\fn main {
        \\    let t0 = env.time.monotonic_ns()
        \\    let t1 = env.time.monotonic_ns()
        \\    env.out(t1 - t0)
        \\}
        \\
    ;
    const artifact = try emitComponent(testing.allocator, app, "sw.q", &.{}, .wasm32, &.{}, null);
    switch (artifact) {
        .preview1_app => |core| {
            defer testing.allocator.free(core);
            try testing.expect(std.mem.indexOf(u8, core, "clock_time_get") != null);
            try testing.expect(std.mem.indexOf(u8, core, "wasi_snapshot_preview1") != null);
            try testing.expect(std.mem.indexOf(u8, core, "cm32p2") == null);
            try testing.expect(std.mem.indexOf(u8, core, "monotonic_ns") == null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "emitComponent: env.kv lowers to a wasi:keyvalue component core + world" {
    const src =
        \\pub fn bump() -> i64 {
        \\    match env.kv.increment("count", 1) { Ok(n) -> n, Err(_) -> 0 }
        \\}
    ;
    const artifact = try emitComponent(testing.allocator, src, "kv.q", &.{}, .wasm32, &.{}, null);
    switch (artifact) {
        .store_component => |kvc| {
            defer testing.allocator.free(kvc.core);
            defer testing.allocator.free(kvc.world);
            // Core (env-out path bytes) imports the canonical cm32p2 wasi:keyvalue
            // interfaces + exports the canonical memory/realloc, named cm32p2||bump.
            try testing.expectEqualSlices(u8, "\x00asm", kvc.core[0..4]);
            try testing.expect(std.mem.indexOf(u8, kvc.core, "cm32p2|wasi:keyvalue/store@0.2.0-draft2") != null);
            try testing.expect(std.mem.indexOf(u8, kvc.core, "cm32p2|wasi:keyvalue/atomics@0.2.0-draft2") != null);
            try testing.expect(std.mem.indexOf(u8, kvc.core, "cm32p2_memory") != null);
            try testing.expect(std.mem.indexOf(u8, kvc.core, "cm32p2_realloc") != null);
            try testing.expect(std.mem.indexOf(u8, kvc.core, "cm32p2||bump") != null);
            // No raw env.kv face leaks into the component core.
            try testing.expect(std.mem.indexOf(u8, kvc.core, "kv_increment") == null);
            // The synthesized world imports both versioned interfaces + exports bump.
            try testing.expect(std.mem.indexOf(u8, kvc.world, "import wasi:keyvalue/store@0.2.0-draft2;") != null);
            try testing.expect(std.mem.indexOf(u8, kvc.world, "import wasi:keyvalue/atomics@0.2.0-draft2;") != null);
            try testing.expect(std.mem.indexOf(u8, kvc.world, "export bump: func() -> s64;") != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "emitComponent: env.kv.set imports the store `[method]bucket.set`" {
    const src =
        \\pub fn put() -> i64 {
        \\    match env.kv.set("k", "v") { Ok(()) -> 1, Err(_) -> 0 }
        \\}
    ;
    const artifact = try emitComponent(testing.allocator, src, "kv.q", &.{}, .wasm32, &.{}, null);
    switch (artifact) {
        .store_component => |kvc| {
            defer testing.allocator.free(kvc.core);
            defer testing.allocator.free(kvc.world);
            try testing.expect(std.mem.indexOf(u8, kvc.core, "cm32p2|wasi:keyvalue/store@0.2.0-draft2") != null);
            try testing.expect(std.mem.indexOf(u8, kvc.core, "[method]bucket.set") != null);
            // set doesn't reach atomics.increment; that import stays out.
            try testing.expect(std.mem.indexOf(u8, kvc.core, "[method]bucket.get") == null);
            try testing.expect(std.mem.indexOf(u8, kvc.world, "export put: func() -> s64;") != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "emitComponent: env.db.query_one<Row> imports `[method]connection.query-one`" {
    // The typed-row query: `Ok(Some(row))` binds a `struct Row` decoded
    // zero-copy over the canonical `list<s64>`, and reading two of its `i64`
    // fields proves the record binding lowers. The core imports the new
    // query-one connection method on the same q64:db/sql interface.
    const src =
        \\struct Row { id: i64, n: i64 }
        \\pub fn first() -> i64 {
        \\    match env.db.query_one<Row>("SELECT id, n FROM t ORDER BY id LIMIT 1") {
        \\        Ok(Some(row)) -> row.id * 100 + row.n
        \\        Ok(None)      -> 0 - 1
        \\        Err(_)        -> 0 - 2
        \\    }
        \\}
    ;
    const artifact = try emitComponent(testing.allocator, src, "row.q", &.{}, .wasm32, &.{}, null);
    switch (artifact) {
        .store_component => |kvc| {
            defer testing.allocator.free(kvc.core);
            defer testing.allocator.free(kvc.world);
            try testing.expect(std.mem.indexOf(u8, kvc.core, "cm32p2|q64:db/sql@0.2.0-draft2") != null);
            try testing.expect(std.mem.indexOf(u8, kvc.core, "[method]connection.query-one") != null);
            // query-one only — no query-value/query-text/exec pulled in.
            try testing.expect(std.mem.indexOf(u8, kvc.core, "[method]connection.query-value") == null);
            try testing.expect(std.mem.indexOf(u8, kvc.world, "import q64:db/sql@0.2.0-draft2;") != null);
            try testing.expect(std.mem.indexOf(u8, kvc.world, "export first: func() -> s64;") != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "emitComponent: env.db.query_one rejects a non-i64 row field (v0 integer-only)" {
    // A `str` column is the deferred widening — the zero-copy `list<s64>` ↔
    // record mapping requires every field to be an 8-byte `i64` cell, so a
    // struct with a `str` field must not build (honest Unsupported, not a
    // silent miscompile).
    const src =
        \\struct Row { id: i64, name: str }
        \\pub fn first() -> i64 {
        \\    match env.db.query_one<Row>("SELECT id, name FROM t LIMIT 1") {
        \\        Ok(Some(row)) -> row.id
        \\        Ok(None)      -> 0 - 1
        \\        Err(_)        -> 0 - 2
        \\    }
        \\}
    ;
    // The unsupported body drops `first`, leaving no exportable surface and no
    // `main` — the emit then has nothing to lower.
    try testing.expectError(error.NoMainFunction, emitComponent(testing.allocator, src, "bad.q", &.{}, .wasm32, &.{}, null));
}

test "emitComponent: env.kv.get imports the store `[method]bucket.get`" {
    const src =
        \\pub fn read() -> i64 {
        \\    match env.kv.get("k") { Ok(Some(v)) -> v.len, Ok(None) -> 0, Err(_) -> 0 }
        \\}
    ;
    const artifact = try emitComponent(testing.allocator, src, "kv.q", &.{}, .wasm32, &.{}, null);
    switch (artifact) {
        .store_component => |kvc| {
            defer testing.allocator.free(kvc.core);
            defer testing.allocator.free(kvc.world);
            try testing.expect(std.mem.indexOf(u8, kvc.core, "cm32p2|wasi:keyvalue/store@0.2.0-draft2") != null);
            try testing.expect(std.mem.indexOf(u8, kvc.core, "[method]bucket.get") != null);
            try testing.expect(std.mem.indexOf(u8, kvc.core, "[method]bucket.set") == null);
            try testing.expect(std.mem.indexOf(u8, kvc.world, "export read: func() -> s64;") != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "emitComponent: env.blob lowers to a q64:blob/store component" {
    const src =
        \\pub fn save() -> i64 {
        \\    match env.blob.put("k", "v") { Ok(()) -> 1, Err(_) -> 0 }
        \\}
        \\pub fn read() -> i64 {
        \\    match env.blob.get("k") { Ok(Some(v)) -> v.len, Ok(None) -> 0, Err(_) -> 0 }
        \\}
        \\pub fn drop() -> i64 {
        \\    match env.blob.delete("k") { Ok(()) -> 1, Err(_) -> 0 }
        \\}
    ;
    const artifact = try emitComponent(testing.allocator, src, "blob.q", &.{}, .wasm32, &.{}, null);
    switch (artifact) {
        .store_component => |kvc| {
            defer testing.allocator.free(kvc.core);
            defer testing.allocator.free(kvc.world);
            try testing.expect(std.mem.indexOf(u8, kvc.core, "cm32p2|q64:blob/store@0.2.0-draft2") != null);
            try testing.expect(std.mem.indexOf(u8, kvc.core, "[method]bucket.get") != null);
            try testing.expect(std.mem.indexOf(u8, kvc.core, "[method]bucket.put") != null);
            try testing.expect(std.mem.indexOf(u8, kvc.core, "[method]bucket.delete") != null);
            // A blob-only qube imports no wasi:keyvalue.
            try testing.expect(std.mem.indexOf(u8, kvc.core, "wasi:keyvalue") == null);
            try testing.expect(std.mem.indexOf(u8, kvc.world, "import q64:blob/store@0.2.0-draft2;") != null);
            try testing.expect(std.mem.indexOf(u8, kvc.world, "export save: func() -> s64;") != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "emitComponent: env.kv + env.blob in one qube imports both interfaces" {
    // Multiple storage capabilities compose: the world imports wasi:keyvalue
    // AND q64:blob, and the core imports both interfaces' methods.
    const src =
        \\pub fn hits() -> i64 {
        \\    match env.kv.increment("hits", 1) { Ok(n) -> n, Err(_) -> 0 }
        \\}
        \\pub fn stash() -> i64 {
        \\    match env.blob.put("k", "v") { Ok(()) -> 1, Err(_) -> 0 }
        \\}
    ;
    const artifact = try emitComponent(testing.allocator, src, "both.q", &.{}, .wasm32, &.{}, null);
    switch (artifact) {
        .store_component => |kvc| {
            defer testing.allocator.free(kvc.core);
            defer testing.allocator.free(kvc.world);
            try testing.expect(std.mem.indexOf(u8, kvc.core, "cm32p2|wasi:keyvalue/atomics@0.2.0-draft2") != null);
            try testing.expect(std.mem.indexOf(u8, kvc.core, "cm32p2|q64:blob/store@0.2.0-draft2") != null);
            try testing.expect(std.mem.indexOf(u8, kvc.world, "import wasi:keyvalue/store@0.2.0-draft2;") != null);
            try testing.expect(std.mem.indexOf(u8, kvc.world, "import q64:blob/store@0.2.0-draft2;") != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "emitComponent: env.db lowers to a q64:db/sql component" {
    const src =
        \\pub fn setup() -> i64 {
        \\    match env.db.execute("CREATE TABLE t(x)") { Ok(rows) -> rows, Err(_) -> 0 }
        \\}
        \\pub fn n() -> i64 {
        \\    match env.db.query_value("SELECT COUNT(*) FROM t") { Ok(Some(v)) -> v, Ok(None) -> 0, Err(_) -> 0 }
        \\}
        \\pub fn s() -> i64 {
        \\    match env.db.query_text("SELECT x FROM t") { Ok(Some(v)) -> v.len, Ok(None) -> 0, Err(_) -> 0 }
        \\}
    ;
    const artifact = try emitComponent(testing.allocator, src, "db.q", &.{}, .wasm32, &.{}, null);
    switch (artifact) {
        .store_component => |kvc| {
            defer testing.allocator.free(kvc.core);
            defer testing.allocator.free(kvc.world);
            try testing.expect(std.mem.indexOf(u8, kvc.core, "cm32p2|q64:db/sql@0.2.0-draft2") != null);
            try testing.expect(std.mem.indexOf(u8, kvc.core, "[method]connection.exec") != null);
            try testing.expect(std.mem.indexOf(u8, kvc.core, "[method]connection.query-value") != null);
            try testing.expect(std.mem.indexOf(u8, kvc.core, "[method]connection.query-text") != null);
            try testing.expect(std.mem.indexOf(u8, kvc.world, "import q64:db/sql@0.2.0-draft2;") != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "emitComponent: env.config lowers to a wasi:config/store component (handle-less get)" {
    const src =
        \\pub fn read() -> i64 {
        \\    match env.config.get("k") { Ok(Some(v)) -> v.len, Ok(None) -> 0, Err(_) -> 0 }
        \\}
    ;
    const artifact = try emitComponent(testing.allocator, src, "cfg.q", &.{}, .wasm32, &.{}, null);
    switch (artifact) {
        .store_component => |kvc| {
            defer testing.allocator.free(kvc.core);
            defer testing.allocator.free(kvc.world);
            // The core imports the config interface module (the import base name
            // is the generic `get`; `config_store_get` is binaryen's internal
            // handle, not in the wasm bytes). A config-only qube pulls in no
            // handle-based store.
            try testing.expect(std.mem.indexOf(u8, kvc.core, "cm32p2|wasi:config/store@0.2.0-draft") != null);
            try testing.expect(std.mem.indexOf(u8, kvc.core, "wasi:keyvalue") == null);
            try testing.expect(std.mem.indexOf(u8, kvc.world, "import wasi:config/store@0.2.0-draft;") != null);
            try testing.expect(std.mem.indexOf(u8, kvc.world, "export read: func() -> s64;") != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "emitComponent: env.time lowers to a wasi:clocks component (bare scalar now)" {
    const src =
        \\pub fn mono() -> i64 { env.time.monotonic_ns() }
        \\pub fn res() -> i64 { env.time.resolution_ns() }
    ;
    const artifact = try emitComponent(testing.allocator, src, "time.q", &.{}, .wasm32, &.{}, null);
    switch (artifact) {
        .store_component => |kvc| {
            defer testing.allocator.free(kvc.core);
            defer testing.allocator.free(kvc.world);
            // The core imports the monotonic clock module under the STABLE
            // major.minor mangle (`@0.2`, not `@0.2.0` — see
            // `clocks_monotonic_core_mod`), while the world pins the full id.
            try testing.expect(std.mem.indexOf(u8, kvc.core, "cm32p2|wasi:clocks/monotonic-clock@0.2") != null);
            try testing.expect(std.mem.indexOf(u8, kvc.core, "monotonic-clock@0.2.0") == null);
            // Scalar-only: no store scaffolding rides along.
            try testing.expect(std.mem.indexOf(u8, kvc.core, "cm32p2_realloc") == null);
            try testing.expect(std.mem.indexOf(u8, kvc.core, "wasi:keyvalue") == null);
            try testing.expect(std.mem.indexOf(u8, kvc.world, "import wasi:clocks/monotonic-clock@0.2.0;") != null);
            try testing.expect(std.mem.indexOf(u8, kvc.world, "export mono: func() -> s64;") != null);
            try testing.expect(std.mem.indexOf(u8, kvc.world, "export res: func() -> s64;") != null);
            // A monotonic-only qube imports NO wall clock — per-interface gating.
            try testing.expect(std.mem.indexOf(u8, kvc.world, "wall-clock") == null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "emitComponent: env.time.sleep_ns lowers to the subscribe/block/drop chain (component) with wasi:io/poll in the world" {
    // TWO exports keep this out of the async gate (a single suspending pub fn
    // lifts async instead — see the async test below), so the sleep takes the
    // sync-blocking 0.2 chain here.
    const src =
        \\pub fn nap(ns: i64) -> i64 {
        \\    env.time.sleep_ns(ns)
        \\    1
        \\}
        \\pub fn probe() -> i64 { 7 }
    ;
    const artifact = try emitComponent(testing.allocator, src, "nap.q", &.{}, .wasm32, &.{}, null);
    switch (artifact) {
        .store_component => |kvc| {
            defer testing.allocator.free(kvc.core);
            defer testing.allocator.free(kvc.world);
            try testing.expect(std.mem.indexOf(u8, kvc.core, "subscribe-duration") != null);
            try testing.expect(std.mem.indexOf(u8, kvc.core, "[method]pollable.block") != null);
            // The drop intrinsic mangles as `pollable_drop` (probed via
            // `component embed --dummy`), NOT `[resource-drop]pollable`.
            try testing.expect(std.mem.indexOf(u8, kvc.core, "pollable_drop") != null);
            try testing.expect(std.mem.indexOf(u8, kvc.core, "cm32p2|wasi:io/poll@0.2") != null);
            try testing.expect(std.mem.indexOf(u8, kvc.world, "import wasi:io/poll@0.2.0;") != null);
            try testing.expect(std.mem.indexOf(u8, kvc.world, "import wasi:clocks/monotonic-clock@0.2.0;") != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "emitComponent: a printing main that sleeps lowers to preview1 poll_oneoff" {
    const app =
        \\fn main {
        \\    env.time.sleep_ns(1000)
        \\    env.out("done")
        \\}
        \\
    ;
    const artifact = try emitComponent(testing.allocator, app, "slp.q", &.{}, .wasm32, &.{}, null);
    switch (artifact) {
        .preview1_app => |core| {
            defer testing.allocator.free(core);
            try testing.expect(std.mem.indexOf(u8, core, "poll_oneoff") != null);
            try testing.expect(std.mem.indexOf(u8, core, "wasi_snapshot_preview1") != null);
            try testing.expect(std.mem.indexOf(u8, core, "cm32p2") == null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "emitComponent: a suspending pub fn lifts ASYNC (callback + task.return, legacy manglings)" {
    const src =
        \\pub fn nap(ns: i64) -> i64 {
        \\    let t0 = env.time.monotonic_ns()
        \\    env.time.sleep_ns(ns)
        \\    env.time.monotonic_ns() - t0
        \\}
    ;
    const artifact = try emitComponent(testing.allocator, src, "nap.q", &.{}, .wasm32, &.{}, null);
    switch (artifact) {
        .store_component => |kvc| {
            defer testing.allocator.free(kvc.core);
            defer testing.allocator.free(kvc.world);
            try testing.expect(std.mem.indexOf(u8, kvc.core, "[async-lift]nap") != null);
            try testing.expect(std.mem.indexOf(u8, kvc.core, "[callback][async-lift]nap") != null);
            try testing.expect(std.mem.indexOf(u8, kvc.core, "[task-return]nap") != null);
            try testing.expect(std.mem.indexOf(u8, kvc.core, "[async-lower]wait-for") != null);
            try testing.expect(std.mem.indexOf(u8, kvc.core, "[waitable-set-new]") != null);
            // Legacy manglings throughout — no cm32p2, no blocking 0.2 chain.
            try testing.expect(std.mem.indexOf(u8, kvc.core, "cm32p2") == null);
            try testing.expect(std.mem.indexOf(u8, kvc.core, "pollable") == null);
            try testing.expect(std.mem.indexOf(u8, kvc.world, "export nap: async func(ns: s64) -> s64;") != null);
            try testing.expect(std.mem.indexOf(u8, kvc.world, clocks_p3_iface) != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "emitComponent: a NON-suspending clock fn still takes the sync 0.2 path (async gate is narrow)" {
    const src =
        \\pub fn mono2() -> i64 { env.time.monotonic_ns() }
    ;
    const artifact = try emitComponent(testing.allocator, src, "m2.q", &.{}, .wasm32, &.{}, null);
    switch (artifact) {
        .store_component => |kvc| {
            defer testing.allocator.free(kvc.core);
            defer testing.allocator.free(kvc.world);
            try testing.expect(std.mem.indexOf(u8, kvc.core, "cm32p2|wasi:clocks/monotonic-clock@0.2") != null);
            try testing.expect(std.mem.indexOf(u8, kvc.core, "[async-lift]") == null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "emitComponent: env.time.unix_ns lowers to a wasi:clocks/wall-clock component (datetime via return area)" {
    const src =
        \\pub fn unix() -> i64 { env.time.unix_ns() }
    ;
    const artifact = try emitComponent(testing.allocator, src, "wall.q", &.{}, .wasm32, &.{}, null);
    switch (artifact) {
        .store_component => |kvc| {
            defer testing.allocator.free(kvc.core);
            defer testing.allocator.free(kvc.world);
            try testing.expect(std.mem.indexOf(u8, kvc.core, "cm32p2|wasi:clocks/wall-clock@0.2") != null);
            // A wall-only qube imports NO monotonic clock, and the datetime
            // return area needs no realloc.
            try testing.expect(std.mem.indexOf(u8, kvc.core, "monotonic-clock") == null);
            try testing.expect(std.mem.indexOf(u8, kvc.core, "cm32p2_realloc") == null);
            try testing.expect(std.mem.indexOf(u8, kvc.world, "import wasi:clocks/wall-clock@0.2.0;") != null);
            try testing.expect(std.mem.indexOf(u8, kvc.world, "monotonic-clock") == null);
            try testing.expect(std.mem.indexOf(u8, kvc.world, "export unix: func() -> s64;") != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "emitComponent: an @http_handler str-in/str-out export lowers to a component" {
    // A str-returning pub fn triggers the component path (no storage needed) and
    // exports through the canonical-ABI return-area wrapper.
    const src =
        \\@http_handler
        \\pub fn serve(method: str, path: str, body: str) -> str {
        \\    "{method} {path} ({body})"
        \\}
    ;
    const artifact = try emitComponent(testing.allocator, src, "http.q", &.{}, .wasm32, &.{}, null);
    switch (artifact) {
        .store_component => |kvc| {
            defer testing.allocator.free(kvc.core);
            defer testing.allocator.free(kvc.world);
            try testing.expect(std.mem.indexOf(u8, kvc.world, "export serve: func(method: string, path: string, body: string) -> string;") != null);
            // The canonical realloc + memory export the return-area wrapper needs.
            try testing.expect(std.mem.indexOf(u8, kvc.core, "cm32p2_memory") != null);
            try testing.expect(std.mem.indexOf(u8, kvc.core, "cm32p2_realloc") != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "emitComponent: a str-returning @http_handler that routes (if/else) and matches env stores" {
    // The real handler shape — routing on method/path with `==`, each leaf a
    // `match` on a store call's `Result` (kv + db + blob), payload bindings
    // interpolated (`Ok(Some(s)) -> "note: {s}"`). Exercises buildStrIf +
    // buildStrMatch and the str value-block lowering.
    const src =
        \\@http_handler
        \\pub fn serve(method: str, path: str, body: str) -> str {
        \\    if method == "POST" && path == "/visit" {
        \\        match env.kv.increment("visits", 1) { Ok(_) -> "visited" Err(_) -> "kv-error" }
        \\    } else if method == "GET" && path == "/note" {
        \\        match env.db.query_text("SELECT body FROM notes LIMIT 1") { Ok(Some(s)) -> "note: {s}" Ok(None) -> "none" Err(_) -> "db-error" }
        \\    } else if method == "PUT" && path == "/asset" {
        \\        match env.blob.put("asset", body) { Ok(()) -> "stored" Err(_) -> "blob-error" }
        \\    } else {
        \\        "not found"
        \\    }
        \\}
    ;
    const artifact = try emitComponent(testing.allocator, src, "api.q", &.{}, .wasm32, &.{}, null);
    switch (artifact) {
        .store_component => |kvc| {
            defer testing.allocator.free(kvc.core);
            defer testing.allocator.free(kvc.world);
            // Exports the sync str handler and imports all three stores.
            try testing.expect(std.mem.indexOf(u8, kvc.world, "export serve: func(method: string, path: string, body: string) -> string;") != null);
            try testing.expect(std.mem.indexOf(u8, kvc.world, "wasi:keyvalue/atomics") != null);
            try testing.expect(std.mem.indexOf(u8, kvc.world, "q64:db/sql") != null);
            try testing.expect(std.mem.indexOf(u8, kvc.world, "q64:blob/store") != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

/// The `Vec` v0 floor's runtime (spec/types.md §Growable, "v0 floor"):
/// a 3-slot header {data, len, cap} at address width; i64 elements;
/// copy-on-grow ×2 (min capacity 4). Growth bumps `sp` directly — these
/// are not MIR calls, so the frame-reclamation slide never reclaims a
/// grown block out from under a live vec.
fn emitVecHelpers(module: c.BinaryenModuleRef, allocator: std.mem.Allocator, i64_type: c.BinaryenType, i32_type: c.BinaryenType, ptr_type: c.BinaryenType, mem64: bool) !void {
    _ = i32_type;
    const none = c.BinaryenTypeNone();
    const W: i64 = if (mem64) 8 else 4;
    const wbytes: u32 = if (mem64) 8 else 4;
    const add_p = if (mem64) c.BinaryenAddInt64() else c.BinaryenAddInt32();
    const and_p = if (mem64) c.BinaryenAndInt64() else c.BinaryenAndInt32();
    const shl_p = if (mem64) c.BinaryenShlInt64() else c.BinaryenShlInt32();
    const eq_p = if (mem64) c.BinaryenEqInt64() else c.BinaryenEqInt32();
    const eqz_p = if (mem64) c.BinaryenEqZInt64() else c.BinaryenEqZInt32();

    const h = struct {
        fn loadW(m: c.BinaryenModuleRef, off: u32, w: u32, pt: c.BinaryenType, base: c.BinaryenExpressionRef) c.BinaryenExpressionRef {
            return c.BinaryenLoad(m, @intCast(w), false, off, 0, pt, base, "0");
        }
        fn storeW(m: c.BinaryenModuleRef, off: u32, w: u32, pt: c.BinaryenType, base: c.BinaryenExpressionRef, v: c.BinaryenExpressionRef) c.BinaryenExpressionRef {
            return c.BinaryenStore(m, @intCast(w), off, 0, base, v, pt, "0");
        }
        /// (sp + 7) & ~7 — an 8-aligned allocation base.
        fn align8(m: c.BinaryenModuleRef, m64: bool, pt: c.BinaryenType, addp: c.BinaryenOp, andp: c.BinaryenOp) c.BinaryenExpressionRef {
            // Allocate from the persistent vec heap `hp`, not the per-call `sp`.
            return c.BinaryenBinary(m, andp, c.BinaryenBinary(m, addp, c.BinaryenGlobalGet(m, "hp", pt), K.ptrc(m, m64, 7)), K.ptrc(m, m64, -8));
        }
        /// Widen an address-width value to i64 (identity on wasm64).
        fn toI64(m: c.BinaryenModuleRef, m64: bool, v: c.BinaryenExpressionRef) c.BinaryenExpressionRef {
            return if (m64) v else c.BinaryenUnary(m, c.BinaryenExtendUInt32(), v);
        }
        /// Narrow an i64 to address width (identity on wasm64).
        fn toW(m: c.BinaryenModuleRef, m64: bool, v: c.BinaryenExpressionRef) c.BinaryenExpressionRef {
            return if (m64) v else c.BinaryenUnary(m, c.BinaryenWrapInt64(), v);
        }
    };

    // __vec_new() -> ptr: hdr = align8(hp); hp = hdr + 3W; zero the slots.
    {
        const HDR: c.BinaryenIndex = 0; // local
        var stmts = [_]c.BinaryenExpressionRef{
            c.BinaryenLocalSet(module, HDR, h.align8(module, mem64, ptr_type, add_p, and_p)),
            c.BinaryenGlobalSet(module, "hp", c.BinaryenBinary(module, add_p, K.get(module, HDR, ptr_type), K.ptrc(module, mem64, 3 * W))),
            h.storeW(module, 0, wbytes, ptr_type, K.get(module, HDR, ptr_type), K.ptrc(module, mem64, 0)),
            h.storeW(module, @intCast(W), wbytes, ptr_type, K.get(module, HDR, ptr_type), K.ptrc(module, mem64, 0)),
            h.storeW(module, @intCast(2 * W), wbytes, ptr_type, K.get(module, HDR, ptr_type), K.ptrc(module, mem64, 0)),
            K.get(module, HDR, ptr_type),
        };
        const body = c.BinaryenBlock(module, null, @ptrCast(&stmts), stmts.len, ptr_type);
        var var_types = [_]c.BinaryenType{ptr_type};
        _ = c.BinaryenAddFunction(module, "__vec_new", none, ptr_type, @ptrCast(&var_types), var_types.len, body);
    }

    // __vec_push(hdr: ptr, v: i64): copy-on-grow, then store + len++.
    {
        const HDR: c.BinaryenIndex = 0;
        const V: c.BinaryenIndex = 1;
        const LEN: c.BinaryenIndex = 2; // ptr-width locals
        const CAP: c.BinaryenIndex = 3;
        const ND: c.BinaryenIndex = 4;
        var stmts: std.ArrayList(c.BinaryenExpressionRef) = .empty;
        defer stmts.deinit(allocator);
        try stmts.append(allocator, c.BinaryenLocalSet(module, LEN, h.loadW(module, @intCast(W), wbytes, ptr_type, K.get(module, HDR, ptr_type))));
        try stmts.append(allocator, c.BinaryenLocalSet(module, CAP, h.loadW(module, @intCast(2 * W), wbytes, ptr_type, K.get(module, HDR, ptr_type))));
        // if (len == cap) grow
        var grow: std.ArrayList(c.BinaryenExpressionRef) = .empty;
        defer grow.deinit(allocator);
        // cap = cap == 0 ? 4 : cap << 1
        try grow.append(allocator, c.BinaryenLocalSet(module, CAP, c.BinaryenIf(module, eqz_p_wrap(module, eqz_p, K.get(module, CAP, ptr_type)), K.ptrc(module, mem64, 4), c.BinaryenBinary(module, shl_p, K.get(module, CAP, ptr_type), K.ptrc(module, mem64, 1)))));
        // nd = align8(hp); hp = nd + cap*8
        try grow.append(allocator, c.BinaryenLocalSet(module, ND, h.align8(module, mem64, ptr_type, add_p, and_p)));
        try grow.append(allocator, c.BinaryenGlobalSet(module, "hp", c.BinaryenBinary(module, add_p, K.get(module, ND, ptr_type), c.BinaryenBinary(module, shl_p, K.get(module, CAP, ptr_type), K.ptrc(module, mem64, 3)))));
        // memory.copy(nd, data, len*8)
        try grow.append(allocator, c.BinaryenMemoryCopy(module, K.get(module, ND, ptr_type), h.loadW(module, 0, wbytes, ptr_type, K.get(module, HDR, ptr_type)), c.BinaryenBinary(module, shl_p, K.get(module, LEN, ptr_type), K.ptrc(module, mem64, 3)), "0", "0"));
        // hdr.data = nd; hdr.cap = cap
        try grow.append(allocator, h.storeW(module, 0, wbytes, ptr_type, K.get(module, HDR, ptr_type), K.get(module, ND, ptr_type)));
        try grow.append(allocator, h.storeW(module, @intCast(2 * W), wbytes, ptr_type, K.get(module, HDR, ptr_type), K.get(module, CAP, ptr_type)));
        const grow_blk = c.BinaryenBlock(module, null, @ptrCast(grow.items.ptr), @intCast(grow.items.len), none);
        try stmts.append(allocator, c.BinaryenIf(module, c.BinaryenBinary(module, eq_p, K.get(module, LEN, ptr_type), K.get(module, CAP, ptr_type)), grow_blk, null));
        // store i64 at data + len*8 = v
        const slot = c.BinaryenBinary(module, add_p, h.loadW(module, 0, wbytes, ptr_type, K.get(module, HDR, ptr_type)), c.BinaryenBinary(module, shl_p, K.get(module, LEN, ptr_type), K.ptrc(module, mem64, 3)));
        try stmts.append(allocator, c.BinaryenStore(module, 8, 0, 0, slot, K.get(module, V, i64_type), i64_type, "0"));
        // hdr.len = len + 1
        try stmts.append(allocator, h.storeW(module, @intCast(W), wbytes, ptr_type, K.get(module, HDR, ptr_type), c.BinaryenBinary(module, add_p, K.get(module, LEN, ptr_type), K.ptrc(module, mem64, 1))));
        const body = c.BinaryenBlock(module, null, @ptrCast(stmts.items.ptr), @intCast(stmts.items.len), none);
        var params = [_]c.BinaryenType{ ptr_type, i64_type };
        const ptype = c.BinaryenTypeCreate(&params, params.len);
        var var_types = [_]c.BinaryenType{ ptr_type, ptr_type, ptr_type };
        _ = c.BinaryenAddFunction(module, "__vec_push", ptype, none, @ptrCast(&var_types), var_types.len, body);
    }

    // __vec_len(hdr) -> i64
    {
        const HDR: c.BinaryenIndex = 0;
        const body = h.toI64(module, mem64, h.loadW(module, @intCast(W), wbytes, ptr_type, K.get(module, HDR, ptr_type)));
        var params = [_]c.BinaryenType{ptr_type};
        const ptype = c.BinaryenTypeCreate(&params, params.len);
        _ = c.BinaryenAddFunction(module, "__vec_len", ptype, i64_type, null, 0, body);
    }

    // __vec_ptr(hdr) -> i64: the element-data address (header data field at
    // offset 0), widened to i64 so a qube can hand the buffer to the host.
    {
        const HDR: c.BinaryenIndex = 0;
        const body = h.toI64(module, mem64, h.loadW(module, 0, wbytes, ptr_type, K.get(module, HDR, ptr_type)));
        var params = [_]c.BinaryenType{ptr_type};
        const ptype = c.BinaryenTypeCreate(&params, params.len);
        _ = c.BinaryenAddFunction(module, "__vec_ptr", ptype, i64_type, null, 0, body);
    }

    // __vec_get(hdr, idx: i64) -> i64: trap on out-of-range (unsigned, so
    // a negative index also traps), then load data[idx].
    {
        const HDR: c.BinaryenIndex = 0;
        const IDX: c.BinaryenIndex = 1;
        const oob = c.BinaryenBinary(module, c.BinaryenGeUInt64(), K.get(module, IDX, i64_type), h.toI64(module, mem64, h.loadW(module, @intCast(W), wbytes, ptr_type, K.get(module, HDR, ptr_type))));
        const slot = c.BinaryenBinary(module, add_p, h.loadW(module, 0, wbytes, ptr_type, K.get(module, HDR, ptr_type)), c.BinaryenBinary(module, shl_p, h.toW(module, mem64, K.get(module, IDX, i64_type)), K.ptrc(module, mem64, 3)));
        var stmts = [_]c.BinaryenExpressionRef{
            c.BinaryenIf(module, oob, c.BinaryenUnreachable(module), null),
            c.BinaryenLoad(module, 8, true, 0, 0, i64_type, slot, "0"),
        };
        const body = c.BinaryenBlock(module, null, @ptrCast(&stmts), stmts.len, i64_type);
        var params = [_]c.BinaryenType{ ptr_type, i64_type };
        const ptype = c.BinaryenTypeCreate(&params, params.len);
        _ = c.BinaryenAddFunction(module, "__vec_get", ptype, i64_type, null, 0, body);
    }

    // __vec_set(hdr, idx: i64, v: i64): trap on out-of-range (unsigned, so a
    // negative index also traps), then store data[idx] = v. Mirrors __vec_get.
    {
        const HDR: c.BinaryenIndex = 0;
        const IDX: c.BinaryenIndex = 1;
        const V: c.BinaryenIndex = 2;
        const oob = c.BinaryenBinary(module, c.BinaryenGeUInt64(), K.get(module, IDX, i64_type), h.toI64(module, mem64, h.loadW(module, @intCast(W), wbytes, ptr_type, K.get(module, HDR, ptr_type))));
        const slot = c.BinaryenBinary(module, add_p, h.loadW(module, 0, wbytes, ptr_type, K.get(module, HDR, ptr_type)), c.BinaryenBinary(module, shl_p, h.toW(module, mem64, K.get(module, IDX, i64_type)), K.ptrc(module, mem64, 3)));
        var stmts = [_]c.BinaryenExpressionRef{
            c.BinaryenIf(module, oob, c.BinaryenUnreachable(module), null),
            c.BinaryenStore(module, 8, 0, 0, slot, K.get(module, V, i64_type), i64_type, "0"),
        };
        const body = c.BinaryenBlock(module, null, @ptrCast(&stmts), stmts.len, none);
        var params = [_]c.BinaryenType{ ptr_type, i64_type, i64_type };
        const ptype = c.BinaryenTypeCreate(&params, params.len);
        _ = c.BinaryenAddFunction(module, "__vec_set", ptype, none, null, 0, body);
    }

    // The 4-byte (`Vec<f32>`) cell variants: identical to the i64-cell helpers
    // but with an element stride of 4 (`idx << 2`) and native f32 stores/loads,
    // so the buffer is packed f32 — a host reads it as `new Float32Array(mem,
    // ptr, n)`. The value crosses as a native f32.
    const f32_type = c.BinaryenTypeFloat32();

    // __vec_push_f32(hdr, v: f32): copy-on-grow at stride 4, then f32.store + len++.
    {
        const HDR: c.BinaryenIndex = 0;
        const V: c.BinaryenIndex = 1;
        const LEN: c.BinaryenIndex = 2;
        const CAP: c.BinaryenIndex = 3;
        const ND: c.BinaryenIndex = 4;
        var stmts: std.ArrayList(c.BinaryenExpressionRef) = .empty;
        defer stmts.deinit(allocator);
        try stmts.append(allocator, c.BinaryenLocalSet(module, LEN, h.loadW(module, @intCast(W), wbytes, ptr_type, K.get(module, HDR, ptr_type))));
        try stmts.append(allocator, c.BinaryenLocalSet(module, CAP, h.loadW(module, @intCast(2 * W), wbytes, ptr_type, K.get(module, HDR, ptr_type))));
        var grow: std.ArrayList(c.BinaryenExpressionRef) = .empty;
        defer grow.deinit(allocator);
        try grow.append(allocator, c.BinaryenLocalSet(module, CAP, c.BinaryenIf(module, eqz_p_wrap(module, eqz_p, K.get(module, CAP, ptr_type)), K.ptrc(module, mem64, 4), c.BinaryenBinary(module, shl_p, K.get(module, CAP, ptr_type), K.ptrc(module, mem64, 1)))));
        try grow.append(allocator, c.BinaryenLocalSet(module, ND, h.align8(module, mem64, ptr_type, add_p, and_p)));
        try grow.append(allocator, c.BinaryenGlobalSet(module, "hp", c.BinaryenBinary(module, add_p, K.get(module, ND, ptr_type), c.BinaryenBinary(module, shl_p, K.get(module, CAP, ptr_type), K.ptrc(module, mem64, 2)))));
        try grow.append(allocator, c.BinaryenMemoryCopy(module, K.get(module, ND, ptr_type), h.loadW(module, 0, wbytes, ptr_type, K.get(module, HDR, ptr_type)), c.BinaryenBinary(module, shl_p, K.get(module, LEN, ptr_type), K.ptrc(module, mem64, 2)), "0", "0"));
        try grow.append(allocator, h.storeW(module, 0, wbytes, ptr_type, K.get(module, HDR, ptr_type), K.get(module, ND, ptr_type)));
        try grow.append(allocator, h.storeW(module, @intCast(2 * W), wbytes, ptr_type, K.get(module, HDR, ptr_type), K.get(module, CAP, ptr_type)));
        const grow_blk = c.BinaryenBlock(module, null, @ptrCast(grow.items.ptr), @intCast(grow.items.len), none);
        try stmts.append(allocator, c.BinaryenIf(module, c.BinaryenBinary(module, eq_p, K.get(module, LEN, ptr_type), K.get(module, CAP, ptr_type)), grow_blk, null));
        const slot = c.BinaryenBinary(module, add_p, h.loadW(module, 0, wbytes, ptr_type, K.get(module, HDR, ptr_type)), c.BinaryenBinary(module, shl_p, K.get(module, LEN, ptr_type), K.ptrc(module, mem64, 2)));
        try stmts.append(allocator, c.BinaryenStore(module, 4, 0, 0, slot, K.get(module, V, f32_type), f32_type, "0"));
        try stmts.append(allocator, h.storeW(module, @intCast(W), wbytes, ptr_type, K.get(module, HDR, ptr_type), c.BinaryenBinary(module, add_p, K.get(module, LEN, ptr_type), K.ptrc(module, mem64, 1))));
        const body = c.BinaryenBlock(module, null, @ptrCast(stmts.items.ptr), @intCast(stmts.items.len), none);
        var params = [_]c.BinaryenType{ ptr_type, f32_type };
        const ptype = c.BinaryenTypeCreate(&params, params.len);
        var var_types = [_]c.BinaryenType{ ptr_type, ptr_type, ptr_type };
        _ = c.BinaryenAddFunction(module, "__vec_push_f32", ptype, none, @ptrCast(&var_types), var_types.len, body);
    }

    // __vec_get_f32(hdr, idx: i64) -> f32: bounds-check, then f32.load data[idx].
    {
        const HDR: c.BinaryenIndex = 0;
        const IDX: c.BinaryenIndex = 1;
        const oob = c.BinaryenBinary(module, c.BinaryenGeUInt64(), K.get(module, IDX, i64_type), h.toI64(module, mem64, h.loadW(module, @intCast(W), wbytes, ptr_type, K.get(module, HDR, ptr_type))));
        const slot = c.BinaryenBinary(module, add_p, h.loadW(module, 0, wbytes, ptr_type, K.get(module, HDR, ptr_type)), c.BinaryenBinary(module, shl_p, h.toW(module, mem64, K.get(module, IDX, i64_type)), K.ptrc(module, mem64, 2)));
        var stmts = [_]c.BinaryenExpressionRef{
            c.BinaryenIf(module, oob, c.BinaryenUnreachable(module), null),
            c.BinaryenLoad(module, 4, false, 0, 0, f32_type, slot, "0"),
        };
        const body = c.BinaryenBlock(module, null, @ptrCast(&stmts), stmts.len, f32_type);
        var params = [_]c.BinaryenType{ ptr_type, i64_type };
        const ptype = c.BinaryenTypeCreate(&params, params.len);
        _ = c.BinaryenAddFunction(module, "__vec_get_f32", ptype, f32_type, null, 0, body);
    }

    // __vec_set_f32(hdr, idx: i64, v: f32): bounds-check, then f32.store data[idx].
    {
        const HDR: c.BinaryenIndex = 0;
        const IDX: c.BinaryenIndex = 1;
        const V: c.BinaryenIndex = 2;
        const oob = c.BinaryenBinary(module, c.BinaryenGeUInt64(), K.get(module, IDX, i64_type), h.toI64(module, mem64, h.loadW(module, @intCast(W), wbytes, ptr_type, K.get(module, HDR, ptr_type))));
        const slot = c.BinaryenBinary(module, add_p, h.loadW(module, 0, wbytes, ptr_type, K.get(module, HDR, ptr_type)), c.BinaryenBinary(module, shl_p, h.toW(module, mem64, K.get(module, IDX, i64_type)), K.ptrc(module, mem64, 2)));
        var stmts = [_]c.BinaryenExpressionRef{
            c.BinaryenIf(module, oob, c.BinaryenUnreachable(module), null),
            c.BinaryenStore(module, 4, 0, 0, slot, K.get(module, V, f32_type), f32_type, "0"),
        };
        const body = c.BinaryenBlock(module, null, @ptrCast(&stmts), stmts.len, none);
        var params = [_]c.BinaryenType{ ptr_type, i64_type, f32_type };
        const ptype = c.BinaryenTypeCreate(&params, params.len);
        _ = c.BinaryenAddFunction(module, "__vec_set_f32", ptype, none, null, 0, body);
    }

}

/// `eqz` as an i32 condition regardless of operand width.
fn eqz_p_wrap(module: c.BinaryenModuleRef, eqz_op: c.BinaryenOp, v: c.BinaryenExpressionRef) c.BinaryenExpressionRef {
    return c.BinaryenUnary(module, eqz_op, v);
}
