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

pub const FuncId = u32;

/// Source-level value types. `str` is abstract here (it only becomes a
/// `(ptr, len)` pair in MIR).
pub const Type = enum { i64, i32, f64, str, void };

pub const Visibility = enum { private, public };

/// One module's worth of HIR, arena-owned. Callers allocate every node via
/// `alloc()` so the whole graph frees in one `deinit()`. The arena is moved
/// with the struct (its buffers live on the heap), so do not hold a
/// captured `Allocator` interface across a return.
pub const Module = struct {
    arena: std.heap.ArenaAllocator,
    funcs: []Func = &.{},
    entry: ?FuncId = null,

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

pub const Func = struct {
    name: []const u8,
    params: []Param = &.{},
    ret: Type = .void,
    body: *Stmt,
    /// Carried for the future component/WIT lift (exports = the pub surface).
    visibility: Visibility = .private,
    // effects: future — the effect pass writes the capability set here, which
    // the component/WIT + QubePod stages consume. Empty in v0.
};

/// High-level statements. Grows per migration phase (let/return/if/while/
/// loop/break/continue/assign land with their codegen phases).
pub const Stmt = union(enum) {
    block: []const *Stmt,
    /// `env.out(expr)` — the `expr` is a `str`-typed value. The trailing
    /// newline env.out writes is part of its capability contract and is
    /// materialized during lowering, not here.
    host_out: *Expr,
};

/// High-level expressions. `str` stays abstract; the `(ptr, len)` ABI is a
/// lowering (MIR) concern. Grows per phase (int_const/concat/call/local/…).
pub const Expr = union(enum) {
    /// A fully-resolved constant string value (escapes decoded, no newline).
    str_const: []const u8,
};
