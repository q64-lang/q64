//! MIR — the Mid-level / Executable Q64 IR.
//!
//! "How the program executes." Still backend-neutral (this file MUST NOT
//! import the Binaryen C API), but ABI-lowered and execution-ready: a `str`
//! is a `(ptr, len)` pair, allocation is abstract region/`alloc` ops, and
//! the static linear-memory image is materialized in `data`. This is the
//! direct input to a backend — `MIR → Binaryen → WASM` today; a future
//! `MIR → LLVM IR → native` backend would consume the very same module.
//!
//! Control flow is structured (block/if/loop/br), matching the WASM target;
//! a CFG/SSA form is a backend-internal concern (see the project plan).
//!
//! Status: v0 covers the literal `env.out` path. The `Op` union grows one
//! arm per migration phase (i64 arithmetic + control flow, then calls, then
//! the string-concat / arena ABI). Allocation/region ops are deliberately
//! abstract so the IR stays LLVM-ready (Memory64 + the `sp` bump global are
//! the *Binaryen backend's* realization, not baked into MIR).

const std = @import("std");

pub const FuncId = u32;

/// Wasm-level value types. Note there is no `str`: by MIR a string has
/// already been lowered to its `(ptr, len)` representation (two i64s).
pub const ValueType = enum { i64, i32, f64, void };

pub const Linkage = enum { entry, local, imported_resolved };

pub const Module = struct {
    arena: std.heap.ArenaAllocator,
    funcs: []Func = &.{},
    entry: ?FuncId = null,
    /// The static linear-memory image (laid out at offset 0). Backend-
    /// agnostic bytes; the WASM backend installs it as one active data
    /// segment.
    data: []const u8 = &.{},

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
    body: *Inst,
    linkage: Linkage = .local,
};

/// A structured instruction node. `ty` is its result type (`.void` for
/// statements). Arena-allocated; children are pointers into the same arena.
pub const Inst = struct {
    ty: ValueType,
    op: Op,
};

/// The executable op set. Grows per migration phase. v0:
///   block          — a sequence of (mostly `.void`) instructions.
///   host_out_const — `env.out` of a constant string already in `data`
///                    (off/len include env.out's trailing newline).
pub const Op = union(enum) {
    block: []const *Inst,
    host_out_const: struct { off: u32, len: u32 },
};
