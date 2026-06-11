//! AST → HIR builder (front boundary of the Q64 IR).
//!
//! Imports `parser` only — NEVER the Binaryen C API. Owns the semantic-but-
//! not-executable work: name resolution (via the injected `ModuleResolver`),
//! shape/typing checks, and desugaring. The HIR→MIR `lower` pass takes over
//! from here.
//!
//! `tryBuild` returns `.unsupported` for any construct it cannot yet
//! represent (signalled internally by `error.Unsupported`); `codegen/emit.zig`
//! reports that as an honest `UnsupportedExpression` (the IR is the sole
//! emission path — there is no legacy fallback). Handled today:
//!   - `fn main` whose statements are `env.out(<expr>)` and runtime `let`
//!     bindings (str and i64), with interpolation in literals mixing const
//!     runs, str bindings, str-returning calls, and i64 bindings (formatted
//!     by `__fmt_i64` via `fmt_int`);
//!   - the transitively-called i64 functions (arithmetic, control flow,
//!     in-body bindings, recursion);
//!   - the transitively-called str functions (const-string, passthrough,
//!     and concat bodies built from str parameters).

const std = @import("std");
const parser = @import("parser");
const ast = parser.ast;
const hir = @import("hir.zig");
const ops = @import("ops.zig");
const consteval = @import("consteval.zig");
const effects = @import("effects.zig");
const sema = @import("sema");

pub const ModuleResolver = hir.ModuleResolver;

/// `Unsupported` — a construct the IR path doesn't represent yet; the caller
/// reports an honest `UnsupportedExpression`. `Rejected` — a definite semantic
/// error was recorded in `Builder.reject`; the caller reports its diagnostic.
const BuildError = error{ Unsupported, Rejected } || std.mem.Allocator.Error;

/// A runtime `str` binding in `main`: its `(ptr, len)` live in two `_start`
/// i64 locals.
const StrBinding = struct { ptr_idx: u32, len_idx: u32 };
const RtMap = std.StringHashMapUnmanaged(StrBinding);

/// One field of a laid-out struct: its declared type and byte offset, per
/// spec/memory.md §"Linear struct layout" (declaration order, natural
/// alignment, no reordering).
const StructField = struct { name: []const u8, ty: hir.Type, offset: u32 };

/// A struct declaration on the v0 layout floor (i64 / bool fields only).
/// Structs with fields outside the floor aren't registered, so uses stay the
/// honest `Unsupported`. Size is rounded up to the struct alignment.
const StructInfo = struct {
    name: []const u8,
    fields: []const StructField,
    size: u32,
    alignment: u32,

    fn field(self: *const StructInfo, name: []const u8) ?StructField {
        for (self.fields) |f| if (std.mem.eql(u8, f.name, name)) return f;
        return null;
    }
};

/// Which of a function's params/return are record values (`.ptr` at the ABI).
/// Present in `Builder.fn_recs` only for functions with any record surface.
const FnRec = struct { params: []const ?*const StructInfo, ret: ?*const StructInfo };

/// A resolved `<binding>.<field>` access on a materialized record binding:
/// the binding's ptr local, the field's layout offset/type, and whether the
/// binding is assignable (`var`).
const RecField = struct { base_idx: u32, offset: u32, ty: hir.Type, mutable: bool };

const Builder = struct {
    a: std.mem.Allocator,
    resolver: ModuleResolver,
    eval: consteval.Evaluator,
    /// Sema type store (A3): signature annotations lower through sema's
    /// `types.lower` instead of ad-hoc name matching. Arena-backed, so no
    /// explicit deinit. The table is null until cross-module symbol
    /// resolution lands — builtins resolve, named types stay unresolved,
    /// which is exactly the scalar floor this builder compiles.
    tstore: sema.types.TypeStore,
    funcs: std.ArrayList(hir.Func) = .empty,
    /// function name → FuncId, for dedup + recursion. Keys are arena-owned.
    ids: std.StringHashMapUnmanaged(hir.FuncId) = .empty,
    /// `main`'s runtime str bindings + the locals backing them (each is two
    /// i64 locals). Only `main` has these (callees use parameters).
    main_rt: RtMap = .empty,
    main_locals: std.ArrayList(hir.Type) = .empty,
    /// Module-level `state` globals: name → index, plus init values + names by index.
    globals: std.StringHashMapUnmanaged(u32) = .empty,
    global_inits: std.ArrayList(i64) = .empty,
    global_names: std.ArrayList([]const u8) = .empty,
    /// This file's struct declarations on the layout floor, laid out per
    /// spec/memory.md §"Linear struct layout". Struct-typed signatures resolve
    /// against this table (v0: the compiling file's structs only).
    structs: std.StringHashMapUnmanaged(*const StructInfo) = .empty,
    /// The fit registry (sema/fits.zig) over this file — B4 static
    /// dispatch resolves `p.area()` through it. Arena-backed (never
    /// deinit'd separately).
    fitreg: ?sema.fits.Registry = null,
    /// FuncId → its record params/return, for functions with a record surface.
    fn_recs: std.AutoHashMapUnmanaged(hir.FuncId, FnRec) = .empty,
    /// `main`'s body block, for the record-binding escape scan (does a bare
    /// `name` appear as a whole value anywhere in `main`?).
    main_body: ?ast.Block = null,
    /// Entry FuncId (main → 0) when the module has a `fn main`; null for a
    /// main-less module (e.g. a backend twin: only `state` + exported commands).
    entry: ?hir.FuncId = null,
    /// The definite semantic error to report when `buildModule` returns
    /// `error.Rejected` (read by `tryBuild`).
    reject: ?hir.Reject = null,
};

/// Record a definite semantic error and bail. `tryBuild` reads `b.reject` and
/// surfaces it as an honest diagnostic instead of falling back to legacy.
fn reject(b: *Builder, r: hir.Reject) BuildError {
    b.reject = r;
    return error.Rejected;
}

/// Try compile-time evaluation. A non-constant result maps to `null` (the
/// caller picks a runtime lowering); an entirely-constant-but-invalid
/// expression (`error.ConstArith`: divide-by-zero, overflow) is a definite
/// error, surfaced as `not_const`. Allocation failure propagates.
fn tryConst(b: *Builder, expr: ast.Expr) BuildError!?[]const u8 {
    return b.eval.evalExpr(expr) catch |e| switch (e) {
        error.NotConst => null,
        error.ConstArith => reject(b, .not_const),
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// The outcome of building HIR for a source file.
pub const Result = union(enum) {
    /// Built HIR — lower it to MIR and emit.
    module: hir.Module,
    /// A construct the IR path doesn't represent yet — the caller reports an
    /// honest `UnsupportedExpression` (there is no legacy fallback).
    unsupported,
    /// A definite semantic error — report it as an honest diagnostic, do NOT
    /// fall back.
    rejected: hir.Reject,
};

/// Build HIR for `sf`'s `fn main` and its reachable functions. Returns the
/// module, `unsupported` (fall back), or a `rejected` reason (report it).
pub fn tryBuild(
    gpa: std.mem.Allocator,
    sf: ast.SourceFile,
    resolver: ModuleResolver,
) std.mem.Allocator.Error!Result {
    var mod = hir.Module.init(gpa);
    const a = mod.alloc();
    var b = Builder{
        .a = a,
        .resolver = resolver,
        .eval = .{ .a = a, .resolver = resolver },
        .tstore = try sema.types.TypeStore.init(a),
    };
    buildModule(&b, sf) catch |e| switch (e) {
        error.Unsupported => {
            mod.deinit();
            return .unsupported;
        },
        error.Rejected => {
            const r = b.reject.?;
            mod.deinit();
            return .{ .rejected = r };
        },
        error.OutOfMemory => {
            mod.deinit();
            return error.OutOfMemory;
        },
    };
    mod.funcs = try b.funcs.toOwnedSlice(b.a);
    mod.entry = b.entry;
    mod.globals = try b.global_inits.toOwnedSlice(b.a);
    mod.global_names = try b.global_names.toOwnedSlice(b.a);
    // Effect pass: infer each function's capability set over the built graph,
    // so every HIR consumer (emit, `show hir`, `show effects`, the future WIT
    // lift) sees effect-annotated functions.
    try effects.analyze(&mod);
    return .{ .module = mod };
}

fn buildModule(b: *Builder, sf: ast.SourceFile) BuildError!void {
    // Pass 0: register module-level `state x = <int>` globals (by declaration
    // order). The init must be an integer literal in v0.
    {
        var it0 = sf.items();
        while (it0.next()) |item| switch (item) {
            .state_decl => |sd| {
                const nm = sd.name() orelse return error.Unsupported;
                const v = sd.value() orelse return error.Unsupported;
                const init_val: i64 = switch (v) {
                    .num_lit => |n| consteval.parseIntLit(n.rawText() orelse return error.Unsupported) catch return error.Unsupported,
                    else => return error.Unsupported, // v0: integer-literal init only
                };
                const idx: u32 = @intCast(b.global_inits.items.len);
                try b.globals.put(b.a, nm.text, idx);
                try b.global_inits.append(b.a, init_val);
                try b.global_names.append(b.a, nm.text);
            },
            else => {},
        };
    }

    // Pass 0.5: lay out this file's struct declarations (B2b). Structs with
    // fields outside the v0 floor (i64 / bool) are skipped, not rejected —
    // a *use* of one surfaces the honest Unsupported.
    try registerStructs(b, sf);
    // Pass 0.6: the fit registry (B4) — `p.area()` dispatches through it.
    // Its form diagnostics (TYP201/202) belong to `q64 check`, not emit.
    b.fitreg = try sema.fits.build(b.a, sf);

    // A module may have no `fn main` (a backend twin: just `state` + exported
    // commands). Then there's no entry — build only the screen functions.
    const main_fn = findMain(sf) orelse {
        // No `fn main`. A valid main-less module is a backend twin: `state`
        // globals and/or twin command functions (qview / state-assign bodies).
        // If a non-twin function turns up (e.g. one with an `env.out` body) or
        // the module has nothing emittable, it isn't a runnable artifact → the
        // honest NoMainFunction diagnostic, not a fall-back.
        buildScreenFuncs(b, sf) catch |e| switch (e) {
            error.Unsupported => return reject(b, .no_main),
            else => return e,
        };
        if (b.entry == null and b.funcs.items.len == 0 and b.global_inits.items.len == 0) {
            return reject(b, .no_main);
        }
        return;
    };
    const body = main_fn.body() orelse return error.Unsupported;
    b.main_body = body;

    // Reserve FuncId 0 for the entry so callees discovered while building
    // main's body get ids 1.. .
    const dummy = try b.a.create(hir.Stmt);
    dummy.* = .{ .block = &.{} };
    try b.funcs.append(b.a, .{ .name = "main", .body = dummy });

    // `main`'s env.out(<i64>) arguments resolve against an empty i64 scope;
    // its runtime str bindings live in `b.main_rt` (the `rt` scope below).
    var mscope = Scope{ .a = b.a };
    const rt = &b.main_rt;

    var stmts: std.ArrayList(*hir.Stmt) = .empty;
    var it = body.statements();
    while (it.next()) |stmt| try buildMainStmt(b, stmt, &mscope, rt, &stmts);

    const block = try b.a.create(hir.Stmt);
    block.* = .{ .block = try stmts.toOwnedSlice(b.a) };
    b.funcs.items[0] = .{ .name = "main", .ret = .void, .body = block, .visibility = .public, .locals = try b.main_locals.toOwnedSlice(b.a) };
    b.entry = 0;

    try buildScreenFuncs(b, sf);
}

/// Build one statement of `main`'s body, appending 0+ HIR statements to `out`.
/// Unlike a function body, `main` statements can write the host (`env.out`,
/// `qview.*`) and have no value/tail — so this handles the host shapes *and*
/// control flow, recursing into `while`/`if` bodies via `buildMainBlock`.
fn buildMainStmt(b: *Builder, stmt: ast.Stmt, scope: *Scope, rt: *RtMap, out: *std.ArrayList(*hir.Stmt)) BuildError!void {
    switch (stmt) {
        .let_stmt => |ls| {
            const init_expr = ls.initializer() orelse return error.Unsupported;
            const nm = (ls.pattern() orelse return error.Unsupported).bindingName() orelse return error.Unsupported;
            // An immutable `let` whose initializer const-folds (incl. a
            // const-bodied call, e.g. `let v = version()`) becomes a
            // compile-time binding. A `var` is mutable, so it must stay a real
            // runtime local even when its initializer is constant.
            if (!ls.isVar()) {
                b.eval.fold_calls = true;
                const folded = try tryConst(b, init_expr);
                b.eval.fold_calls = false;
                if (folded) |bytes| {
                    try b.eval.bind(nm.text, bytes);
                    return;
                }
            }
            // Otherwise a runtime str binding (`let g = shout("hi")`): build
            // the str value and store its (ptr, len) into two new locals.
            if (init_expr == .string_lit or (try isStrCall(b, init_expr))) {
                const value = if (init_expr == .string_lit)
                    try buildConcat(b, init_expr.string_lit, scope, false, rt)
                else
                    try buildStrExpr(b, init_expr, scope, rt);
                const ptr_idx: u32 = @intCast(b.main_locals.items.len);
                // The (ptr, len) backing locals are address-width pointers
                // (i32 on wasm32, i64 on wasm64) — `.ptr`, not `.i64`.
                try b.main_locals.append(b.a, .ptr);
                try b.main_locals.append(b.a, .ptr);
                try b.main_rt.put(b.a, nm.text, .{ .ptr_idx = ptr_idx, .len_idx = ptr_idx + 1 });
                const st = try b.a.create(hir.Stmt);
                st.* = .{ .str_let = .{ .ptr_idx = ptr_idx, .len_idx = ptr_idx + 1, .value = value } };
                try out.append(b.a, st);
            } else if (init_expr == .record and try recordEscapes(b, nm.text)) {
                // B2b: the binding is used as a whole value somewhere in
                // `main` (passed to a call, …) — materialize it in the scope
                // arena and bind the base pointer. Field access becomes
                // (ptr, offset) loads/stores through `findRecField`.
                const rv = (try buildRecExpr(b, init_expr, scope)) orelse return error.Unsupported;
                try bindMainRecord(b, scope, nm.text, ls.isVar(), rv.e, rv.si, out);
            } else if (init_expr == .record) {
                // B2 (SROA): a *non-escaping* record-literal binding lowers
                // to one scalar local per field, *named with the dotted
                // access path* ("p.x"). `p.x` parses as a single greedy
                // PATH_EXPR, so the existing path machinery — reads, `var`
                // assignment, `{p.x}` interpolation — resolves field access
                // with no aggregate representation at all. The struct never
                // exists in memory. v0 scope (documented in todo.md):
                // main-only, i64/bool field values, no shorthand inits.
                const rec = init_expr.record;
                var inits = rec.inits();
                var any = false;
                while (inits.next()) |fi| {
                    any = true;
                    const fname = fi.name() orelse return error.Unsupported;
                    const fval = fi.value() orelse return error.Unsupported; // shorthand: later
                    const full = try std.fmt.allocPrint(b.a, "{s}.{s}", .{ nm.text, fname.text });
                    const lty: hir.Type = if (try exprIsBool(b, fval, scope)) .bool else .i64;
                    scope.next_idx = @intCast(b.main_locals.items.len);
                    const value = try buildIntExpr(b, fval, scope);
                    const idx = try scope.declare(full, ls.isVar(), lty);
                    try b.main_locals.append(b.a, lty);
                    const st = try b.a.create(hir.Stmt);
                    st.* = .{ .let = .{ .idx = idx, .value = value } };
                    try out.append(b.a, st);
                }
                if (!any) return error.Unsupported; // empty literal binds nothing
            } else if (try recCallStruct(b, init_expr)) |_| {
                // `let p = make(3, 4)` — a record-returning call: bind the
                // returned base pointer (the record lives in the scope arena).
                const rv = (try buildRecExpr(b, init_expr, scope)) orelse return error.Unsupported;
                try bindMainRecord(b, scope, nm.text, ls.isVar(), rv.e, rv.si, out);
            } else {
                // A runtime value binding: an i64 (`let a = double(21)`) or a
                // bool (`let even = n % 2 == 0`, `var flag = true`). A bool
                // binding takes one slot too — its value is an i32 0/1.
                const lty: hir.Type = if (try exprIsBool(b, init_expr, scope)) .bool else .i64;
                // Build the initializer first so it can't see its own name,
                // then allocate a single local and register in scope so later
                // expressions can resolve it. The local index is the current
                // size of `main_locals` (str bindings take two slots each,
                // i64/bool bindings take one — the same shared index space).
                scope.next_idx = @intCast(b.main_locals.items.len);
                const value = try buildIntExpr(b, init_expr, scope);
                const idx = try scope.declare(nm.text, ls.isVar(), lty);
                try b.main_locals.append(b.a, lty);
                const st = try b.a.create(hir.Stmt);
                st.* = .{ .let = .{ .idx = idx, .value = value } };
                try out.append(b.a, st);
            }
        },
        .expr_stmt => |es| {
            const expr = es.expression() orelse return error.Unsupported;
            const call = switch (expr) {
                .call => |cc| cc,
                else => return error.Unsupported,
            };
            // A host face call other than env.out (e.g. `qview.text(24, 80, 0)`
            // or `qview.set_text(80, 9, "…")`): str args flow as (ptr, len), the
            // rest as i64; no return. The backend declares the matching import.
            if (try hostFaceName(b, call)) |fname| {
                var args: std.ArrayList(*hir.Expr) = .empty;
                var ait = call.args();
                while (ait.next()) |a| try args.append(b.a, try buildHostArg(b, a, scope, rt));
                const st = try b.a.create(hir.Stmt);
                st.* = .{ .host_call = .{ .name = fname, .args = try args.toOwnedSlice(b.a) } };
                try out.append(b.a, st);
                return;
            }
            if (!isEnvOut(b.a, call)) return reject(b, .unsupported_call);
            const arg = firstArg(call) orelse return error.Unsupported;

            const st = try b.a.create(hir.Stmt);
            if (try tryConst(b, arg)) |bytes| {
                // A constant string/number/interpolation → fold into the data.
                const e = try b.a.create(hir.Expr);
                e.* = .{ .str_const = bytes };
                st.* = .{ .host_out = e };
            } else if (arg == .path and rt.get(try pathText(b, arg.path)) != null) {
                // env.out(g) where g is a runtime str binding.
                const bnd = rt.get(try pathText(b, arg.path)).?;
                const e = try b.a.create(hir.Expr);
                e.* = .{ .str_binding = .{ .ptr_idx = bnd.ptr_idx, .len_idx = bnd.len_idx } };
                st.* = .{ .host_out_str = e };
            } else if (arg == .string_lit) {
                // A string literal with interpolation. If it folds entirely to
                // a constant (e.g. only untyped fold-only helpers), emit a
                // folded `host_out`; otherwise a runtime concat.
                const v = try buildConcat(b, arg.string_lit, scope, false, rt);
                st.* = if (v.* == .str_const) .{ .host_out = v } else .{ .host_out_str = v };
            } else if (try isStrCall(b, arg)) {
                // A real call to a str-returning function.
                st.* = .{ .host_out_str = try buildStrExpr(b, arg, scope, rt) };
            } else if (try exprIsBool(b, arg, scope)) {
                // A boolean: a comparison, `&&`/`||`/`!`, a literal, a bool
                // binding, or a `-> bool` call. Printed as "true" / "false".
                st.* = .{ .host_out_bool = try buildIntExpr(b, arg, scope) };
            } else {
                // Otherwise an i64 expression (a call to an i64 function).
                const e = try buildIntExpr(b, arg, scope);
                st.* = .{ .host_out_int = e };
            }
            try out.append(b.a, st);
        },
        .assign_stmt => |as| {
            const tgt = as.target() orelse return error.Unsupported;
            const tpath = switch (tgt) {
                .path => |p| p,
                else => return error.Unsupported,
            };
            const tname = try tpath.text(b.a);
            defer b.a.free(tname);
            const op = as.op() orelse return error.Unsupported;
            const rhs_ast = as.value() orelse return error.Unsupported;
            const st = try b.a.create(hir.Stmt);
            if (scope.find(tname)) |loc| {
                // Local reassignment (`x = …`, `x += …`). A bool is not an int:
                // a plain `=` must match the binding's type; compound ops are
                // arithmetic (i64 only).
                if (!loc.mutable) return reject(b, .immutable_assign);
                const rhs_is_bool = try exprIsBool(b, rhs_ast, scope);
                if (op.kind == .EQ) {
                    if ((loc.ty == .bool) != rhs_is_bool) return error.Unsupported;
                } else if (loc.ty != .i64) {
                    return error.Unsupported;
                }
                const rhs = try buildIntExpr(b, rhs_ast, scope);
                const value = if (op.kind == .EQ) rhs else blk: {
                    const k = compoundOp(op) orelse return error.Unsupported;
                    const lhs = try b.a.create(hir.Expr);
                    lhs.* = .{ .local = .{ .idx = loc.idx, .ty = loc.ty } };
                    const bx = try b.a.create(hir.Expr);
                    bx.* = .{ .bin = .{ .kind = k, .lhs = lhs, .rhs = rhs } };
                    break :blk bx;
                };
                st.* = .{ .assign = .{ .idx = loc.idx, .value = value } };
            } else if (try findRecField(scope, tname)) |rf| {
                // `p.x = …` on a materialized record: a store at (ptr, offset).
                // Same typing discipline as a local: plain `=` must match the
                // field's type; compound ops are i64 arithmetic.
                if (!rf.mutable) return reject(b, .immutable_assign);
                const rhs_is_bool = try exprIsBool(b, rhs_ast, scope);
                if (op.kind == .EQ) {
                    if ((rf.ty == .bool) != rhs_is_bool) return error.Unsupported;
                } else if (rf.ty != .i64) {
                    return error.Unsupported;
                }
                const rhs = try buildIntExpr(b, rhs_ast, scope);
                const value = if (op.kind == .EQ) rhs else blk: {
                    const k = compoundOp(op) orelse return error.Unsupported;
                    const bx = try b.a.create(hir.Expr);
                    bx.* = .{ .bin = .{ .kind = k, .lhs = try recFieldExpr(b, rf), .rhs = rhs } };
                    break :blk bx;
                };
                const base = try b.a.create(hir.Expr);
                base.* = .{ .local = .{ .idx = rf.base_idx, .ty = .ptr } };
                st.* = .{ .field_set = .{ .base = base, .offset = rf.offset, .ty = rf.ty, .value = value } };
            } else if (b.globals.get(tname)) |gi| {
                // A module-level `state` global (`count = count + 1`).
                if (op.kind != .EQ) return error.Unsupported;
                st.* = .{ .global_set = .{ .idx = gi, .value = try buildIntExpr(b, rhs_ast, scope) } };
            } else return error.Unsupported;
            try out.append(b.a, st);
        },
        .while_stmt => |ws| {
            const cond = try buildIntExpr(b, ws.condition() orelse return error.Unsupported, scope);
            const wbody = try buildMainBlock(b, ws.body() orelse return error.Unsupported, scope, rt);
            const st = try b.a.create(hir.Stmt);
            st.* = .{ .while_ = .{ .cond = cond, .body = wbody } };
            try out.append(b.a, st);
        },
        .if_stmt => |is| try out.append(b.a, try buildMainIfNode(b, is, scope, rt)),
        .loop_stmt => |lp| {
            const lbody = try buildMainBlock(b, lp.body() orelse return error.Unsupported, scope, rt);
            const st = try b.a.create(hir.Stmt);
            st.* = .{ .loop_ = lbody };
            try out.append(b.a, st);
        },
        .break_stmt => |bs| {
            if (bs.value() != null) return error.Unsupported; // value-break not supported
            const st = try b.a.create(hir.Stmt);
            st.* = .brk;
            try out.append(b.a, st);
        },
        .continue_stmt => {
            const st = try b.a.create(hir.Stmt);
            st.* = .cont;
            try out.append(b.a, st);
        },
        else => return error.Unsupported,
    }
}

/// Build a `{ … }` block of `main` statements into one HIR block.
fn buildMainBlock(b: *Builder, block: ast.Block, scope: *Scope, rt: *RtMap) BuildError!*hir.Stmt {
    var items: std.ArrayList(*hir.Stmt) = .empty;
    var it = block.statements();
    while (it.next()) |stmt| try buildMainStmt(b, stmt, scope, rt, &items);
    const out = try b.a.create(hir.Stmt);
    out.* = .{ .block = try items.toOwnedSlice(b.a) };
    return out;
}

/// The `main` analogue of `buildIfStmtNode`: an `if`/`else(-if)` whose bodies
/// can contain host statements. An `else if` nests as a one-statement block.
fn buildMainIfNode(b: *Builder, is: ast.IfStmt, scope: *Scope, rt: *RtMap) BuildError!*hir.Stmt {
    const cond = try buildIntExpr(b, is.condition() orelse return error.Unsupported, scope);
    const then_ = try buildMainBlock(b, is.thenBody() orelse return error.Unsupported, scope, rt);
    const else_: ?*hir.Stmt = if (is.elseIf()) |eif| blk: {
        const inner = try buildMainIfNode(b, eif, scope, rt);
        const wrap = try b.a.create(hir.Stmt);
        wrap.* = .{ .block = try b.a.dupe(*hir.Stmt, &.{inner}) };
        break :blk wrap;
    } else if (is.elseBody()) |eb|
        try buildMainBlock(b, eb, scope, rt)
    else
        null;
    const out = try b.a.create(hir.Stmt);
    out.* = .{ .if_ = .{ .cond = cond, .then_ = then_, .else_ = else_ } };
    return out;
}

/// Build the qube's **public surface**: every non-`main` top-level `pub fn`,
/// whether or not `main` reaches it. A void-returning one is an exported screen/
/// twin handler (`pub fn on_press(id: i64) { … }`, `pub fn inc() { count += 1 }`);
/// a value-returning one (`pub fn greet(name: str) -> str { … }`) is a library
/// export, built through `registerFunc`. Either way the function is marked
/// `.public` so the component/WIT lift surfaces it as an export — and so a local
/// `pub fn` already built `.private` because `main` called it is upgraded to
/// public here (a transitively-reached *dependency* function, declared in
/// another file, never reaches this pass, so it correctly stays `.private`).
///
/// A private no-return-type helper is skipped — it's folded into a caller or
/// emitted on demand via `registerFunc`, not part of the surface.
fn buildScreenFuncs(b: *Builder, sf: ast.SourceFile) BuildError!void {
    var it = sf.items();
    while (it.next()) |item| switch (item) {
        .fn_decl => |fd| {
            const nm = fd.name() orelse continue;
            if (std.mem.eql(u8, nm.text, "main")) continue;
            if (fd.visibility() == null) continue; // private — built on demand if reached
            if (fd.returnType() == null) {
                try buildScreenFunc(b, fd); // void-returning handler
            } else {
                // A value-returning export (i64 / bool / str). `registerFunc`
                // dedups, so a `pub fn` already built because `main` reached it
                // returns its existing id; we then mark it public.
                const id = try registerFunc(b, nm.text);
                b.funcs.items[id].visibility = .public;
            }
        },
        else => {},
    };
}

/// Build a non-main "screen" function: i64 params, a void body of screen
/// statements (`qview.*` host calls and `state` global assignments). Appended
/// to `b.funcs`, exported when public.
fn buildScreenFunc(b: *Builder, fd: ast.FnDecl) BuildError!void {
    var scope = Scope{ .a = b.a };
    var params: std.ArrayList(hir.Param) = .empty;
    // A str param occupies TWO wasm slots (ptr, len). It lives in `scope` with
    // its idx = the ptr slot; references resolve to a str_binding {idx, idx+1}
    // (see buildStrExpr). We bump next_idx by one extra so the following param /
    // body local lands at the right wasm local index. n_params counts every
    // param (str included) since each is one `scope` entry; only the wasm SLOT
    // count diverges, which next_idx tracks.
    if (fd.params()) |ps| {
        var pit = ps.iter();
        while (pit.next()) |p| {
            const pn = (p.name() orelse return error.Unsupported).text;
            const psc = (try paramScalar(b, p)) orelse return error.Unsupported;
            const pty: hir.Type = switch (psc) {
                .str, .bool, .i64 => psc,
                else => return error.Unsupported,
            };
            _ = try scope.declare(pn, false, pty);
            if (pty == .str) scope.next_idx += 1; // second slot (len)
            try params.append(b.a, .{ .name = pn, .ty = pty });
        }
    }
    const n_scope_params: u32 = @intCast(params.items.len);
    scope.n_params = n_scope_params;

    var stmts: std.ArrayList(*hir.Stmt) = .empty;
    var it = (fd.body() orelse return error.Unsupported).statements();
    while (it.next()) |stmt| try buildScreenStmt(b, stmt, &scope, &stmts);

    const block = try b.a.create(hir.Stmt);
    block.* = .{ .block = try stmts.toOwnedSlice(b.a) };
    // Body locals = the scope entries past the params (each param, str included,
    // is one scope entry). A str param's extra wasm slot was added to next_idx,
    // so body-local wasm indices already land past the full params width.
    const n_body: usize = scope.locals.items.len - n_scope_params;
    const locals = try b.a.alloc(hir.Type, n_body);
    // The non-parameter locals, in index order, carry their declared types
    // (i64 by default, bool for a boolean `let`/`var` binding).
    for (locals, 0..) |*t, j| t.* = scope.locals.items[n_scope_params + j].ty;
    const vis: hir.Visibility = if (fd.visibility() != null) .public else .private;
    try b.funcs.append(b.a, .{
        .name = try b.a.dupe(u8, (fd.name() orelse return error.Unsupported).text),
        .params = try params.toOwnedSlice(b.a),
        .ret = .void,
        .locals = locals,
        .body = block,
        .visibility = vis,
        .is_screen = true,
    });
}

/// Build one screen-function statement (a handler body): a host call, a `state`
/// global assignment, or an `if`/`else` (recursing). Params (i64/bool/str) live
/// in `scope`. No `let`/`while` yet — handlers stay simple.
fn buildScreenStmt(b: *Builder, stmt: ast.Stmt, scope: *Scope, out: *std.ArrayList(*hir.Stmt)) BuildError!void {
    switch (stmt) {
        .expr_stmt => |es| {
            const call = switch (es.expression() orelse return error.Unsupported) {
                .call => |cc| cc,
                else => return error.Unsupported,
            };
            const fname = (try hostFaceName(b, call)) orelse return error.Unsupported;
            try out.append(b.a, try buildHostCall(b, fname, call, scope, null));
        },
        .assign_stmt => |as| {
            const tgt = switch (as.target() orelse return error.Unsupported) {
                .path => |p| p,
                else => return error.Unsupported,
            };
            const tname = try tgt.text(b.a);
            defer b.a.free(tname);
            const gi = b.globals.get(tname) orelse return error.Unsupported; // global assign only
            const rhs = try buildIntExpr(b, as.value() orelse return error.Unsupported, scope);
            const op = as.op() orelse return error.Unsupported;
            const value = if (op.kind == .EQ) rhs else blk: {
                const k = compoundOp(op) orelse return error.Unsupported;
                const lhs = try b.a.create(hir.Expr);
                lhs.* = .{ .global_get = gi };
                const bx = try b.a.create(hir.Expr);
                bx.* = .{ .bin = .{ .kind = k, .lhs = lhs, .rhs = rhs } };
                break :blk bx;
            };
            const st = try b.a.create(hir.Stmt);
            st.* = .{ .global_set = .{ .idx = gi, .value = value } };
            try out.append(b.a, st);
        },
        .if_stmt => |is| try out.append(b.a, try buildScreenIf(b, is, scope)),
        else => return error.Unsupported,
    }
}

/// Build a screen-function block (the body of an `if`/`else` branch) as a HIR
/// block of screen statements.
fn buildScreenBlock(b: *Builder, block: ast.Block, scope: *Scope) BuildError!*hir.Stmt {
    var items: std.ArrayList(*hir.Stmt) = .empty;
    var it = block.statements();
    while (it.next()) |s| try buildScreenStmt(b, s, scope, &items);
    const blk = try b.a.create(hir.Stmt);
    blk.* = .{ .block = try items.toOwnedSlice(b.a) };
    return blk;
}

/// Build a screen-function `if`/`else(-if)` chain. The condition is an i64/bool
/// expression (incl. `str_eq`, `text.len > 0`); branches hold screen statements.
fn buildScreenIf(b: *Builder, is: ast.IfStmt, scope: *Scope) BuildError!*hir.Stmt {
    const cond = try buildIntExpr(b, is.condition() orelse return error.Unsupported, scope);
    const then_ = try buildScreenBlock(b, is.thenBody() orelse return error.Unsupported, scope);
    const else_: ?*hir.Stmt = if (is.elseIf()) |eif| blk: {
        const inner = try buildScreenIf(b, eif, scope);
        const wrap = try b.a.create(hir.Stmt);
        wrap.* = .{ .block = try b.a.dupe(*hir.Stmt, &.{inner}) };
        break :blk wrap;
    } else if (is.elseBody()) |eb|
        try buildScreenBlock(b, eb, scope)
    else
        null;
    const st = try b.a.create(hir.Stmt);
    st.* = .{ .if_ = .{ .cond = cond, .then_ = then_, .else_ = else_ } };
    return st;
}

/// Build one host-call argument. Prefer the `str` path — a string literal, a
/// `str` local, or a runtime `str` binding (a handler's `text: str` param) — so
/// `qview.set_text(node, attr, "…")` flows as a (ptr, len) pair. Fall back to
/// the i64 path for everything else (numbers, i64 locals/globals).
fn buildHostArg(b: *Builder, arg: ast.Expr, scope: *Scope, rt: ?*const RtMap) BuildError!*hir.Expr {
    if (buildStrExpr(b, arg, scope, rt)) |e| {
        return e;
    } else |err| switch (err) {
        error.Unsupported => {}, // not a str — try the i64 path
        else => return err,
    }
    return buildIntExpr(b, arg, scope);
}

/// Build a `qview.*` host-call statement: str args via the str path, the rest
/// as i64 (see `buildHostArg`).
fn buildHostCall(b: *Builder, fname: []const u8, call: ast.CallExpr, scope: *Scope, rt: ?*const RtMap) BuildError!*hir.Stmt {
    var args: std.ArrayList(*hir.Expr) = .empty;
    var ait = call.args();
    while (ait.next()) |a| try args.append(b.a, try buildHostArg(b, a, scope, rt));
    const st = try b.a.create(hir.Stmt);
    st.* = .{ .host_call = .{ .name = fname, .args = try args.toOwnedSlice(b.a) } };
    return st;
}

fn pathText(b: *Builder, p: ast.PathExpr) BuildError![]const u8 {
    return p.text(b.a);
}

/// Resolve `name` to a registered i64 function, building it (and anything it
/// calls) the first time. Returns its FuncId. The id and the parameter list
/// are reserved *before* the body is built, so a recursive call inside the
/// body sees the correct arity (not the placeholder's).
fn registerFunc(b: *Builder, name: []const u8) BuildError!hir.FuncId {
    if (b.ids.get(name)) |id| return id;

    const fd = b.resolver.lookup(name) orelse return reject(b, .name_not_found);
    const rec_ret = try structOfRet(b, fd);
    const ret_ty: hir.Type = if (rec_ret != null) .ptr else blk: {
        const rs = (try fnRetScalar(b, fd)) orelse return error.Unsupported;
        if (rs == .str) return registerStrFunc(b, name, fd);
        // An i64 or a `-> bool` (i32 0/1) value function; both have i64 params
        // and a value body built by `buildIntBlock`.
        break :blk switch (rs) {
            .bool, .i64 => rs,
            else => return error.Unsupported,
        };
    };

    const owned = try b.a.dupe(u8, name);

    // Parameters (i64, bool, or a record — one `.ptr` slot) occupy local
    // indices 0..n; seed the body scope.
    var scope = Scope{ .a = b.a };
    var params: std.ArrayList(hir.Param) = .empty;
    var rec_params: std.ArrayList(?*const StructInfo) = .empty;
    var any_rec = (rec_ret != null);
    if (fd.params()) |ps| {
        var pit = ps.iter();
        while (pit.next()) |p| {
            const pn = (p.name() orelse return error.Unsupported).text;
            if (try paramScalar(b, p)) |psc| {
                const pty: hir.Type = switch (psc) {
                    .bool, .i64 => psc,
                    else => return error.Unsupported,
                };
                _ = try scope.declare(pn, false, pty);
                try params.append(b.a, .{ .name = pn, .ty = pty });
                try rec_params.append(b.a, null);
            } else if (try structOfType(b, p.type_())) |si| {
                // A record param: one address-width pointer into the caller's
                // scope arena. Field access in the body loads through it.
                _ = try scope.declare(pn, false, .ptr);
                try scope.recs.put(b.a, pn, si);
                try params.append(b.a, .{ .name = pn, .ty = .ptr });
                try rec_params.append(b.a, si);
                any_rec = true;
            } else return error.Unsupported;
        }
    }
    scope.n_params = @intCast(params.items.len);
    const param_slice = try params.toOwnedSlice(b.a);

    const id: hir.FuncId = @intCast(b.funcs.items.len);
    try b.ids.put(b.a, owned, id);

    const dummy = try b.a.create(hir.Stmt);
    dummy.* = .{ .block = &.{} };
    // Reserve with the real params so recursive arg-count checks are correct.
    try b.funcs.append(b.a, .{ .name = owned, .params = param_slice, .ret = ret_ty, .body = dummy });
    if (any_rec) {
        try b.fn_recs.put(b.a, id, .{ .params = try rec_params.toOwnedSlice(b.a), .ret = rec_ret });
    } else {
        rec_params.deinit(b.a);
    }

    // A record-returning function: v0 bodies are a single tail expression (a
    // record literal, a passthrough param, or a record-returning call) —
    // control flow in record bodies lands with a later slice.
    if (rec_ret) |want| {
        const tail = try singleTailExpr(fd) orelse return error.Unsupported;
        const rv = (try buildRecExpr(b, tail, &scope)) orelse return error.Unsupported;
        if (rv.si != want) return reject(b, .unsupported_call); // body builds a different struct
        const vstmt = try b.a.create(hir.Stmt);
        vstmt.* = .{ .expr = rv.e };
        const block = try b.a.create(hir.Stmt);
        block.* = .{ .block = try b.a.dupe(*hir.Stmt, &.{vstmt}) };
        b.funcs.items[id] = .{ .name = owned, .params = param_slice, .ret = .ptr, .body = block };
        return id;
    }

    const body = try buildIntBlock(b, fd.body() orelse return error.Unsupported, &scope);
    // A value-producing i64 function whose tail is an `if` with no `else` has a
    // path that yields no value → UnsupportedCall (matches the legacy emitter,
    // which rejects a value `if` lacking an else).
    if (tailIsValueIfNoElse(body)) return reject(b, .unsupported_call);
    const extra = scope.extra();
    const locals = try b.a.alloc(hir.Type, extra);
    // The non-parameter locals, in index order, carry their declared types
    // (i64 by default, bool for a boolean `let`/`var` binding).
    for (locals, 0..) |*t, j| t.* = scope.locals.items[scope.n_params + j].ty;

    b.funcs.items[id] = .{ .name = owned, .params = param_slice, .ret = ret_ty, .locals = locals, .body = body };
    return id;
}

/// True if `body` (an i64 function block) ends in an `if` with no `else` — a
/// value position with a path that produces no value.
fn tailIsValueIfNoElse(body: *const hir.Stmt) bool {
    const items = switch (body.*) {
        .block => |s| s,
        else => return false,
    };
    if (items.len == 0) return false;
    return switch (items[items.len - 1].*) {
        .if_ => |iff| iff.else_ == null,
        else => false,
    };
}

/// Register a `str`-returning function. v0 handles an all-str-parameter
/// function whose body is a single tail str expression (a constant string, a
/// passthrough parameter ref, or a call to another str function). Concat
/// bodies and runtime bindings land in a later slice.
fn registerStrFunc(b: *Builder, name: []const u8, fd: ast.FnDecl) BuildError!hir.FuncId {
    var scope = Scope{ .a = b.a };
    var params: std.ArrayList(hir.Param) = .empty;
    if (fd.params()) |ps| {
        var pit = ps.iter();
        while (pit.next()) |p| {
            const psc = (try paramScalar(b, p)) orelse return error.Unsupported;
            if (psc != .str) return error.Unsupported; // all-str params for now
            const pn = (p.name() orelse return error.Unsupported).text;
            _ = try scope.declare(pn, false, .str);
            try params.append(b.a, .{ .name = pn, .ty = .str });
        }
    }
    scope.n_params = @intCast(params.items.len);
    const param_slice = try params.toOwnedSlice(b.a);

    const owned = try b.a.dupe(u8, name);
    const id: hir.FuncId = @intCast(b.funcs.items.len);
    try b.ids.put(b.a, owned, id);
    const dummy = try b.a.create(hir.Stmt);
    dummy.* = .{ .block = &.{} };
    try b.funcs.append(b.a, .{ .name = owned, .params = param_slice, .ret = .str, .body = dummy });

    const tail = try singleTailExpr(fd) orelse return error.Unsupported;
    const value = try buildStrExpr(b, tail, &scope, null); // callee bodies have no runtime bindings
    const vstmt = try b.a.create(hir.Stmt);
    vstmt.* = .{ .expr = value };
    const block = try b.a.create(hir.Stmt);
    block.* = .{ .block = try b.a.dupe(*hir.Stmt, &.{vstmt}) };

    b.funcs.items[id] = .{ .name = owned, .params = param_slice, .ret = .str, .body = block };
    return id;
}

/// Build a `str`-valued expression: a constant string literal (no runtime
/// interpolation), a passthrough parameter reference, or a call to a str
/// function (whose arguments are themselves str values).
/// If `name` resolves to a `str` value (a scope local/param or a runtime str
/// binding), build a str_binding expr for it; else null. Used to recognize a
/// str-method receiver in `<recv>.<method>(…)`, which parses as a dotted call.
fn strReceiver(b: *Builder, name: []const u8, scope: *Scope, rt: ?*const RtMap) BuildError!?*hir.Expr {
    if (scope.find(name)) |loc| {
        if (loc.ty != .str) return null;
        const e = try b.a.create(hir.Expr);
        e.* = .{ .str_binding = .{ .ptr_idx = loc.idx, .len_idx = loc.idx + 1 } };
        return e;
    }
    if (rtBinding(rt, name)) |bnd| {
        const e = try b.a.create(hir.Expr);
        e.* = .{ .str_binding = .{ .ptr_idx = bnd.ptr_idx, .len_idx = bnd.len_idx } };
        return e;
    }
    return null;
}

fn buildStrExpr(b: *Builder, expr: ast.Expr, scope: *Scope, rt: ?*const RtMap) BuildError!*hir.Expr {
    const out = try b.a.create(hir.Expr);
    switch (expr) {
        .string_lit => |sl| {
            // A fully-constant literal folds; one with dynamic interpolation
            // becomes a runtime concat. (Only reached for callee bodies.)
            if (b.eval.renderStringLit(sl)) |bytes| {
                out.* = .{ .str_const = bytes };
            } else |e| switch (e) {
                error.NotConst => return buildConcat(b, sl, scope, true, rt),
                error.ConstArith => return reject(b, .not_const),
                error.OutOfMemory => return error.OutOfMemory,
            }
        },
        .path => |p| {
            const txt = try p.text(b.a);
            defer b.a.free(txt);
            if (scope.find(txt)) |loc| {
                if (loc.ty != .str) return error.Unsupported; // an i64 local in a str position
                // A `str` local/param occupies two slots; `loc.idx` is the ptr
                // slot and `loc.idx + 1` the len slot. Resolve to an explicit
                // str_binding (not the str_param idx*2 ABI) so mixed i64/str
                // params index their wasm locals correctly.
                out.* = .{ .str_binding = .{ .ptr_idx = loc.idx, .len_idx = loc.idx + 1 } };
            } else if (rtBinding(rt, txt)) |bnd| {
                out.* = .{ .str_binding = .{ .ptr_idx = bnd.ptr_idx, .len_idx = bnd.len_idx } };
            } else return error.Unsupported;
        },
        .call => |cc| {
            const callee = cc.callee() orelse return error.Unsupported;
            const cpath = switch (callee) {
                .path => |p| p,
                else => return error.Unsupported,
            };
            const cname = try cpath.text(b.a);
            defer b.a.free(cname);
            // `<str>.slice(start, end)` parses as a call with a dotted path callee
            // (like `qview.set_attr(…)`). The str-VALUED method.
            if (std.mem.lastIndexOfScalar(u8, cname, '.')) |dot| {
                if (std.mem.eql(u8, cname[dot + 1 ..], "slice")) {
                    if (try strReceiver(b, cname[0..dot], scope, rt)) |sval| {
                        var sit = cc.args();
                        const start = try buildIntExpr(b, sit.next() orelse return error.Unsupported, scope);
                        const end = try buildIntExpr(b, sit.next() orelse return error.Unsupported, scope);
                        out.* = .{ .str_slice = .{ .str = sval, .start = start, .end = end } };
                        return out;
                    }
                }
            }
            const id = try registerFunc(b, cname);
            if (b.funcs.items[id].ret != .str) return error.Unsupported;
            var args: std.ArrayList(*hir.Expr) = .empty;
            var ait = cc.args();
            while (ait.next()) |a| try args.append(b.a, try buildStrArg(b, a, scope, rt));
            if (args.items.len != b.funcs.items[id].params.len) return reject(b, .unsupported_call);
            out.* = .{ .call = .{ .func = id, .args = try args.toOwnedSlice(b.a) } };
        },
        .method => |me| {
            // `s.slice(start, end)` — the only str-VALUED method. (index_of /
            // starts_with / contains are i64/bool, handled in buildIntExpr.)
            const mname = (me.method() orelse return error.Unsupported).text;
            if (!std.mem.eql(u8, mname, "slice")) return error.Unsupported;
            const sval = try buildStrExpr(b, me.receiver() orelse return error.Unsupported, scope, rt);
            var ait = me.args();
            const start = try buildIntExpr(b, ait.next() orelse return error.Unsupported, scope);
            const end = try buildIntExpr(b, ait.next() orelse return error.Unsupported, scope);
            out.* = .{ .str_slice = .{ .str = sval, .start = start, .end = end } };
        },
        else => return error.Unsupported,
    }
    return out;
}



/// Build a `str` argument at a call site: a compile-time constant (a literal
/// or a const-bodied call like `vshout()`) folds to a `str_const`; a bare
/// parameter passes through, and a runtime str binding passes by reference.
fn buildStrArg(b: *Builder, arg: ast.Expr, scope: *Scope, rt: ?*const RtMap) BuildError!*hir.Expr {
    b.eval.fold_calls = true;
    const folded = try tryConst(b, arg);
    b.eval.fold_calls = false;
    const out = try b.a.create(hir.Expr);
    if (folded) |bytes| {
        out.* = .{ .str_const = bytes };
        return out;
    }
    switch (arg) {
        .path => |p| {
            const txt = try p.text(b.a);
            defer b.a.free(txt);
            if (scope.find(txt)) |loc| {
                if (loc.ty != .str) return error.Unsupported; // an i64 local in a str arg slot
                // ptr slot at loc.idx, len at loc.idx + 1 (see buildStrExpr).
                out.* = .{ .str_binding = .{ .ptr_idx = loc.idx, .len_idx = loc.idx + 1 } };
            } else if (rtBinding(rt, txt)) |bnd| {
                out.* = .{ .str_binding = .{ .ptr_idx = bnd.ptr_idx, .len_idx = bnd.len_idx } };
            } else return error.Unsupported;
        },
        // A nested, non-const call as a str argument (`wrap(shout("yo"))`): bind
        // it first (`let t = shout("yo"); wrap(t)`). Reported as NotConstExpr.
        .call => return reject(b, .not_const),
        else => return error.Unsupported,
    }
    return out;
}

fn rtBinding(rt: ?*const RtMap, name: []const u8) ?StrBinding {
    return if (rt) |m| m.get(name) else null;
}

/// Split an interpolated string literal into runtime-concat pieces (mirrors
/// the legacy `splitInterpolation`). Constant runs (escapes, `{{`/`}}`, and
/// const-foldable interpolations) accumulate into `str_const` pieces; `{name}`
/// matching a parameter becomes a `local` piece; `{f()}` (top-level only,
/// nullary str) becomes a `call` piece. A reference that is neither constant
/// nor a parameter (a runtime binding) defers to the legacy path.
fn buildConcat(b: *Builder, sl: ast.StringLit, scope: *Scope, in_callee: bool, rt: ?*const RtMap) BuildError!*hir.Expr {
    const raw = sl.rawText() orelse return error.Unsupported;
    if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') return error.Unsupported;
    const text = raw[1 .. raw.len - 1];

    var pieces: std.ArrayList(*hir.Expr) = .empty;
    var lit: std.ArrayList(u8) = .empty;

    const flush = struct {
        fn call(bld: *Builder, buf: *std.ArrayList(u8), dst: *std.ArrayList(*hir.Expr)) BuildError!void {
            if (buf.items.len == 0) return;
            const e = try bld.a.create(hir.Expr);
            e.* = .{ .str_const = try buf.toOwnedSlice(bld.a) };
            try dst.append(bld.a, e);
        }
    }.call;

    var i: usize = 0;
    while (i < text.len) {
        const ch = text[i];
        if (ch == '\\' and i + 1 < text.len) {
            try lit.append(b.a, consteval.decodeEscape(text[i + 1]));
            i += 2;
            continue;
        }
        if (ch == '{') {
            if (i + 1 < text.len and text[i + 1] == '{') {
                try lit.append(b.a, '{');
                i += 2;
                continue;
            }
            const close = std.mem.indexOfScalarPos(u8, text, i + 1, '}') orelse return error.Unsupported;
            const inner = text[i + 1 .. close];
            const r = parser.parse.parseExpression(b.a, inner, "<interp>") catch return error.Unsupported;
            const iexpr = ast.Expr.cast(r.root) orelse return error.Unsupported;
            switch (iexpr) {
                .call => |cc| {
                    if (in_callee) return error.Unsupported; // callee bodies don't nest calls (v0)
                    var ca = cc.args();
                    if (ca.next() != null) return error.Unsupported; // nullary only
                    const callee = cc.callee() orelse return error.Unsupported;
                    const cpath = switch (callee) {
                        .path => |p| p,
                        else => return error.Unsupported,
                    };
                    const cname = try cpath.text(b.a);
                    defer b.a.free(cname);
                    const fd = b.resolver.lookup(cname) orelse return reject(b, .name_not_found);
                    // An untyped value function (`fn version { "9.9.9" }`, no
                    // `-> str`) can't be emitted as a runtime str function, so
                    // fold its const body — legacy-compatible. A typed `-> str`
                    // function stays a real runtime call (like `env.out(f())`).
                    if (fd.returnType() == null) {
                        b.eval.fold_calls = true;
                        const folded = try tryConst(b, iexpr);
                        b.eval.fold_calls = false;
                        try lit.appendSlice(b.a, folded orelse return reject(b, .unsupported_call));
                    } else {
                        const id = try registerFunc(b, cname);
                        if (b.funcs.items[id].ret != .str) return error.Unsupported;
                        try flush(b, &lit, &pieces);
                        const e = try b.a.create(hir.Expr);
                        e.* = .{ .call = .{ .func = id, .args = &.{} } };
                        try pieces.append(b.a, e);
                    }
                },
                .path => |pp| {
                    const ptext = try pp.text(b.a);
                    defer b.a.free(ptext);
                    if (scope.find(ptext)) |loc| {
                        try flush(b, &lit, &pieces);
                        const piece = try b.a.create(hir.Expr);
                        // A str local (callee param) passes through as-is; an
                        // i64 local interpolates as its decimal text.
                        if (loc.ty == .str) {
                            piece.* = .{ .local = .{ .idx = loc.idx, .ty = loc.ty } };
                        } else {
                            const lref = try b.a.create(hir.Expr);
                            lref.* = .{ .local = .{ .idx = loc.idx, .ty = loc.ty } };
                            piece.* = .{ .fmt_int = lref };
                        }
                        try pieces.append(b.a, piece);
                    } else if (rtBinding(rt, ptext)) |bnd| {
                        try flush(b, &lit, &pieces);
                        const e = try b.a.create(hir.Expr);
                        e.* = .{ .str_binding = .{ .ptr_idx = bnd.ptr_idx, .len_idx = bnd.len_idx } };
                        try pieces.append(b.a, e);
                    } else if (try findRecField(scope, ptext)) |rf| {
                        // `{p.x}` on a materialized record: format the i64
                        // field. (A bool field has no text form here yet.)
                        if (rf.ty != .i64) return error.Unsupported;
                        try flush(b, &lit, &pieces);
                        const piece = try b.a.create(hir.Expr);
                        piece.* = .{ .fmt_int = try recFieldExpr(b, rf) };
                        try pieces.append(b.a, piece);
                    } else {
                        // A const binding folds into the run; otherwise defer.
                        const v = (try tryConst(b, iexpr)) orelse return error.Unsupported;
                        try lit.appendSlice(b.a, v);
                    }
                },
                else => {
                    const v = (try tryConst(b, iexpr)) orelse return error.Unsupported;
                    try lit.appendSlice(b.a, v);
                },
            }
            i = close + 1;
            continue;
        }
        if (ch == '}' and i + 1 < text.len and text[i + 1] == '}') {
            try lit.append(b.a, '}');
            i += 2;
            continue;
        }
        try lit.append(b.a, ch);
        i += 1;
    }
    try flush(b, &lit, &pieces);

    // If every piece folded to constants, the interpolation is a compile-time
    // constant string: return a bare `str_const` so the caller can emit a
    // folded `host_out` (value + newline contiguous) rather than a runtime
    // concat. (Reached e.g. for `"{version()}"` where `version` is an untyped
    // fold-only helper.)
    if (pieces.items.len <= 1) {
        const out = try b.a.create(hir.Expr);
        out.* = if (pieces.items.len == 1 and pieces.items[0].* == .str_const)
            pieces.items[0].*
        else if (pieces.items.len == 0)
            .{ .str_const = "" }
        else
            .{ .concat = try pieces.toOwnedSlice(b.a) };
        return out;
    }

    const out = try b.a.create(hir.Expr);
    out.* = .{ .concat = try pieces.toOwnedSlice(b.a) };
    return out;
}

/// A function body that is a single tail expression (one statement), or
/// `null` if it has more (bindings / control flow).
fn singleTailExpr(fd: ast.FnDecl) BuildError!?ast.Expr {
    const body = fd.body() orelse return error.Unsupported;
    var it = body.statements();
    var first: ?ast.Expr = null;
    var count: usize = 0;
    while (it.next()) |stmt| {
        count += 1;
        if (count > 1) return null;
        first = switch (stmt) {
            .expr_stmt => |es| es.expression(),
            .return_stmt => |rs| rs.value(),
            else => return null,
        };
    }
    return first;
}

/// True if `arg` is a call to a `str`-returning function (so `main` should
/// emit a `host_out_str` rather than trying an i64 lowering).
fn isStrCall(b: *Builder, arg: ast.Expr) BuildError!bool {
    const call = switch (arg) {
        .call => |cc| cc,
        else => return false,
    };
    const callee = call.callee() orelse return false;
    const cpath = switch (callee) {
        .path => |p| p,
        else => return false,
    };
    const cname = try cpath.text(b.a);
    defer b.a.free(cname);
    const fd = b.resolver.lookup(cname) orelse return false;
    const rs = try fnRetScalar(b, fd);
    return rs != null and rs.? == .str;
}

/// A3: annotations lower through the sema type store; the result maps
/// onto the codegen scalar floor. Anything beyond it — named types,
/// compounds, the wider numeric tower (i8…u128/f16/f32) — is `null`,
/// which callers turn into the honest `Unsupported`.
fn semaScalar(b: *Builder, te_opt: ?ast.TypeExpr) std.mem.Allocator.Error!?hir.Type {
    const id = try sema.types.lower(&b.tstore, null, te_opt);
    return switch (b.tstore.get(id)) {
        .builtin => |bi| switch (bi) {
            .i64 => .i64,
            .i32 => .i32,
            .f64 => .f64,
            .bool => .bool,
            .str => .str,
            .void => .void,
            else => null,
        },
        else => null,
    };
}

/// Scalar return type of `fd`'s annotation; `null` when absent or
/// outside the floor. (Absent ≠ void here: the void-returning handler
/// path is chosen by the caller before consulting this.)
fn fnRetScalar(b: *Builder, fd: ast.FnDecl) std.mem.Allocator.Error!?hir.Type {
    const rt = fd.returnType() orelse return null;
    return semaScalar(b, rt.type_());
}

fn paramScalar(b: *Builder, p: ast.Param) std.mem.Allocator.Error!?hir.Type {
    return semaScalar(b, p.type_());
}

// ---------------------------------------------------------------------
// Record layout + materialized record values (B2b — the layout story).
// ---------------------------------------------------------------------

/// The size/alignment of a field type on the v0 layout floor, per
/// spec/memory.md §"Linear struct layout". `null` = outside the floor.
fn fieldWidth(ty: hir.Type) ?struct { size: u32, alignment: u32 } {
    return switch (ty) {
        .i64 => .{ .size = 8, .alignment = 8 },
        .bool => .{ .size = 1, .alignment = 1 },
        else => null,
    };
}

/// Lay out every struct declaration in `sf` (declaration order, natural
/// alignment, size rounded up to the struct alignment). A struct with a
/// field outside the v0 floor — or with no record fields at all — is not
/// registered; a use of it stays the honest `Unsupported`.
fn registerStructs(b: *Builder, sf: ast.SourceFile) BuildError!void {
    var it = sf.items();
    while (it.next()) |item| switch (item) {
        .struct_decl => |sd| {
            const nm = sd.name() orelse continue;
            var fields: std.ArrayList(StructField) = .empty;
            var off: u32 = 0;
            var max_align: u32 = 1;
            var ok = true;
            var fit = sd.fields();
            while (fit.next()) |f| {
                const fname = f.name() orelse {
                    ok = false;
                    break;
                };
                const fty = (try semaScalar(b, f.type_())) orelse {
                    ok = false;
                    break;
                };
                const w = fieldWidth(fty) orelse {
                    ok = false;
                    break;
                };
                off = std.mem.alignForward(u32, off, w.alignment);
                try fields.append(b.a, .{ .name = fname.text, .ty = fty, .offset = off });
                off += w.size;
                if (w.alignment > max_align) max_align = w.alignment;
            }
            if (!ok or fields.items.len == 0) continue;
            const si = try b.a.create(StructInfo);
            si.* = .{
                .name = nm.text,
                .fields = try fields.toOwnedSlice(b.a),
                .size = std.mem.alignForward(u32, off, max_align),
                .alignment = max_align,
            };
            try b.structs.put(b.a, nm.text, si);
        },
        else => {},
    };
}

/// The registered struct a type annotation names, if any. Generic paths and
/// non-path types are not records on the v0 floor.
fn structOfType(b: *Builder, te_opt: ?ast.TypeExpr) BuildError!?*const StructInfo {
    const te = te_opt orelse return null;
    switch (te) {
        .path => |pt| {
            if (pt.hasGenericArgs()) return null;
            const nm = try pt.name(b.a);
            defer b.a.free(nm);
            return b.structs.get(nm);
        },
        else => return null,
    }
}

fn structOfRet(b: *Builder, fd: ast.FnDecl) BuildError!?*const StructInfo {
    const rt = fd.returnType() orelse return null;
    return structOfType(b, rt.type_());
}

/// If `expr` is a call to a record-returning function (resolvable, bare
/// name), the struct it returns. Used to detect `let p = make(3, 4)`.
fn recCallStruct(b: *Builder, expr: ast.Expr) BuildError!?*const StructInfo {
    const call = switch (expr) {
        .call => |cc| cc,
        else => return null,
    };
    const callee = call.callee() orelse return null;
    const cpath = switch (callee) {
        .path => |p| p,
        else => return null,
    };
    const cname = try cpath.text(b.a);
    defer b.a.free(cname);
    if (std.mem.indexOfScalar(u8, cname, '.') != null) return null; // host/method calls aren't record-valued
    const fd = b.resolver.lookup(cname) orelse return null;
    return structOfRet(b, fd);
}

/// Resolve `<binding>.<field>` against the scope's materialized record
/// bindings (`Scope.recs`). `null` when the head isn't one; an unknown field
/// on a known record — or nested access — is `Unsupported` (nesting needs
/// struct-typed fields, a later slice).
fn findRecField(scope: *const Scope, txt: []const u8) BuildError!?RecField {
    const dot = std.mem.indexOfScalar(u8, txt, '.') orelse return null;
    const si = scope.recs.get(txt[0..dot]) orelse return null;
    const loc = scope.find(txt[0..dot]) orelse return null;
    const rest = txt[dot + 1 ..];
    if (std.mem.indexOfScalar(u8, rest, '.') != null) return error.Unsupported;
    const f = si.field(rest) orelse return error.Unsupported;
    return .{ .base_idx = loc.idx, .offset = f.offset, .ty = f.ty, .mutable = loc.mutable };
}

/// A `field_get` expression for a resolved record field.
fn recFieldExpr(b: *Builder, rf: RecField) BuildError!*hir.Expr {
    const base = try b.a.create(hir.Expr);
    base.* = .{ .local = .{ .idx = rf.base_idx, .ty = .ptr } };
    const out = try b.a.create(hir.Expr);
    out.* = .{ .field_get = .{ .base = base, .offset = rf.offset, .ty = rf.ty } };
    return out;
}

/// Does the name appear as a *whole-value* use anywhere in `main`'s body —
/// a bare PATH_EXPR that is exactly `name` (a call argument, `env.out(p)`,
/// …), or a *method call through it* (`p.area()` — the receiver passes as
/// a pointer, so the record must exist in memory)? A plain field access
/// (`p.x`) parses as one greedy dotted PATH_EXPR and never matches.
/// Conservative: a match anywhere (even before the binding) materializes
/// the record; SROA is the optimization, not the semantics.
fn recordEscapes(b: *Builder, name: []const u8) BuildError!bool {
    const body = b.main_body orelse return false;
    return nodeHasWholePath(b, body.cst, name);
}

fn nodeHasWholePath(b: *Builder, node: *const parser.cst.Node, name: []const u8) BuildError!bool {
    if (node.kind == .PATH_EXPR) {
        const txt = try (ast.PathExpr{ .cst = node }).text(b.a);
        defer b.a.free(txt);
        return std.mem.eql(u8, txt, name); // paths don't nest — no recursion
    }
    if (node.kind == .CALL_EXPR) {
        // A dotted callee whose head is `name` is a method call on the
        // binding (`p.area()`) — a receiver use, so the record escapes.
        // (A field can't be called, so any call through the path counts.)
        for (node.children) |ch| switch (ch) {
            .node => |nn| {
                if (nn.kind != .PATH_EXPR) continue;
                const txt = try (ast.PathExpr{ .cst = nn }).text(b.a);
                defer b.a.free(txt);
                if (std.mem.indexOfScalar(u8, txt, '.')) |dot| {
                    if (std.mem.eql(u8, txt[0..dot], name)) return true;
                }
                break; // only the callee (the first path child) counts
            },
            .token => {},
        };
    }
    for (node.children) |ch| switch (ch) {
        .node => |nn| if (try nodeHasWholePath(b, nn, name)) return true,
        .token => {},
    };
    return false;
}

/// The fit method `<struct>.<name>` from the registry: every fit whose
/// target is the struct (any face) is searched for a method signature
/// with the name. v0 dispatch keys on (concrete type, method name) —
/// unambiguous until two fits collide, which is a later TYP check.
fn findFitMethod(b: *Builder, struct_name: []const u8, mname: []const u8) ?ast.MethodSig {
    if (b.fitreg == null) return null;
    const reg = &b.fitreg.?;
    for (reg.fits.items) |f| {
        const t = f.target orelse continue;
        if (!std.mem.eql(u8, t, struct_name)) continue;
        var ms = f.decl.methods();
        while (ms.next()) |m| {
            const nm = m.name() orelse continue;
            if (std.mem.eql(u8, nm.text, mname)) return m;
        }
    }
    return null;
}

/// Resolve `<si>.<mname>` to a registered HIR function, building the fit
/// method's body the first time (deduped as "Struct.method" in `b.ids`,
/// which is also its wasm name). The method must take `self` first — the
/// dispatch receiver, passed as the record's base pointer per B2b's ABI;
/// remaining params and the return stay on the scalar floor (i64/bool).
/// Null when no fit for the struct declares the method.
fn registerFitMethod(b: *Builder, si: *const StructInfo, mname: []const u8) BuildError!?hir.FuncId {
    const key = try std.fmt.allocPrint(b.a, "{s}.{s}", .{ si.name, mname });
    if (b.ids.get(key)) |id| return id;
    const m = findFitMethod(b, si.name, mname) orelse return null;
    const body_blk = m.body() orelse return error.Unsupported; // a bodyless sig can't be called
    const rt = m.returnType() orelse return error.Unsupported;
    const rs = (try semaScalar(b, rt.type_())) orelse return error.Unsupported;
    const ret_ty: hir.Type = switch (rs) {
        .bool, .i64 => rs,
        else => return error.Unsupported, // str/record-valued methods: later
    };

    var scope = Scope{ .a = b.a };
    var params: std.ArrayList(hir.Param) = .empty;
    var rec_params: std.ArrayList(?*const StructInfo) = .empty;
    const ps = m.params() orelse return error.Unsupported;
    var pit = ps.iter();
    const recv = pit.next() orelse return error.Unsupported;
    if (!recv.isSelf()) return error.Unsupported; // dispatch needs a receiver
    _ = try scope.declare("self", false, .ptr);
    try scope.recs.put(b.a, "self", si);
    try params.append(b.a, .{ .name = "self", .ty = .ptr });
    try rec_params.append(b.a, si);
    while (pit.next()) |p| {
        const psc = (try paramScalar(b, p)) orelse return error.Unsupported;
        const pty: hir.Type = switch (psc) {
            .bool, .i64 => psc,
            else => return error.Unsupported,
        };
        const pn = (p.name() orelse return error.Unsupported).text;
        _ = try scope.declare(pn, false, pty);
        try params.append(b.a, .{ .name = pn, .ty = pty });
        try rec_params.append(b.a, null);
    }
    scope.n_params = @intCast(params.items.len);
    const param_slice = try params.toOwnedSlice(b.a);

    // Reserve before building the body so `self.other()` (and recursion)
    // resolves with the correct arity.
    const id: hir.FuncId = @intCast(b.funcs.items.len);
    try b.ids.put(b.a, key, id);
    const dummy = try b.a.create(hir.Stmt);
    dummy.* = .{ .block = &.{} };
    try b.funcs.append(b.a, .{ .name = key, .params = param_slice, .ret = ret_ty, .body = dummy });
    try b.fn_recs.put(b.a, id, .{ .params = try rec_params.toOwnedSlice(b.a), .ret = null });

    const body = try buildIntBlock(b, body_blk, &scope);
    if (tailIsValueIfNoElse(body)) return reject(b, .unsupported_call);
    const extra = scope.extra();
    const locals = try b.a.alloc(hir.Type, extra);
    for (locals, 0..) |*t, j| t.* = scope.locals.items[scope.n_params + j].ty;
    b.funcs.items[id] = .{ .name = key, .params = param_slice, .ret = ret_ty, .locals = locals, .body = body };
    return id;
}

/// Bind a record value in `main`: one `.ptr` local (shared index space with
/// the other main bindings) + a `Scope.recs` entry so field access and
/// whole-value uses resolve.
fn bindMainRecord(b: *Builder, scope: *Scope, name: []const u8, is_var: bool, value: *hir.Expr, si: *const StructInfo, out: *std.ArrayList(*hir.Stmt)) BuildError!void {
    scope.next_idx = @intCast(b.main_locals.items.len);
    const idx = try scope.declare(name, is_var, .ptr);
    try b.main_locals.append(b.a, .ptr);
    try scope.recs.put(b.a, name, si);
    const st = try b.a.create(hir.Stmt);
    st.* = .{ .let = .{ .idx = idx, .value = value } };
    try out.append(b.a, st);
}

/// Build a record-valued expression (a `.ptr`): a record literal (allocated
/// in the scope arena), a bare reference to a materialized record binding /
/// record param, or a call to a record-returning function. `null` when the
/// expression isn't record-shaped (the caller picks another path).
fn buildRecExpr(b: *Builder, expr: ast.Expr, scope: *Scope) BuildError!?struct { e: *hir.Expr, si: *const StructInfo } {
    switch (expr) {
        .paren => |p| return buildRecExpr(b, p.inner() orelse return error.Unsupported, scope),
        .record => |re| {
            const pname = try (re.path() orelse return error.Unsupported).text(b.a);
            defer b.a.free(pname);
            const si = b.structs.get(pname) orelse return error.Unsupported; // a literal of an unregistered struct
            var inits: std.ArrayList(hir.FieldInit) = .empty;
            var seen: usize = 0;
            var iit = re.inits();
            while (iit.next()) |fi| {
                const fname = fi.name() orelse return error.Unsupported;
                const fval = fi.value() orelse return error.Unsupported; // shorthand inits: later
                const f = si.field(fname.text) orelse return error.Unsupported;
                // A bool is not an int: the value's kind must match the field.
                if ((f.ty == .bool) != (try exprIsBool(b, fval, scope))) return error.Unsupported;
                try inits.append(b.a, .{ .offset = f.offset, .ty = f.ty, .value = try buildIntExpr(b, fval, scope) });
                seen += 1;
            }
            // Every field must be initialized, each exactly once (the layout
            // has no default values). seen == fields.len with per-name lookup
            // admits a duplicate+omission pair only if a name repeats — which
            // the duplicate-name check below rejects.
            if (seen != si.fields.len) return error.Unsupported;
            var i: usize = 0;
            while (i < inits.items.len) : (i += 1) {
                var j = i + 1;
                while (j < inits.items.len) : (j += 1) {
                    if (inits.items[i].offset == inits.items[j].offset) return error.Unsupported;
                }
            }
            const out = try b.a.create(hir.Expr);
            out.* = .{ .record_alloc = .{ .size = si.size, .alignment = si.alignment, .inits = try inits.toOwnedSlice(b.a) } };
            return .{ .e = out, .si = si };
        },
        .path => |p| {
            const txt = try p.text(b.a);
            defer b.a.free(txt);
            const si = scope.recs.get(txt) orelse return null;
            const loc = scope.find(txt) orelse return null;
            const out = try b.a.create(hir.Expr);
            out.* = .{ .local = .{ .idx = loc.idx, .ty = .ptr } };
            return .{ .e = out, .si = si };
        },
        .call => |cc| {
            const si = (try recCallStruct(b, expr)) orelse return null;
            const callee_path = switch (cc.callee() orelse return error.Unsupported) {
                .path => |p| p,
                else => return error.Unsupported,
            };
            const cname = try callee_path.text(b.a);
            defer b.a.free(cname);
            const id = try registerFunc(b, cname);
            const args = try buildCallArgs(b, id, cc, scope, null);
            const out = try b.a.create(hir.Expr);
            out.* = .{ .call = .{ .func = id, .args = args } };
            return .{ .e = out, .si = si };
        },
        else => return null,
    }
}

/// Build + check a call's arguments against the callee's parameter kinds
/// (int / bool / record). Shared by the i64 path, the record path, and
/// fit-method dispatch: a non-null `recv` fills the callee's first
/// parameter (the `self` receiver), and the source arguments fill the
/// rest. A record argument must be a record value of the parameter's
/// exact struct.
fn buildCallArgs(b: *Builder, id: hir.FuncId, cc: ast.CallExpr, scope: *Scope, recv: ?*hir.Expr) BuildError![]const *hir.Expr {
    // Snapshot the parameter kinds before building the args — building an
    // argument may register a new callee and grow `b.funcs`, so we can't
    // hold a slice into it across the loop.
    const ParamKind = union(enum) { int, bool_, rec: *const StructInfo };
    const np = b.funcs.items[id].params.len;
    const kinds = try b.a.alloc(ParamKind, np);
    const frec = b.fn_recs.get(id);
    for (b.funcs.items[id].params, 0..) |p, k| {
        kinds[k] = switch (p.ty) {
            .bool => .bool_,
            .i64 => .int,
            // A `.ptr` param is a record on this path (str callees never get here).
            .ptr => .{ .rec = (frec orelse return error.Unsupported).params[k] orelse return error.Unsupported },
            else => return error.Unsupported,
        };
    }

    var args: std.ArrayList(*hir.Expr) = .empty;
    var ait = cc.args();
    var ai: usize = 0;
    if (recv) |r| {
        try args.append(b.a, r);
        ai = 1;
    }
    while (ait.next()) |a| : (ai += 1) {
        if (ai >= np) return reject(b, .unsupported_call);
        switch (kinds[ai]) {
            .rec => |want| {
                const rv = (try buildRecExpr(b, a, scope)) orelse return reject(b, .unsupported_call);
                if (rv.si != want) return reject(b, .unsupported_call); // a different struct
                try args.append(b.a, rv.e);
            },
            // A bool is not an int: each arg's kind must match its parameter.
            .int => {
                if (try exprIsBool(b, a, scope)) return reject(b, .unsupported_call);
                try args.append(b.a, try buildIntExpr(b, a, scope));
            },
            .bool_ => {
                if (!(try exprIsBool(b, a, scope))) return reject(b, .unsupported_call);
                try args.append(b.a, try buildIntExpr(b, a, scope));
            },
        }
    }
    if (ai != np) return reject(b, .unsupported_call);
    return args.toOwnedSlice(b.a);
}

/// Does `arg` denote a boolean value? Used to route `env.out` to the bool
/// path, type `let` bindings, and check call-argument kinds. A3 slice 2:
/// the decision delegates to sema's expression typer
/// (`sema.exprtype.scalarOf`); this bridge adapts the builder's `Scope`
/// and module resolver into sema's `Env` callbacks. The callbacks
/// collapse into sema's own tables when name lookup moves there
/// (A3 final slice).
fn exprIsBool(b: *Builder, arg: ast.Expr, scope: *const Scope) BuildError!bool {
    var bridge = ExprTypeBridge{ .b = b, .scope = scope };
    return (try sema.exprtype.scalarOf(b.a, arg, .{
        .ctx = @ptrCast(&bridge),
        .localType = ExprTypeBridge.localType,
        .callRet = ExprTypeBridge.callRet,
    })) == .bool;
}

const ExprTypeBridge = struct {
    b: *Builder,
    scope: *const Scope,

    fn localType(ctx: *anyopaque, name: []const u8) ?sema.exprtype.ScalarType {
        const self: *ExprTypeBridge = @ptrCast(@alignCast(ctx));
        const loc = self.scope.find(name) orelse {
            // `p.x` on a materialized record: the field's declared type.
            const rf = (findRecField(self.scope, name) catch return null) orelse return null;
            return switch (rf.ty) {
                .bool => .bool,
                .i64 => .i64,
                else => .unknown,
            };
        };
        return switch (loc.ty) {
            .bool => .bool,
            .i64 => .i64,
            .str => .str,
            else => .unknown,
        };
    }

    fn callRet(ctx: *anyopaque, name: []const u8) std.mem.Allocator.Error!?sema.exprtype.ScalarType {
        const self: *ExprTypeBridge = @ptrCast(@alignCast(ctx));
        // A dotted call on a record binding (`r.wide()`): the fit
        // method's declared return type.
        if (std.mem.indexOfScalar(u8, name, '.')) |dot| {
            const mname = name[dot + 1 ..];
            if (std.mem.indexOfScalar(u8, mname, '.') != null) return null;
            const si = self.scope.recs.get(name[0..dot]) orelse return null;
            const m = findFitMethod(self.b, si.name, mname) orelse return null;
            const rt = m.returnType() orelse return null;
            const rs = (try semaScalar(self.b, rt.type_())) orelse return null;
            return switch (rs) {
                .bool => .bool,
                .i64 => .i64,
                .str => .str,
                else => null,
            };
        }
        const fd = self.b.resolver.lookup(name) orelse return null;
        const rs = (try fnRetScalar(self.b, fd)) orelse return null;
        return switch (rs) {
            .bool => .bool,
            .i64 => .i64,
            .str => .str,
            else => null,
        };
    }
};

/// Name → local-index resolution for a function body. Append-only with a
/// backward scan (latest declaration wins), mirroring the legacy IntScope:
/// parameters first, then in-body `let`/`var` in declaration order. `ty`
/// distinguishes an i64 local (a callee i64 parameter / `let`, or one of
/// main's i64 bindings) from a `str` local (a callee str parameter).
const Local = struct { name: []const u8, idx: u32, mutable: bool, ty: hir.Type = .i64 };
const Scope = struct {
    a: std.mem.Allocator,
    locals: std.ArrayList(Local) = .empty,
    next_idx: u32 = 0,
    n_params: u32 = 0,
    /// Materialized record bindings/params: name → the struct it holds. The
    /// binding's `.ptr` local lives in `locals` under the same name; field
    /// access resolves through `findRecField`. (SROA'd record bindings are
    /// NOT here — their fields are plain dotted-name locals.)
    recs: std.StringHashMapUnmanaged(*const StructInfo) = .empty,

    fn find(self: *const Scope, name: []const u8) ?Local {
        var i = self.locals.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.locals.items[i].name, name)) return self.locals.items[i];
        }
        return null;
    }
    fn declare(self: *Scope, name: []const u8, mutable: bool, ty: hir.Type) BuildError!u32 {
        const idx = self.next_idx;
        try self.locals.append(self.a, .{ .name = name, .idx = idx, .mutable = mutable, .ty = ty });
        self.next_idx += 1;
        return idx;
    }
    fn extra(self: *const Scope) u32 {
        return self.next_idx - self.n_params;
    }
};

fn buildIntBlock(b: *Builder, block: ast.Block, scope: *Scope) BuildError!*hir.Stmt {
    var items: std.ArrayList(*hir.Stmt) = .empty;
    var it = block.statements();
    while (it.next()) |stmt| try items.append(b.a, try buildIntStmt(b, stmt, scope));
    const out = try b.a.create(hir.Stmt);
    out.* = .{ .block = try items.toOwnedSlice(b.a) };
    return out;
}

fn buildIntStmt(b: *Builder, stmt: ast.Stmt, scope: *Scope) BuildError!*hir.Stmt {
    const out = try b.a.create(hir.Stmt);
    switch (stmt) {
        .expr_stmt => |es| out.* = .{ .expr = try buildIntExpr(b, es.expression() orelse return error.Unsupported, scope) },
        .return_stmt => |rs| {
            const v: ?*hir.Expr = if (rs.value()) |e| try buildIntExpr(b, e, scope) else null;
            out.* = .{ .ret = v };
        },
        .let_stmt => |ls| {
            const init_expr = ls.initializer() orelse return error.Unsupported;
            const nm = (ls.pattern() orelse return error.Unsupported).bindingName() orelse return error.Unsupported;
            // A `bool` binding (`let even = n % 2 == 0`) gets a bool local; any
            // other value expression is i64. (str lets in a value body aren't
            // reached here — those functions take the str path.)
            const ty: hir.Type = if (try exprIsBool(b, init_expr, scope)) .bool else .i64;
            // Build the initializer before declaring, so it can't see itself.
            const value = try buildIntExpr(b, init_expr, scope);
            const idx = try scope.declare(nm.text, ls.isVar(), ty);
            out.* = .{ .let = .{ .idx = idx, .value = value } };
        },
        .assign_stmt => |as| {
            const tgt = as.target() orelse return error.Unsupported;
            const tpath = switch (tgt) {
                .path => |p| p,
                else => return error.Unsupported,
            };
            const tname = try tpath.text(b.a);
            defer b.a.free(tname);
            const loc = scope.find(tname) orelse return error.Unsupported;
            if (!loc.mutable) return reject(b, .immutable_assign); // a `let` binding or a parameter
            const rhs_ast = as.value() orelse return error.Unsupported;
            const op = as.op() orelse return error.Unsupported;
            // A bool is not an int: the two don't interconvert. A plain `=` must
            // assign a value of the binding's type; compound ops (`+=` …) are
            // arithmetic and only apply to an i64 binding.
            const rhs_is_bool = try exprIsBool(b, rhs_ast, scope);
            if (op.kind == .EQ) {
                if ((loc.ty == .bool) != rhs_is_bool) return error.Unsupported;
            } else if (loc.ty != .i64) {
                return error.Unsupported; // `bool += …` and the like are not arithmetic
            }
            const rhs = try buildIntExpr(b, rhs_ast, scope);
            const value = if (op.kind == .EQ) rhs else blk: {
                const k = compoundOp(op) orelse return error.Unsupported;
                const lhs = try b.a.create(hir.Expr);
                lhs.* = .{ .local = .{ .idx = loc.idx, .ty = loc.ty } };
                const bx = try b.a.create(hir.Expr);
                bx.* = .{ .bin = .{ .kind = k, .lhs = lhs, .rhs = rhs } };
                break :blk bx;
            };
            out.* = .{ .assign = .{ .idx = loc.idx, .value = value } };
        },
        .if_stmt => |is| return buildIfStmtNode(b, is, scope),
        .while_stmt => |ws| {
            const cond = try buildIntExpr(b, ws.condition() orelse return error.Unsupported, scope);
            const body = try buildIntBlock(b, ws.body() orelse return error.Unsupported, scope);
            out.* = .{ .while_ = .{ .cond = cond, .body = body } };
        },
        .loop_stmt => |lp| out.* = .{ .loop_ = try buildIntBlock(b, lp.body() orelse return error.Unsupported, scope) },
        .break_stmt => |bs| {
            if (bs.value() != null) return error.Unsupported; // value-break not supported
            out.* = .brk;
        },
        .continue_stmt => out.* = .cont,
        else => return error.Unsupported,
    }
    return out;
}

/// Build an `if`/`else(-if)` HIR node. An `else if` becomes an else block
/// holding a single nested `if_`, so lowering treats the chain uniformly.
fn buildIfStmtNode(b: *Builder, is: ast.IfStmt, scope: *Scope) BuildError!*hir.Stmt {
    const cond = try buildIntExpr(b, is.condition() orelse return error.Unsupported, scope);
    const then_ = try buildIntBlock(b, is.thenBody() orelse return error.Unsupported, scope);
    const else_: ?*hir.Stmt = if (is.elseIf()) |eif| blk: {
        const inner = try buildIfStmtNode(b, eif, scope);
        const wrap = try b.a.create(hir.Stmt);
        wrap.* = .{ .block = try b.a.dupe(*hir.Stmt, &.{inner}) };
        break :blk wrap;
    } else if (is.elseBody()) |eb|
        try buildIntBlock(b, eb, scope)
    else
        null;
    const out = try b.a.create(hir.Stmt);
    out.* = .{ .if_ = .{ .cond = cond, .then_ = then_, .else_ = else_ } };
    return out;
}

fn buildIntExpr(b: *Builder, expr: ast.Expr, scope: *Scope) BuildError!*hir.Expr {
    const out = try b.a.create(hir.Expr);
    switch (expr) {
        .num_lit => |n| out.* = .{ .int_const = consteval.parseIntLit(n.rawText() orelse return error.Unsupported) catch return error.Unsupported },
        .literal => |lit| {
            // `true` / `false`. `none` (optionals) isn't represented yet.
            const tok = lit.token() orelse return error.Unsupported;
            out.* = switch (tok.kind) {
                .KW_TRUE => .{ .bool_const = true },
                .KW_FALSE => .{ .bool_const = false },
                else => return error.Unsupported,
            };
        },
        .paren => |p| return buildIntExpr(b, p.inner() orelse return error.Unsupported, scope),
        .path => |p| {
            const txt = try p.text(b.a);
            defer b.a.free(txt);
            // `s.len` parses as the dotted path "s.len" (like `qview.set_attr`),
            // not a FieldExpr. If the prefix names a `str` local, it's the i64
            // byte-length read. (`loc.idx` is the ptr slot, `+1` the len slot.)
            if (std.mem.lastIndexOfScalar(u8, txt, '.')) |dot| {
                if (std.mem.eql(u8, txt[dot + 1 ..], "len")) {
                    if (scope.find(txt[0..dot])) |loc| {
                        if (loc.ty == .str) {
                            const sval = try b.a.create(hir.Expr);
                            sval.* = .{ .str_binding = .{ .ptr_idx = loc.idx, .len_idx = loc.idx + 1 } };
                            out.* = .{ .str_len = sval };
                            return out;
                        }
                    }
                }
            }
            if (scope.find(txt)) |loc| {
                // i64 and bool (i32 0/1) locals are readable here; a `str`
                // local belongs in the str path — and a bare record binding
                // (`.ptr`) is a whole-value use, not an i64/bool expression.
                if (loc.ty != .i64 and loc.ty != .bool) return error.Unsupported;
                out.* = .{ .local = .{ .idx = loc.idx, .ty = loc.ty } };
            } else if (try findRecField(scope, txt)) |rf| {
                // `p.x` on a materialized record: a load at (base ptr, offset).
                return recFieldExpr(b, rf);
            } else if (b.globals.get(txt)) |gi| {
                out.* = .{ .global_get = gi };       // module-level `state`
            } else if (b.eval.evalInt(expr)) |v| {
                // A compile-time `let` binding (`let n = 7`) used in a runtime
                // expression (e.g. an `if`/`while` condition) materializes as
                // its constant value.
                out.* = .{ .int_const = v };
            } else |_| return error.Unsupported;
        },
        .unary => |u| {
            const kind = unKind(u.op() orelse return error.Unsupported) orelse return error.Unsupported;
            out.* = .{ .un = .{ .kind = kind, .operand = try buildIntExpr(b, u.operand() orelse return error.Unsupported, scope) } };
        },
        .bin => |bx| {
            const op_tok = bx.op() orelse return error.Unsupported;
            // String equality: `==`/`!=` on str values compares bytes. Detected
            // by the LHS building as a str; if it doesn't, fall to the numeric
            // path. `!=` is `==` wrapped in a logical not.
            if (binKind(op_tok)) |bk| if (bk == .eq or bk == .ne) {
                if (buildStrExpr(b, bx.lhs() orelse return error.Unsupported, scope, null)) |lhs_s| {
                    const rhs_s = try buildStrExpr(b, bx.rhs() orelse return error.Unsupported, scope, null);
                    const eq = try b.a.create(hir.Expr);
                    eq.* = .{ .str_eq = .{ .lhs = lhs_s, .rhs = rhs_s } };
                    if (bk == .ne) {
                        out.* = .{ .un = .{ .kind = .not, .operand = eq } };
                        return out;
                    }
                    return eq;
                } else |e| switch (e) {
                    error.Unsupported => {}, // LHS isn't a str — numeric compare
                    else => return e,
                }
            };
            const lhs = try buildIntExpr(b, bx.lhs() orelse return error.Unsupported, scope);
            const rhs = try buildIntExpr(b, bx.rhs() orelse return error.Unsupported, scope);
            if (logicalKind(op_tok)) |lk| {
                // `&&` / `||` short-circuit, so they're control flow, not a
                // binary value op (see `lowerExpr`'s `.logical` → `if_`).
                out.* = .{ .logical = .{ .op = lk, .lhs = lhs, .rhs = rhs } };
            } else {
                const kind = binKind(op_tok) orelse return error.Unsupported;
                out.* = .{ .bin = .{ .kind = kind, .lhs = lhs, .rhs = rhs } };
            }
        },
        .call => |cc| {
            const callee = cc.callee() orelse return error.Unsupported;
            const cpath = switch (callee) {
                .path => |p| p,
                else => return error.Unsupported,
            };
            const cname = try cpath.text(b.a);
            defer b.a.free(cname);
            // B4 static dispatch: `r.area()` — a dotted call whose head is a
            // materialized record binding/param resolves through the fit
            // registry to a direct call, the receiver passed as the record's
            // base pointer (no vtable, no monomorphization). `self.other()`
            // inside a fit method resolves the same way (`self` is in recs).
            if (std.mem.indexOfScalar(u8, cname, '.')) |dot| {
                const head = cname[0..dot];
                const mname = cname[dot + 1 ..];
                if (std.mem.indexOfScalar(u8, mname, '.') == null) {
                    if (scope.recs.get(head)) |si| {
                        const loc = scope.find(head) orelse return error.Unsupported;
                        const fid = (try registerFitMethod(b, si, mname)) orelse
                            return reject(b, .name_not_found); // no fit declares it
                        switch (b.funcs.items[fid].ret) {
                            .i64, .bool => {},
                            else => return reject(b, .unsupported_call),
                        }
                        const recv = try b.a.create(hir.Expr);
                        recv.* = .{ .local = .{ .idx = loc.idx, .ty = .ptr } };
                        out.* = .{ .call = .{ .func = fid, .args = try buildCallArgs(b, fid, cc, scope, recv) } };
                        return out;
                    }
                }
            }
            // i64/bool str methods parse as dotted calls: `<str>.index_of(byte)`
            // -> i64, `<str>.starts_with(p)` / `<str>.contains(sub)` -> bool.
            if (std.mem.lastIndexOfScalar(u8, cname, '.')) |dot| {
                const method = cname[dot + 1 ..];
                const is_method = std.mem.eql(u8, method, "index_of") or std.mem.eql(u8, method, "starts_with") or std.mem.eql(u8, method, "contains");
                if (is_method) {
                    if (try strReceiver(b, cname[0..dot], scope, null)) |sval| {
                        var mit = cc.args();
                        const a0 = mit.next() orelse return error.Unsupported;
                        if (std.mem.eql(u8, method, "index_of")) {
                            out.* = .{ .str_index_of = .{ .str = sval, .byte = try buildIntExpr(b, a0, scope) } };
                        } else if (std.mem.eql(u8, method, "starts_with")) {
                            out.* = .{ .str_starts_with = .{ .str = sval, .prefix = try buildStrExpr(b, a0, scope, null) } };
                        } else {
                            out.* = .{ .str_contains = .{ .str = sval, .sub = try buildStrExpr(b, a0, scope, null) } };
                        }
                        return out;
                    }
                }
            }
            const id = try registerFunc(b, cname);
            // An i64 or bool (i32 0/1) callee produces a value usable here; a
            // str or record callee does not belong in an i64/bool expression.
            switch (b.funcs.items[id].ret) {
                .i64, .bool => {},
                else => return reject(b, .unsupported_call),
            }
            out.* = .{ .call = .{ .func = id, .args = try buildCallArgs(b, id, cc, scope, null) } };
        },
        .field => |fe| {
            // `s.len` — the byte length of a str value, as i64. (The only field
            // access supported today; structs aren't represented in this path.)
            const fld = (fe.field() orelse return error.Unsupported).text;
            if (!std.mem.eql(u8, fld, "len")) return error.Unsupported;
            const base = fe.base() orelse return error.Unsupported;
            const sval = buildStrExpr(b, base, scope, null) catch |e| switch (e) {
                error.Unsupported => return error.Unsupported, // `.len` on a non-str
                else => return e,
            };
            out.* = .{ .str_len = sval };
        },
        .index => |ix| {
            // `s[i]` — the unsigned byte at index i of a str value, as i64.
            const base = ix.base() orelse return error.Unsupported;
            const sval = buildStrExpr(b, base, scope, null) catch |e| switch (e) {
                error.Unsupported => return error.Unsupported, // indexing a non-str
                else => return e,
            };
            const idx = try buildIntExpr(b, ix.index() orelse return error.Unsupported, scope);
            out.* = .{ .str_index = .{ .str = sval, .idx = idx } };
        },
        .method => |me| {
            // i64/bool str methods: `index_of(byte)` -> i64, `starts_with(p)` /
            // `contains(sub)` -> bool. (`slice` is str-valued — see buildStrExpr.)
            const mname = (me.method() orelse return error.Unsupported).text;
            const sval = buildStrExpr(b, me.receiver() orelse return error.Unsupported, scope, null) catch |e| switch (e) {
                error.Unsupported => return error.Unsupported, // method on a non-str
                else => return e,
            };
            var ait = me.args();
            const a0 = ait.next() orelse return error.Unsupported;
            if (std.mem.eql(u8, mname, "index_of")) {
                out.* = .{ .str_index_of = .{ .str = sval, .byte = try buildIntExpr(b, a0, scope) } };
            } else if (std.mem.eql(u8, mname, "starts_with")) {
                out.* = .{ .str_starts_with = .{ .str = sval, .prefix = try buildStrExpr(b, a0, scope, null) } };
            } else if (std.mem.eql(u8, mname, "contains")) {
                out.* = .{ .str_contains = .{ .str = sval, .sub = try buildStrExpr(b, a0, scope, null) } };
            } else return error.Unsupported;
        },
        else => return error.Unsupported,
    }
    return out;
}

fn compoundOp(tok: parser.cst.Token) ?ops.BinKind {
    return switch (tok.kind) {
        .PLUS_EQ => .add,
        .MINUS_EQ => .sub,
        .STAR_EQ => .mul,
        .SLASH_EQ => .div,
        .PERCENT_EQ => .rem,
        else => null,
    };
}

fn binKind(tok: parser.cst.Token) ?ops.BinKind {
    return switch (tok.kind) {
        .PLUS => .add,
        .MINUS => .sub,
        .STAR => .mul,
        .SLASH => .div,
        .PERCENT => .rem,
        .AMP => .bit_and,
        .PIPE => .bit_or,
        .CARET => .bit_xor,
        .SHL => .shl,
        .SHR => .shr,
        .EQ_EQ => .eq,
        .BANG_EQ => .ne,
        .L_ANGLE => .lt,
        .LT_EQ => .le,
        .R_ANGLE => .gt,
        .GT_EQ => .ge,
        else => null,
    };
}

fn logicalKind(tok: parser.cst.Token) ?ops.LogicalKind {
    return switch (tok.kind) {
        .AMP_AMP => .and_,
        .PIPE_PIPE => .or_,
        else => null,
    };
}

fn unKind(tok: parser.cst.Token) ?ops.UnKind {
    return switch (tok.kind) {
        .MINUS => .neg,
        .TILDE => .bit_not,
        .BANG => .not,
        else => null,
    };
}

fn findMain(sf: ast.SourceFile) ?ast.FnDecl {
    var it = sf.items();
    while (it.next()) |item| switch (item) {
        .fn_decl => |fd| {
            const name = fd.name() orelse continue;
            if (std.mem.eql(u8, name.text, "main")) return fd;
        },
        else => {},
    };
    return null;
}

/// If `call`'s callee is a host face we drive directly (today: `qview.<fn>`),
/// return its dotted name (arena-owned). Such a call lowers to a wasm import
/// call with i64 args and no result. Otherwise null.
fn hostFaceName(b: *Builder, call: ast.CallExpr) BuildError!?[]const u8 {
    const callee = call.callee() orelse return null;
    const path = switch (callee) {
        .path => |p| p,
        else => return null,
    };
    const txt = try path.text(b.a);
    if (std.mem.startsWith(u8, txt, "qview.")) return txt; // arena-owned; kept
    b.a.free(txt);
    return null;
}

fn isEnvOut(a: std.mem.Allocator, call: ast.CallExpr) bool {
    const callee = call.callee() orelse return false;
    const path = switch (callee) {
        .path => |p| p,
        else => return false,
    };
    const txt = path.text(a) catch return false;
    defer a.free(txt);
    return std.mem.eql(u8, txt, "env.out");
}

fn firstArg(call: ast.CallExpr) ?ast.Expr {
    var args = call.args();
    return args.next();
}

// ---------------------------------------------------------------------
// Tests (pure Zig — no Binaryen). Run via the `ir_tests` target.
// ---------------------------------------------------------------------
const testing = std.testing;
const print = @import("print.zig");

/// A test ModuleResolver over a set of (name, source) library functions: it
/// parses each source once and looks up a `pub fn <name>` by scanning items.
const TestResolver = struct {
    a: std.mem.Allocator,
    results: std.ArrayList(parser.parse.Result) = .empty,

    fn deinit(self: *TestResolver) void {
        for (self.results.items) |r| r.deinit(self.a);
        self.results.deinit(self.a);
    }

    fn addLib(self: *TestResolver, src: []const u8) !void {
        try self.results.append(self.a, try parser.parse.parse(self.a, src, "<lib>"));
    }

    fn lookup(ctx: *anyopaque, name: []const u8) ?ast.FnDecl {
        const self: *TestResolver = @ptrCast(@alignCast(ctx));
        for (self.results.items) |r| {
            const sf = ast.SourceFile.cast(r.root) orelse continue;
            var it = sf.items();
            while (it.next()) |item| switch (item) {
                .fn_decl => |fd| {
                    const nm = fd.name() orelse continue;
                    if (std.mem.eql(u8, nm.text, name)) return fd;
                },
                else => {},
            };
        }
        return null;
    }

    fn resolver(self: *TestResolver) ModuleResolver {
        return .{ .ctx = self, .lookupFn = TestResolver.lookup };
    }
};

fn buildFromSource(gpa: std.mem.Allocator, source: []const u8, res: ModuleResolver) !?hir.Module {
    const pr = try parser.parse.parse(gpa, source, "<test>");
    defer pr.deinit(gpa);
    const sf = ast.SourceFile.cast(pr.root) orelse return null;
    return switch (try tryBuild(gpa, sf, res)) {
        .module => |m| m,
        else => null,
    };
}

/// Build and return the reject reason, or null if the source built / was
/// merely unsupported. For tests that assert a specific honest-baseline error.
fn rejectFromSource(gpa: std.mem.Allocator, source: []const u8, res: ModuleResolver) !?hir.Reject {
    const pr = try parser.parse.parse(gpa, source, "<test>");
    defer pr.deinit(gpa);
    const sf = ast.SourceFile.cast(pr.root) orelse return null;
    var r = try tryBuild(gpa, sf, res);
    switch (r) {
        .module => |*m| {
            m.deinit();
            return null;
        },
        .unsupported => return null,
        .rejected => |reason| return reason,
    }
}

const noLib: ModuleResolver = .{ .ctx = undefined, .lookupFn = struct {
    fn f(_: *anyopaque, _: []const u8) ?ast.FnDecl {
        return null;
    }
}.f };

test "tryBuild: a main of env.out string literals builds HIR" {
    var mod = (try buildFromSource(testing.allocator, "fn main {\n env.out(\"one\")\n}\n", noLib)) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "host_out \"one\"") != null);
}

test "tryBuild: runtime interpolation of an unbound name is unsupported (null)" {
    // `x` is neither a const binding nor a runtime binding here, so the
    // interpolation isn't representable → `.unsupported` (codegen reports
    // UnsupportedExpression). buildFromSource maps non-module results to null.
    try testing.expect((try buildFromSource(testing.allocator, "fn main {\n env.out(\"v{x}\")\n}\n", noLib)) == null);
}

test "tryBuild: const interpolation + const let bindings fold to host_out" {
    var mod = (try buildFromSource(testing.allocator, "fn main {\n let n = 6 * 7\n env.out(\"{(1 + 2) * 3} {n + 1}\")\n}\n", noLib)) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // The whole interpolation folds to one constant string at compile time.
    try testing.expect(std.mem.indexOf(u8, dump, "host_out \"9 43\"") != null);
}

test "tryBuild: a main-less twin exports its public handler (visibility slot)" {
    // No `fn main`; a `state` global + a `pub fn` command (a backend twin).
    // The HIR carries the handler's visibility, which `show hir` surfaces and
    // the (future) component/WIT lift reads as the export surface.
    var mod = (try buildFromSource(testing.allocator, "state count = 0\npub fn inc() { count = count + 1 }\n", noLib)) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    try testing.expect(mod.entry == null); // main-less
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "pub fn inc -> void") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "global_set #0") != null);
}

test "tryBuild: a const-bodied call folds in a let, not in env.out" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    try tr.addLib("pub fn version() -> str { \"0.1.0\" }\n");

    // In a `let` it folds; the binding is a compile-time constant.
    var mod = (try buildFromSource(testing.allocator, "fn main {\n let v = version()\n env.out(v)\n}\n", tr.resolver())) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    try testing.expectEqual(@as(usize, 1), mod.funcs.len); // just main; version folded away
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "host_out \"0.1.0\"") != null);

    // Directly, `env.out(version())` is a real (non-folded) call: version is
    // emitted as a str function and its result is written at runtime.
    var direct = (try buildFromSource(testing.allocator, "fn main {\n env.out(version())\n}\n", tr.resolver())) orelse
        return error.TestUnexpectedResult;
    defer direct.deinit();
    try testing.expectEqual(@as(usize, 2), direct.funcs.len); // main + version
    const d = try print.hirToString(testing.allocator, &direct);
    defer testing.allocator.free(d);
    try testing.expect(std.mem.indexOf(u8, d, "host_out_str") != null);
    try testing.expect(std.mem.indexOf(u8, d, "fn version -> str") != null);
}

test "tryBuild: an i64 function call builds the callee + host_out_int" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    try tr.addLib("pub fn double(n: i64) -> i64 { n + n }\n");

    var mod = (try buildFromSource(testing.allocator, "fn main {\n env.out(double(21))\n}\n", tr.resolver())) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();

    try testing.expectEqual(@as(usize, 2), mod.funcs.len); // main + double
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "host_out_int") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "fn double -> i64") != null);
}

test "tryBuild: transitively-called i64 function is registered" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    try tr.addLib("pub fn square(n: i64) -> i64 { n * n }\npub fn hyp_sq(a: i64, b: i64) -> i64 { square(a) + square(b) }\n");

    var mod = (try buildFromSource(testing.allocator, "fn main {\n env.out(hyp_sq(3, 4))\n}\n", tr.resolver())) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    try testing.expectEqual(@as(usize, 3), mod.funcs.len); // main + hyp_sq + square
}

test "tryBuild: a str passthrough function + str-literal arg builds HIR" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    try tr.addLib("pub fn id(s: str) -> str { s }\n");

    var mod = (try buildFromSource(testing.allocator, "fn main {\n env.out(id(\"passed\"))\n}\n", tr.resolver())) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    try testing.expectEqual(@as(usize, 2), mod.funcs.len); // main + id
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "host_out_str") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "fn id -> str") != null);
    // The passthrough param ref resolves to an explicit str_binding at its two
    // wasm slots (ptr=0, len=1) — the uniform str-value form (no str_param idx*2).
    try testing.expect(std.mem.indexOf(u8, dump, "str_binding[0,1]") != null);
}

test "tryBuild: interpolation with a call builds a concat" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    try tr.addLib("pub fn version() -> str { \"0.1.0\" }\n");

    var mod = (try buildFromSource(testing.allocator, "fn main {\n env.out(\"v{version()} ok\")\n}\n", tr.resolver())) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // A concat of: const "v", the version() call, const " ok".
    try testing.expect(std.mem.indexOf(u8, dump, "concat[") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "call#") != null);
}

test "tryBuild: a concat-bodied str function (interpolated param) builds" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    try tr.addLib("pub fn shout(s: str) -> str { \"{s}!\" }\n");

    var mod = (try buildFromSource(testing.allocator, "fn main {\n env.out(shout(\"loud\"))\n}\n", tr.resolver())) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // shout's body is a concat of its parameter and the literal "!".
    try testing.expect(std.mem.indexOf(u8, dump, "fn shout -> str") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "concat[local#0") != null);
}

test "tryBuild: a runtime str binding + use in interpolation + arg" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    try tr.addLib("pub fn shout(s: str) -> str { \"{s}!\" }\npub fn wrap(s: str) -> str { \"[{s}]\" }\n");

    var mod = (try buildFromSource(testing.allocator, "fn main {\n let g = shout(\"hi\")\n env.out(g)\n env.out(\"{g}\")\n env.out(wrap(g))\n}\n", tr.resolver())) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    // main now has two i64 locals backing g's (ptr, len).
    try testing.expectEqual(@as(usize, 2), mod.funcs[mod.entry.?].locals.len);
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "str_let [0,1]") != null); // g binds into locals 0,1
    try testing.expect(std.mem.indexOf(u8, dump, "str_binding[0,1]") != null); // referenced by index
}

test "tryBuild: a runtime i64 binding + reuse as arg + interpolation builds HIR" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    try tr.addLib("pub fn double(n: i64) -> i64 { n + n }\npub fn add(a: i64, b: i64) -> i64 { a + b }\n");

    var mod = (try buildFromSource(testing.allocator,
        "fn main {\n let a = double(21)\n env.out(add(a, 8))\n let b = add(a, 8)\n env.out(\"a={a}, b={b}\")\n}\n",
        tr.resolver())) orelse return error.TestUnexpectedResult;
    defer mod.deinit();
    // Two i64 binding locals back a and b.
    try testing.expectEqual(@as(usize, 2), mod.funcs[mod.entry.?].locals.len);
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // `let local#0 = call(double, [21])`, then the int call references it.
    try testing.expect(std.mem.indexOf(u8, dump, "let local#0 = call#") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "host_out_int call#") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "let local#1 = call#") != null);
    // Interpolation: each i64 binding becomes an `fmt_int(local#N)` concat piece.
    try testing.expect(std.mem.indexOf(u8, dump, "fmt_int(local#0)") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "fmt_int(local#1)") != null);
}

test "tryBuild: a str binding and i64 binding share main's local space" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    try tr.addLib("pub fn shout(s: str) -> str { \"{s}!\" }\npub fn double(n: i64) -> i64 { n + n }\n");

    // g claims locals 0,1 (str binding = ptr,len); a then claims local 2.
    var mod = (try buildFromSource(testing.allocator,
        "fn main {\n let g = shout(\"hi\")\n let a = double(21)\n env.out(\"{g}/{a}\")\n}\n",
        tr.resolver())) orelse return error.TestUnexpectedResult;
    defer mod.deinit();
    try testing.expectEqual(@as(usize, 3), mod.funcs[mod.entry.?].locals.len);
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "str_let [0,1]") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "let local#2 = call#") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "str_binding[0,1]") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "fmt_int(local#2)") != null);
}

test "tryBuild: a recursive control-flow body builds HIR" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    try tr.addLib("pub fn fact(n: i64) -> i64 { if n <= 1 { 1 } else { n * fact(n - 1) } }\n");

    var mod = (try buildFromSource(testing.allocator, "fn main {\n env.out(fact(5))\n}\n", tr.resolver())) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    try testing.expectEqual(@as(usize, 2), mod.funcs.len); // main + fact
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "if ") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "call#1") != null); // recursive call to fact
}

test "tryBuild: logical not in a condition builds a (not ...) over the comparison" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    // `if !(n == 0)` — the `!is_even(n)` shape, grounded on a comparison so it
    // stays inside the i64 expression subset.
    try tr.addLib("pub fn nonzero(n: i64) -> i64 { if !(n == 0) { 1 } else { 0 } }\n");

    var mod = (try buildFromSource(testing.allocator, "fn main {\n env.out(nonzero(7))\n}\n", tr.resolver())) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "(not ") != null); // the `!` node
    try testing.expect(std.mem.indexOf(u8, dump, "eq") != null); // wrapping the comparison
}

test "tryBuild: `&&` / `||` build short-circuit logical nodes (not bin ops)" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    try tr.addLib("pub fn both(a: i64, b: i64) -> i64 { if a > 0 && b > 0 { 1 } else { 0 } }\n");
    try tr.addLib("pub fn either(a: i64, b: i64) -> i64 { if a > 0 || b > 0 { 1 } else { 0 } }\n");

    var mod = (try buildFromSource(testing.allocator,
        "fn main {\n env.out(both(1, 1))\n env.out(either(0, 1))\n}\n", tr.resolver())) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "and_") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "or_") != null);
}

test "tryBuild: `true` / `false` literals build bool_const nodes" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    try tr.addLib("pub fn pick(n: i64) -> i64 { if true { n } else { 0 } }\n");
    try tr.addLib("pub fn nope(n: i64) -> i64 { if n > 0 && false { 1 } else { 0 } }\n");

    var mod = (try buildFromSource(testing.allocator,
        "fn main {\n env.out(pick(7))\n env.out(nope(7))\n}\n", tr.resolver())) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "if true") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "false") != null);
}

test "tryBuild: a `-> bool` function + env.out routes to host_out_bool" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    try tr.addLib("pub fn is_even(n: i64) -> bool { n % 2 == 0 }\n");

    var mod = (try buildFromSource(testing.allocator,
        "fn main {\n env.out(is_even(4))\n}\n", tr.resolver())) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "fn is_even -> bool") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "host_out_bool") != null);
}

test "tryBuild: env.out of a bare comparison / literal is a bool, not an int" {
    var mod = (try buildFromSource(testing.allocator,
        "fn main {\n env.out(3 > 5)\n env.out(true)\n}\n", noLib)) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // Both env.out args are booleans → host_out_bool, never host_out_int.
    try testing.expect(std.mem.indexOf(u8, dump, "host_out_bool") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "host_out_int") == null);
}

test "tryBuild: a bool `let` binding is read back as a bool (host_out_bool)" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    // A bool local in a function body: declared from a comparison, reassigned
    // with `!`, and returned — all in the bool (i32) lane.
    try tr.addLib("pub fn check(n: i64) -> bool { var even = n % 2 == 0\n even = !even\n even }\n");

    var mod = (try buildFromSource(testing.allocator,
        "fn main {\n let flag = 5 > 2\n env.out(flag)\n env.out(check(4))\n}\n", tr.resolver())) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "fn check -> bool") != null);
    // `env.out(flag)` where flag is a bool binding → the bool path.
    try testing.expect(std.mem.indexOf(u8, dump, "host_out_bool") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "host_out_int") == null);
}

test "tryBuild: a bool is not an int — assigning an int to a bool is rejected" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    // `x` is a bool; `x = 5` mixes the types and must not build.
    try tr.addLib("pub fn bad() -> i64 { var x = 1 == 1\n x = 5\n 0 }\n");

    const mod = try buildFromSource(testing.allocator,
        "fn main {\n env.out(bad())\n}\n", tr.resolver());
    try testing.expect(mod == null); // unsupported: no int↔bool coercion
}

test "tryBuild: a bool parameter is accepted; an int arg to it is rejected" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    try tr.addLib("pub fn pick(b: bool, n: i64) -> i64 { if b { n } else { 0 } }\n");

    var ok = (try buildFromSource(testing.allocator,
        "fn main {\n env.out(pick(true, 42))\n}\n", tr.resolver())) orelse
        return error.TestUnexpectedResult;
    ok.deinit();

    // `pick(5, 42)` passes an int where a bool param is expected → rejected.
    const bad = try buildFromSource(testing.allocator,
        "fn main {\n env.out(pick(5, 42))\n}\n", tr.resolver());
    if (bad) |*m| {
        var mm = m.*;
        mm.deinit();
        return error.TestUnexpectedResult; // should not have built
    }
}

test "tryBuild: main supports reassignment + while + if (with host bodies)" {
    var mod = (try buildFromSource(testing.allocator,
        "fn main {\n var i = 0\n while i < 3 { env.out(i)\n i = i + 1 }\n if i == 3 { env.out(\"done\") }\n}\n", noLib)) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "while") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "assign") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "if ") != null);
    // env.out inside the loop body is a real host write, not folded away.
    try testing.expect(std.mem.indexOf(u8, dump, "host_out_int") != null);
}

test "tryBuild: a `var` with a constant initializer stays a runtime local" {
    // `var` is mutable, so it must NOT const-fold (unlike an immutable `let`).
    var mod = (try buildFromSource(testing.allocator,
        "fn main {\n var n = 0\n n = n + 1\n env.out(n)\n}\n", noLib)) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "let") != null); // a real local, not folded
    try testing.expect(std.mem.indexOf(u8, dump, "assign") != null);
}

test "effects: main's env.out infers @stdout (+ @io)" {
    var mod = (try buildFromSource(testing.allocator, "fn main {\n env.out(\"hi\")\n}\n", noLib)) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // The header line carries the inferred set; @stdout implies @io.
    try testing.expect(std.mem.indexOf(u8, dump, "@stdout + @io") != null);
}

test "effects: a qview host call infers @ui (a peer, no @io)" {
    var mod = (try buildFromSource(testing.allocator, "fn main {\n qview.text(0, 0, 0)\n}\n", noLib)) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "@ui") != null);
    // @ui is a peer surface — it must NOT pull in @io.
    try testing.expect(std.mem.indexOf(u8, dump, "@io") == null);
}

test "effects: a pure i64 helper carries no capability" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    try tr.addLib("pub fn double(n: i64) -> i64 { n + n }\n");
    var mod = (try buildFromSource(testing.allocator,
        "import dev.q64.m.{double}\nfn main {\n env.out(double(21))\n}\n", tr.resolver())) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // `double` does no I/O — its header has no effect markers.
    try testing.expect(std.mem.indexOf(u8, dump, "fn double -> i64\n") != null);
    // main still writes stdout.
    try testing.expect(std.mem.indexOf(u8, dump, "@stdout") != null);
}

// The surface pass resolves a file-local `pub fn` by name; production indexes
// the compiled file's own functions (`Resolver.indexLocalFunctions`). The test
// resolver simulates that by also registering the source as a lookup source.
fn buildLocal(gpa: std.mem.Allocator, tr: *TestResolver, source: []const u8) !?hir.Module {
    try tr.addLib(source);
    return buildFromSource(gpa, source, tr.resolver());
}

test "B2: record-literal binding lowers to per-field scalar locals (SROA)" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src =
        \\struct Point { x: i64, y: i64 }
        \\
        \\fn main {
        \\    let p = Point { x: 40 + 2, y: 8 }
        \\    var q = Point { x: 1, y: p.y }
        \\    q.x = q.x + p.x
        \\    env.out(q.x)
        \\    env.out("p = ({p.x}, {p.y})")
        \\}
        \\
    ;
    var mod = (try buildLocal(testing.allocator, &tr, src)) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // Four field locals + the q.x reassign; reads resolve as plain locals.
    try testing.expect(std.mem.indexOf(u8, dump, "host_out_int") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "host_out_str") != null);
}

test "surface: an unreached pub fn is built and exported (public)" {
    // `greet` is never called by main, but as a `pub fn` it is part of the
    // qube's export surface — it must still be built and marked public.
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    var mod = (try buildLocal(testing.allocator, &tr,
        "pub fn greet(name: str) -> str { \"hi {name}\" }\nfn main {\n env.out(\"hello\")\n}\n")) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "pub fn greet -> str") != null);
}

test "surface: a reached local pub fn is upgraded to a public export" {
    // `shout` is called by main (so built `.private` on demand), but it is
    // declared `pub` in this file, so the surface pass upgrades it to public.
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    var mod = (try buildLocal(testing.allocator, &tr,
        "pub fn shout(s: str) -> str { \"{s}!\" }\nfn main {\n env.out(shout(\"hi\"))\n}\n")) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "pub fn shout -> str") != null);
}

test "surface: a main-less library of pub fns builds (not NoMainFunction)" {
    // A library qube (no `fn main`) exporting only value-returning pub fns was
    // rejected as no_main before the surface pass built value exports.
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    var mod = (try buildLocal(testing.allocator, &tr,
        "pub fn version() -> str { \"0.1.0\" }\npub fn add(a: i64, b: i64) -> i64 { a + b }\n")) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    try testing.expect(mod.entry == null); // no entry — it's a library
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "pub fn version -> str") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "pub fn add -> i64") != null);
}

test "B2b: an escaping record binding materializes (record_alloc + field_get)" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src =
        \\struct Point { x: i64, y: i64 }
        \\
        \\fn dot(a: Point, b: Point) -> i64 { a.x * b.x + a.y * b.y }
        \\
        \\fn main {
        \\    let p = Point { x: 3, y: 4 }
        \\    env.out(dot(p, p))
        \\    env.out(p.x)
        \\}
        \\
    ;
    var mod = (try buildLocal(testing.allocator, &tr, src)) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // Two 8-byte fields → 16 bytes at align 8 (spec/memory.md layout rules);
    // the binding holds the base pointer, reads go through field_get.
    try testing.expect(std.mem.indexOf(u8, dump, "record_alloc size=16 align=8") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "field_get(") != null);
    // The callee body reads its record params through field_get too.
    try testing.expect(std.mem.indexOf(u8, dump, "fn dot -> i64") != null);
}

test "B2b: a non-escaping record binding still SROAs (no record_alloc)" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src =
        \\struct Point { x: i64, y: i64 }
        \\
        \\fn main {
        \\    let p = Point { x: 40 + 2, y: 8 }
        \\    env.out(p.x)
        \\}
        \\
    ;
    var mod = (try buildLocal(testing.allocator, &tr, src)) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "record_alloc") == null);
    try testing.expect(std.mem.indexOf(u8, dump, "host_out_int") != null);
}

test "B2b: a record-returning call binds the base pointer (`fn make -> ptr`)" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src =
        \\struct Point { x: i64, y: i64 }
        \\
        \\fn make(x: i64, y: i64) -> Point { Point { x: x, y: y } }
        \\
        \\fn main {
        \\    let p = make(3, 4)
        \\    env.out(p.x)
        \\}
        \\
    ;
    var mod = (try buildLocal(testing.allocator, &tr, src)) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "fn make -> ptr") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "record_alloc size=16 align=8") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "field_get(") != null);
}

test "B2b: field assignment through the base pointer is a field_set" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src =
        \\struct Point { x: i64, y: i64 }
        \\
        \\fn dot(a: Point, b: Point) -> i64 { a.x * b.x + a.y * b.y }
        \\
        \\fn main {
        \\    var c = Point { x: 2, y: 4 }
        \\    c.x = c.x + 1
        \\    env.out(dot(c, c))
        \\}
        \\
    ;
    var mod = (try buildLocal(testing.allocator, &tr, src)) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "field_set") != null);
}

test "B2b: bool fields pack at 1 byte; the next i64 pads to offset 8" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src =
        \\struct Flag { hot: bool, n: i64 }
        \\
        \\fn pick(f: Flag) -> i64 { if f.hot { f.n } else { 0 - f.n } }
        \\
        \\fn main {
        \\    let f = Flag { hot: true, n: 7 }
        \\    env.out(pick(f))
        \\}
        \\
    ;
    var mod = (try buildLocal(testing.allocator, &tr, src)) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // bool at +0 (1 byte), i64 aligned up to +8, size rounded to 16.
    try testing.expect(std.mem.indexOf(u8, dump, "record_alloc size=16 align=8") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "+8:") != null);
}

test "B2b: passing a different struct where Point is expected is UnsupportedCall" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src =
        \\struct P { x: i64 }
        \\struct Q { x: i64 }
        \\
        \\fn f(p: P) -> i64 { p.x }
        \\
        \\fn main {
        \\    let q = Q { x: 1 }
        \\    env.out(f(q))
        \\}
        \\
    ;
    try tr.addLib(src);
    const r = try rejectFromSource(testing.allocator, src, tr.resolver());
    try testing.expectEqual(hir.Reject.unsupported_call, r.?);
}

test "B2b: assigning a field of a `let` record is ImmutableAssign" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src =
        \\struct P { x: i64 }
        \\
        \\fn f(p: P) -> i64 { p.x }
        \\
        \\fn main {
        \\    let p = P { x: 1 }
        \\    p.x = 2
        \\    env.out(f(p))
        \\}
        \\
    ;
    try tr.addLib(src);
    const r = try rejectFromSource(testing.allocator, src, tr.resolver());
    try testing.expectEqual(hir.Reject.immutable_assign, r.?);
}

test "B4: r.area() dispatches through the fit registry to a direct call" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src =
        \\face Area { fn area(self) -> i64 }
        \\
        \\struct Rect { w: i64, h: i64 }
        \\
        \\fit Rect : Area {
        \\    fn area(self) -> i64 { self.w * self.h }
        \\}
        \\
        \\fn main {
        \\    let r = Rect { w: 6, h: 7 }
        \\    env.out(r.area())
        \\}
        \\
    ;
    var mod = (try buildLocal(testing.allocator, &tr, src)) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // The fit method is a plain function named Struct.method, its self a
    // record (.ptr) param; the call site passes the binding's pointer.
    try testing.expect(std.mem.indexOf(u8, dump, "fn Rect.area -> i64") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "field_get(") != null);
    // The method call forces the binding to materialize (escape).
    try testing.expect(std.mem.indexOf(u8, dump, "record_alloc size=16 align=8") != null);
}

test "B4: a method may call another fit method on self" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src =
        \\face Area { fn area(self) -> i64 }
        \\face Scalable { fn scaled(self, k: i64) -> i64 }
        \\
        \\struct Rect { w: i64, h: i64 }
        \\
        \\fit Rect : Area { fn area(self) -> i64 { self.w * self.h } }
        \\fit Rect : Scalable { fn scaled(self, k: i64) -> i64 { self.area() * k } }
        \\
        \\fn main {
        \\    let r = Rect { w: 6, h: 7 }
        \\    env.out(r.scaled(10))
        \\}
        \\
    ;
    var mod = (try buildLocal(testing.allocator, &tr, src)) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "fn Rect.scaled -> i64") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "fn Rect.area -> i64") != null);
}

test "B4: a `-> bool` fit method routes env.out to the bool path" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src =
        \\face Wide { fn wide(self) -> bool }
        \\
        \\struct Rect { w: i64, h: i64 }
        \\
        \\fit Rect : Wide { fn wide(self) -> bool { self.w > self.h } }
        \\
        \\fn main {
        \\    let r = Rect { w: 6, h: 7 }
        \\    env.out(r.wide())
        \\}
        \\
    ;
    var mod = (try buildLocal(testing.allocator, &tr, src)) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "fn Rect.wide -> bool") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "host_out_bool") != null);
}

test "B4: a method no fit declares is NameNotFound" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src =
        \\face Area { fn area(self) -> i64 }
        \\
        \\struct Rect { w: i64, h: i64 }
        \\
        \\fit Rect : Area { fn area(self) -> i64 { self.w * self.h } }
        \\
        \\fn main {
        \\    let r = Rect { w: 6, h: 7 }
        \\    env.out(r.perimeter())
        \\}
        \\
    ;
    try tr.addLib(src);
    const r = try rejectFromSource(testing.allocator, src, tr.resolver());
    try testing.expectEqual(hir.Reject.name_not_found, r.?);
}

test "B4: wrong fit-method arity is UnsupportedCall" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src =
        \\face Scalable { fn scaled(self, k: i64) -> i64 }
        \\
        \\struct Rect { w: i64 }
        \\
        \\fit Rect : Scalable { fn scaled(self, k: i64) -> i64 { self.w * k } }
        \\
        \\fn main {
        \\    let r = Rect { w: 6 }
        \\    env.out(r.scaled(2, 3))
        \\}
        \\
    ;
    try tr.addLib(src);
    const r = try rejectFromSource(testing.allocator, src, tr.resolver());
    try testing.expectEqual(hir.Reject.unsupported_call, r.?);
}
