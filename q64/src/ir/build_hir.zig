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

/// What an array's elements are: a scalar (loaded/stored at its width)
/// or an inline record (the element address IS the value — B2b's ABI).
const ElemKind = union(enum) { scalar: hir.Type, rec: *const StructInfo };

/// An array's element count: compile-time for a literal binding, a
/// runtime local for a stamped generic's `[T]` slice parameter.
const Count = union(enum) { konst: u32, local_idx: u32 };

/// An array binding/param: its base-ptr local, element count, stride,
/// and element kind.
const ArrInfo = struct { ptr_idx: u32, count: Count, stride: u32, elem: ElemKind };

/// The count as an i64 expression.
fn countExpr(b: *Builder, cnt: Count) BuildError!*hir.Expr {
    const out = try b.a.create(hir.Expr);
    out.* = switch (cnt) {
        .konst => |k| .{ .int_const = k },
        .local_idx => |i| .{ .local = .{ .idx = i, .ty = .i64 } },
    };
    return out;
}

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
    /// The locals list `buildMainStmt`-style bodies append to: `main`'s
    /// list normally, a stamped generic instance's during stamping (B5
    /// monomorphization reuses the entry-style builder for its bodies).
    cur_locals: *std.ArrayList(hir.Type) = undefined,
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
    b.cur_locals = &b.main_locals;

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
            // runtime local even when its initializer is constant. Floats
            // never const-fold (the evaluator is integer/text-only): an f64
            // initializer goes straight to a typed runtime local so later
            // arithmetic sees a real f64 binding.
            if (!ls.isVar() and !isFloatSc(try exprScalar(b, init_expr, scope))) {
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
            if (init_expr == .string_lit or (try isStrCall(b, init_expr, scope))) {
                const value = if (init_expr == .string_lit)
                    try buildConcat(b, init_expr.string_lit, scope, false, rt)
                else
                    try buildStrExpr(b, init_expr, scope, rt);
                const ptr_idx: u32 = @intCast(b.cur_locals.items.len);
                // The (ptr, len) backing locals are address-width pointers
                // (i32 on wasm32, i64 on wasm64) — `.ptr`, not `.i64`.
                try b.cur_locals.append(b.a, .ptr);
                try b.cur_locals.append(b.a, .ptr);
                try b.main_rt.put(b.a, nm.text, .{ .ptr_idx = ptr_idx, .len_idx = ptr_idx + 1 });
                const st = try b.a.create(hir.Stmt);
                st.* = .{ .str_let = .{ .ptr_idx = ptr_idx, .len_idx = ptr_idx + 1, .value = value } };
                try out.append(b.a, st);
            } else if (init_expr == .record and (try recordEscapes(b, nm.text) or try recordHasNarrow(b, init_expr.record))) {
                // B2b: the binding is used as a whole value somewhere in
                // `main` (passed to a call, …) — materialize it in the scope
                // arena and bind the base pointer. Field access becomes
                // (ptr, offset) loads/stores through `findRecField`.
                const rv = (try buildRecExpr(b, init_expr, scope)) orelse return error.Unsupported;
                try bindMainRecord(b, scope, nm.text, ls.isVar(), rv.e, rv.si, out);
            } else if (init_expr == .record) {
                // B2 (SROA): a *non-escaping*, all-wide record-literal binding lowers
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
                    const lty: hir.Type = scalarBindTy(try exprScalar(b, fval, scope));
                    scope.next_idx = @intCast(b.cur_locals.items.len);
                    const value = try buildIntExpr(b, fval, scope);
                    const idx = try scope.declare(full, ls.isVar(), lty);
                    try b.cur_locals.append(b.a, lty);
                    const st = try b.a.create(hir.Stmt);
                    st.* = .{ .let = .{ .idx = idx, .value = value } };
                    try out.append(b.a, st);
                }
                if (!any) return error.Unsupported; // empty literal binds nothing
            } else if (init_expr == .array) {
                // An array literal: materialize in the scope arena; the
                // binding holds the base pointer (one .ptr local), the
                // count/stride/element kind stay compile-time (Scope.arrs).
                const arr = try buildArrayLit(b, init_expr.array, scope);
                scope.next_idx = @intCast(b.cur_locals.items.len);
                const idx = try scope.declare(nm.text, ls.isVar(), .ptr);
                try b.cur_locals.append(b.a, .ptr);
                try scope.arrs.put(b.a, nm.text, .{ .ptr_idx = idx, .count = .{ .konst = arr.count }, .stride = arr.stride, .elem = arr.elem });
                const st = try b.a.create(hir.Stmt);
                st.* = .{ .let = .{ .idx = idx, .value = arr.e } };
                try out.append(b.a, st);
            } else if (try recCallStruct(b, init_expr)) |_| {
                // `let p = make(3, 4)` — a record-returning call: bind the
                // returned base pointer (the record lives in the scope arena).
                const rv = (try buildRecExpr(b, init_expr, scope)) orelse return error.Unsupported;
                try bindMainRecord(b, scope, nm.text, ls.isVar(), rv.e, rv.si, out);
            } else {
                // A runtime value binding: an i64 (`let a = double(21)`) or a
                // (a narrow field read must widen explicitly: i64(c.r))
                // bool (`let even = n % 2 == 0`, `var flag = true`). A bool
                // binding takes one slot too — its value is an i32 0/1.
                const init_sc = try exprScalar(b, init_expr, scope);
                if (init_sc == .narrow_int) return error.Unsupported;
                const lty: hir.Type = scalarBindTy(init_sc);
                // Build the initializer first so it can't see its own name,
                // then allocate a single local and register in scope so later
                // expressions can resolve it. The local index is the current
                // size of `main_locals` (str bindings take two slots each,
                // i64/bool bindings take one — the same shared index space).
                scope.next_idx = @intCast(b.cur_locals.items.len);
                const value = try buildIntExpr(b, init_expr, scope);
                const idx = try scope.declare(nm.text, ls.isVar(), lty);
                try b.cur_locals.append(b.a, lty);
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
            // A statement-position call to a face-bounded generic function
            // (`print_all(colors)` / `print_all([...])`): monomorphize per
            // the inferred element type and call the stamped instance (B5).
            if (callPathName(b, call)) |gn| {
                defer b.a.free(gn);
                if (std.mem.indexOfScalar(u8, gn, '.') == null) {
                    if (b.resolver.lookup(gn)) |fd| {
                        if (fd.isGeneric()) {
                            try out.append(b.a, try buildGenericCallStmt(b, gn, fd, call, scope));
                            return;
                        }
                    }
                }
            }
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
            } else if (try isStrCall(b, arg, scope)) {
                // A real call to a str-returning function.
                st.* = .{ .host_out_str = try buildStrExpr(b, arg, scope, rt) };
            } else if (try exprIsBool(b, arg, scope)) {
                // A boolean: a comparison, `&&`/`||`/`!`, a literal, a bool
                // binding, or a `-> bool` call. Printed as "true" / "false".
                st.* = .{ .host_out_bool = try buildIntExpr(b, arg, scope) };
            } else if (isFloatSc(try exprScalar(b, arg, scope))) {
                // A float: formatted via __fmt_f64 (decimal, ≤6 frac
                // digits); an f32 promotes to f64 first — one formatter.
                var fv = try buildIntExpr(b, arg, scope);
                if ((try exprScalar(b, arg, scope)) == .f32) {
                    const w = try b.a.create(hir.Expr);
                    w.* = .{ .num_cast = .{ .to = .f64, .value = fv } };
                    fv = w;
                }
                st.* = .{ .host_out_float = fv };
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
                const rhs_sc = try exprScalar(b, rhs_ast, scope);
                if (op.kind == .EQ) {
                    if (scalarBindTy(rhs_sc) != loc.ty) return error.Unsupported;
                } else if (loc.ty == .f64) {
                    // f64 compound assigns: arithmetic only, no `%=`.
                    if (op.kind == .PERCENT_EQ or rhs_sc != .f64) return error.Unsupported;
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
                if (narrowRange(rf.ty) != null) {
                    // A narrow field: plain `=` of an in-range literal only
                    // (compound ops are arithmetic — unsupported on narrows).
                    if (op.kind != .EQ) return error.Unsupported;
                    const base0 = try b.a.create(hir.Expr);
                    base0.* = .{ .local = .{ .idx = rf.base_idx, .ty = .ptr } };
                    st.* = .{ .field_set = .{ .base = base0, .offset = rf.offset, .ty = rf.ty, .value = try buildNarrowValue(b, rf.ty, rhs_ast) } };
                    try out.append(b.a, st);
                    return;
                }
                const rhs_sc = try exprScalar(b, rhs_ast, scope);
                if (op.kind == .EQ) {
                    if (scalarBindTy(rhs_sc) != rf.ty) return error.Unsupported;
                } else if (rf.ty == .f64) {
                    if (op.kind == .PERCENT_EQ or rhs_sc != .f64) return error.Unsupported;
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
        .for_stmt => |fs| {
            // `for x in xs { … }` over an array binding desugars to an
            // index loop: i = 0; while i < count { x = xs[i]; …; i += 1 }.
            // A scalar element loads into `x`; a record element binds `x`
            // to the element's inline address (B2b's record-ptr ABI), so
            // `x.fmt()` dispatches and `x.field` reads work in the body.
            const pat = (fs.pattern() orelse return error.Unsupported).bindingName() orelse return error.Unsupported;
            const iter = fs.iterable() orelse return error.Unsupported;
            const iname = switch (iter) {
                .path => |p| try p.text(b.a),
                else => return error.Unsupported, // v0 iterates array bindings (ranges later)
            };
            defer b.a.free(iname);
            const ai = scope.arrs.get(iname) orelse return error.Unsupported;

            // i (hidden) and x occupy fresh main locals.
            scope.next_idx = @intCast(b.cur_locals.items.len);
            const hidden = try std.fmt.allocPrint(b.a, "{s}#idx", .{pat.text});
            const i_idx = try scope.declare(hidden, true, .i64);
            try b.cur_locals.append(b.a, .i64);
            const x_ty: hir.Type = switch (ai.elem) {
                .scalar => |t| t,
                .rec => .ptr,
            };
            scope.next_idx = @intCast(b.cur_locals.items.len);
            const x_idx = try scope.declare(pat.text, false, x_ty);
            try b.cur_locals.append(b.a, x_ty);
            if (ai.elem == .rec) try scope.recs.put(b.a, pat.text, ai.elem.rec);

            // let i = 0
            {
                const zero = try b.a.create(hir.Expr);
                zero.* = .{ .int_const = 0 };
                const st0 = try b.a.create(hir.Stmt);
                st0.* = .{ .let = .{ .idx = i_idx, .value = zero } };
                try out.append(b.a, st0);
            }
            // body items: x = element; <source body>; i = i + 1
            var items: std.ArrayList(*hir.Stmt) = .empty;
            {
                const iref = try b.a.create(hir.Expr);
                iref.* = .{ .local = .{ .idx = i_idx, .ty = .i64 } };
                // The loop bound proves i < count, so no bounds check here.
                const base = try b.a.create(hir.Expr);
                base.* = .{ .local = .{ .idx = ai.ptr_idx, .ty = .ptr } };
                const eptr = try b.a.create(hir.Expr);
                eptr.* = .{ .elem_ptr = .{ .base = base, .index = iref, .stride = ai.stride } };
                const xval: *hir.Expr = switch (ai.elem) {
                    .rec => eptr,
                    .scalar => |t| blk: {
                        const g = try b.a.create(hir.Expr);
                        g.* = .{ .field_get = .{ .base = eptr, .offset = 0, .ty = t } };
                        break :blk g;
                    },
                };
                const setx = try b.a.create(hir.Stmt);
                setx.* = .{ .assign = .{ .idx = x_idx, .value = xval } };
                try items.append(b.a, setx);
            }
            var bit = (fs.body() orelse return error.Unsupported).statements();
            while (bit.next()) |bstmt| try buildMainStmt(b, bstmt, scope, rt, &items);
            {
                const iref = try b.a.create(hir.Expr);
                iref.* = .{ .local = .{ .idx = i_idx, .ty = .i64 } };
                const one = try b.a.create(hir.Expr);
                one.* = .{ .int_const = 1 };
                const inc = try b.a.create(hir.Expr);
                inc.* = .{ .bin = .{ .kind = .add, .lhs = iref, .rhs = one } };
                const sti = try b.a.create(hir.Stmt);
                sti.* = .{ .assign = .{ .idx = i_idx, .value = inc } };
                try items.append(b.a, sti);
            }
            const body_blk = try b.a.create(hir.Stmt);
            body_blk.* = .{ .block = try items.toOwnedSlice(b.a) };
            // while i < count
            const iref2 = try b.a.create(hir.Expr);
            iref2.* = .{ .local = .{ .idx = i_idx, .ty = .i64 } };
            const cnt = try countExpr(b, ai.count);
            const cond = try b.a.create(hir.Expr);
            cond.* = .{ .bin = .{ .kind = .lt, .lhs = iref2, .rhs = cnt } };
            const st = try b.a.create(hir.Stmt);
            st.* = .{ .while_ = .{ .cond = cond, .body = body_blk } };
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
            if (fd.isGeneric()) continue; // exists only monomorphized (B5)
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

/// The dotted text of `call`'s path callee (caller frees), or null when
/// the callee isn't a plain path.
fn callPathName(b: *Builder, call: ast.CallExpr) ?[]const u8 {
    const callee = call.callee() orelse return null;
    const cpath = switch (callee) {
        .path => |p| p,
        else => return null,
    };
    return cpath.text(b.a) catch null;
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
        // An i64, f64, or `-> bool` (i32 0/1) value function; the value
        // body builds through `buildIntBlock` whatever the scalar.
        break :blk switch (rs) {
            .bool, .i64, .f64, .f32 => rs,
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
                    .bool, .i64, .f64, .f32 => psc,
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
            // B4: a str-returning fit method on a record binding/param
            // (`r.fmt()`) — same static dispatch as the i64 path.
            if (std.mem.indexOfScalar(u8, cname, '.')) |dot| {
                const head = cname[0..dot];
                const mname = cname[dot + 1 ..];
                if (std.mem.indexOfScalar(u8, mname, '.') == null) {
                    if (scope.recs.get(head)) |si| {
                        const loc = scope.find(head) orelse return error.Unsupported;
                        const fid = (try registerFitMethod(b, si, mname)) orelse
                            return reject(b, .name_not_found);
                        if (b.funcs.items[fid].ret != .str) return error.Unsupported; // not a str value
                        const recv = try b.a.create(hir.Expr);
                        recv.* = .{ .local = .{ .idx = loc.idx, .ty = .ptr } };
                        out.* = .{ .call = .{ .func = fid, .args = try buildCallArgs(b, fid, cc.args(), scope, recv) } };
                        return out;
                    }
                }
            }
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
            const mname = (me.method() orelse return error.Unsupported).text;
            // A str-returning fit method on a record-valued receiver
            // expression (`colors[1].fmt()`): same dispatch as the i64
            // method path, the receiver's address as `self`.
            if (try buildRecExpr(b, me.receiver() orelse return error.Unsupported, scope)) |rv| {
                const fid = (try registerFitMethod(b, rv.si, mname)) orelse
                    return reject(b, .name_not_found);
                if (b.funcs.items[fid].ret != .str) return error.Unsupported;
                out.* = .{ .call = .{ .func = fid, .args = try buildCallArgs(b, fid, me.args(), scope, rv.e) } };
                return out;
            }
            // `s.slice(start, end)` — the only str-VALUED method. (index_of /
            // starts_with / contains are i64/bool, handled in buildIntExpr.)
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
                .call => |cc| fit: {
                    // A fit-method call piece: `{r.fmt()}` is a str piece,
                    // `{r.area()}` formats decimal. Resolves in main and
                    // inside fit-method bodies alike (`{self.area()}` —
                    // the receiver is in scope.recs either way).
                    if (callPathName(b, cc)) |cn| {
                        defer b.a.free(cn);
                        if (std.mem.indexOfScalar(u8, cn, '.')) |dotp| {
                            const head = cn[0..dotp];
                            const mn = cn[dotp + 1 ..];
                            if (std.mem.indexOfScalar(u8, mn, '.') == null) {
                                if (scope.recs.get(head)) |si| {
                                    const loc = scope.find(head) orelse return error.Unsupported;
                                    const fid = (try registerFitMethod(b, si, mn)) orelse
                                        return reject(b, .name_not_found);
                                    const recv = try b.a.create(hir.Expr);
                                    recv.* = .{ .local = .{ .idx = loc.idx, .ty = .ptr } };
                                    const call_e = try b.a.create(hir.Expr);
                                    call_e.* = .{ .call = .{ .func = fid, .args = try buildCallArgs(b, fid, cc.args(), scope, recv) } };
                                    try flush(b, &lit, &pieces);
                                    const piece = switch (b.funcs.items[fid].ret) {
                                        .str => call_e,
                                        .i64 => blk2: {
                                            const w = try b.a.create(hir.Expr);
                                            w.* = .{ .fmt_int = call_e };
                                            break :blk2 w;
                                        },
                                        .f64 => blk3: {
                                            const w = try b.a.create(hir.Expr);
                                            w.* = .{ .fmt_float = call_e };
                                            break :blk3 w;
                                        },
                                        .f32 => blk4: {
                                            const pr = try b.a.create(hir.Expr);
                                            pr.* = .{ .num_cast = .{ .to = .f64, .value = call_e } };
                                            const w = try b.a.create(hir.Expr);
                                            w.* = .{ .fmt_float = pr };
                                            break :blk4 w;
                                        },
                                        else => return error.Unsupported, // a bool has no text form here yet
                                    };
                                    try pieces.append(b.a, piece);
                                    break :fit;
                                }
                            }
                        }
                    }
                    if (in_callee) return error.Unsupported; // callee bodies don't nest plain calls (v0)
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
                        // A str local (callee param) passes through as-is; a
                        // numeric local interpolates as its decimal text
                        // (i64 via __fmt_i64, f64 via __fmt_f64).
                        if (loc.ty == .str) {
                            piece.* = .{ .local = .{ .idx = loc.idx, .ty = loc.ty } };
                        } else {
                            const lref = try b.a.create(hir.Expr);
                            lref.* = .{ .local = .{ .idx = loc.idx, .ty = loc.ty } };
                            piece.* = switch (loc.ty) {
                                .f64 => .{ .fmt_float = lref },
                                .f32 => blkf: {
                                    const w = try b.a.create(hir.Expr);
                                    w.* = .{ .num_cast = .{ .to = .f64, .value = lref } };
                                    break :blkf .{ .fmt_float = w };
                                },
                                else => .{ .fmt_int = lref },
                            };
                        }
                        try pieces.append(b.a, piece);
                    } else if (rtBinding(rt, ptext)) |bnd| {
                        try flush(b, &lit, &pieces);
                        const e = try b.a.create(hir.Expr);
                        e.* = .{ .str_binding = .{ .ptr_idx = bnd.ptr_idx, .len_idx = bnd.len_idx } };
                        try pieces.append(b.a, e);
                    } else if (try findRecField(scope, ptext)) |rf| {
                        // `{p.x}` on a materialized record: format the
                        // numeric field. (A bool field has no text form yet.)
                        const interp_ok = switch (rf.ty) {
                            .i64, .f64, .f32, .u8, .i8, .u16, .i16, .u32, .i32 => true,
                            else => false,
                        };
                        if (!interp_ok) return error.Unsupported;
                        try flush(b, &lit, &pieces);
                        const piece = try b.a.create(hir.Expr);
                        piece.* = switch (rf.ty) {
                            .f64 => .{ .fmt_float = try recFieldExpr(b, rf) },
                            .f32 => blkf: {
                                const w = try b.a.create(hir.Expr);
                                w.* = .{ .num_cast = .{ .to = .f64, .value = try recFieldExpr(b, rf) } };
                                break :blkf .{ .fmt_float = w };
                            },
                            else => .{ .fmt_int = try recFieldExpr(b, rf) },
                        };
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

/// True if `arg` is a call to a `str`-returning function — a named
/// function, or a fit method on a record binding in `scope`
/// (`r.fmt()`) — so `main` emits a `host_out_str` / str binding rather
/// than trying an i64 lowering.
fn isStrCall(b: *Builder, arg: ast.Expr, scope: *const Scope) BuildError!bool {
    // A method on a record-valued receiver expression (`colors[1].fmt()`).
    if (arg == .method) {
        const me = arg.method;
        const mname = (me.method() orelse return false).text;
        const si = (try recvStruct(b, scope, me.receiver() orelse return false)) orelse return false;
        const m = findFitMethod(b, si.name, mname) orelse return false;
        const rt = m.returnType() orelse return false;
        const rs = (try semaScalar(b, rt.type_())) orelse return false;
        return rs == .str;
    }
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
    if (std.mem.indexOfScalar(u8, cname, '.')) |dot| {
        const mname = cname[dot + 1 ..];
        if (std.mem.indexOfScalar(u8, mname, '.') != null) return false;
        const si = scope.recs.get(cname[0..dot]) orelse return false;
        const m = findFitMethod(b, si.name, mname) orelse return false;
        const rt = m.returnType() orelse return false;
        const rs = (try semaScalar(b, rt.type_())) orelse return false;
        return rs == .str;
    }
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
            .u32 => .u32,
            .i16 => .i16,
            .u16 => .u16,
            .i8 => .i8,
            .u8 => .u8,
            .f32 => .f32,
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
        .i64, .f64 => .{ .size = 8, .alignment = 8 },
        .u32, .i32, .f32 => .{ .size = 4, .alignment = 4 },
        .u16, .i16 => .{ .size = 2, .alignment = 2 },
        .u8, .i8 => .{ .size = 1, .alignment = 1 },
        .bool => .{ .size = 1, .alignment = 1 },
        else => null,
    };
}

/// The value range of a narrow integer storage type, or null for
/// non-narrow types. Field initializers/assignments must be literals
/// inside this range (the build-time mirror of TYP040).
fn narrowRange(ty: hir.Type) ?struct { min: i64, max: i64 } {
    return switch (ty) {
        .u8 => .{ .min = 0, .max = 255 },
        .i8 => .{ .min = -128, .max = 127 },
        .u16 => .{ .min = 0, .max = 65535 },
        .i16 => .{ .min = -32768, .max = 32767 },
        .u32 => .{ .min = 0, .max = 4294967295 },
        .i32 => .{ .min = -2147483648, .max = 2147483647 },
        else => null,
    };
}

/// Build a narrow-field initializer/assignment value: a bare (or
/// negated) integer literal inside the field's range. Anything else —
/// an i64 expression, another field — needs an explicit narrowing cast,
/// which waits on the trapping-cast slice; honestly Unsupported.
fn buildNarrowValue(b: *Builder, ty: hir.Type, fval: ast.Expr) BuildError!*hir.Expr {
    const r = narrowRange(ty).?;
    const v: i64 = switch (fval) {
        .num_lit => |n| blk: {
            const tok = n.token() orelse return error.Unsupported;
            if (tok.kind != .INT_LIT) return error.Unsupported;
            break :blk consteval.parseIntLit(tok.text) catch return error.Unsupported;
        },
        .unary => |u| blk: {
            const op = u.op() orelse return error.Unsupported;
            if (op.kind != .MINUS) return error.Unsupported;
            const inner = u.operand() orelse return error.Unsupported;
            const n = switch (inner) {
                .num_lit => |nl| nl,
                else => return error.Unsupported,
            };
            const tok = n.token() orelse return error.Unsupported;
            if (tok.kind != .INT_LIT) return error.Unsupported;
            const mag = consteval.parseIntLit(tok.text) catch return error.Unsupported;
            break :blk -mag;
        },
        else => return error.Unsupported,
    };
    if (v < r.min or v > r.max) return reject(b, .not_const); // out of range for the width
    const out = try b.a.create(hir.Expr);
    out.* = .{ .int_const = v };
    return out;
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
/// Does the record literal's struct declare any narrow integer field?
/// Narrow fields are *storage* — their range checks and width truncation
/// only exist in memory, so such records always materialize (SROA has no
/// storage and would silently widen them).
fn recordHasNarrow(b: *Builder, re: ast.RecordExpr) BuildError!bool {
    const pname = try (re.path() orelse return false).text(b.a);
    defer b.a.free(pname);
    const si = b.structs.get(pname) orelse return false;
    for (si.fields) |f| if (narrowRange(f.ty) != null) return true;
    return false;
}

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
    if (node.kind == .STR_LITERAL) {
        // Interpolation lives inside the string token, invisible to the
        // node walk: a `{name.method(...)}` piece is a receiver use, so
        // the record must materialize. A plain `{name.field}` stays
        // SROA-friendly (no '(' before the closing brace).
        for (node.children) |ch| switch (ch) {
            .token => |t| if (t.kind == .STR_PLAIN) {
                const needle = try std.fmt.allocPrint(b.a, "{{{s}.", .{name});
                defer b.a.free(needle);
                var at: usize = 0;
                while (std.mem.indexOfPos(u8, t.text, at, needle)) |hit| {
                    const after = hit + needle.len;
                    const close = std.mem.indexOfScalarPos(u8, t.text, after, '}') orelse break;
                    if (std.mem.indexOfScalar(u8, t.text[after..close], '(') != null) return true;
                    at = hit + 1;
                }
            },
            .node => {},
        };
        return false;
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

/// The struct a record-valued receiver expression holds, resolved
/// WITHOUT building it (for routing predicates): a record binding/param,
/// an array-of-records index, a record-returning call, or parens.
fn recvStruct(b: *Builder, scope: *const Scope, expr: ast.Expr) BuildError!?*const StructInfo {
    switch (expr) {
        .paren => |p| return recvStruct(b, scope, p.inner() orelse return null),
        .path => |p| {
            const txt = try p.text(b.a);
            defer b.a.free(txt);
            return scope.recs.get(txt);
        },
        .index => |ix| {
            const base = ix.base() orelse return null;
            if (base != .path) return null;
            const bn = try base.path.text(b.a);
            defer b.a.free(bn);
            const ai = scope.arrs.get(bn) orelse return null;
            return switch (ai.elem) {
                .rec => |r| r,
                .scalar => null,
            };
        },
        .call => return recCallStruct(b, expr),
        else => return null,
    }
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
        .bool, .i64, .f64, .f32, .str => rs,
        else => return error.Unsupported, // record-valued methods: later
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
            .bool, .i64, .f64, .f32 => psc,
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

    // A str-returning method (`fn fmt(self) -> str { "..." }`): a single
    // tail str expression, like registerStrFunc — interpolation resolves
    // `{self.w}` through the rec-field concat piece.
    if (ret_ty == .str) {
        const tail = singleTailOfBlock(body_blk) orelse return error.Unsupported;
        const value = try buildStrExpr(b, tail, &scope, null);
        const vstmt = try b.a.create(hir.Stmt);
        vstmt.* = .{ .expr = value };
        const block = try b.a.create(hir.Stmt);
        block.* = .{ .block = try b.a.dupe(*hir.Stmt, &.{vstmt}) };
        b.funcs.items[id] = .{ .name = key, .params = param_slice, .ret = .str, .body = block };
        return id;
    }

    const body = try buildIntBlock(b, body_blk, &scope);
    if (tailIsValueIfNoElse(body)) return reject(b, .unsupported_call);
    const extra = scope.extra();
    const locals = try b.a.alloc(hir.Type, extra);
    for (locals, 0..) |*t, j| t.* = scope.locals.items[scope.n_params + j].ty;
    b.funcs.items[id] = .{ .name = key, .params = param_slice, .ret = ret_ty, .locals = locals, .body = body };
    return id;
}

/// The single tail expression of a one-statement block, or null.
fn singleTailOfBlock(body: ast.Block) ?ast.Expr {
    var it = body.statements();
    var first: ?ast.Expr = null;
    var count: usize = 0;
    while (it.next()) |stmt| {
        count += 1;
        if (count > 1) return null;
        first = switch (stmt) {
            .expr_stmt => |es| es.expression(),
            .return_stmt => |rsx| rsx.value(),
            else => return null,
        };
    }
    return first;
}

/// Build an array literal (`[a, b, c]`) into an `array_lit` expr. The
/// element kind comes from the first element: a record value (inline
/// copies, stride = struct size) or an i64/f64/f32 scalar; every element
/// must match it. Empty literals need a type annotation — later.
fn buildArrayLit(b: *Builder, ae: ast.ArrayExpr, scope: *Scope) BuildError!struct { e: *hir.Expr, count: u32, stride: u32, elem: ElemKind } {
    var elems: std.ArrayList(ast.Expr) = .empty;
    defer elems.deinit(b.a);
    var it = ae.elements();
    while (it.next()) |el| try elems.append(b.a, el);
    if (elems.items.len == 0) return error.Unsupported;

    var inits: std.ArrayList(*hir.Expr) = .empty;
    // Record elements?
    if (try buildRecExpr(b, elems.items[0], scope)) |first| {
        try inits.append(b.a, first.e);
        for (elems.items[1..]) |el| {
            const rv = (try buildRecExpr(b, el, scope)) orelse return error.Unsupported;
            if (rv.si != first.si) return error.Unsupported; // mixed element structs
            try inits.append(b.a, rv.e);
        }
        const out = try b.a.create(hir.Expr);
        out.* = .{ .array_lit = .{
            .stride = first.si.size,
            .alignment = first.si.alignment,
            .elem_ty = .ptr,
            .copy_bytes = first.si.size,
            .inits = try inits.toOwnedSlice(b.a),
        } };
        return .{ .e = out, .count = @intCast(elems.items.len), .stride = first.si.size, .elem = .{ .rec = first.si } };
    }
    // Scalar elements.
    const sc = try exprScalar(b, elems.items[0], scope);
    const ety: hir.Type = switch (sc) {
        .f64 => .f64,
        .f32 => .f32,
        else => .i64, // flexible/int literals and i64 exprs
    };
    const w = fieldWidth(ety).?;
    for (elems.items) |el| {
        const esc = try exprScalar(b, el, scope);
        const ok = switch (ety) {
            .f64 => esc == .f64,
            .f32 => esc == .f32,
            else => esc == .i64 or esc == .unknown,
        };
        if (!ok) return error.Unsupported; // mixed element types
        try inits.append(b.a, try buildIntExpr(b, el, scope));
    }
    const out = try b.a.create(hir.Expr);
    out.* = .{ .array_lit = .{
        .stride = w.size,
        .alignment = w.alignment,
        .elem_ty = ety,
        .copy_bytes = null,
        .inits = try inits.toOwnedSlice(b.a),
    } };
    return .{ .e = out, .count = @intCast(elems.items.len), .stride = w.size, .elem = .{ .scalar = ety } };
}

/// The element address `base_ptr_local[index]` with the spec's trapping
/// bounds check folded in.
fn elemPtrExpr(b: *Builder, ai: ArrInfo, index: *hir.Expr) BuildError!*hir.Expr {
    const cnt = try countExpr(b, ai.count);
    const checked = try b.a.create(hir.Expr);
    checked.* = .{ .bounds_check = .{ .index = index, .count = cnt } };
    const base = try b.a.create(hir.Expr);
    base.* = .{ .local = .{ .idx = ai.ptr_idx, .ty = .ptr } };
    const out = try b.a.create(hir.Expr);
    out.* = .{ .elem_ptr = .{ .base = base, .index = checked, .stride = ai.stride } };
    return out;
}

/// B5 monomorphization (the last gate to B4's golden program): a call
/// to `fn f<T: Face>(items: [T])` stamps one concrete instance per
/// element type — `f<Color>` — with the `[T]` parameter lowered to a
/// (ptr, count) pair (base pointer + element count, the str-param ABI
/// shape) and `T`'s methods resolving through the fit registry inside
/// the stamped body. v0 floor: one type parameter, void return, params
/// are `[T]` slices or non-generic scalars, the argument is an array
/// binding or literal of records. No vtables; each instance is a plain
/// function.
const GenericSig = sema.fits.GenericSig;
const parseGenericSig = sema.fits.parseGenericSig;
const sliceOfWhich = sema.fits.sliceOfWhich;

/// One inferred type-parameter slot: what T turned out to be.
const TSlot = struct { elem: ElemKind, stride: u32 };

/// The array info an argument denotes: a binding name or an array
/// literal (which is built — its value expr rides along).
const ArrArg = struct { ptr: *hir.Expr, count: *hir.Expr, elem: ElemKind, stride: u32 };

fn buildArrArg(b: *Builder, arg: ast.Expr, scope: *Scope) BuildError!?ArrArg {
    switch (arg) {
        .path => |p| {
            const txt = try p.text(b.a);
            defer b.a.free(txt);
            const ai = scope.arrs.get(txt) orelse return null;
            const ptr = try b.a.create(hir.Expr);
            ptr.* = .{ .local = .{ .idx = ai.ptr_idx, .ty = .ptr } };
            return .{ .ptr = ptr, .count = try countExpr(b, ai.count), .elem = ai.elem, .stride = ai.stride };
        },
        .array => |ae| {
            const arr = try buildArrayLit(b, ae, scope);
            const cnt = try b.a.create(hir.Expr);
            cnt.* = .{ .int_const = arr.count };
            return .{ .ptr = arr.e, .count = cnt, .elem = arr.elem, .stride = arr.stride };
        },
        else => return null,
    }
}

/// Build `f(arg…)` against a generic declaration: infer T from the
/// first `[T]` argument, fit-check the bound, stamp (or reuse) the
/// instance, and emit the call statement.
/// Build `f(arg…)` against a generic declaration: infer each type
/// param from its first `[T]` argument, fit-check the bounds, stamp
/// (or reuse) the instance, and yield the call expression (the stamped
/// instance's return type is on `b.funcs`).
fn buildGenericCall(b: *Builder, gname: []const u8, fd: ast.FnDecl, call: ast.CallExpr, scope: *Scope) BuildError!*hir.Expr {
    const sig = parseGenericSig(fd.genericParams().?) orelse return error.Unsupported;
    const ps = fd.params() orelse return error.Unsupported;

    // Walk params and args together: each type param infers at its
    // first `[T]` arg (and must stay consistent at later ones).
    var slots: [sema.fits.max_generic_params]?TSlot = @splat(null);
    var args: std.ArrayList(*hir.Expr) = .empty;
    var pit = ps.iter();
    var ait = call.args();
    while (pit.next()) |p| {
        const a0 = ait.next() orelse return reject(b, .unsupported_call);
        if (sliceOfWhich(p, sig, b.a)) |which| {
            const aa = (try buildArrArg(b, a0, scope)) orelse return reject(b, .unsupported_call);
            if (slots[which]) |prev| {
                if (!elemEql(prev.elem, aa.elem)) return reject(b, .unsupported_call); // T must infer consistently
            } else {
                slots[which] = .{ .elem = aa.elem, .stride = aa.stride };
            }
            try args.append(b.a, aa.ptr);
            try args.append(b.a, aa.count);
        } else {
            // A non-generic scalar parameter.
            const psc = (try paramScalar(b, p)) orelse return error.Unsupported;
            const want: hir.Type = switch (psc) {
                .bool, .i64, .f64, .f32 => psc,
                else => return error.Unsupported,
            };
            const got = scalarBindTy(try exprScalar(b, a0, scope));
            if (got != want and !(want == .i64 and got == .i64)) return reject(b, .unsupported_call);
            try args.append(b.a, try buildIntExpr(b, a0, scope));
        }
    }
    if (ait.next() != null) return reject(b, .unsupported_call);
    // Every type param must have an inference source (a `[T]` param).
    for (slots[0..sig.n]) |s| if (s == null) return error.Unsupported;

    // The bounds: each T must fit its face (TYP200 — `q64 check` emits
    // it; the emit path rejects honestly). Scalars have no fits yet, so
    // a *bounded* param takes record elements only; an unbounded one
    // stamps per scalar type as well.
    for (sig.params[0..sig.n], 0..) |gp, i| {
        const face = gp.bound orelse continue;
        const si = switch (slots[i].?.elem) {
            .rec => |r| r,
            .scalar => return reject(b, .unsupported_call),
        };
        if (b.fitreg == null or b.fitreg.?.find(si.name, face) == null)
            return reject(b, .unsupported_call);
    }

    const fid = try stampGeneric(b, gname, fd, sig, slots[0..sig.n]);
    const e = try b.a.create(hir.Expr);
    e.* = .{ .call = .{ .func = fid, .args = try args.toOwnedSlice(b.a) } };
    return e;
}

/// The statement form (`print_all(colors)` as a `main` statement): the
/// stamped instance must be void — a value left on the stack is
/// rejected at lowering.
fn buildGenericCallStmt(b: *Builder, gname: []const u8, fd: ast.FnDecl, call: ast.CallExpr, scope: *Scope) BuildError!*hir.Stmt {
    const e = try buildGenericCall(b, gname, fd, call, scope);
    const st = try b.a.create(hir.Stmt);
    st.* = .{ .expr = e };
    return st;
}

/// Do two element kinds name the same T?
fn elemEql(x: ElemKind, y: ElemKind) bool {
    return switch (x) {
        .rec => |r| y == .rec and y.rec == r,
        .scalar => |t| y == .scalar and y.scalar == t,
    };
}

/// Stamp (or fetch) the concrete instance `gname<T1, T2…>` — each T a
/// record struct or a scalar type (`each<i64>`). The body builds with
/// the entry-style builder (it may env.out), `[T]` params as
/// (ptr, count) pairs registered in `Scope.arrs` with a *runtime*
/// count, and its own locals list. A `-> i64`/`bool`/`f64`/`f32`
/// declaration makes a *value-returning* instance: the body's last
/// statement is its value tail (a tail expression or `return expr`);
/// `-> T` and str/record returns are a later slice.
fn stampGeneric(b: *Builder, gname: []const u8, fd: ast.FnDecl, sig: GenericSig, slots: []const ?TSlot) BuildError!hir.FuncId {
    var keybuf: std.ArrayList(u8) = .empty;
    try keybuf.appendSlice(b.a, gname);
    try keybuf.append(b.a, '<');
    for (slots, 0..) |s, i| {
        if (i > 0) try keybuf.appendSlice(b.a, ", ");
        try keybuf.appendSlice(b.a, switch (s.?.elem) {
            .rec => |r| r.name,
            .scalar => |t| @tagName(t),
        });
    }
    try keybuf.append(b.a, '>');
    const key = try keybuf.toOwnedSlice(b.a);
    if (b.ids.get(key)) |id| return id;

    const ret_ty: hir.Type = if (fd.returnType() == null) .void else blk: {
        const rs = (try fnRetScalar(b, fd)) orelse return error.Unsupported; // `-> T` (needs by-value T), str, records: later
        break :blk switch (rs) {
            .bool, .i64, .f64, .f32 => rs,
            else => return error.Unsupported,
        };
    };

    var scope = Scope{ .a = b.a };
    var params: std.ArrayList(hir.Param) = .empty;
    const ps = fd.params() orelse return error.Unsupported;
    var pit = ps.iter();
    while (pit.next()) |p| {
        const pn = (p.name() orelse return error.Unsupported).text;
        if (sliceOfWhich(p, sig, b.a)) |which| {
            const slot = slots[which].?;
            // (ptr, count): two wasm params, the arr registered on the name.
            const ptr_idx = try scope.declare(pn, false, .ptr);
            const hidden = try std.fmt.allocPrint(b.a, "{s}#len", .{pn});
            const cnt_idx = try scope.declare(hidden, false, .i64);
            try params.append(b.a, .{ .name = pn, .ty = .ptr });
            try params.append(b.a, .{ .name = hidden, .ty = .i64 });
            try scope.arrs.put(b.a, pn, .{
                .ptr_idx = ptr_idx,
                .count = .{ .local_idx = cnt_idx },
                .stride = slot.stride,
                .elem = slot.elem,
            });
        } else {
            const psc = (try paramScalar(b, p)) orelse return error.Unsupported;
            const pty: hir.Type = switch (psc) {
                .bool, .i64, .f64, .f32 => psc,
                else => return error.Unsupported,
            };
            _ = try scope.declare(pn, false, pty);
            try params.append(b.a, .{ .name = pn, .ty = pty });
        }
    }
    scope.n_params = @intCast(params.items.len);
    const param_slice = try params.toOwnedSlice(b.a);

    const id: hir.FuncId = @intCast(b.funcs.items.len);
    try b.ids.put(b.a, key, id);
    const dummy = try b.a.create(hir.Stmt);
    dummy.* = .{ .block = &.{} };
    try b.funcs.append(b.a, .{ .name = key, .params = param_slice, .ret = ret_ty, .body = dummy, .is_screen = true });

    // The body builds entry-style (host statements allowed) with its own
    // locals list and rt map; locals index past the params.
    var inst_locals: std.ArrayList(hir.Type) = .empty;
    var inst_rt: RtMap = .empty;
    const saved_locals = b.cur_locals;
    b.cur_locals = &inst_locals;
    defer b.cur_locals = saved_locals;
    // Pad so `scope.next_idx = cur_locals.len` bookkeeping lands past the
    // params (main has no params; stamped instances do).
    try inst_locals.appendNTimes(b.a, .i64, param_slice.len);

    var ast_stmts: std.ArrayList(ast.Stmt) = .empty;
    defer ast_stmts.deinit(b.a);
    var it = (fd.body() orelse return error.Unsupported).statements();
    while (it.next()) |stmt| try ast_stmts.append(b.a, stmt);

    var stmts: std.ArrayList(*hir.Stmt) = .empty;
    for (ast_stmts.items, 0..) |stmt, i| {
        if (ret_ty != .void and i == ast_stmts.items.len - 1) {
            // The value tail: a tail expression or an explicit `return`,
            // typed as the declared return scalar. The lowering reads it
            // as the value block's tail (lowerIntBlock).
            const e: ast.Expr, const is_ret: bool = switch (stmt) {
                .expr_stmt => |es| .{ es.expression() orelse return error.Unsupported, false },
                .return_stmt => |rs| .{ rs.value() orelse return error.Unsupported, true },
                else => return error.Unsupported, // a value `if` tail: later
            };
            if (scalarBindTy(try exprScalar(b, e, &scope)) != ret_ty) return error.Unsupported;
            const st = try b.a.create(hir.Stmt);
            const value = try buildIntExpr(b, e, &scope);
            st.* = if (is_ret) .{ .ret = value } else .{ .expr = value };
            try stmts.append(b.a, st);
        } else {
            try buildMainStmt(b, stmt, &scope, &inst_rt, &stmts);
        }
    }

    const block = try b.a.create(hir.Stmt);
    block.* = .{ .block = try stmts.toOwnedSlice(b.a) };
    const all = try inst_locals.toOwnedSlice(b.a);
    b.funcs.items[id] = .{
        .name = key,
        .params = param_slice,
        .ret = ret_ty,
        .locals = all[param_slice.len..], // past the param padding
        .body = block,
        .is_screen = true,
    };
    return id;
}

/// Bind a record value in `main`: one `.ptr` local (shared index space with
/// the other main bindings) + a `Scope.recs` entry so field access and
/// whole-value uses resolve.
fn bindMainRecord(b: *Builder, scope: *Scope, name: []const u8, is_var: bool, value: *hir.Expr, si: *const StructInfo, out: *std.ArrayList(*hir.Stmt)) BuildError!void {
    scope.next_idx = @intCast(b.cur_locals.items.len);
    const idx = try scope.declare(name, is_var, .ptr);
    try b.cur_locals.append(b.a, .ptr);
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
                if (narrowRange(f.ty) != null) {
                    // A narrow integer field: an in-range literal (the
                    // build-time mirror of TYP040); wider values need the
                    // trapping narrowing cast, a later slice.
                    try inits.append(b.a, .{ .offset = f.offset, .ty = f.ty, .value = try buildNarrowValue(b, f.ty, fval) });
                    seen += 1;
                    continue;
                }
                // No implicit conversion: the value's scalar kind must
                // match the field's declared type.
                if (scalarBindTy(try exprScalar(b, fval, scope)) != f.ty) return error.Unsupported;
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
        .index => |ix| {
            // `xs[i]` where xs holds inline records: the element address
            // IS the record value (bounds-checked).
            const base = ix.base() orelse return null;
            if (base != .path) return null;
            const bn = try base.path.text(b.a);
            defer b.a.free(bn);
            const ai = scope.arrs.get(bn) orelse return null;
            const si = switch (ai.elem) {
                .rec => |r| r,
                .scalar => return null,
            };
            const idx = try buildIntExpr(b, ix.index() orelse return error.Unsupported, scope);
            return .{ .e = try elemPtrExpr(b, ai, idx), .si = si };
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
            const args = try buildCallArgs(b, id, cc.args(), scope, null);
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
fn buildCallArgs(b: *Builder, id: hir.FuncId, args_iter: ast.ArgIter, scope: *Scope, recv: ?*hir.Expr) BuildError![]const *hir.Expr {
    // Snapshot the parameter kinds before building the args — building an
    // argument may register a new callee and grow `b.funcs`, so we can't
    // hold a slice into it across the loop.
    const ParamKind = union(enum) { int, float: hir.Type, bool_, rec: *const StructInfo };
    const np = b.funcs.items[id].params.len;
    const kinds = try b.a.alloc(ParamKind, np);
    const frec = b.fn_recs.get(id);
    for (b.funcs.items[id].params, 0..) |p, k| {
        kinds[k] = switch (p.ty) {
            .bool => .bool_,
            .i64 => .int,
            .f64 => .{ .float = .f64 },
            .f32 => .{ .float = .f32 },
            // A `.ptr` param is a record on this path (str callees never get here).
            .ptr => .{ .rec = (frec orelse return error.Unsupported).params[k] orelse return error.Unsupported },
            else => return error.Unsupported,
        };
    }

    var args: std.ArrayList(*hir.Expr) = .empty;
    var ait = args_iter;
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
            // No implicit conversion: each arg's scalar kind must match
            // its parameter (bool ≠ int ≠ float).
            .int => {
                switch (try exprScalar(b, a, scope)) {
                    .i64, .unknown => {},
                    else => return reject(b, .unsupported_call), // bool/float/narrow need a cast
                }
                try args.append(b.a, try buildIntExpr(b, a, scope));
            },
            .float => |want| {
                const sc = try exprScalar(b, a, scope);
                const ok = (want == .f64 and sc == .f64) or (want == .f32 and sc == .f32);
                if (!ok) return reject(b, .unsupported_call);
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
    return (try exprScalar(b, arg, scope)) == .bool;
}

/// The expression's scalar-floor type under the current scope (sema's
/// typer through the bridge). Drives binding types, env.out routing,
/// and the no-implicit-conversion checks.
fn exprScalar(b: *Builder, arg: ast.Expr, scope: *const Scope) BuildError!sema.exprtype.ScalarType {
    var bridge = ExprTypeBridge{ .b = b, .scope = scope };
    return sema.exprtype.scalarOf(b.a, arg, .{
        .ctx = @ptrCast(&bridge),
        .localType = ExprTypeBridge.localType,
        .callRet = ExprTypeBridge.callRet,
    });
}

/// Binding type for a value of this scalar (the typed-local floor).
fn scalarBindTy(sc: sema.exprtype.ScalarType) hir.Type {
    return switch (sc) {
        .bool => .bool,
        .f64 => .f64,
        .f32 => .f32,
        else => .i64,
    };
}

/// Is this scalar a float (f32 or f64)? The two never mix with each
/// other or with integers — spec/types.md §Arithmetic.
fn isFloatSc(sc: sema.exprtype.ScalarType) bool {
    return sc == .f64 or sc == .f32;
}

/// The cast target named by a builtin numeric-cast callee (`f32(x)`,
/// `f64(x)`, `i64(x)` — spec/types.md §Casts), or null.
fn castTarget(cname: []const u8) ?hir.Type {
    if (std.mem.eql(u8, cname, "f32")) return .f32;
    if (std.mem.eql(u8, cname, "f64")) return .f64;
    if (std.mem.eql(u8, cname, "i64")) return .i64;
    return null;
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
                .f64 => .f64,
                .f32 => .f32,
                .u8, .i8, .u16, .i16, .u32, .i32 => .narrow_int,
                else => .unknown,
            };
        };
        return switch (loc.ty) {
            .bool => .bool,
            .i64 => .i64,
            .f64 => .f64,
            .f32 => .f32,
            .str => .str,
            else => .unknown,
        };
    }

    fn callRet(ctx: *anyopaque, name: []const u8) std.mem.Allocator.Error!?sema.exprtype.ScalarType {
        const self: *ExprTypeBridge = @ptrCast(@alignCast(ctx));
        // A builtin numeric cast types as its target (`f32(x)` is f32).
        if (castTarget(name)) |ct| {
            return switch (ct) {
                .f32 => .f32,
                .f64 => .f64,
                else => .i64,
            };
        }
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
                .f64 => .f64,
                .f32 => .f32,
                .str => .str,
                else => null,
            };
        }
        const fd = self.b.resolver.lookup(name) orelse return null;
        const rs = (try fnRetScalar(self.b, fd)) orelse return null;
        return switch (rs) {
            .bool => .bool,
            .i64 => .i64,
            .f64 => .f64,
            .f32 => .f32,
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
    /// Array-literal bindings: name → element/stride/count info. The base
    /// pointer lives in `locals` under the same name (a `.ptr`); the count
    /// is compile-time (array literals have fixed length; growth is Vec's
    /// job, later).
    arrs: std.StringHashMapUnmanaged(ArrInfo) = .empty,

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
            const init_sc = try exprScalar(b, init_expr, scope);
            if (init_sc == .narrow_int) return error.Unsupported; // widen explicitly: i64(c.r)
            const ty: hir.Type = scalarBindTy(init_sc);
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
            // No implicit conversion: a plain `=` must assign a value of the
            // binding's type; compound ops (`+=` …) are arithmetic and apply
            // to numeric bindings (no `%=` on f64 — wasm has no float rem).
            const rhs_sc = try exprScalar(b, rhs_ast, scope);
            if (op.kind == .EQ) {
                if (scalarBindTy(rhs_sc) != loc.ty) return error.Unsupported;
            } else if (loc.ty == .f64) {
                if (op.kind == .PERCENT_EQ or rhs_sc != .f64) return error.Unsupported;
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
        .num_lit => |n| {
            const tok = n.token() orelse return error.Unsupported;
            if (tok.kind == .FLOAT_LIT) {
                out.* = .{ .float_const = std.fmt.parseFloat(f64, tok.text) catch return error.Unsupported };
            } else {
                out.* = .{ .int_const = consteval.parseIntLit(tok.text) catch return error.Unsupported };
            }
        },
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
            // `xs.len` of an array binding is its compile-time count.
            if (std.mem.lastIndexOfScalar(u8, txt, '.')) |dotl| {
                if (std.mem.eql(u8, txt[dotl + 1 ..], "len")) {
                    if (scope.arrs.get(txt[0..dotl])) |ai| {
                        return countExpr(b, ai.count);
                    }
                }
            }
            if (scope.find(txt)) |loc| {
                // i64, f64, and bool (i32 0/1) locals are readable here; a
                // `str` local belongs in the str path — and a bare record
                // binding (`.ptr`) is a whole-value use, not a scalar.
                if (loc.ty != .i64 and loc.ty != .bool and loc.ty != .f64 and loc.ty != .f32) return error.Unsupported;
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
            // No implicit numeric conversion (spec/types.md): a float on
            // either side requires the *same* float on both (f32 and f64
            // don't mix either), and the float operator set excludes `%`,
            // bitwise, and shifts (no wasm float forms).
            {
                const ls = try exprScalar(b, bx.lhs() orelse return error.Unsupported, scope);
                const rs2 = try exprScalar(b, bx.rhs() orelse return error.Unsupported, scope);
                // Narrow-int arithmetic waits on the spec pinning overflow
                // semantics (wrap vs trap); widen explicitly: i64(c.r) + 1.
                if (ls == .narrow_int or rs2 == .narrow_int) return error.Unsupported;
                if (isFloatSc(ls) or isFloatSc(rs2)) {
                    if (ls != rs2) return error.Unsupported;
                    const float_ok = switch (op_tok.kind) {
                        .PLUS, .MINUS, .STAR, .SLASH, .EQ_EQ, .BANG_EQ, .L_ANGLE, .LT_EQ, .R_ANGLE, .GT_EQ => true,
                        else => false,
                    };
                    if (!float_ok) return error.Unsupported;
                }
            }
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
            // A builtin numeric cast (`f32(x)`, `f64(x)`, `i64(x)` —
            // spec/types.md §Casts): the only conversions; the source
            // must itself be numeric.
            if (castTarget(cname)) |ct| {
                var cit = cc.args();
                const a0 = cit.next() orelse return reject(b, .unsupported_call);
                if (cit.next() != null) return reject(b, .unsupported_call); // exactly one operand
                const src_sc = try exprScalar(b, a0, scope);
                if (src_sc == .bool or src_sc == .str) return error.Unsupported;
                out.* = .{ .num_cast = .{ .to = ct, .value = try buildIntExpr(b, a0, scope) } };
                return out;
            }
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
                            .i64, .bool, .f64, .f32 => {},
                            else => return reject(b, .unsupported_call),
                        }
                        const recv = try b.a.create(hir.Expr);
                        recv.* = .{ .local = .{ .idx = loc.idx, .ty = .ptr } };
                        out.* = .{ .call = .{ .func = fid, .args = try buildCallArgs(b, fid, cc.args(), scope, recv) } };
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
            // A generic callee in value position (`let n = count_of(xs)`):
            // monomorphize per the inferred element type, like the
            // statement form (B5). The stamped instance must produce a
            // scalar value here.
            if (b.resolver.lookup(cname)) |gfd| {
                if (gfd.isGeneric()) {
                    const ge = try buildGenericCall(b, cname, gfd, cc, scope);
                    switch (b.funcs.items[ge.call.func].ret) {
                        .i64, .bool, .f64, .f32 => {},
                        else => return reject(b, .unsupported_call),
                    }
                    return ge;
                }
            }
            const id = try registerFunc(b, cname);
            // An i64 or bool (i32 0/1) callee produces a value usable here; a
            // str or record callee does not belong in an i64/bool expression.
            switch (b.funcs.items[id].ret) {
                .i64, .bool, .f64, .f32 => {},
                else => return reject(b, .unsupported_call),
            }
            out.* = .{ .call = .{ .func = id, .args = try buildCallArgs(b, id, cc.args(), scope, null) } };
        },
        .field => |fe| {
            const fld = (fe.field() orelse return error.Unsupported).text;
            const fbase = fe.base() orelse return error.Unsupported;
            // A field on a record-valued *expression* (`cs[0].r`,
            // `make(1,2).x`): load through the value's address. Integer-
            // compute fields only (i64 + the narrow widths — they widen on
            // load); float/bool fields need the binding form until field
            // expressions are sema-typed.
            if (try buildRecExpr(b, fbase, scope)) |rv| {
                const f = rv.si.field(fld) orelse return error.Unsupported;
                const int_ok = switch (f.ty) {
                    .i64, .u8, .i8, .u16, .i16, .u32, .i32 => true,
                    else => false,
                };
                if (!int_ok) return error.Unsupported;
                out.* = .{ .field_get = .{ .base = rv.e, .offset = f.offset, .ty = f.ty } };
                return out;
            }
            // `s.len` — the byte length of a str value, as i64.
            if (!std.mem.eql(u8, fld, "len")) return error.Unsupported;
            const base = fbase;
            const sval = buildStrExpr(b, base, scope, null) catch |e| switch (e) {
                error.Unsupported => return error.Unsupported, // `.len` on a non-str
                else => return e,
            };
            out.* = .{ .str_len = sval };
        },
        .index => |ix| {
            // `xs[i]` on an array binding: a bounds-checked element load
            // (scalar elements only here; a record element is a value —
            // see buildRecExpr's index arm).
            const base = ix.base() orelse return error.Unsupported;
            if (base == .path) {
                const bn = try base.path.text(b.a);
                defer b.a.free(bn);
                if (scope.arrs.get(bn)) |ai| {
                    const ety = switch (ai.elem) {
                        .scalar => |t| t,
                        .rec => return error.Unsupported, // record value — not a scalar read
                    };
                    const idx = try buildIntExpr(b, ix.index() orelse return error.Unsupported, scope);
                    const eptr = try elemPtrExpr(b, ai, idx);
                    out.* = .{ .field_get = .{ .base = eptr, .offset = 0, .ty = ety } };
                    return out;
                }
            }
            // `s[i]` — the unsigned byte at index i of a str value, as i64.
            const sval = buildStrExpr(b, base, scope, null) catch |e| switch (e) {
                error.Unsupported => return error.Unsupported, // indexing a non-str
                else => return e,
            };
            const idx = try buildIntExpr(b, ix.index() orelse return error.Unsupported, scope);
            out.* = .{ .str_index = .{ .str = sval, .idx = idx } };
        },
        .method => |me| {
            const mname = (me.method() orelse return error.Unsupported).text;
            // B4: a method on a record-valued receiver *expression* —
            // `make(1, 2).area()`, `Point { x: 1, y: 2 }.norm()` — the
            // receiver's base pointer is the self argument directly (the
            // record lives in the scope arena either way).
            if (try buildRecExpr(b, me.receiver() orelse return error.Unsupported, scope)) |rv| {
                const fid = (try registerFitMethod(b, rv.si, mname)) orelse
                    return reject(b, .name_not_found);
                switch (b.funcs.items[fid].ret) {
                    .i64, .bool, .f64, .f32 => {},
                    else => return reject(b, .unsupported_call),
                }
                out.* = .{ .call = .{ .func = fid, .args = try buildCallArgs(b, fid, me.args(), scope, rv.e) } };
                return out;
            }
            // i64/bool str methods: `index_of(byte)` -> i64, `starts_with(p)` /
            // `contains(sub)` -> bool. (`slice` is str-valued — see buildStrExpr.)
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

test "B4: a str-returning fit method (Display.fmt) builds a concat over self" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src =
        \\face Display { fn fmt(self) -> str }
        \\
        \\struct Rect { w: i64, h: i64 }
        \\
        \\fit Rect : Display {
        \\    fn fmt(self) -> str { "Rect({self.w}x{self.h})" }
        \\}
        \\
        \\fn main {
        \\    let r = Rect { w: 6, h: 7 }
        \\    env.out(r.fmt())
        \\}
        \\
    ;
    var mod = (try buildLocal(testing.allocator, &tr, src)) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "fn Rect.fmt -> str") != null);
    // The body interpolates self's fields: fmt_int over field_get pieces.
    try testing.expect(std.mem.indexOf(u8, dump, "fmt_int(field_get(") != null);
    // main routes the call to the str path.
    try testing.expect(std.mem.indexOf(u8, dump, "host_out_str") != null);
}

test "B4: dispatch works on a record param inside a plain callee" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src =
        \\face Area { fn area(self) -> i64 }
        \\
        \\struct Rect { w: i64, h: i64 }
        \\
        \\fit Rect : Area { fn area(self) -> i64 { self.w * self.h } }
        \\
        \\fn describe(r: Rect) -> i64 { r.area() }
        \\
        \\fn main {
        \\    let r = Rect { w: 6, h: 7 }
        \\    env.out(describe(r))
        \\}
        \\
    ;
    var mod = (try buildLocal(testing.allocator, &tr, src)) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "fn describe -> i64") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "fn Rect.area -> i64") != null);
}

test "B4: a method on a receiver expression (call result / literal) dispatches" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src =
        \\face Area { fn area(self) -> i64 }
        \\
        \\struct Rect { w: i64, h: i64 }
        \\
        \\fit Rect : Area { fn area(self) -> i64 { self.w * self.h } }
        \\
        \\fn make(w: i64, h: i64) -> Rect { Rect { w: w, h: h } }
        \\
        \\fn main {
        \\    env.out(make(6, 7).area())
        \\    env.out((Rect { w: 3, h: 5 }).area())
        \\}
        \\
    ;
    var mod = (try buildLocal(testing.allocator, &tr, src)) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // Both receivers feed Rect.area directly: a call result and a fresh
    // record_alloc, each a `.ptr` value passed as `self`.
    try testing.expect(std.mem.indexOf(u8, dump, "fn Rect.area -> i64") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "record_alloc size=16 align=8") != null);
}

test "B4: fit-method calls inside interpolation (str and i64 pieces)" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src =
        \\face Display { fn fmt(self) -> str }
        \\face Area { fn area(self) -> i64 }
        \\face Label { fn label(self) -> str }
        \\
        \\struct Rect { w: i64, h: i64 }
        \\
        \\fit Rect : Display { fn fmt(self) -> str { "rgb({self.w}, {self.h})" } }
        \\fit Rect : Area { fn area(self) -> i64 { self.w * self.h } }
        \\fit Rect : Label { fn label(self) -> str { "{self.w}x{self.h} = {self.area()}" } }
        \\
        \\fn main {
        \\    let r = Rect { w: 6, h: 7 }
        \\    env.out("r is {r.fmt()} with area {r.area()}")
        \\    env.out("label: {r.label()}")
        \\}
        \\
    ;
    var mod = (try buildLocal(testing.allocator, &tr, src)) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // The interpolated method call materializes the receiver (escape via
    // the string-token scan) and shows up as a concat piece: the str
    // method directly, the i64 method wrapped in fmt_int.
    try testing.expect(std.mem.indexOf(u8, dump, "record_alloc size=16 align=8") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "fn Rect.fmt -> str") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "fn Rect.label -> str") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "fmt_int(call#") != null);
    // `{self.area()}` inside Label's body: a call piece in a callee concat.
    try testing.expect(std.mem.indexOf(u8, dump, "fn Rect.area -> i64") != null);
}

test "B4: plain field interpolation alone keeps SROA (no materialization)" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src =
        \\struct Point { x: i64, y: i64 }
        \\
        \\fn main {
        \\    let p = Point { x: 1, y: 2 }
        \\    env.out("p = ({p.x}, {p.y})")
        \\}
        \\
    ;
    var mod = (try buildLocal(testing.allocator, &tr, src)) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "record_alloc") == null);
}

test "f64: typed bindings, arithmetic, fields, fit methods, interpolation" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src =
        \\struct Vec2 { x: f64, y: f64 }
        \\face Norm { fn norm2(self) -> f64 }
        \\fit Vec2 : Norm { fn norm2(self) -> f64 { self.x * self.x + self.y * self.y } }
        \\
        \\fn scale(x: f64, k: f64) -> f64 { x * k }
        \\
        \\fn main {
        \\    let a = 1.5
        \\    var b = a * 2.0
        \\    b += 0.25
        \\    env.out(b)
        \\    env.out(scale(a, 4.0))
        \\    let v = Vec2 { x: 3.0, y: 4.0 }
        \\    env.out("norm2 = {v.norm2()}, x = {v.x}, a = {a}")
        \\}
        \\
    ;
    var mod = (try buildLocal(testing.allocator, &tr, src)) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "host_out_float") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "fn scale -> f64") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "fn Vec2.norm2 -> f64") != null);
    // f64 pieces format through __fmt_f64, fields load as f64.
    try testing.expect(std.mem.indexOf(u8, dump, "fmt_float(") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "field_get(") != null);
}

test "f64: no implicit conversion — mixed arithmetic and float `%` are Unsupported" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const mixed =
        \\fn main {
        \\    let a = 1.5
        \\    env.out(a + 1)
        \\}
        \\
    ;
    try tr.addLib(mixed);
    try testing.expect((try buildFromSource(testing.allocator, mixed, tr.resolver())) == null);

    var tr2 = TestResolver{ .a = testing.allocator };
    defer tr2.deinit();
    const frem =
        \\fn main {
        \\    let a = 7.5
        \\    env.out(a % 2.0)
        \\}
        \\
    ;
    try tr2.addLib(frem);
    try testing.expect((try buildFromSource(testing.allocator, frem, tr2.resolver())) == null);
}

test "f32: casts, arithmetic, 4-byte fields, fit methods, interpolation promote" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src =
        \\struct Sample { v: f32, gain: f32 }
        \\face Amp { fn amped(self) -> f32 }
        \\fit Sample : Amp { fn amped(self) -> f32 { self.v * self.gain } }
        \\
        \\fn mix(a: f32, b: f32) -> f32 { (a + b) / f32(2.0) }
        \\
        \\fn main {
        \\    let a = f32(1.5)
        \\    env.out(mix(a, f32(0.25)))
        \\    env.out(i64(2.75))
        \\    let s = Sample { v: f32(0.5), gain: f32(3.0) }
        \\    env.out("v = {s.v}, amped = {s.amped()}, a = {a}")
        \\}
        \\
    ;
    var mod = (try buildLocal(testing.allocator, &tr, src)) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "fn mix -> f32") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "fn Sample.amped -> f32") != null);
    // Casts print as their target (`f32(…)`); interpolation promotes
    // f32 pieces to f64 for the single __fmt_f64 formatter.
    try testing.expect(std.mem.indexOf(u8, dump, "f32(") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "fmt_float(f64(") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "i64(") != null);
}

test "f32: two f32 fields pack at 4/4 (size 8, align 4)" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src =
        \\struct Sample { v: f32, gain: f32 }
        \\fn get(s: Sample) -> f32 { s.gain }
        \\fn main {
        \\    let s = Sample { v: f32(0.5), gain: f32(3.0) }
        \\    env.out(get(s))
        \\}
        \\
    ;
    var mod = (try buildLocal(testing.allocator, &tr, src)) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "record_alloc size=8 align=4") != null);
    // `gain` sits at +4, loaded as f32.
    try testing.expect(std.mem.indexOf(u8, dump, "+4 : f32") != null);
}

test "f32: floats never mix — f32+f64, f32+int, and bool casts are Unsupported" {
    const cases = [_][]const u8{
        "fn main {\n    let a = f32(1.5)\n    env.out(a + 1.5)\n}\n",
        "fn main {\n    let a = f32(1.5)\n    env.out(a + 1)\n}\n",
        "fn main {\n    env.out(f32(true))\n}\n",
    };
    for (cases) |src| {
        var tr = TestResolver{ .a = testing.allocator };
        defer tr.deinit();
        try tr.addLib(src);
        try testing.expect((try buildFromSource(testing.allocator, src, tr.resolver())) == null);
    }
}

test "narrow ints: u8 fields store/load width-true; explicit widening composes" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src =
        \\struct Color { r: u8, g: u8, b: u8 }
        \\struct Mix { tag: i8, count: u16, id: u32 }
        \\
        \\fn sum_rg(c: Color) -> i64 { i64(c.r) + i64(c.g) }
        \\
        \\fn main {
        \\    let c = Color { r: 255, g: 128, b: 0 }
        \\    env.out(sum_rg(c))
        \\    var m = Mix { tag: -5, count: 65535, id: 4294967295 }
        \\    m.tag = -7
        \\    env.out("tag = {m.tag}, id = {m.id}")
        \\}
        \\
    ;
    var mod = (try buildLocal(testing.allocator, &tr, src)) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // Three u8s pack to 3 bytes at align 1; Mix is i8@0, u16@2, u32@4 → 8/4.
    try testing.expect(std.mem.indexOf(u8, dump, "record_alloc size=3 align=1") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "record_alloc size=8 align=4") != null);
    // Narrow reads format through fmt_int (the widened load).
    try testing.expect(std.mem.indexOf(u8, dump, "fmt_int(field_get(") != null);
}

test "narrow ints: range checks and the no-implicit-widening rule" {
    // Out of range for the width → the honest NotConstExpr.
    {
        var tr = TestResolver{ .a = testing.allocator };
        defer tr.deinit();
        const src =
            \\struct C { r: u8 }
            \\fn main {
            \\    let c = C { r: 256 }
            \\    env.out(c.r)
            \\}
            \\
        ;
        try tr.addLib(src);
        const r = try rejectFromSource(testing.allocator, src, tr.resolver());
        try testing.expectEqual(hir.Reject.not_const, r.?);
    }
    // Narrow arithmetic and narrow bindings need an explicit i64(...) cast.
    const unsupported = [_][]const u8{
        "struct C { r: u8 }\nfn main {\n    let c = C { r: 9 }\n    env.out(c.r + 1)\n}\n",
        "struct C { r: u8 }\nfn main {\n    let c = C { r: 9 }\n    let x = c.r\n    env.out(x)\n}\n",
    };
    for (unsupported) |src| {
        var tr = TestResolver{ .a = testing.allocator };
        defer tr.deinit();
        try tr.addLib(src);
        try testing.expect((try buildFromSource(testing.allocator, src, tr.resolver())) == null);
    }
}

test "arrays: literals, for-in desugar, trapping index, len, record elements" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src =
        \\struct Color { r: u8 }
        \\face D { fn fmt(self) -> str }
        \\fit Color : D { fn fmt(self) -> str { "c{self.r}" } }
        \\
        \\fn main {
        \\    let xs = [10, 20, 30]
        \\    env.out(xs.len)
        \\    env.out(xs[1])
        \\    var total = 0
        \\    for x in xs {
        \\        total = total + x
        \\    }
        \\    env.out(total)
        \\    let cs = [Color { r: 7 }, Color { r: 9 }]
        \\    for c in cs {
        \\        env.out(c.fmt())
        \\    }
        \\    env.out(cs[1].fmt())
        \\    env.out(i64(cs[0].r))
        \\}
        \\
    ;
    var mod = (try buildLocal(testing.allocator, &tr, src)) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // i64 elements: stride 8; record elements: inline copies at stride 1.
    try testing.expect(std.mem.indexOf(u8, dump, "array_lit stride=8 align=8 n=3") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "array_lit stride=1 align=1 n=2") != null);
    // xs.len folds to its compile-time count; xs[1] bounds-checks.
    try testing.expect(std.mem.indexOf(u8, dump, "host_out_int 3") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "bounds(") != null);
    // The for loop desugars to a while over the hidden index.
    try testing.expect(std.mem.indexOf(u8, dump, "while (local#") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "elem_ptr(") != null);
    // Record elements dispatch.
    try testing.expect(std.mem.indexOf(u8, dump, "fn Color.fmt -> str") != null);
}

test "arrays: mixed element types are Unsupported; empty literal too" {
    const cases = [_][]const u8{
        "fn main {\n    let xs = [1, 2.5]\n    env.out(xs.len)\n}\n",
        "fn main {\n    let xs = []\n    env.out(xs.len)\n}\n",
    };
    for (cases) |src| {
        var tr = TestResolver{ .a = testing.allocator };
        defer tr.deinit();
        try tr.addLib(src);
        try testing.expect((try buildFromSource(testing.allocator, src, tr.resolver())) == null);
    }
}

test "B5: the golden triangle — print_all<T: Display> stamps and runs" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src =
        \\pub face Display {
        \\    fn fmt(self) -> str @pure
        \\}
        \\
        \\pub struct Color { r: u8, g: u8, b: u8 }
        \\
        \\pub fit Color : Display {
        \\    fn fmt(self) -> str {
        \\        "rgb({self.r}, {self.g}, {self.b})"
        \\    }
        \\}
        \\
        \\pub fn print_all<T: Display>(items: [T]) {
        \\    for item in items {
        \\        env.out("{item.fmt()}")
        \\    }
        \\}
        \\
        \\fn main {
        \\    print_all([
        \\        Color { r: 255, g: 0,   b: 0   },
        \\        Color { r: 0,   g: 255, b: 0   },
        \\    ])
        \\}
        \\
    ;
    var mod = (try buildLocal(testing.allocator, &tr, src)) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // One stamped private instance, named per T; its [T] param is a
    // (ptr, count) pair; the fit method resolves inside the body.
    try testing.expect(std.mem.indexOf(u8, dump, "fn print_all<Color> -> void") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "fn Color.fmt -> str") != null);
    // main calls the instance as a void statement.
    try testing.expect(std.mem.indexOf(u8, dump, "expr call#") != null);
}

test "B5: two call sites with different T stamp two instances (dedup per T)" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src =
        \\face D { fn fmt(self) -> str }
        \\struct A { x: i64 }
        \\struct B { y: i64 }
        \\fit A : D { fn fmt(self) -> str { "A{self.x}" } }
        \\fit B : D { fn fmt(self) -> str { "B{self.y}" } }
        \\fn show_all<T: D>(items: [T]) {
        \\    for it in items {
        \\        env.out(it.fmt())
        \\    }
        \\}
        \\fn main {
        \\    show_all([A { x: 1 }])
        \\    show_all([B { y: 9 }])
        \\    show_all([A { x: 2 }])
        \\}
        \\
    ;
    var mod = (try buildLocal(testing.allocator, &tr, src)) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    var count_a: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, dump, at, "fn show_all<A> -> void")) |hit| {
        count_a += 1;
        at = hit + 1;
    }
    try testing.expectEqual(@as(usize, 1), count_a); // deduped per T
    try testing.expect(std.mem.indexOf(u8, dump, "fn show_all<B> -> void") != null);
}

test "B5: scalar element types stamp per type (each<i64>, each<f64>)" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src =
        \\fn each<T>(items: [T]) {
        \\    for x in items {
        \\        env.out("{x}")
        \\    }
        \\}
        \\fn main {
        \\    each([10, 20, 30])
        \\    each([1.5, 2.5])
        \\    each([40, 50])
        \\}
        \\
    ;
    var mod = (try buildLocal(testing.allocator, &tr, src)) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // One instance per scalar element type, deduped.
    var count_i64: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, dump, at, "fn each<i64> -> void")) |hit| {
        count_i64 += 1;
        at = hit + 1;
    }
    try testing.expectEqual(@as(usize, 1), count_i64);
    try testing.expect(std.mem.indexOf(u8, dump, "fn each<f64> -> void") != null);
}

test "B5: value-returning generic calls (tail expr, return, composition)" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src =
        \\fn count_of<T>(items: [T]) -> i64 {
        \\    items.len
        \\}
        \\fn total<T>(items: [T]) -> i64 {
        \\    var n = 0
        \\    for x in items {
        \\        n = n + x
        \\    }
        \\    return n
        \\}
        \\fn main {
        \\    env.out(count_of([1.5, 2.5]))
        \\    let n = total([10, 20, 30])
        \\    env.out(n + count_of([7, 8]))
        \\}
        \\
    ;
    var mod = (try buildLocal(testing.allocator, &tr, src)) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // Instances are stamped per element type with the declared value ret.
    try testing.expect(std.mem.indexOf(u8, dump, "fn count_of<f64> -> i64") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "fn count_of<i64> -> i64") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "fn total<i64> -> i64") != null);
}

test "B5: multiple type params stamp per (T, U) combination" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src =
        \\face D { fn fmt(self) -> str }
        \\struct A { x: i64 }
        \\struct B { y: i64 }
        \\fit A : D { fn fmt(self) -> str { "A{self.x}" } }
        \\fit B : D { fn fmt(self) -> str { "B{self.y}" } }
        \\fn both<T: D, U: D>(xs: [T], ys: [U]) {
        \\    for x in xs { env.out(x.fmt()) }
        \\    for y in ys { env.out(y.fmt()) }
        \\}
        \\fn zipped_count<T, U>(xs: [T], ys: [U]) -> i64 {
        \\    xs.len + ys.len
        \\}
        \\fn main {
        \\    both([A { x: 1 }], [B { y: 2 }])
        \\    both([B { y: 7 }], [A { x: 8 }])
        \\    env.out(zipped_count([1, 2], [1.5]))
        \\}
        \\
    ;
    var mod = (try buildLocal(testing.allocator, &tr, src)) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // Slot order is part of the instance identity.
    try testing.expect(std.mem.indexOf(u8, dump, "fn both<A, B> -> void") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "fn both<B, A> -> void") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "fn zipped_count<i64, f64> -> i64") != null);
}

test "B5: a multi-param bound rejects the non-fitting slot" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src =
        \\face D { fn fmt(self) -> str }
        \\struct A { x: i64 }
        \\struct NoFit { y: i64 }
        \\fit A : D { fn fmt(self) -> str { "A{self.x}" } }
        \\fn both<T: D, U: D>(xs: [T], ys: [U]) {
        \\    for x in xs { env.out(x.fmt()) }
        \\}
        \\fn main {
        \\    both([A { x: 1 }], [NoFit { y: 2 }])
        \\}
        \\
    ;
    try tr.addLib(src);
    const r = try rejectFromSource(testing.allocator, src, tr.resolver());
    try testing.expectEqual(hir.Reject.unsupported_call, r.?);
}

test "B5: a `-> T` generic return is honestly unsupported (needs by-value T)" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src =
        \\fn first<T>(items: [T]) -> T {
        \\    items[0]
        \\}
        \\fn main {
        \\    env.out(first([10, 20]))
        \\}
        \\
    ;
    try testing.expect((try buildLocal(testing.allocator, &tr, src)) == null);
}

test "B5: a scalar element type never satisfies a face bound" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src =
        \\face D { fn fmt(self) -> str }
        \\fn show_all<T: D>(items: [T]) {
        \\    for it in items {
        \\        env.out(it.fmt())
        \\    }
        \\}
        \\fn main {
        \\    show_all([1, 2])
        \\}
        \\
    ;
    try tr.addLib(src);
    const r = try rejectFromSource(testing.allocator, src, tr.resolver());
    try testing.expectEqual(hir.Reject.unsupported_call, r.?);
}

test "B5: an element type with no fit for the bound is UnsupportedCall" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src =
        \\face D { fn fmt(self) -> str }
        \\struct NoFit { x: i64 }
        \\fn show_all<T: D>(items: [T]) {
        \\    for it in items {
        \\        env.out(it.fmt())
        \\    }
        \\}
        \\fn main {
        \\    show_all([NoFit { x: 1 }])
        \\}
        \\
    ;
    try tr.addLib(src);
    const r = try rejectFromSource(testing.allocator, src, tr.resolver());
    try testing.expectEqual(hir.Reject.unsupported_call, r.?);
}
