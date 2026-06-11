//! MIR — the Mid-level / Executable Q64 IR.
//!
//! "How the program executes." Still backend-neutral (this file MUST NOT
//! import the Binaryen C API), but ABI-lowered and execution-ready: a `str`
//! is a `(ptr, len)` pair, allocation is abstract region/`alloc` ops, and
//! the static linear-memory image is materialized in `data`. This is the
//! direct input to a backend — `MIR → Binaryen → WASM` today; a future
//! `MIR → LLVM IR → native` backend would consume the very same module.
//!
//! Control flow is structured (block/if/loop/br), matching the WASM target.
//! A `Func.body` is form-agnostic (`Body = structured | cfg`): the `cfg` arm
//! is an explicit escape hatch for a future basic-block backend (relooper /
//! LLVM), reusing the same value `Inst`s and swapping only the control-flow
//! skeleton. Structured is the only form produced today.
//!
//! Status: v0 covers the literal `env.out` path. The `Op` union grows one
//! arm per migration phase (i64 arithmetic + control flow, then calls, then
//! the string-concat / arena ABI). Allocation/region ops are deliberately
//! abstract so the IR stays LLVM-ready (Memory64 + the `sp` bump global are
//! the *Binaryen backend's* realization, not baked into MIR).

const std = @import("std");
pub const ops = @import("ops.zig");

pub const FuncId = u32;

/// One field initializer of a `record_make`: store `value` at `base + offset`.
/// The store width follows the value's type: an `.i64` field is an 8-byte
/// store, an `.i32` (bool) field a 1-byte store (spec/memory.md §"Linear
/// struct layout").
pub const FieldInit = struct { offset: u32, value: *Inst };

/// Wasm-level value types. A `str` is the `(ptr, len)` pair — the backend
/// realizes it as a two-i64 multivalue (tuple); a str function returns it and
/// a str parameter is two i64 wasm params.
/// `ptr` is an address-space-width pointer/length (i32 on wasm32, i64 on
/// wasm64), used for the locals backing a `str` binding's `(ptr, len)`. The
/// backend realizes it as `i32`/`i64`; integer *values* use `i64` regardless.
pub const ValueType = enum { i64, i32, f64, str, ptr, void };

pub const Linkage = enum { entry, local, imported_resolved };

pub const Module = struct {
    arena: std.heap.ArenaAllocator,
    funcs: []Func = &.{},
    entry: ?FuncId = null,
    /// The static linear-memory image (laid out at offset 0). Backend-
    /// agnostic bytes; the WASM backend installs it as one active data
    /// segment.
    data: []const u8 = &.{},
    /// Module-level mutable i64 globals (reactive `state`), with their init
    /// values. The backend emits one `(global (mut i64))` per entry.
    globals: []const i64 = &.{},
    /// Global names parallel to `globals` (exported by name so a host can read them).
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

pub const Func = struct {
    /// Null-terminated so the backend can hand it straight to Binaryen.
    name: [:0]const u8,
    params: []const ValueType = &.{},
    ret: ValueType = .void,
    locals: []const ValueType = &.{},
    body: Body,
    linkage: Linkage = .local,
    /// Export this function by `name` (in addition to the entry's `_start`).
    /// Set for public screen handlers (e.g. `on_press`) the host invokes.
    exported: bool = false,
};

/// A function body in one of two interchangeable forms. **Structured is the
/// only form produced today** (and the one the WASM/Binaryen backend wants —
/// see the structured-control-flow note in the project plan). `cfg` is the
/// explicit *escape hatch*: a backend that prefers a basic-block CFG (an LLVM
/// / native backend, or a future optimizer pass) consumes `cfg` instead, and
/// a structured↔CFG converter lives at this seam. Crucially, both forms reuse
/// the same value/effect `Inst`s — only the *control-flow skeleton* differs —
/// so adding the CFG form never reshapes the rest of MIR. Nothing emits `cfg`
/// yet; the WASM backend rejects it (`Error.CfgUnsupported`).
pub const Body = union(enum) {
    structured: *Inst,
    cfg: *Cfg,
};

// --- The CFG escape hatch -------------------------------------------------
//
// Reserved for a future basic-block backend (relooper / LLVM). Defined now so
// the `Body` seam is real and `Func`'s shape is final; no pass produces a Cfg
// yet. The straight-line ops inside a block are the same value/effect `Inst`s
// the structured form uses; only the branching (the `Terminator`) is distinct.

pub const BlockId = u32;

pub const Cfg = struct {
    blocks: []const BasicBlock,
    entry: BlockId = 0,
};

pub const BasicBlock = struct {
    /// Straight-line value/effect instructions (no control flow).
    insts: []const *Inst,
    term: Terminator,
};

pub const Terminator = union(enum) {
    ret: ?*Inst,
    br: BlockId,
    cond_br: struct { cond: *Inst, then_blk: BlockId, else_blk: BlockId },
    @"unreachable",
};

/// A structured instruction node. `ty` is its result type (`.void` for
/// statements). Arena-allocated; children are pointers into the same arena.
pub const Inst = struct {
    ty: ValueType,
    op: Op,
};

/// The executable op set. Grows per migration phase.
///   block          — a sequence of instructions; `ty` is the tail's type.
///   host_out_const — `env.out` of a constant string already in `data`
///                    (off/len include env.out's trailing newline).
///   const_i64/local_get/local_set/bin/un/call/ret — the i64 value + call ops.
///   host_out_int   — `env.out` of an i64: format to decimal then write,
///                    followed by the shared newline byte at `nl_off`.
pub const Op = union(enum) {
    block: []const *Inst,
    host_out_const: struct { off: u32, len: u32 },
    const_i64: i64,
    /// A boolean (0/1) constant — the branch leaves of a short-circuit
    /// `&&`/`||` `if_`, which yields an i32 to match comparisons and `!`.
    const_i32: i32,
    local_get: u32,
    local_set: struct { idx: u32, value: *Inst },
    bin: struct { kind: ops.BinKind, lhs: *Inst, rhs: *Inst },
    un: struct { kind: ops.UnKind, operand: *Inst },
    call: struct { func: FuncId, args: []const *Inst },
    ret: ?*Inst,
    host_out_int: struct { value: *Inst, nl_off: u32 },
    /// A constant `str` value: the `(ptr, len)` pointing at `off`/`len` in the
    /// memory image (no trailing newline — it's a value, not a host write).
    str_const_val: struct { off: u32, len: u32 },
    /// The `str` value of parameter `#idx` (all-str param lists today, so its
    /// `(ptr, len)` lives at wasm locals `2·idx`, `2·idx+1`).
    str_param: u32,
    /// A `str` value built at runtime in the scope arena by concatenating the
    /// pieces (each a `str` value: a const run, a parameter, or a call). The
    /// backend bump-allocates and `memory.copy`s each piece, yielding the
    /// `(buf, len)` of the assembled string.
    str_concat: []const *Inst,
    /// Store a `str` value's `(ptr, len)` into a binding's two i64 locals.
    str_bind: struct { ptr_idx: u32, len_idx: u32, value: *Inst },
    /// Read a `str` binding's two locals as a `(ptr, len)` value.
    str_binding: struct { ptr_idx: u32, len_idx: u32 },
    /// `env.out` of a runtime `str` value (a `(ptr, len)` pair) followed by the
    /// shared newline byte at `nl_off`.
    host_out_str: struct { value: *Inst, nl_off: u32 },
    /// A call to a host import face (e.g. `qview.text`). `name` is the dotted
    /// source name; the backend declares the matching wasm import
    /// (`(import "qview" "text" …)`) and emits the call. Args are i64 values
    /// (valid on wasm32 — only memory *addresses* are width-sensitive). Void.
    host_call: struct { name: []const u8, args: []const *Inst },
    /// Read / write a module-level mutable i64 global (reactive `state`), by index.
    global_get: u32,
    global_set: struct { idx: u32, value: *Inst },
    /// The decimal `str` value of an i64 — formats `value` via `__fmt_i64` and
    /// yields its `(ptr, len)`. Used as a piece inside `str_concat` when an
    /// i64 binding (or any i64 expression) appears in interpolation.
    fmt_int_to_str: *Inst,
    /// The byte length of a `str` value as i64 (`s.len`). `value` is a str-typed
    /// inst; the backend reads its len component and zero-extends to i64.
    str_len: *Inst,
    /// The unsigned byte at `idx` of a str value as i64 (`s[i]`). `str` is a
    /// str-typed inst (its ptr component is the base); `idx` is an i64 offset.
    /// Lowers to an `i32.load8_u` at `ptr + idx`, zero-extended to i64.
    str_index: struct { str: *Inst, idx: *Inst },
    /// Byte-wise equality of two str values as i32 (0/1). Both are str-typed
    /// insts; lowers to a `__str_eq(pa, la, pb, lb)` helper call.
    str_eq: struct { lhs: *Inst, rhs: *Inst },
    /// `s.slice(start, end)` -> str (ptr+start, end-start). `str` is str-typed;
    /// `start`/`end` are i64. Lowers inline to a (ptr, len) pair.
    str_slice: struct { str: *Inst, start: *Inst, end: *Inst },
    /// `s.index_of(byte)` -> i64. `str` str-typed, `byte` i64. __str_index_of.
    str_index_of: struct { str: *Inst, byte: *Inst },
    /// `s.starts_with(prefix)` -> i32. Both str-typed. __str_starts_with.
    str_starts_with: struct { str: *Inst, prefix: *Inst },
    /// `s.contains(sub)` -> i32. Both str-typed. __str_contains.
    str_contains: struct { str: *Inst, sub: *Inst },
    /// Materialize a record in the scope arena: align the bump pointer up to
    /// `alignment`, allocate `size` bytes, store each field at its offset
    /// (width per the value's type — 8 bytes for `.i64`, 1 byte for `.i32`
    /// bools), and yield the base pointer (a `.ptr`).
    record_make: struct { size: u32, alignment: u32, inits: []const FieldInit },
    /// Load a record field at `base + offset`. The result type is `inst.ty`:
    /// `.i64` → an 8-byte load, `.i32` (bool) → a 1-byte zero-extending load.
    field_get: struct { base: *Inst, offset: u32 },
    /// Store a record field at `base + offset` (width per the value's type). Void.
    field_set: struct { base: *Inst, offset: u32, value: *Inst },
    // Structured control flow. `if_` yields `inst.ty` (i64 value-if, or void).
    // `while_`/`loop` are void and diverge/iterate; the backend expands them
    // to labeled `block`/`loop`/`br_if` and resolves `br`/`br_cont` to the
    // innermost loop's exit/re-enter labels. `cond` is an i32 (0/1).
    if_: struct { cond: *Inst, then_: *Inst, else_: ?*Inst },
    while_: struct { cond: *Inst, body: *Inst },
    loop: *Inst,
    br, // break → innermost loop exit
    br_cont, // continue → innermost loop re-enter
    @"unreachable",
};
