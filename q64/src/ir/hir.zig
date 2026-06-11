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

/// Resolves a function name (imported or file-local) to its AST declaration.
/// The AST→HIR builder calls this to turn a call site into a `FuncId`; the
/// codegen router backs it with the existing `Resolver.lookup`, so HIR
/// construction reuses import resolution without `ir/` depending on codegen.
/// (Name resolution will move fully into the builder in a later phase.)
pub const ModuleResolver = struct {
    ctx: *anyopaque,
    lookupFn: *const fn (*anyopaque, name: []const u8) ?ast.FnDecl,

    pub fn lookup(self: ModuleResolver, name: []const u8) ?ast.FnDecl {
        return self.lookupFn(self.ctx, name);
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
pub const Type = enum { i64, i32, u32, i16, u16, i8, u8, f32, f64, str, bool, ptr, void };

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
            .stdout, .stderr, .network, .fs, .kv, .wire => .io,
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
    pub fn witImport(self: Effect) ?[]const u8 {
        return switch (self) {
            .stdout => "wasi:cli/stdout",
            .stderr => "wasi:cli/stderr",
            .network => "wasi:sockets/*",
            .fs => "wasi:filesystem/*",
            .kv => "wasi:keyvalue/store",
            .time => "wasi:clocks/*",
            .random => "wasi:random/random",
            .envvars => "wasi:cli/environment",
            .exit => "wasi:cli/exit",
            .audio => "q64:host/audio",
            .midi => "q64:host/midi",
            .ui => "q64:host/ui",
            .inference => "q64:host/inference",
            .io, .wire => null,
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
};

/// High-level statements. `block` is shared; the `host_out*` forms appear in
/// `main`; the rest make up an `i64` function body. Local references use the
/// resolved index assigned by the builder (parameters first, then in-body
/// bindings in declaration order). Compound assignment (`+=` …) is desugared
/// to `assign(idx, bin(op, local(idx), rhs))`.
pub const Stmt = union(enum) {
    block: []const *Stmt,
    /// `env.out(expr)` — `expr` is `str`-typed. The trailing newline is the
    /// capability ABI's, materialized during lowering.
    host_out: *Expr,
    /// `env.out(expr)` where `expr` is `i64` — formatted to decimal on lowering.
    host_out_int: *Expr,
    /// `env.out(expr)` where `expr` is `f64` — formatted via `__fmt_f64`.
    host_out_float: *Expr,
    /// `env.out(expr)` where `expr` is a runtime `str` value (e.g. a call to a
    /// str-returning function) — its `(ptr, len)` is written, then a newline.
    host_out_str: *Expr,
    /// `env.out(expr)` where `expr` is a boolean (a comparison, `&&`/`||`/`!`,
    /// a `true`/`false` literal, or a `-> bool` call). Lowers to a value `if`
    /// that writes the constant `"true"` / `"false"` text.
    host_out_bool: *Expr,
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
    /// Short-circuit `&&` / `||`. Kept distinct from `bin` because it lowers
    /// to control flow (a value `if_`), not a backend binary op. Yields a
    /// boolean (i32 0/1); both operands are truthiness-tested.
    logical: struct { op: ops.LogicalKind, lhs: *Expr, rhs: *Expr },
    /// A call to another function, resolved to its `FuncId`.
    call: struct { func: FuncId, args: []const *Expr },
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
    record_alloc: struct { size: u32, alignment: u32, inits: []const FieldInit },
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
};
