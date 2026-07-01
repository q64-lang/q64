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

/// One field initializer of a `record_make`: store `value` at `base +
/// offset`, truncating to `width` bytes (spec/memory.md §"Linear struct
/// layout"). A narrow integer field (`u8`…`i32`) carries an i64 compute
/// value with width 1/2/4; floats and i64 store at their natural width.
pub const FieldInit = struct { offset: u32, width: u8, value: *Inst };
pub const StrFieldInit = struct { offset: u32, value: *Inst };

/// Wasm-level value types. A `str` is the `(ptr, len)` pair — the backend
/// realizes it as a two-i64 multivalue (tuple); a str function returns it and
/// a str parameter is two i64 wasm params.
/// `ptr` is an address-space-width pointer/length (i32 on wasm32, i64 on
/// wasm64), used for the locals backing a `str` binding's `(ptr, len)`. The
/// backend realizes it as `i32`/`i64`; integer *values* use `i64` regardless.
pub const ValueType = enum { i64, i32, f32, f64, str, ptr, void };

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
    /// The module-init function id (the wasm `start`), if any — runs once at
    /// instantiation to populate module-lifetime singleton globals. The backend
    /// wires it via `BinaryenSetStart`; it is never exported.
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
    /// For a `.ptr`-returning function: the returned record/boxed-enum
    /// value's byte size — the backend's frame-reclamation slide copies
    /// this many bytes down to the call-site watermark
    /// (spec/memory.md §"Frame reclamation"). 0 otherwise.
    ret_size: u32 = 0,
    /// The returned aggregate contains pointers (a str enum payload):
    /// the flat slide would dangle them, so the call site skips
    /// reclamation entirely (the spec's pinned interior-pointer
    /// boundary — recursive slides land with named regions).
    ret_ptr_bearing: bool = false,
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
/// Target byte stream of a host write (`env.out` → stdout, `env.err` → stderr).
/// Mirrors `hir.Stream`; only the final sink differs (fd 1/2 or the raw
/// `env.out`/`env.err` face), so the formatting ops carry the tag.
pub const Stream = enum { out, err };

pub const Op = union(enum) {
    block: []const *Inst,
    host_out_const: struct { off: u32, len: u32, stream: Stream },
    const_i64: i64,
    const_f64: f64,
    /// An explicit numeric conversion; the target type is `inst.ty`, the
    /// source the operand's type. float→int uses the *trapping* trunc
    /// (spec/types.md §Casts: narrowing traps on overflow/NaN).
    num_cast: *Inst,
    /// A bit reinterpretation between f64 and i64 (target type = `inst.ty`); the
    /// raw bits are kept (an f64 channel cell ↔ value). Distinct from `num_cast`,
    /// which converts the value.
    bitcast: *Inst,
    /// A boolean (0/1) constant — the branch leaves of a short-circuit
    /// `&&`/`||` `if_`, which yields an i32 to match comparisons and `!`.
    const_i32: i32,
    local_get: u32,
    local_set: struct { idx: u32, value: *Inst },
    bin: struct { kind: ops.BinKind, lhs: *Inst, rhs: *Inst },
    un: struct { kind: ops.UnKind, operand: *Inst },
    call: struct { func: FuncId, args: []const *Inst },
    ret: ?*Inst,
    host_out_int: struct { value: *Inst, nl_off: u32, stream: Stream },
    /// `env.out` of an f64: `__fmt_f64` to decimal text, write, newline.
    host_out_float: struct { value: *Inst, nl_off: u32, stream: Stream },
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
    host_out_str: struct { value: *Inst, nl_off: u32, stream: Stream },
    /// A call to a host import face (e.g. `qview.text`). `name` is the dotted
    /// source name; the backend declares the matching wasm import
    /// (`(import "qview" "text" …)`) and emits the call. Args are i64 values
    /// (valid on wasm32 — only memory *addresses* are width-sensitive). Void.
    host_call: struct { name: []const u8, args: []const *Inst },
    /// A call to a **foreign WIT import** function (`<iface>.<fn>(…)` from a
    /// `--wit-import` interface). `module` is the interface's WIT id, `field`
    /// the function name; the backend declares the matching wasm import
    /// (`(import "<module>" "<field>" (params …) <ret>)`) and emits the call.
    /// Unlike `host_call` this yields a value — the inst's `.ty` is the import's
    /// result type. Args are scalar i64/f64 values (the canonical-ABI boundary).
    foreign_call: struct { module: []const u8, field: []const u8, args: []const *Inst },
    /// Read / write a module-level mutable i64 global (reactive `state`), by index.
    global_get: u32,
    global_set: struct { idx: u32, value: *Inst },
    /// The decimal `str` value of an i64 — formats `value` via `__fmt_i64` and
    /// yields its `(ptr, len)`. Used as a piece inside `str_concat` when an
    /// i64 binding (or any i64 expression) appears in interpolation.
    fmt_int_to_str: *Inst,
    /// The decimal `str` value of an f64 via `__fmt_f64` (integer part,
    /// `.`, ≤6 fractional digits, trailing zeros trimmed). A concat piece.
    fmt_float_to_str: *Inst,
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
    /// A `[str]` literal: bump-allocate `inits.len` consecutive `(ptr, len)`
    /// str cells (stride = two address-width words) in the scope arena, store
    /// each str element, and yield the `(data_ptr, count)` pair (a str-shaped
    /// value). `.ty` is `.str` — the pair representation is shared with `str`;
    /// the count rides the len component, read back by `str_len`.
    strlist_make: []const *Inst,
    /// `xs[i]` on a `[str]` value (`list` a str-shaped `(data_ptr, count)`
    /// pair): trap if `i >= count` (unsigned; negatives trap too), then load
    /// the i-th `(ptr, len)` cell and yield it as a str value. `.ty` is `.str`.
    strlist_get: struct { list: *Inst, idx: *Inst },
    /// `env.envvars.get(key)` — call the `env.envvar` host import with
    /// `(dest=sp, key ptr, key len)`, which writes the value at `dest` and
    /// returns its byte length (0 if unset). Bump `sp`, yield the `(dest, len)`
    /// str value. `.ty` is `.str`.
    envvar_get: struct { key: *Inst },
    /// `env.args` — materialize the command-line arguments as a `[str]` value.
    /// Calls the `env.args` host import with the arena pointer; the host writes
    /// `[count][cells…][bytes…]` there and returns the total bytes; the guest
    /// bumps `sp` and yields the `(data_ptr, count)` pair. `.ty` is `.str`.
    host_args,
    /// `env.exit(code)` (spec/env.md §`env.exit`): call the `env.exit` host
    /// import (raw face) or `wasi_snapshot_preview1.proc_exit` (preview1 path)
    /// with the i64 `code`. Void — the host terminates the instance.
    host_exit: struct { code: *Inst },
    /// `env.fs.read(path)` (spec/env.md §"Wire ABI: fs.read"): call the
    /// `env.fs_read` import with (dest=sp, path ptr, path len), trap on a
    /// negative length, bump `sp`, yield the (dest, len) str value.
    fs_read: struct { path: *Inst },
    /// `env.kv.increment(key, delta)` (spec/env.md §`env.kv`): call the
    /// `env.kv_increment` import with (key ptr, key len, delta) and yield its
    /// i64 result. `key` is a str inst; null for the keyless (empty-key) form.
    kv_increment: struct { key: ?*Inst, delta: *Inst },
    /// `env.kv.set(key, value)` (spec/env.md §`env.kv`): lazily `store.open` the
    /// identity-pinned bucket, call `[method]bucket.set` with (bucket, key ptr,
    /// key len, value ptr, value len, ret) and decode `result<_, error>` into a
    /// boxed `Result<(), IoError>` (`.ptr`). `key`/`value` are str insts.
    kv_set: struct { key: *Inst, value: *Inst },
    /// `env.kv.get(key)` (spec/env.md §`env.kv`): lazily `store.open` the bucket,
    /// call `[method]bucket.get` with (bucket, key ptr, key len, ret) and decode
    /// `result<option<list<u8>>, error>` into a boxed `Result<Option<Bytes>,
    /// IoError>` (`.ptr`). `key` is a str inst.
    kv_get: struct { key: *Inst },
    /// `env.blob.put(key, value)` (spec/env.md §`env.blob`): lazy
    /// `q64:blob/store.open` + `[method]bucket.put`, boxed `Result<(), IoError>`.
    blob_put: struct { key: *Inst, value: *Inst },
    /// `env.blob.get(key)`: `[method]bucket.get`, boxed
    /// `Result<Option<Bytes>, IoError>` (`.ptr`).
    blob_get: struct { key: *Inst },
    /// `env.blob.delete(key)`: `[method]bucket.delete`, boxed `Result<(), IoError>`.
    blob_delete: struct { key: *Inst },
    /// `env.db.execute(sql)`: lazy `open` + `[method]connection.exec`, scalar
    /// `result<u64, error>` boxed as `Result<u64, IoError>` (`.ptr`).
    db_execute: struct { sql: *Inst },
    /// `env.db.query_value(sql)`: `[method]connection.query-value`, boxed
    /// `Result<Option<i64>, IoError>` (`.ptr`).
    db_query_value: struct { sql: *Inst },
    /// `env.db.query_text(sql)`: `[method]connection.query-text`, boxed
    /// `Result<Option<Bytes>, IoError>` (`.ptr`).
    db_query_text: struct { sql: *Inst },
    /// `chan_recv(session)` — receive the next inbound channel message (the
    /// `env.channel_recv` host import). Operand is the session handle (i64);
    /// yields 1 (message available) or 0 (closed). Drives `for _ in session`.
    chan_recv: *Inst,
    /// `chan_take(session)` — the `env.channel_take` host import: the i64 payload
    /// of the message `chan_recv` just reported. Operand is the session handle.
    chan_take: *Inst,
    /// Open a host-backed stream — the nullary `env.<name>` host import (e.g.
    /// `channel_connect` for `connect`, `presses` for the press source) — yielding
    /// a session handle (i64).
    chan_open: []const u8,
    /// `Vec` v0 floor (spec/types.md §Growable): a fresh empty vec —
    /// a 3-slot {data, len, cap} header in the scope arena, yielding
    /// its base pointer. Lowers to the `__vec_new` helper.
    vec_new,
    /// `v.push(x)` — append an i64 element, copy-on-grow. `vec` is the
    /// header pointer (`.ptr`), `value` i64. `__vec_push`.
    vec_push: struct { vec: *Inst, value: *Inst },
    /// `v.len` -> i64 (a live header read).
    vec_len: struct { vec: *Inst },
    /// `v[i]` -> i64, bounds-checked against the live len (a trap on
    /// out-of-range, like arrays). `__vec_get`.
    vec_get: struct { vec: *Inst, idx: *Inst },
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
    record_make: struct {
        size: u32,
        alignment: u32,
        inits: []const FieldInit,
        /// str payload cells: store the value's (ptr, len) at offset /
        /// offset+8, widened to 8-byte cells.
        str_inits: []const StrFieldInit = &.{},
    },
    /// Load a record field at `base + offset`: `width` bytes, sign- or
    /// zero-extended per `signed`, yielding `inst.ty` (i64 for every
    /// integer width — the compute floor; f64/f32/i32-bool natively).
    field_get: struct { base: *Inst, offset: u32, width: u8, signed: bool },
    /// Store a record field at `base + offset`, truncating the value to
    /// `width` bytes. Void.
    field_set: struct { base: *Inst, offset: u32, width: u8, value: *Inst },
    /// Materialize an array in the scope arena: bump `alignment`-aligned,
    /// `inits.len · stride` bytes; each scalar init stores at its slot
    /// (`elem_width` bytes), a record init (`copy_bytes` set) memory.copys
    /// its bytes inline. Yields the base pointer.
    array_make: struct { stride: u32, alignment: u32, elem_width: u8, copy_bytes: ?u32, inits: []const *Inst },
    /// `base + index·stride` (`base` is a `.ptr`, `index` an i64). A `.ptr`.
    elem_ptr: struct { base: *Inst, index: *Inst, stride: u32 },
    /// Pass `index` through; trap (`unreachable`) unless 0 ≤ index < count.
    bounds_check: struct { index: *Inst, count: *Inst },
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
