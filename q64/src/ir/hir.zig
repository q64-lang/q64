//! HIR — the High-level / Semantic Q64 IR.
//!
//! "What the program means," backend- *and* lowering-agnostic. Name-
//! resolved and (eventually) type/region/effect-annotated, with source
//! sugar desugared but values kept high-level: a `str` is an abstract
//! string value, not yet a `(ptr, len)` pair. The semantic passes
//! (typeck/region/effect) operate here; the HIR→MIR `lower` pass turns it
//! into the executable MIR.
//!
//! This file is pure Zig and MUST NOT import the Binaryen C API — keeping
//! the IR neutral is enforced structurally (only the codegen backend links
//! Binaryen). See `q64/src/ir/README.md` and the project plan.
//!
//! Status: v0 covers the constructs the codegen router lowers through the
//! IR today (currently `fn main` whose body is `env.out("literal")`). The
//! unions grow one arm at a time as each migration phase lands; everything
//! else still flows through the legacy AST→Binaryen path in `codegen/`.

const std = @import("std");
const parser = @import("parser");
const ast = parser.ast;
pub const ops = @import("ops.zig");

pub const FuncId = u32;

/// A resolved function: its AST declaration plus the **scope** (module) its body
/// resolves against. Resolution is module-scoped — a name is looked up in the
/// caller's scope, but the callee's body resolves in *its own* scope (its module's
/// locals + imports), so a library can call its own helpers and its own imports.
pub const Resolved = struct {
    fd: ast.FnDecl,
    /// The scope index the callee's body resolves in (the module that defines it).
    scope: u32,
};

/// Resolves a function name to its AST declaration, **within a given scope**.
/// The AST→HIR builder calls this to turn a call site into a `FuncId`; the
/// codegen router backs it with the sema `Linker`. Scope 0 is the root file;
/// each imported module gets its own scope (see `sema.link`).
pub const ModuleResolver = struct {
    ctx: *anyopaque,
    lookupFn: *const fn (*anyopaque, scope: u32, name: []const u8) ?Resolved,
    /// The source file of a module scope — the builder uses it to collect an
    /// imported module's own module-level constants the first time it
    /// compiles a body in that scope. Optional: a resolver without it limits
    /// imported modules to const-free bodies (the pre-existing behavior).
    sourceFileFn: ?*const fn (*anyopaque, scope: u32) ?ast.SourceFile = null,

    pub fn lookup(self: ModuleResolver, scope: u32, name: []const u8) ?Resolved {
        return self.lookupFn(self.ctx, scope, name);
    }

    pub fn sourceFile(self: ModuleResolver, scope: u32) ?ast.SourceFile {
        const f = self.sourceFileFn orelse return null;
        return f(self.ctx, scope);
    }
};

/// One function of a foreign WIT interface a qube imports (WIT rung 5, the
/// codegen call binding). `name` is the q64-callable function name (`add`); the
/// param/result types are the scalar lowering of the WIT signature.
pub const ForeignFn = struct {
    name: []const u8,
    params: []const Type,
    ret: Type, // `.void` for a no-result import.
};

/// A foreign interface a qube imports by its WIT id. A source call
/// `<local>.<fn>(args)` where `<local>` names this interface lowers to a wasm
/// import `(import "<wit_id>" "<fn>" …)` and a call to it. `local` is the name
/// q64 source uses to refer to the interface (its last id segment, e.g. `math`
/// for `acme:mathlib/math`).
pub const ForeignIface = struct {
    local: []const u8,
    wit_id: []const u8,
    funcs: []const ForeignFn,

    /// The function `name` in this interface, if present.
    pub fn find(self: ForeignIface, name: []const u8) ?ForeignFn {
        for (self.funcs) |f| if (std.mem.eql(u8, f.name, name)) return f;
        return null;
    }
};

/// Source-level value types. `str` is abstract here (it only becomes a
/// `(ptr, len)` pair in MIR).
/// `ptr` is an address-space-width pointer/length (i32 on wasm32, i64 on
/// wasm64) — used for the two locals backing a runtime `str` binding's
/// `(ptr, len)`. Distinct from `i64` (a genuine integer value) so the backend
/// realizes pointer locals at the build's address width. `str` itself stays
/// abstract (the `(ptr, len)` pair is a lowering concern).
// The narrow integer widths (`u8` … `i32`) are *storage* types in v0:
// valid as struct fields (loads widen to the i64 compute floor, stores
// truncate to the field width), formattable, and explicit-cast sources.
// Arithmetic on them is deliberately unsupported until the spec pins
// narrow-overflow semantics (wrap vs trap).
// The SIMD types (`f32x4`, `i32x4`) are the lane-shaped views of the single
// wasm `v128` storage type. They stay distinct at the HIR tier — like `f32`
// vs `f64` — so a binding's type alone determines the instruction family;
// MIR collapses both to `v128` and the lane shape rides on each SIMD op.
pub const Type = enum { i64, i32, u32, i16, u16, i8, u8, f32, f64, f32x4, i32x4, str, bool, ptr, void };

/// A definite semantic error the AST→HIR builder detected — distinct from
/// "construct not yet supported" (which signals a fall-back). The codegen
/// front maps each to its honest-baseline diagnostic code, so the IR path
/// owns these diagnostics directly (no legacy emitter needed). Backend-neutral
/// (no Binaryen, no codegen `Error` dependency): the mapping lives in codegen.
pub const Reject = enum {
    /// No `fn main` and the module isn't a valid main-less twin → NoMainFunction.
    no_main,
    /// A call that can't be lowered as written: a non-`env.out`/non-host callee,
    /// a wrong argument count, a non-i64 callee in an i64 expression, or a
    /// value `if` with no `else` → UnsupportedCall.
    unsupported_call,
    /// A called/interpolated name resolves to no function → NameNotFound.
    name_not_found,
    /// An entirely-constant expression that can't be evaluated (divide-by-zero,
    /// overflow), or a nested non-const call argument → NotConstExpr.
    not_const,
    /// Assignment to a `let` binding or a parameter → ImmutableAssign.
    immutable_assign,
};

pub const Visibility = enum { private, public };

/// A positive **capability effect** — "this function may do X" (spec/effects.md
/// §"Capabilities"). The compiler infers a function's set from the host faces
/// it transitively reaches; the component/WIT lift turns the set into the
/// synthesized world's *imports* (visibility gives the *exports*). Capabilities
/// propagate **up** the call graph: calling an `@io` callee makes the caller
/// `@io` too.
///
/// v0 detects the faces the HIR models today (`env.out` → `@stdout`, a `qview.*`
/// host call → `@ui`); the remaining markers are listed so the enum is
/// spec-complete and the lift has stable names, even before a face that emits
/// them lands. The *assert* / *observation* markers (`@pure`, `@realtime`,
/// `@cancel`, …) are a separate, later pass — this enum is capabilities only.
///
/// `@io` sorts last so a set prints finest-grained first (`@stdout + @io`).
pub const Effect = enum {
    stdout,
    stderr,
    network,
    fs,
    kv,
    blob,
    db,
    config,
    audio,
    midi,
    ui,
    inference,
    time,
    random,
    exit,
    envvars,
    wire,
    io,

    /// The `@`-prefixed source marker (`@stdout`, …).
    pub fn marker(self: Effect) []const u8 {
        return switch (self) {
            .stdout => "@stdout",
            .stderr => "@stderr",
            .network => "@network",
            .fs => "@fs",
            .kv => "@kv",
            .blob => "@blob",
            .db => "@db",
            .config => "@config",
            .audio => "@audio",
            .midi => "@midi",
            .ui => "@ui",
            .inference => "@inference",
            .time => "@time",
            .random => "@random",
            .exit => "@exit",
            .envvars => "@envvars",
            .wire => "@wire",
            .io => "@io",
        };
    }

    /// The capability this effect implies, if any (`@stdout` ⇒ `@io`), per
    /// spec/effects.md §"Implication graph". One level; the effect pass closes
    /// it transitively. The peer capabilities (`@audio`, `@ui`, `@time`, …) do
    /// not imply `@io` — they target dedicated host surfaces.
    pub fn implies(self: Effect) ?Effect {
        return switch (self) {
            .stdout, .stderr, .network, .fs, .kv, .blob, .db, .config, .wire => .io,
            else => null,
        };
    }

    /// The WIT interface a component built from this qube imports for the
    /// effect, per spec/effects.md §"The capability table is the import table".
    /// `null` for effects with no single import surface: `@io` (the umbrella —
    /// only its finer-grained members import) and `@wire` (the import is the
    /// remote qube's own `world`, not a fixed interface). The WASI rows pin to
    /// the WASIp3 snapshot env.md tracks; the host-custom rows (`@audio`/`@midi`/
    /// `@ui`/`@inference`) have no WASI P2 interface.
    /// The WASI/host WIT interface(s) a capability lowers to (spec/env.md §"Env
    /// ↔ WASI Preview 3"). A face can map to **more than one** interface — e.g.
    /// `env.kv` is `wasi:keyvalue/{store, atomics}`: the adapter opens the bucket
    /// via `store` and the qube's `increment` is `atomics.increment`. Returns an
    /// empty slice for `@io` (the umbrella — only its finer-grained members
    /// import) and `@wire` (the import is the remote qube's own `world`, not a
    /// fixed interface). The WASI rows pin to the WASIp3 snapshot env.md tracks.
    pub fn witImports(self: Effect) []const []const u8 {
        return switch (self) {
            .stdout => &.{"wasi:cli/stdout"},
            .stderr => &.{"wasi:cli/stderr"},
            // `env.net`: outbound sockets + outbound HTTP (spec/env.md table).
            .network => &.{ "wasi:sockets/tcp", "wasi:sockets/udp", "wasi:sockets/instance-network", "wasi:sockets/ip-name-lookup", "wasi:http/handler" },
            .fs => &.{ "wasi:filesystem/types", "wasi:filesystem/preopens" },
            .kv => &.{ "wasi:keyvalue/store", "wasi:keyvalue/atomics" },
            // `env.blob` targets a q64-owned interface (our host supplies it),
            // NOT raw wasi:blobstore: blobstore's write path is stream-only
            // (outgoing-value → wasi:io/streams), which q64 codegen does not yet
            // emit. The narrow store shape keeps put/get/delete on the flat
            // list<u8> path (spec/env.md §`env.blob`). Revisit once wasi:io
            // stream emission lands.
            .blob => &.{"q64:blob/store"},
            // `env.db` targets a q64-owned SQL interface (our host supplies it),
            // NOT raw wasi:sql: that draft's single-cell row model, 13-case value
            // variant, and lack of batch don't map to a landed q64 decode. v0
            // exposes exec + scalar query projections (spec/env.md §`env.db`).
            .db => &.{"q64:db/sql"},
            // `env.config` maps to the real `wasi:config/store` proposal
            // (read-only config/secrets; spec/env.md §`env.config`).
            .config => &.{"wasi:config/store"},
            // Coarse per-effect mapping (like kv's store+atomics pair): the
            // emitted world is finer — it imports only the clock interfaces
            // the qube actually reaches (see `synthStoreWorld`).
            .time => &.{ "wasi:clocks/monotonic-clock", "wasi:clocks/wall-clock" },
            .random => &.{"wasi:random/random"},
            .envvars => &.{"wasi:cli/environment"},
            .exit => &.{"wasi:cli/exit"},
            .audio => &.{"q64:host/audio"},
            .midi => &.{"q64:host/midi"},
            .ui => &.{"q64:host/ui"},
            .inference => &.{"q64:host/inference"},
            .io, .wire => &.{},
        };
    }
};

/// One module's worth of HIR, arena-owned. Callers allocate every node via
/// `alloc()` so the whole graph frees in one `deinit()`. The arena is moved
/// with the struct (its buffers live on the heap), so do not hold a
/// captured `Allocator` interface across a return.
pub const Module = struct {
    arena: std.heap.ArenaAllocator,
    funcs: []Func = &.{},
    entry: ?FuncId = null,
    /// Module-level reactive `state` bindings, in declaration order. Each lowers
    /// to a mutable wasm global initialized to `inits[i]`. Read via `global_get`,
    /// written via `global_set` (by index).
    globals: []const i64 = &.{},
    /// Names of the module globals, parallel to `globals` (for exporting by name).
    global_names: []const []const u8 = &.{},
    /// The module-init function (the wasm `start`), if any — runs once at
    /// instantiation to allocate module-lifetime singletons (`let twin =
    /// Counter.spawn()`) into their globals. A void `Func` in `funcs`; the
    /// backend wires it via `BinaryenSetStart` (it is never exported).
    init_fn: ?FuncId = null,

    pub fn init(gpa: std.mem.Allocator) Module {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }
    pub fn deinit(self: *Module) void {
        self.arena.deinit();
    }
    pub fn alloc(self: *Module) std.mem.Allocator {
        return self.arena.allocator();
    }
};

pub const Param = struct { name: []const u8, ty: Type };

/// One field initializer of a `record_alloc`: store `value` (typed `ty`) at
/// `base + offset`. Offsets/sizes follow spec/memory.md §"Linear struct
/// layout"; the builder computes them from the struct declaration.
pub const FieldInit = struct { offset: u32, ty: Type, value: *Expr };
pub const StrFieldInit = struct { offset: u32, value: *Expr };

pub const Func = struct {
    name: []const u8,
    params: []Param = &.{},
    ret: Type = .void,
    /// Locals declared beyond the parameters (in-body `let`/`var`), in
    /// declaration order. Parameters occupy local indices `0..params.len`.
    locals: []Type = &.{},
    body: *Stmt,
    /// Carried for the future component/WIT lift (exports = the pub surface).
    visibility: Visibility = .private,
    /// A "screen" function — its body is screen statements (host_call / global
    /// assign / let), lowered like the entry. main is the entry screen; other
    /// screen functions (e.g. `on_press`) are exported by name when public.
    is_screen: bool = false,
    /// The capability effect set, inferred by the effect pass (`effects.zig`):
    /// the host faces this function transitively reaches, implication-closed and
    /// sorted (finest-grained first, `@io` last), deduped. Empty before the pass
    /// runs and for a function that reaches no capability. The component/WIT +
    /// QubePod stages read this as the import side of the world.
    effects: []const Effect = &.{},
    /// For a record/boxed-enum-returning function (`ret == .ptr`): the
    /// returned value's byte size, read by the backend's frame-reclamation
    /// slide (spec/memory.md §"Frame reclamation"). 0 otherwise.
    ret_size: u32 = 0,
    /// The returned aggregate contains pointers (a str enum payload):
    /// the flat slide would dangle them, so the call site skips
    /// reclamation entirely (the spec's pinned interior-pointer
    /// boundary — recursive slides land with named regions).
    ret_ptr_bearing: bool = false,
};

/// High-level statements. `block` is shared; the `host_out*` forms appear in
/// `main`; the rest make up an `i64` function body. Local references use the
/// resolved index assigned by the builder (parameters first, then in-body
/// bindings in declaration order). Compound assignment (`+=` …) is desugared
/// to `assign(idx, bin(op, local(idx), rhs))`.
/// Which standard byte stream a host write targets. `out` → `env.out` /
/// `wasi:cli/stdout`; `err` → `env.err` / `wasi:cli/stderr`. The formatting and
/// newline handling are identical; only the final sink (the raw `env.*` face or
/// the preview1 fd) differs, so the whole `host_out*` family carries this tag
/// rather than duplicating into a parallel `host_err*` set.
pub const Stream = enum { out, err };

/// One host byte-write: the value expression plus its target stream. Shared by
/// every `host_out*` statement form (`env.out` and `env.err` differ only in
/// `.stream`).
pub const HostWrite = struct { value: *Expr, stream: Stream };

pub const Stmt = union(enum) {
    block: []const *Stmt,
    /// `v.push(x)` — append an element to a vec (copy-on-grow). `cell4` selects a
    /// packed 4-byte cell (a `Vec<f32>`, value carried in the low 32 bits) over
    /// the default 8-byte i64 cell.
    vec_push: struct { vec: *Expr, value: *Expr, cell4: bool = false },
    /// `v[i] = x` — store `value` at index `idx` of a vec (bounds-checked, traps
    /// out-of-range like `vec_get`). The write counterpart of `vec_get`. `cell4`
    /// selects the packed 4-byte cell.
    vec_set: struct { vec: *Expr, idx: *Expr, value: *Expr, cell4: bool = false },
    /// `x.store(v, i)` — store the four f32 lanes of a `Simd<f32, 4>` at
    /// `v[i..i+4)` of a `Vec<f32>` (bounds-checked as one unit; traps if
    /// `i + 4 > len`). The write half of `Simd.load`.
    simd_store: struct { vec: *Expr, idx: *Expr, value: *Expr },
    /// `env.out/err(expr)` — `expr` is `str`-typed. The trailing newline is the
    /// capability ABI's, materialized during lowering.
    host_out: HostWrite,
    /// `env.out/err(expr)` where `expr` is `i64` — formatted to decimal on lowering.
    host_out_int: HostWrite,
    /// `env.out/err(expr)` where `expr` is `f64` — formatted via `__fmt_f64`.
    host_out_float: HostWrite,
    /// `env.out/err(expr)` where `expr` is a runtime `str` value (e.g. a call to
    /// a str-returning function) — its `(ptr, len)` is written, then a newline.
    host_out_str: HostWrite,
    /// `env.out/err(expr)` where `expr` is a boolean (a comparison, `&&`/`||`/`!`,
    /// a `true`/`false` literal, or a `-> bool` call). Lowers to a value `if`
    /// that writes the constant `"true"` / `"false"` text.
    host_out_bool: HostWrite,
    /// `env.exit(expr)` — `expr` is the `i64` process exit code. Lowers to the
    /// raw `env.exit` host face (browser / wasmtime-core hosts) or, on the
    /// preview1/component path, `wasi_snapshot_preview1.proc_exit` (which the
    /// WASI adapter lifts to `wasi:cli/exit`). Marks `@exit`.
    host_exit: *Expr,
    /// `env.time.sleep_ns(ns)` — BLOCKING sleep for `ns` nanoseconds
    /// (spec/env.md §"Face method ↔ WIT function mapping"). A synchronously-
    /// lowered wait per the component-model async ABI — the host parks the
    /// task; the suspending `sleep -> future<()>` arrives with the CPS
    /// milestone (todo.md §"Futures ladder"). Marks `@time`.
    time_sleep_ns: *Expr,
    /// A call to a host import face (`qview.text(…)`): `name` is the dotted
    /// source name; `args` are i64 expressions. Lowers to a wasm import call.
    host_call: struct { name: []const u8, args: []const *Expr },
    /// Write a module-level `state` global (`count = …`), by index.
    global_set: struct { idx: u32, value: *Expr },
    /// An `i64` expression statement; as a block's tail it is the value.
    expr: *Expr,
    ret: ?*Expr,
    let: struct { idx: u32, value: *Expr },
    assign: struct { idx: u32, value: *Expr },
    /// A runtime `str` binding (`let g = shout("hi")`): store the value's
    /// `(ptr, len)` into the two locals `ptr_idx`/`len_idx`.
    str_let: struct { ptr_idx: u32, len_idx: u32, value: *Expr },
    /// Store a record field through its base pointer (`p.x = v` on a
    /// materialized record): write `value` (typed `ty`) at `base + offset`.
    field_set: struct { base: *Expr, offset: u32, ty: Type, value: *Expr },
    /// `then_`/`else_` are blocks (an `else if` is a block holding one `if_`).
    if_: struct { cond: *Expr, then_: *Stmt, else_: ?*Stmt },
    while_: struct { cond: *Expr, body: *Stmt },
    loop_: *Stmt,
    brk,
    cont,
    /// `panic <msg?>` — write the message (a `str`, when present) to stderr,
    /// then trap (a wasm `unreachable`, which the host surfaces as exit 1).
    /// A non-str / absent payload traps without a message on the v0 floor.
    panic: ?*Expr,
};

/// High-level expressions. `str` stays abstract; the `(ptr, len)` ABI is a
/// lowering (MIR) concern. Grows per phase (concat/interpolation later).
pub const Expr = union(enum) {
    /// A fully-resolved constant string value (escapes decoded, no newline).
    str_const: []const u8,
    int_const: i64,
    /// An f64 constant (`3.14`, `1e9`). Floats never const-fold in v0 —
    /// they stay runtime values end to end.
    float_const: f64,
    /// An explicit numeric cast (`f32(x)`, `f64(x)`, `i64(x)` —
    /// spec/types.md §Casts; the only conversions, nothing implicit).
    /// float→int narrowing traps on overflow/NaN per the spec.
    num_cast: struct { to: Type, value: *Expr },
    /// A **bit reinterpretation** between `f64` and `i64` (not a value
    /// conversion): the raw bits are kept. Used to store an `f64` in a channel's
    /// i64 buffer cell and read it back. (`num_cast` would convert the value.)
    bitcast: struct { to: Type, value: *Expr },
    /// A `true` / `false` literal. A boolean (i32 0/1), like a comparison or
    /// `!` — usable in conditions and as an operand of `&&`/`||`/`!`.
    bool_const: bool,
    /// A parameter or in-body binding, by resolved local index. `ty` is the
    /// binding's type (i64 / bool / str), so lowering reads it as the right
    /// kind (an i64/i32 `local_get`, or a `str_param`).
    local: struct { idx: u32, ty: Type = .i64 },
    /// Read a module-level `state` global, by index.
    global_get: u32,
    bin: struct { kind: ops.BinKind, lhs: *Expr, rhs: *Expr },
    un: struct { kind: ops.UnKind, operand: *Expr },
    /// `Simd.splat(x)` — broadcast a scalar into every lane of a `v128`.
    /// The operand is `f32`-typed for `.f32x4` and `i64`-typed for `.i32x4`
    /// (codegen wraps to the i32 lane). Kept off the generic `un` because
    /// the lane shape must ride the op: `v128` alone cannot recover it.
    simd_splat: struct { shape: ops.LaneShape, operand: *Expr },
    /// `v.extract(lane)` — read one lane of a `v128` as a scalar. `lane` is
    /// a compile-time immediate (0–3). Yields `f32` for `.f32x4`; `i64` for
    /// `.i32x4` (codegen sign-extends the i32 lane to the i64 compute floor).
    simd_extract: struct { shape: ops.LaneShape, vec: *Expr, lane: u8 },
    /// Lane-wise `v.add(w)` / `v.mul(w)` on two same-shape `v128` values.
    /// `kind` is restricted to `.add`/`.mul` by construction. A dedicated op
    /// (not `bin`) because instruction selection needs the lane shape, which
    /// the operands' `v128` value type alone cannot provide.
    simd_bin: struct { kind: ops.BinKind, shape: ops.LaneShape, lhs: *Expr, rhs: *Expr },
    simd_un: struct { kind: ops.UnKind, shape: ops.LaneShape, operand: *Expr },
    /// `Simd.load(v, i)` — load four f32 lanes from `v[i..i+4)` of a
    /// `Vec<f32>` as a `Simd<f32, 4>` (bounds-checked as one unit).
    simd_load: struct { vec: *Expr, idx: *Expr },
    /// `v.replace(n, x)` — the vector with lane `n` replaced by scalar `x`.
    simd_replace: struct { shape: ops.LaneShape, vec: *Expr, lane: u8, value: *Expr },
    /// `a.mul_add(b, c)` — lane-wise `a·b + c` via relaxed-SIMD fused
    /// multiply-add (f32x4 only). Relaxed: whether the intermediate product
    /// rounds is implementation-defined — that's the price of the FMA.
    simd_fma: struct { a: *Expr, b: *Expr, c: *Expr },
    /// Short-circuit `&&` / `||`. Kept distinct from `bin` because it lowers
    /// to control flow (a value `if_`), not a backend binary op. Yields a
    /// boolean (i32 0/1); both operands are truthiness-tested.
    logical: struct { op: ops.LogicalKind, lhs: *Expr, rhs: *Expr },
    /// A call to another function, resolved to its `FuncId`.
    call: struct { func: FuncId, args: []const *Expr },
    /// A call to a **foreign WIT interface** function (WIT rung 5, the call
    /// binding): `<iface>.<fn>(args)` where `<iface>` is a `--wit-import`
    /// interface. Lowers to a wasm import `(import "<module>" "<field>" …)` and
    /// a call. `module` is the interface's WIT id, `field` the function name.
    /// Scalar args/result only (the canonical-ABI boundary). Carries `@wire`.
    foreign_call: struct { module: []const u8, field: []const u8, ret: Type, args: []const *Expr },
    /// A runtime string concatenation (interpolation with dynamic pieces).
    /// Each piece is a `str` value: a `str_const` run, a `local` parameter, a
    /// `call`, an `fmt_int` of an i64, or a `str_binding`.
    concat: []const *Expr,
    /// The `str` value of a runtime binding, read from its two locals.
    str_binding: struct { ptr_idx: u32, len_idx: u32 },
    /// The decimal `str` of an i64 value (the high-level form of `__fmt_i64`).
    /// Used as a concat piece when an i64 binding appears in interpolation, and
    /// as the value of an `env.out(<i64>)` would be — but `host_out_int` is the
    /// shorter path for the latter, so `fmt_int` only appears inside `concat`.
    fmt_int: *Expr,
    /// The decimal `str` of an f64 value (`__fmt_f64`: integer part, `.`,
    /// up to 6 fractional digits, trailing zeros trimmed). A concat piece,
    /// like `fmt_int`.
    fmt_float: *Expr,
    /// The byte length of a `str` value as an i64 (`s.len`). The operand is a
    /// str-valued expression; lowering reads its `(ptr, len)` len component and
    /// zero-extends it to i64.
    str_len: *Expr,
    /// The unsigned byte at index `idx` of a `str` value as an i64 (`s[i]`). No
    /// bounds check today — out-of-range reads other memory (caller guards with
    /// `s.len`). `str` is str-valued, `idx` is i64.
    str_index: struct { str: *Expr, idx: *Expr },
    /// Byte-wise equality of two `str` values (`a == b`) as a bool (i32 0/1).
    /// `!=` is this wrapped in `un{.not}`. Lowers to a `__str_eq` helper call.
    str_eq: struct { lhs: *Expr, rhs: *Expr },
    /// `env.fs.read(path)` — the file's bytes as a str value
    /// (spec/env.md §"Wire ABI: fs.read"). Marks the function `@fs`.
    fs_read: struct { path: *Expr },
    /// `env.kv.increment(key, delta)` — atomically add `delta` to the counter
    /// at `key` in the project's key-value store and return the new total, i64
    /// (spec/env.md §`env.kv`, `wasi:keyvalue/atomics.increment`). `key` is a
    /// `str`; the keyless `env.kv.increment(delta)` form leaves `key` null (the
    /// host uses the empty key — a single shared counter). Marks the fn `@kv`.
    kv_increment: struct { key: ?*Expr, delta: *Expr },
    /// `env.kv.set(key, value)` — store `value` (a `Bytes`/`str`, ptr+len) at
    /// `key` in the project's key-value store, overwriting any existing value
    /// (spec/env.md §`env.kv`, `wasi:keyvalue/store.bucket.set`). Both operands
    /// are `str`-shaped `(ptr, len)` pairs. Lowers to a lazy `store.open` +
    /// `[method]bucket.set` and yields a boxed `Result<(), IoError>` (`Ok(())`
    /// on success, `Err` carrying the store error code). Marks the fn `@kv`.
    kv_set: struct { key: *Expr, value: *Expr },
    /// `env.kv.get(key)` — read the value stored at `key` in the project's
    /// key-value store (spec/env.md §`env.kv`, `wasi:keyvalue/store.bucket.get`).
    /// `key` is a `str` `(ptr, len)`. Lowers to a lazy `store.open` +
    /// `[method]bucket.get` and yields a boxed `Result<Option<Bytes>, IoError>`
    /// (`Ok(Some(v))` when present, `Ok(None)` when absent, `Err` on a store
    /// error). Marks the fn `@kv`.
    kv_get: struct { key: *Expr },
    /// `env.blob.put(key, value)` — store `value` (a `Bytes`/`str`) at `key` in
    /// the project's object store (spec/env.md §`env.blob`). Lowers to a lazy
    /// `q64:blob/store.open` + `[method]bucket.put`, yielding a boxed
    /// `Result<(), IoError>`. Marks the fn `@blob`. The q64-owned store interface
    /// keeps bytes flat (host does any blobstore streaming). Same shape as
    /// `kv_set` — a different bucket + import.
    blob_put: struct { key: *Expr, value: *Expr },
    /// `env.blob.get(key)` — read the object at `key` (spec/env.md §`env.blob`,
    /// `q64:blob/store.bucket.get`). Boxed `Result<Option<Bytes>, IoError>`
    /// (`Ok(Some(v))`/`Ok(None)`/`Err`). Marks the fn `@blob`. Same shape as
    /// `kv_get`.
    blob_get: struct { key: *Expr },
    /// `env.blob.delete(key)` — remove the object at `key` (idempotent;
    /// `q64:blob/store.bucket.delete`). Boxed `Result<(), IoError>`. Marks `@blob`.
    blob_delete: struct { key: *Expr },
    /// `env.db.execute(sql)` — run a no-row statement (DDL / INSERT / UPDATE /
    /// DELETE) on the project's SQL database (spec/env.md §`env.db`,
    /// `q64:db/sql.connection.exec`). `sql` is a `str`. Lowers to a lazy
    /// `open` + `[method]connection.exec`, boxed `Result<u64, IoError>`
    /// (`Ok(rows-affected)`). Marks the fn `@db`.
    db_execute: struct { sql: *Expr },
    /// `env.db.query_value(sql)` — the first column of the first row as an
    /// integer (`q64:db/sql.connection.query-value`). Boxed
    /// `Result<Option<i64>, IoError>` (`Ok(Some(n))`/`Ok(None)`/`Err`). Marks `@db`.
    db_query_value: struct { sql: *Expr },
    /// `env.db.query_text(sql)` — the first column of the first row as text
    /// (`q64:db/sql.connection.query-text`). Boxed
    /// `Result<Option<Bytes>, IoError>` (`Ok(Some(s))`/`Ok(None)`/`Err`). Marks `@db`.
    db_query_text: struct { sql: *Expr },
    /// `env.db.query_one<Row>(sql)` — the first row's integer columns as a typed
    /// struct (`q64:db/sql.connection.query-one`, `result<option<list<s64>>>`).
    /// Boxed `Result<Option<Row>, IoError>` (`Ok(Some(row))`/`Ok(None)`/`Err`);
    /// the row struct decodes zero-copy over the canonical `list<s64>` (N
    /// contiguous 8-byte cells = an all-`i64` record). `ncols` is Row's field
    /// count (a decode/repro aid; the box holds the list pointer directly).
    /// Marks `@db`.
    db_query_one: struct { sql: *Expr, ncols: u32 },
    /// `env.config.get(key)` — read a config/secret value by key
    /// (spec/env.md §`env.config`, `wasi:config/store.get`). `key` is a `str`.
    /// `get` is a TOP-LEVEL interface function (no host handle), so it lowers to
    /// a direct `get(key, ret)` — no lazy `open`. Boxed `Result<Option<Bytes>,
    /// IoError>` (`Ok(Some(v))`/`Ok(None)`/`Err`). Marks the fn `@config`.
    config_get: struct { key: *Expr },
    /// `env.time.monotonic_ns()` — the monotonic clock reading in nanoseconds,
    /// i64 (spec/env.md §`env.time`, `wasi:clocks/monotonic-clock.now`). Nullary
    /// and scalar: no key, no handle, no Result box — the one face that crosses
    /// the boundary in registers alone (which is why it is `@realtime`-safe,
    /// spec/env.md §"realtime"). Marks the fn `@time`.
    time_monotonic_ns,
    /// `env.random.u64()` — one i64 of host randomness (`@random`). The
    /// host decides real entropy vs a seeded stream — determinism is a
    /// host policy the capability makes visible, never a language rule.
    random_u64,
    /// `env.time.resolution_ns()` — the monotonic clock's tick size in
    /// nanoseconds, i64 (`wasi:clocks/monotonic-clock.resolution`). Same
    /// bare-scalar shape as `monotonic_ns`. Marks the fn `@time`.
    time_resolution_ns,
    /// `env.time.unix_ns()` — wall-clock time as nanoseconds since the Unix
    /// epoch, i64 (`wasi:clocks/wall-clock.now`; the `datetime {seconds,
    /// nanoseconds}` record is folded to one i64 — good to year 2262). Unlike
    /// the monotonic pair, the record result crosses via a small return area
    /// in component mode. Marks the fn `@time`.
    time_unix_ns,
    /// `chan_recv(session)` — receive the next inbound message on a remote
    /// channel session (`@channel_handler`'s `for _ in session`). Lowers to the
    /// `env.channel_recv` host import: returns 1 when a message arrived (run the
    /// loop body), 0 when the peer closed (end the loop). The operand is the
    /// session handle (an i64). Carries `@wire`. v0 host-import seam (parallel to
    /// `env.kv`); the spec's eventual lowering is a WASIp3 `stream<Rx>`.
    chan_recv: *Expr,
    /// `chan_take(session)` — take the value of the message `chan_recv` just
    /// reported (the `env.channel_take` host import). Called once per iteration
    /// of a value-bearing `for n in session` (an i64 `Rx`), AFTER `chan_recv`
    /// returned 1. The operand is the session handle (i64); yields the i64
    /// payload. Carries `@wire`.
    chan_take: *Expr,
    /// Open a host-backed channel/event stream, yielding a session handle (i64):
    /// `connect<iface.fn>()` (`name` = "channel_connect", a remote channel) or a
    /// host event source like `presses()` (`name` = "presses", HOST SEAM 2).
    /// Lowers to the nullary `env.<name>` host import. Carries `@wire`.
    chan_open: []const u8,
    /// `Vec` v0 floor: a fresh empty vec (header base pointer).
    vec_new,
    /// `v.len` — a live read of the vec's length, i64.
    vec_len: struct { vec: *Expr },
    /// `v.ptr` — the linear-memory address of the vec's element data, widened to
    /// i64. Lets a qube hand a buffer to the host (`new Float32Array(mem, ptr,
    /// n)`); the address is only stable while the vec isn't grown/reallocated.
    vec_ptr: struct { vec: *Expr },
    /// `v.head` — the vec's *header* address (i64). The re-entry handle for
    /// hosts: a header address passed back into an exported fn's `Vec<…>`
    /// parameter reconnects the same buffer (the header holds {data, len,
    /// cap}), which is how a persistent host drives stateful `process`
    /// calls across export boundaries.
    vec_head: struct { vec: *Expr },
    /// `v[i]` — a bounds-checked element load. `cell4` selects the packed 4-byte
    /// cell (a `Vec<f32>`, value zero-extended from 32 bits) over the 8-byte cell.
    vec_get: struct { vec: *Expr, idx: *Expr, cell4: bool = false },
    /// `s.slice(start, end)` — a str sub-view (ptr+start, end-start). No bounds
    /// check; caller guards with `s.len`. `start`/`end` are i64. str-valued.
    str_slice: struct { str: *Expr, start: *Expr, end: *Expr },
    /// `s.index_of(byte)` — index of the first byte == `byte` (i64), or -1. i64.
    str_index_of: struct { str: *Expr, byte: *Expr },
    /// `s.starts_with(prefix)` — does `s` begin with `prefix`? bool (i32 0/1).
    str_starts_with: struct { str: *Expr, prefix: *Expr },
    /// `s.contains(sub)` — does `sub` occur anywhere in `s`? bool (i32 0/1).
    str_contains: struct { str: *Expr, sub: *Expr },
    /// A record value materialized in memory (a record literal that escapes
    /// SROA): allocate `size` bytes in the scope arena at `alignment`, store
    /// each field at its layout offset, yield the base pointer (a `ptr`).
    /// Layout per spec/memory.md §"Linear struct layout".
    record_alloc: struct {
        size: u32,
        alignment: u32,
        inits: []const FieldInit,
        /// str-valued payload cells (a boxed enum's `Some("hi")`): the
        /// value's (ptr, len) stores into two 8-byte cells at offset /
        /// offset+8 (zero-extended to i64 on wasm32).
        str_inits: []const StrFieldInit = &.{},
    },
    /// Read a record field through its base pointer (`p.x` where `p` is a
    /// materialized record value): load the `ty`-typed field at `base + offset`.
    field_get: struct { base: *Expr, offset: u32, ty: Type },
    /// An array literal materialized in the scope arena: `count` elements
    /// of `stride` bytes each. A scalar element stores at its width; a
    /// record element (`copy_bytes` set) is a `.ptr` value whose bytes are
    /// copied inline into the slot. Yields the base pointer.
    array_lit: struct { stride: u32, alignment: u32, elem_ty: Type, copy_bytes: ?u32, inits: []const *Expr },
    /// The address of element `index` (`base + index·stride`) — a `.ptr`.
    /// An inline record element's value IS this address; a scalar loads
    /// through `field_get` at offset 0.
    elem_ptr: struct { base: *Expr, index: *Expr, stride: u32 },
    /// `index`, passed through — but **traps** if `index >= count` or
    /// `index < 0` (spec/types.md: bounds violations trap; `a.get(i)` is
    /// the fallible form, later).
    bounds_check: struct { index: *Expr, count: *Expr },
    /// A `[str]` literal (`["a", "b"]`): materialize `count` consecutive
    /// `(ptr, len)` str cells in the scope arena and yield the `(data_ptr,
    /// count)` pair — the str-list value. Each init is a `str` expr. Indexing
    /// (`strlist_get`) yields a str; `.len()` reads the count via `str_len`
    /// (the second pair component). Represented as the same pair as `str`.
    strlist_make: []const *Expr,
    /// `xs[i]` on a `[str]` value: bounds-check `i < count`, load the i-th
    /// `(ptr, len)` cell, and yield it as a str value.
    strlist_get: struct { list: *Expr, idx: *Expr },
    /// `env.envvars.get(key)` — the value of environment variable `key` as a
    /// `str` (empty if unset). The host (`env.envvar` face) writes the value
    /// into the scope arena and returns its length. Marks `@envvars`
    /// (`wasi:cli/environment.get-environment`).
    envvar_get: *Expr,
    /// `env.args` — the command-line arguments as a `[str]` value. The host
    /// (`env.args` face) materializes the `(ptr, len)` cells + bytes into the
    /// scope arena and the guest yields the `(data_ptr, count)` pair. Pure per
    /// spec/env.md (no capability), so it marks no effect.
    host_args,
};
