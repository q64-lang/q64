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
    /// Locals declared beyond the parameters (in-body `let`/`var`), in
    /// declaration order. Parameters occupy local indices `0..params.len`.
    locals: []Type = &.{},
    body: *Stmt,
    /// Carried for the future component/WIT lift (exports = the pub surface).
    visibility: Visibility = .private,
    // effects: future — the effect pass writes the capability set here, which
    // the component/WIT + QubePod stages consume. Empty in v0.
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
    /// `env.out(expr)` where `expr` is a runtime `str` value (e.g. a call to a
    /// str-returning function) — its `(ptr, len)` is written, then a newline.
    host_out_str: *Expr,
    /// A call to a host import face (`qview.text(…)`): `name` is the dotted
    /// source name; `args` are i64 expressions. Lowers to a wasm import call.
    host_call: struct { name: []const u8, args: []const *Expr },
    /// An `i64` expression statement; as a block's tail it is the value.
    expr: *Expr,
    ret: ?*Expr,
    let: struct { idx: u32, value: *Expr },
    assign: struct { idx: u32, value: *Expr },
    /// A runtime `str` binding (`let g = shout("hi")`): store the value's
    /// `(ptr, len)` into the two locals `ptr_idx`/`len_idx`.
    str_let: struct { ptr_idx: u32, len_idx: u32, value: *Expr },
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
    /// A parameter or in-body binding, by resolved local index.
    local: u32,
    bin: struct { kind: ops.BinKind, lhs: *Expr, rhs: *Expr },
    un: struct { kind: ops.UnKind, operand: *Expr },
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
};
