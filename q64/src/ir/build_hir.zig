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
    /// Interned tuple layouts, keyed by element-type signature (e.g.
    /// "i64,i64"). A tuple is an anonymous record; interning makes the same
    /// tuple type share one `StructInfo` so a tuple arg matches a tuple param
    /// by pointer (the record-arg ABI compares `si` identity).
    tuple_sis: std.StringHashMapUnmanaged(*const StructInfo) = .empty,
    /// Actor declarations by name (concurrency v0). An actor is registered as a
    /// struct (its `state` fields) in `structs`; this map keeps the decl so a
    /// `c.handle(...)` dispatch can build the handler, and construction can
    /// fill `state` defaults.
    actor_decls: std.StringHashMapUnmanaged(ast.ActorDecl) = .empty,
    /// Graph declarations by name (Phase 4 v0). A `graph` runs eagerly as a
    /// function: its `let` stage bindings execute in order and the last binding
    /// is the pipeline's output. Kept so a `pipeline(args)` call can build it.
    graph_decls: std.StringHashMapUnmanaged(ast.GraphDecl) = .empty,
    /// This file's all-unit enum declarations (C1): a variant value is
    /// its declaration-order tag (an i64 at the compute floor).
    enums: std.StringHashMapUnmanaged(*const EnumInfo) = .empty,
    /// Generic-enum instantiations (`Option<str>`): "Name\x00key" →
    /// the resolved EnumInfo (key = one 'i'/'s' char per type param).
    /// The base registry entry IS the all-'i' instantiation.
    enum_insts: std.StringHashMapUnmanaged(*const EnumInfo) = .empty,
    /// The fit registry (sema/fits.zig) over this file — B4 static
    /// dispatch resolves `p.area()` through it. Arena-backed (never
    /// deinit'd separately).
    fitreg: ?sema.fits.Registry = null,
    /// FuncId → its record params/return, for functions with a record surface.
    fn_recs: std.AutoHashMapUnmanaged(hir.FuncId, FnRec) = .empty,
    /// Which of a function's parameters are `Vec<…>` (passed as a `.ptr`,
    /// like a record, but iterated/indexed as a vec). Parallel to the hir
    /// param list. Absent when the function has no vec params.
    fn_vec_params: std.AutoHashMapUnmanaged(hir.FuncId, []const bool) = .empty,
    /// Counter for hidden temp-vec names in iterator method chains
    /// (`xs.filter(…).map(…)` materializes the inner stage into `#chainN`).
    vec_tmp: u32 = 0,
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
    // Pass 0.55: register this file's all-unit enum declarations (C1) —
    // a variant value is its declaration-order tag. Enums with payload
    // variants are skipped (a *use* surfaces the honest Unsupported).
    try registerEnums(b, sf);
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

/// `let P { x, y } = rec` — single-level record destructuring. Stashes the
/// record's base pointer in a hidden local, then binds each named field to a
/// fresh local read from it. v0: i64 fields, plain (non-nested) field binders
/// — `x` binds the field to its own name, `x: other` renames. Emits its
/// statements into `out`; works in `main` and callee bodies alike.
fn buildRecordDestructure(b: *Builder, pat: ast.Pattern, init_expr: ast.Expr, scope: *Scope, out: *std.ArrayList(*hir.Stmt)) BuildError!void {
    const rv = (try buildRecExpr(b, init_expr, scope)) orelse return error.Unsupported;
    const base_idx = try declareBodyLocal(b, scope, "#destr", false, .ptr);
    const set = try b.a.create(hir.Stmt);
    set.* = .{ .let = .{ .idx = base_idx, .value = rv.e } };
    try out.append(b.a, set);

    var it = pat.recordFields();
    var any = false;
    while (it.next()) |fp| {
        any = true;
        const fname = (fp.name() orelse return error.Unsupported).text;
        // `x: <sub>` — only a plain ident rename is in v0 scope; a nested
        // pattern (`pos: Point { … }`, a literal) is deferred.
        const bind_name = if (fp.subPattern()) |sp| blk: {
            if (sp.kind() != .IDENT_PATTERN) return error.Unsupported;
            break :blk (sp.bindingName() orelse return error.Unsupported).text;
        } else fname;
        const fld = rv.si.field(fname) orelse return reject(b, .name_not_found);
        const fty: hir.Type = switch (fld.ty) {
            .i64, .bool, .f64, .f32 => fld.ty,
            else => return error.Unsupported, // narrow/str/record fields: later
        };
        const idx = try declareBodyLocal(b, scope, bind_name, false, fty);
        const base = try b.a.create(hir.Expr);
        base.* = .{ .local = .{ .idx = base_idx, .ty = .ptr } };
        const ld = try b.a.create(hir.Expr);
        ld.* = .{ .field_get = .{ .base = base, .offset = fld.offset, .ty = fty } };
        const st = try b.a.create(hir.Stmt);
        st.* = .{ .let = .{ .idx = idx, .value = ld } };
        try out.append(b.a, st);
    }
    if (!any) return error.Unsupported; // `P {}` binds nothing
}

/// `let (a, b) = (e1, e2)` — tuple-literal destructuring. q64 has no
/// first-class tuple value yet, so this is the parallel-binding form: the
/// right side must be a tuple *literal*, bound element-by-element to the left
/// side's ident sub-patterns. v0: i64/bool/float elements, ident binders,
/// matching arity. Emits its `let`s into `out`; works in main + callee bodies.
fn buildTupleDestructure(b: *Builder, pat: ast.Pattern, init_expr: ast.Expr, scope: *Scope, isVar: bool, out: *std.ArrayList(*hir.Stmt)) BuildError!void {
    // Count the left-side ident binders.
    var names: std.ArrayList([]const u8) = .empty;
    var pit = ast.PatternIter{ .children = pat.cst.children };
    while (pit.next()) |sp| {
        if (sp.kind() != .IDENT_PATTERN) return error.Unsupported; // `_`/nested: later
        try names.append(b.a, (sp.bindingName() orelse return error.Unsupported).text);
    }
    if (names.items.len == 0) return error.Unsupported;

    switch (init_expr) {
        // `let (a, b) = (e1, e2)` — parallel binding straight from the literal
        // (no tuple value materialized).
        .tuple => |tup| {
            var eit = tup.elements();
            for (names.items) |name| {
                const el = eit.next() orelse return error.Unsupported; // too few elements
                const sc = try exprScalar(b, el, scope);
                if (sc == .narrow_int or sc == .str) return error.Unsupported;
                const ty = scalarBindTy(sc);
                const value = try buildIntExpr(b, el, scope); // build before declaring
                const idx = try declareBodyLocal(b, scope, name, isVar, ty);
                const st = try b.a.create(hir.Stmt);
                st.* = .{ .let = .{ .idx = idx, .value = value } };
                try out.append(b.a, st);
            }
            if (eit.next() != null) return error.Unsupported; // too many elements
        },
        // `let (a, b) = t` — read the fields of a tuple *value* (an anonymous
        // record). Stash the base pointer, then load each slot.
        else => {
            const rv = (try buildRecExpr(b, init_expr, scope)) orelse return error.Unsupported;
            if (rv.si.fields.len != names.items.len) return error.Unsupported; // arity
            const base_idx = try declareBodyLocal(b, scope, "#tdes", false, .ptr);
            const set = try b.a.create(hir.Stmt);
            set.* = .{ .let = .{ .idx = base_idx, .value = rv.e } };
            try out.append(b.a, set);
            for (names.items, 0..) |name, i| {
                const fld = rv.si.fields[i];
                const fty: hir.Type = switch (fld.ty) {
                    .i64, .bool, .f64, .f32 => fld.ty,
                    else => return error.Unsupported,
                };
                const idx = try declareBodyLocal(b, scope, name, isVar, fty);
                const base = try b.a.create(hir.Expr);
                base.* = .{ .local = .{ .idx = base_idx, .ty = .ptr } };
                const ld = try b.a.create(hir.Expr);
                ld.* = .{ .field_get = .{ .base = base, .offset = fld.offset, .ty = fty } };
                const st = try b.a.create(hir.Stmt);
                st.* = .{ .let = .{ .idx = idx, .value = ld } };
                try out.append(b.a, st);
            }
        },
    }
}

/// Build one statement of `main`'s body, appending 0+ HIR statements to `out`.
/// Unlike a function body, `main` statements can write the host (`env.out`,
/// `qview.*`) and have no value/tail — so this handles the host shapes *and*
/// control flow, recursing into `while`/`if` bodies via `buildMainBlock`.
fn buildMainStmt(b: *Builder, stmt: ast.Stmt, scope: *Scope, rt: *RtMap, out: *std.ArrayList(*hir.Stmt)) BuildError!void {
    switch (stmt) {
        .let_stmt => |ls| {
            const init_expr = ls.initializer() orelse return error.Unsupported;
            const lpat = ls.pattern() orelse return error.Unsupported;
            // `let P { x, y } = rec` — single-level record destructuring.
            if (lpat.kind() == .RECORD_STRUCT_PATTERN) {
                return buildRecordDestructure(b, lpat, init_expr, scope, out);
            }
            // `let (a, b) = (e1, e2)` — tuple-literal destructuring.
            if (lpat.kind() == .TUPLE_PATTERN) {
                return buildTupleDestructure(b, lpat, init_expr, scope, ls.isVar(), out);
            }
            const nm = lpat.bindingName() orelse return error.Unsupported;
            // `let h = spawn { e }` — a task handle. On the v0 cooperative
            // floor (non-suspending tasks), the task runs to completion eagerly
            // and the handle holds its result; `h.await()` reads it.
            if (init_expr == .spawn) {
                return buildSpawnLet(b, init_expr.spawn, nm, ls.isVar(), scope, rt, out);
            }
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
            // C2: a value-`match` initializer (`let x = match l { … }`):
            // desugar into a hidden result local assigned per arm, then
            // bind the name reading it (the name is NOT in scope inside
            // the arms — an initializer can't see itself).
            if (init_expr == .match) {
                const mty = try matchValueTy(b, init_expr.match, scope);
                scope.next_idx = @intCast(b.cur_locals.items.len);
                const res_idx = try scope.declare("#mres", true, mty);
                try b.cur_locals.append(b.a, mty);
                try buildMatchInto(b, init_expr.match, scope, out, res_idx, mty);
                scope.next_idx = @intCast(b.cur_locals.items.len);
                const bidx = try scope.declare(nm.text, ls.isVar(), mty);
                try b.cur_locals.append(b.a, mty);
                const read = try b.a.create(hir.Expr);
                read.* = .{ .local = .{ .idx = res_idx, .ty = mty } };
                const bst = try b.a.create(hir.Stmt);
                bst.* = .{ .let = .{ .idx = bidx, .value = read } };
                try out.append(b.a, bst);
                return;
            }
            // Otherwise a runtime str binding (`let g = shout("hi")`): build
            // the str value and store its (ptr, len) into two new locals.
            if (init_expr == .string_lit or (try isStrCall(b, init_expr, scope)) or (try exprScalar(b, init_expr, scope)) == .str) {
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
                // Also visible in the scope (ptr at idx, len at idx+1 — the
                // str-binding convention) so the str-method forms (`s.len`,
                // `s[i]`, `s.contains(…)`) resolve through `strReceiver`.
                scope.next_idx = ptr_idx;
                _ = try scope.declare(nm.text, ls.isVar(), .str);
                const len_hidden = try std.fmt.allocPrint(b.a, "{s}#len", .{nm.text});
                _ = try scope.declare(len_hidden, false, .ptr);
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
            } else if (try tryVecFrom(b, init_expr, nm.text, ls.isVar(), scope, out)) {
                // `let v = Vec.from([…])` — handled (vec_new + pushes).
            } else if (try tryChannelNew(b, init_expr, nm.text, ls.isVar(), scope, out)) {
                // `let ch = channel(…)` — a Vec buffer + read cursor.
            } else if (try tryChannelRecv(b, init_expr, nm.text, ls.isVar(), scope, out)) {
                // `let v = ch.recv()` — buf[cursor]; cursor += 1.
            } else if (try tryVecMap(b, init_expr, nm.text, ls.isVar(), scope, out)) {
                // `let d = xs.map|filter(|x| …)` — handled (vec_new + pushes).
            } else if (try tryVecReduce(b, init_expr, nm.text, ls.isVar(), scope, out)) {
                // `let r = xs.reduce(init, |acc, x| …)` — handled (scalar fold).
            } else if (if (init_expr == .call or init_expr == .tuple or isBoxedVariantPath(b, init_expr)) try buildRecExpr(b, init_expr, scope) else null) |rv| {
                // `let p = make(3, 4)` / `let c = first([...])` — a
                // record-returning call (incl. a generic whose `-> T`
                // inferred to a record): bind the returned base pointer
                // (the record lives in the scope arena). Gated on `.call`
                // so a bare `let q = p` stays the documented
                // whole-record-copy rejection, not a silent alias.
                // `let t = (3, 4)` — a tuple literal is an anonymous record.
                try bindMainRecord(b, scope, nm.text, ls.isVar(), rv.e, rv.si, out);
                // A boxed-enum value: remember the enum for `match`.
                if (try enumOfExpr(b, scope, init_expr)) |info| {
                    try scope.enum_binds.put(b.a, nm.text, info);
                }
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
                // An enum-valued initializer (`var c = Color.Red`, or a
                // copy of another enum binding): remember the enum so
                // `match` resolves bare variant names against it.
                if (try enumOfExpr(b, scope, init_expr)) |info| {
                    try scope.enum_binds.put(b.a, nm.text, info);
                }
            }
        },
        .expr_stmt => |es| {
            const expr = es.expression() orelse return error.Unsupported;
            try buildMainExprStmt(b, expr, scope, rt, out);
        },
        .match_stmt => |ms| try buildMainMatch(b, ms, scope, rt, out),
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
            // C2: `x = match l { … }` — desugar the value match into
            // per-arm assignments of the target.
            if (rhs_ast == .match) {
                const mloc = scope.find(tname) orelse return error.Unsupported;
                if (!mloc.mutable) return reject(b, .immutable_assign);
                if (op.kind != .EQ) return error.Unsupported;
                if ((try matchValueTy(b, rhs_ast.match, scope)) != mloc.ty) return error.Unsupported;
                try buildMatchInto(b, rhs_ast.match, scope, out, mloc.idx, mloc.ty);
                return;
            }
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
            // `for i in lo..hi { … }` — a counted range loop.
            if (iter == .range) {
                try buildForRange(b, fs, iter.range, pat.text, scope, rt, out);
                return;
            }
            const iname = switch (iter) {
                .path => |p| try p.text(b.a),
                else => return error.Unsupported, // v0 iterates array bindings (ranges later)
            };
            defer b.a.free(iname);
            if (scope.vecs.contains(iname)) {
                try buildForVec(b, fs, iname, pat.text, scope, rt, out);
                return;
            }
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
            if (ws.ifLet()) |il| {
                try buildMainWhileLet(b, ws, il, scope, rt, out);
                return;
            }
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
        .scope_stmt => |ss| try buildScopeStmt(b, ss, scope, rt, out),
        .select_stmt => |sel| try buildSelectStmt(b, sel, scope, rt, out),
        else => return error.Unsupported,
    }
}

/// `select { v = ch.recv() -> body, … }` on the v0 cooperative floor: a
/// non-suspending first-ready-wins choice. Each arm's channel op is tested for
/// readiness (`recv`: the buffer has an unread element); the first ready arm
/// performs its op (binding the result) and runs its body. Lowers to an
/// if / else-if chain; if no arm is ready it falls through (a real suspending
/// select — park until one is ready — arrives with the scheduler). v0: `recv`
/// arms on channel bindings.
fn buildSelectStmt(b: *Builder, sel: ast.SelectStmt, scope: *Scope, rt: *RtMap, out: *std.ArrayList(*hir.Stmt)) BuildError!void {
    // A non-suspending select: append the first-ready-wins chain; it falls
    // through when no arm is ready (the scheduler adds parking via `any_ready`).
    const lowered = try lowerSelectArms(b, sel, scope, rt);
    if (lowered.chain) |c| try out.append(b.a, c);
}

/// Lower a `select`'s arms to a first-ready-wins if/else `chain` plus an
/// `any_ready` predicate (the OR of every arm's readiness). The static
/// `buildSelectStmt` uses only the chain (fall-through); the scheduler gates a
/// select block on `any_ready` so it parks until an arm is ready, then runs the
/// chain (which fires exactly one arm). recv/send arms on scope channels.
fn lowerSelectArms(b: *Builder, sel: ast.SelectStmt, scope: *Scope, rt: *RtMap) BuildError!struct { chain: ?*hir.Stmt, any_ready: ?*hir.Expr } {
    const Arm = struct { cond: *hir.Expr, body: *hir.Stmt, head: []const u8, is_recv: bool };
    var arms: std.ArrayList(Arm) = .empty;
    defer arms.deinit(b.a);

    var it = sel.arms();
    while (it.next()) |arm| {
        const op = arm.operation() orelse return error.Unsupported;
        const cc = switch (op) {
            .call => |x| x,
            else => return error.Unsupported,
        };
        const cname = (callPathName(b, cc)) orelse return error.Unsupported;
        defer b.a.free(cname);
        const dot = std.mem.lastIndexOfScalar(u8, cname, '.') orelse return error.Unsupported;
        const method = cname[dot + 1 ..];
        const head = scope.chans.getKey(cname[0..dot]) orelse return error.Unsupported; // stable key
        const loc = scope.find(head) orelse return error.Unsupported;

        // The arm's readiness test and its channel op (run when the arm wins).
        var cond: *hir.Expr = undefined;
        var items: std.ArrayList(*hir.Stmt) = .empty;
        const is_recv = std.mem.eql(u8, method, "recv");
        if (is_recv) {
            const cur_idx = scope.chans.get(head) orelse return error.Unsupported;
            // Readiness: cursor < vec_len(buffer).
            const curref = try b.a.create(hir.Expr);
            curref.* = .{ .local = .{ .idx = cur_idx, .ty = .i64 } };
            const bufref = try b.a.create(hir.Expr);
            bufref.* = .{ .local = .{ .idx = loc.idx, .ty = .ptr } };
            const lenx = try b.a.create(hir.Expr);
            lenx.* = .{ .vec_len = .{ .vec = bufref } };
            cond = try b.a.create(hir.Expr);
            cond.* = .{ .bin = .{ .kind = .lt, .lhs = curref, .rhs = lenx } };

            // Op: read the value (bind it, or discard), then bump the cursor.
            const buf2 = try b.a.create(hir.Expr);
            buf2.* = .{ .local = .{ .idx = loc.idx, .ty = .ptr } };
            const cur2 = try b.a.create(hir.Expr);
            cur2.* = .{ .local = .{ .idx = cur_idx, .ty = .i64 } };
            const get = try b.a.create(hir.Expr);
            get.* = .{ .vec_get = .{ .vec = buf2, .idx = cur2 } };
            if (arm.binding()) |p| {
                if (p.kind() == .IDENT_PATTERN) {
                    const vn = (p.bindingName() orelse return error.Unsupported).text;
                    const v_idx = try declareBodyLocal(b, scope, vn, false, .i64);
                    const bind = try b.a.create(hir.Stmt);
                    bind.* = .{ .let = .{ .idx = v_idx, .value = get } };
                    try items.append(b.a, bind);
                }
                // `_ = ch.recv()` discards the value; the cursor bump consumes it.
            }
            // cursor += 1
            const cur3 = try b.a.create(hir.Expr);
            cur3.* = .{ .local = .{ .idx = cur_idx, .ty = .i64 } };
            const one = try b.a.create(hir.Expr);
            one.* = .{ .int_const = 1 };
            const inc = try b.a.create(hir.Expr);
            inc.* = .{ .bin = .{ .kind = .add, .lhs = cur3, .rhs = one } };
            const setc = try b.a.create(hir.Stmt);
            setc.* = .{ .assign = .{ .idx = cur_idx, .value = inc } };
            try items.append(b.a, setc);
        } else if (std.mem.eql(u8, method, "send")) {
            // A `send` arm: `ch.send(x) -> body`. Its readiness is "the buffer
            // has room": always-ready on an unbounded channel (`true`), or the
            // backpressure predicate (`vec_len - cursor < capacity`) on a bounded
            // one — so a parking select waits when every send arm is full. The op
            // is a `vec_push`; a send arm binds nothing.
            if (arm.binding() != null) return error.Unsupported;
            var ait = cc.args();
            const a0 = ait.next() orelse return error.Unsupported;
            if (ait.next() != null) return error.Unsupported; // v0: one value per send
            cond = (try chanSendReadyCond(b, scope, head)) orelse blk: {
                const t = try b.a.create(hir.Expr);
                t.* = .{ .bool_const = true };
                break :blk t;
            };
            const bufp = try b.a.create(hir.Expr);
            bufp.* = .{ .local = .{ .idx = loc.idx, .ty = .ptr } };
            const push = try b.a.create(hir.Stmt);
            push.* = .{ .vec_push = .{ .vec = bufp, .value = try buildIntExpr(b, a0, scope) } };
            try items.append(b.a, push);
        } else return error.Unsupported; // v0: recv / send arms
        // The user body (block or trailing expression). Built with the callee
        // (void) or main statement builder per the scope context, so a select in
        // a scheduled task works in a function body as well as in `main`.
        if (arm.block()) |blk| {
            var bit = blk.statements();
            while (bit.next()) |bstmt| {
                if (scope.callee) try buildVoidStmt(b, bstmt, scope, &items) else try buildMainStmt(b, bstmt, scope, rt, &items);
            }
        } else if (arm.bodyExpr()) |be| {
            if (scope.callee) try buildVoidExprStmt(b, be, scope, &items) else try buildMainExprStmt(b, be, scope, rt, &items);
        }
        const body = try b.a.create(hir.Stmt);
        body.* = .{ .block = try items.toOwnedSlice(b.a) };
        try arms.append(b.a, .{ .cond = cond, .body = body, .head = head, .is_recv = is_recv });
    }

    // Fold back-to-front into an if / else-if chain; no else (a non-suspending
    // select falls through when no arm is ready — the scheduler adds parking).
    var chain: ?*hir.Stmt = null;
    var i = arms.items.len;
    while (i > 0) {
        i -= 1;
        var else_part = chain;
        if (else_part) |ep| if (ep.* == .if_) {
            const wrap = try b.a.create(hir.Stmt);
            wrap.* = .{ .block = try b.a.dupe(*hir.Stmt, &.{ep}) };
            else_part = wrap;
        };
        const st = try b.a.create(hir.Stmt);
        st.* = .{ .if_ = .{ .cond = arms.items[i].cond, .then_ = arms.items[i].body, .else_ = else_part } };
        chain = st;
    }
    // `any_ready` = OR of every arm's readiness (built fresh — a recv arm's is
    // `cursor < len`, a send arm's is the room test, `true` when unbounded), the
    // scheduler's park predicate.
    var any_ready: ?*hir.Expr = null;
    for (arms.items) |a| {
        const r = if (a.is_recv) try chanReadyCond(b, scope, a.head) else (try chanSendReadyCond(b, scope, a.head)) orelse blk: {
            const t = try b.a.create(hir.Expr);
            t.* = .{ .bool_const = true };
            break :blk t;
        };
        any_ready = if (any_ready) |acc| try mkLogicalE(b, .or_, acc, r) else r;
    }
    return .{ .chain = chain, .any_ready = any_ready };
}

/// `let h = spawn { stmts; tail }` — bind a task handle. v0 cooperative floor:
/// a task that does not itself suspend runs to completion eagerly, so the
/// handle is simply its result value (read back by `h.await()`). The body is
/// lowered as a value block — leading statements run for effect (they may
/// declare locals the tail reads), and the tail expression is the handle's
/// value. (`spawn scope`, str/record results, and true deferral arrive with
/// the CPS transform.)
fn buildSpawnLet(b: *Builder, sp: ast.SpawnExpr, nm: parser.cst.Token, is_var: bool, scope: *Scope, rt: *RtMap, out: *std.ArrayList(*hir.Stmt)) BuildError!void {
    const sbody = sp.block() orelse return error.Unsupported; // spawn scope: later
    var stmts: std.ArrayList(ast.Stmt) = .empty;
    defer stmts.deinit(b.a);
    var it = sbody.statements();
    while (it.next()) |s| try stmts.append(b.a, s);
    if (stmts.items.len == 0) return error.Unsupported; // `spawn {}` isn't a value
    // Leading statements run for effect; the last must be a value expression.
    for (stmts.items[0 .. stmts.items.len - 1]) |s| try buildMainStmt(b, s, scope, rt, out);
    const e = switch (stmts.items[stmts.items.len - 1]) {
        .expr_stmt => |es| es.expression() orelse return error.Unsupported,
        else => return error.Unsupported,
    };
    const sc = try exprScalar(b, e, scope);
    if (sc == .narrow_int or sc == .str) return error.Unsupported; // str/record handles: later
    const ty = scalarBindTy(sc);
    scope.next_idx = @intCast(b.cur_locals.items.len);
    const value = try buildIntExpr(b, e, scope);
    const idx = try scope.declare(nm.text, is_var, ty);
    try b.cur_locals.append(b.a, ty);
    const st = try b.a.create(hir.Stmt);
    st.* = .{ .let = .{ .idx = idx, .value = value } };
    try out.append(b.a, st);
}

/// If `stmt` is a statement-position `spawn …`, its spawn expression (the
/// fire-and-forget task). Covers both `spawn { block }` and the `spawn scope
/// { … }` sugar.
fn spawnExprOf(stmt: ast.Stmt) ?ast.SpawnExpr {
    const es = switch (stmt) {
        .expr_stmt => |e| e,
        else => return null,
    };
    const expr = es.expression() orelse return null;
    return switch (expr) {
        .spawn => |s| s,
        else => null,
    };
}

/// The scope channel a top-level statement targets with `method`
/// (`"recv"`/`"send"`) — `let v = ch.recv()`, `_ = ch.recv()`, or
/// `ch.send(x)` — or null. The returned slice is the stable `scope.chans`
/// key (the channel binding's name, source-lived), safe to retain in a set.
/// Only the v0 single-call producer/consumer shapes are recognized; a `recv`
/// buried in a `select` or a nested block is not (such a task runs
/// eager-at-spawn, the existing behavior).
fn stmtChanTarget(b: *Builder, stmt: ast.Stmt, scope: *Scope, method: []const u8) ?[]const u8 {
    const e: ast.Expr = switch (stmt) {
        .let_stmt => |ls| ls.initializer() orelse return null,
        .expr_stmt => |es| es.expression() orelse return null,
        else => return null,
    };
    const cc = switch (e) {
        .call => |x| x,
        else => return null,
    };
    const cname = callPathName(b, cc) orelse return null;
    defer b.a.free(cname);
    const dot = std.mem.lastIndexOfScalar(u8, cname, '.') orelse return null;
    if (!std.mem.eql(u8, cname[dot + 1 ..], method)) return null;
    return scope.chans.getKey(cname[0..dot]);
}

/// True if the spawned task `sp` does a `recv` on a scope channel that has
/// **no pending sends yet** (`sent`). On the v0 cooperative floor that recv
/// reads an empty buffer and traps, so such a task must be deferred to the
/// scope join — where a producer emitted later in the scope has filled the
/// channel. A recv whose channel is already covered does not block, so its
/// task still runs eager-at-spawn (unchanged behavior).
fn taskWouldBlock(b: *Builder, sp: ast.SpawnExpr, scope: *Scope, sent: *const std.StringHashMapUnmanaged(void)) bool {
    const body = sp.block() orelse return false;
    var it = body.statements();
    while (it.next()) |stmt| {
        if (stmtChanTarget(b, stmt, scope, "recv")) |c| {
            if (!sent.contains(c)) return true;
        }
    }
    return false;
}

/// Record (into `sent`) every scope channel the spawned task `sp` sends to,
/// so a later consumer can tell its producer has already been emitted.
fn recordTaskSends(b: *Builder, sp: ast.SpawnExpr, scope: *Scope, sent: *std.StringHashMapUnmanaged(void)) BuildError!void {
    const body = sp.block() orelse return;
    var it = body.statements();
    while (it.next()) |stmt| {
        if (stmtChanTarget(b, stmt, scope, "send")) |c| try sent.put(b.a, c, {});
    }
}

/// Emit one spawned task's body inline at the current point (main position):
/// either a `spawn { block }` (its statements) or `spawn scope { … }` (the
/// nested scope). Shared by the eager-at-spawn pass and the deferred-join pass.
fn emitSpawnTaskMain(b: *Builder, sp: ast.SpawnExpr, scope: *Scope, rt: *RtMap, out: *std.ArrayList(*hir.Stmt)) BuildError!void {
    if (sp.block()) |body| {
        var bit = body.statements();
        while (bit.next()) |bstmt| try buildMainStmt(b, bstmt, scope, rt, out);
    } else if (sp.scopeStmt()) |inner| {
        try buildScopeStmt(b, inner, scope, rt, out);
    } else return error.Unsupported;
}

// ─── Runtime cooperative scheduler (cyclic tasks) ───────────────────────────
//
// Static ordering (eager-at-spawn + the consumer-before-producer deferral)
// covers acyclic task graphs. A *cyclic* dependency — task P sends on `a` then
// recvs on `b`, task Q recvs on `a` then sends on `b` — has no valid static
// order: P must run up to its `b.recv()`, suspend, let Q produce, then resume.
// On the cooperative floor (no stack switching) this is a per-task **state
// machine** driven by a round-robin loop, all in one function frame:
//
//   let pc0 = 0; let pc1 = 0; let prog = 1
//   while ((pc0 < N0 or pc1 < N1) and prog == 1) {
//       prog = 0
//       if (pc0 == 0)              { <seg>; pc0 = 1; prog = 1 }   // run a step
//       if (pc0 == 1 and b_ready)  { r = b.recv(); pc0 = 2; prog = 1 }  // suspend pt
//       if (pc0 == 2)              { env.out(r); pc0 = 3; prog = 1 }
//       … task 1 …
//   }
//
// Each task lowers to a tiny CFG of pc-numbered blocks (`SchedBlock`): a plain
// run, a `recv` suspend point (gated `pc == id and <buffer non-empty>`), or a
// counted `for` loop (a branch head + a back-edge that increments the counter
// and jumps back — so a `recv` *inside* a loop is a real suspend point, which
// is the request/reply streaming shape). Because the whole loop is one frame
// and pc-gating runs each block at the right time, task locals persist
// naturally as ordinary locals — no closure box, funcref, or hoisting. `prog`
// is the **deadlock guard**: a full round with no advance means every task is
// blocked forever, so the loop exits (v0: incomplete tasks just stop).
//
// v0 boundaries: main-position scopes; task bodies of straight-line statements
// + one level of counted `for i in lo..hi` loops (no nested loops, no `if`);
// `let v = ch.recv()` recvs; i64 channels. The gate (`scopeNeedsScheduler`) is
// deliberately narrow so only genuinely cyclic programs — which the static path
// can't compile anyway — are routed here.

/// A `let v = ch.recv()` step on a scope channel: the channel head, the result
/// binding name, and the `ch.recv()` call expression (for `tryChannelRecv`).
const RecvStep = struct { chan: []const u8, name: []const u8, call: ast.Expr };

/// `let x = channel(...)` → the binding name (a stable, source-lived slice).
fn channelDeclName(b: *Builder, stmt: ast.Stmt) ?[]const u8 {
    const ls = switch (stmt) {
        .let_stmt => |x| x,
        else => return null,
    };
    const init = ls.initializer() orelse return null;
    const cc = switch (init) {
        .call => |x| x,
        else => return null,
    };
    const cn = callPathName(b, cc) orelse return null;
    defer b.a.free(cn);
    if (!std.mem.eql(u8, cn, "channel")) return null;
    const pat = ls.pattern() orelse return null;
    const nm = pat.bindingName() orelse return null;
    return nm.text;
}

/// A `recv` on a channel in `chans` — `let v = ch.recv()`, the discard form
/// `let _ = ch.recv()`, or a bare statement `ch.recv()` (also a discard). The
/// discard forms bind the sentinel name `"_"` (which lowering reads as "consume
/// the value, don't bind it"). Returns null if it isn't a scope-channel recv.
fn recvStepOf(b: *Builder, stmt: ast.Stmt, chans: *const std.StringHashMapUnmanaged(void)) ?RecvStep {
    // The recv call expression + the binding name (or "_" for a discard).
    const init: ast.Expr, const name: []const u8 = switch (stmt) {
        .let_stmt => |ls| blk: {
            const i = ls.initializer() orelse return null;
            const pat = ls.pattern() orelse return null;
            const nm: []const u8 = if (pat.kind() == .WILD_PATTERN) "_" else (pat.bindingName() orelse return null).text;
            break :blk .{ i, nm };
        },
        .expr_stmt => |es| .{ es.expression() orelse return null, "_" }, // bare `ch.recv()` — discard
        else => return null,
    };
    const cc = switch (init) {
        .call => |x| x,
        else => return null,
    };
    const cn = callPathName(b, cc) orelse return null;
    defer b.a.free(cn);
    const dot = std.mem.lastIndexOfScalar(u8, cn, '.') orelse return null;
    if (!std.mem.eql(u8, cn[dot + 1 ..], "recv")) return null;
    const key = chans.getKey(cn[0..dot]) orelse return null;
    return .{ .chan = key, .name = name, .call = init };
}

/// `ch.send(x)` statement on a channel in `chans`, or null.
fn sendStepChan(b: *Builder, stmt: ast.Stmt, chans: *const std.StringHashMapUnmanaged(void)) ?[]const u8 {
    const es = switch (stmt) {
        .expr_stmt => |x| x,
        else => return null,
    };
    const e = es.expression() orelse return null;
    const cc = switch (e) {
        .call => |x| x,
        else => return null,
    };
    const cn = callPathName(b, cc) orelse return null;
    defer b.a.free(cn);
    const dot = std.mem.lastIndexOfScalar(u8, cn, '.') orelse return null;
    if (!std.mem.eql(u8, cn[dot + 1 ..], "send")) return null;
    return chans.getKey(cn[0..dot]);
}

/// `let x = SomeActor {}` where `SomeActor` is a declared actor → the binding
/// name, else null. Used to collect a scope's actor instances so handler calls
/// (`tell`/`ask`) on them are accepted as cooperative steps inside scheduled
/// tasks (the actor's state is shared; the handler runs synchronously — the
/// suspension on the cooperative floor comes from the task's channel ops).
fn actorBindingOf(b: *Builder, stmt: ast.Stmt) ?[]const u8 {
    const ls = switch (stmt) {
        .let_stmt => |x| x,
        else => return null,
    };
    const init = ls.initializer() orelse return null;
    const re = switch (init) {
        .record => |x| x,
        else => return null,
    };
    const tyname = (re.path() orelse return null).text(b.a) catch return null;
    defer b.a.free(tyname);
    if (!b.actor_decls.contains(tyname)) return null;
    const nm = (ls.pattern() orelse return null).bindingName() orelse return null;
    return nm.text;
}

/// True if `stmt` is a handler call on a scope actor — `a.h(args)` (a `tell`) or
/// `let r = a.h(args)` (an `ask`), with `a` in `actors`.
fn isActorCall(b: *Builder, stmt: ast.Stmt, actors: *const std.StringHashMapUnmanaged(void)) bool {
    const cc: ast.CallExpr = switch (stmt) {
        .expr_stmt => |es| switch (es.expression() orelse return false) {
            .call => |c| c,
            else => return false,
        },
        .let_stmt => |ls| switch (ls.initializer() orelse return false) {
            .call => |c| c,
            else => return false,
        },
        else => return false,
    };
    const cn = callPathName(b, cc) orelse return false;
    defer b.a.free(cn);
    const dot = std.mem.lastIndexOfScalar(u8, cn, '.') orelse return false;
    return actors.contains(cn[0..dot]);
}

/// What a task-body scan found: whether it sends / recvs on scope channels, and
/// whether any `recv` sits **inside control flow** (a loop or `if`). The static
/// path only detects top-level recvs, so a recv-in-control task must go to the
/// scheduler even when it isn't part of a mutual cycle.
const TaskScan = struct { sends: bool = false, recvs: bool = false, recv_in_ctrl: bool = false, send_bounded: bool = false };

/// Recursively check a task body is schedulable, filling `scan`. Schedulable
/// forms: `let v = ch.recv()`, `ch.send(e)`, `env.out(e)`, a non-call `let`, an
/// assignment, a counted `for i in lo..hi`, a `while`, and an `if`/`else` chain
/// (bodies recurse). `loop_depth` caps loop nesting (v0: one level — a nested
/// loop's counter would need a per-entry reset the pre-init can't give it);
/// `in_ctrl` marks that we're inside a loop/`if` body. Any other statement →
/// not schedulable (fall back to the static path).
fn taskSchedulable(b: *Builder, body: ast.Block, chans: *const std.StringHashMapUnmanaged(void), bounded: *const std.StringHashMapUnmanaged(void), actors: *const std.StringHashMapUnmanaged(void), scan: *TaskScan, loop_depth: usize, in_ctrl: bool) bool {
    var it = body.statements();
    while (it.next()) |stmt| {
        if (recvStepOf(b, stmt, chans) != null) {
            scan.recvs = true;
            if (in_ctrl) scan.recv_in_ctrl = true;
            continue;
        }
        if (sendStepChan(b, stmt, chans)) |ch| {
            scan.sends = true;
            if (bounded.contains(ch)) scan.send_bounded = true;
            continue;
        }
        // A `tell`/`ask` on a scope actor is a synchronous cooperative step
        // (`a.bump()` / `let r = a.get()`): the handler runs to completion at the
        // call site against the shared state record, so it lowers like any plain
        // statement. This lets a task that both blocks on channels and talks to
        // an actor be scheduled (a synchronous ask alone never forces the loop).
        if (isActorCall(b, stmt, actors)) continue;
        switch (stmt) {
            .expr_stmt => |es| {
                const e = es.expression() orelse return false;
                const cc = switch (e) {
                    .call => |x| x,
                    else => return false,
                };
                if (!isEnvOut(b.a, cc)) return false; // other calls aren't v0
            },
            .let_stmt => |ls| {
                const init = ls.initializer() orelse return false;
                if (init == .call) return false; // a non-recv call init: not v0
            },
            .assign_stmt => {}, // `x = e` — a plain step (mutates a task local)
            .for_stmt => |fs| {
                if (loop_depth != 0) return false; // v0: no nested loops in a task
                const iter = fs.iterable() orelse return false;
                if (iter != .range) return false; // counted ranges only
                const fb = fs.body() orelse return false;
                if (!taskSchedulable(b, fb, chans, bounded, actors, scan, loop_depth + 1, true)) return false;
            },
            .while_stmt => |ws| {
                if (loop_depth != 0) return false; // v0: no nested loops
                if (ws.ifLet() != null) return false; // `while let`: later
                const wb = ws.body() orelse return false;
                if (!taskSchedulable(b, wb, chans, bounded, actors, scan, loop_depth + 1, true)) return false;
            },
            .if_stmt => |ifs| {
                if (!ifStmtSchedulable(b, ifs, chans, bounded, actors, scan, loop_depth)) return false;
            },
            .select_stmt => |sel| {
                if (!selectSchedulable(b, sel, chans, bounded, scan)) return false;
                scan.recv_in_ctrl = true; // a select parks → route to the scheduler
            },
            else => return false, // other control flow in a task: v0
        }
    }
    return true;
}

/// A `select` in a task: every arm must be a `recv`/`send` on a scope channel.
/// Records the send/recv signal; the arm bodies are lowered later (v0: simple).
fn selectSchedulable(b: *Builder, sel: ast.SelectStmt, chans: *const std.StringHashMapUnmanaged(void), bounded: *const std.StringHashMapUnmanaged(void), scan: *TaskScan) bool {
    var it = sel.arms();
    var n: usize = 0;
    while (it.next()) |arm| {
        n += 1;
        const op = arm.operation() orelse return false;
        const cc = switch (op) {
            .call => |x| x,
            else => return false,
        };
        const cn = callPathName(b, cc) orelse return false;
        defer b.a.free(cn);
        const dot = std.mem.lastIndexOfScalar(u8, cn, '.') orelse return false;
        const head = cn[0..dot];
        if (!chans.contains(head)) return false;
        const method = cn[dot + 1 ..];
        if (std.mem.eql(u8, method, "recv")) {
            scan.recvs = true;
        } else if (std.mem.eql(u8, method, "send")) {
            scan.sends = true;
            if (bounded.contains(head)) scan.send_bounded = true;
        } else return false;
    }
    return n > 0;
}

/// An `if`/`else`/`else if` chain in a task: each branch body must itself be
/// schedulable (and is `in_ctrl`). `if let` is rejected (a later slice).
fn ifStmtSchedulable(b: *Builder, ifs: ast.IfStmt, chans: *const std.StringHashMapUnmanaged(void), bounded: *const std.StringHashMapUnmanaged(void), actors: *const std.StringHashMapUnmanaged(void), scan: *TaskScan, loop_depth: usize) bool {
    if (ifs.ifLet() != null) return false;
    const tb = ifs.thenBody() orelse return false;
    if (!taskSchedulable(b, tb, chans, bounded, actors, scan, loop_depth, true)) return false;
    if (ifs.elseBody()) |eb| return taskSchedulable(b, eb, chans, bounded, actors, scan, loop_depth, true);
    if (ifs.elseIf()) |ei| return ifStmtSchedulable(b, ei, chans, bounded, actors, scan, loop_depth);
    return true; // no else
}

/// `let x = channel(capacity: N)` → N, or null (not a channel decl, or no
/// capacity argument — an unbounded channel).
fn channelDeclCap(b: *Builder, stmt: ast.Stmt) ?i64 {
    const ls = switch (stmt) {
        .let_stmt => |x| x,
        else => return null,
    };
    const init = ls.initializer() orelse return null;
    const cc = switch (init) {
        .call => |x| x,
        else => return null,
    };
    const cn = callPathName(b, cc) orelse return null;
    defer b.a.free(cn);
    if (!std.mem.eql(u8, cn, "channel")) return null;
    return channelCapOf(cc);
}

/// Read-only gate: does this scope need the runtime scheduler (rather than the
/// static eager/deferred path)? True iff every non-spawn statement is a channel
/// decl, every spawned task is schedulable, there are ≥2 tasks, and at least
/// one task either **both sends and recvs** (the mutual-wait cycle), has a
/// `recv` inside control flow (which the static path can't lower — it only sees
/// top-level recvs), or **sends on a bounded channel** (whose `send` may need to
/// park on a full buffer — backpressure the static path ignores). Each condition
/// only holds for programs the static path can't serve, so no currently-static
/// program is routed here.
fn scopeNeedsScheduler(b: *Builder, blk: ast.Block, scope: *Scope) bool {
    var chans: std.StringHashMapUnmanaged(void) = .empty;
    defer chans.deinit(b.a);
    var bounded: std.StringHashMapUnmanaged(void) = .empty;
    defer bounded.deinit(b.a);
    var actors: std.StringHashMapUnmanaged(void) = .empty;
    defer actors.deinit(b.a);
    var it = blk.statements();
    while (it.next()) |stmt| {
        if (channelDeclName(b, stmt)) |nm| {
            chans.put(b.a, nm, {}) catch return false;
            if (channelDeclCap(b, stmt) != null) bounded.put(b.a, nm, {}) catch return false;
        } else if (actorBindingOf(b, stmt)) |nm| {
            // Actor instances are built (a state record) only in `main`-position
            // scopes — the callee scheduler can't build records yet (v0).
            if (scope.callee) return false;
            actors.put(b.a, nm, {}) catch return false;
        }
    }
    var ntasks: usize = 0;
    var needs = false;
    it = blk.statements();
    while (it.next()) |stmt| {
        if (spawnExprOf(stmt)) |sp| {
            const body = sp.block() orelse return false; // `spawn scope`: not v0-schedulable
            ntasks += 1;
            var scan: TaskScan = .{};
            if (!taskSchedulable(b, body, &chans, &bounded, &actors, &scan, 0, false)) return false;
            if ((scan.sends and scan.recvs) or scan.recv_in_ctrl or scan.send_bounded) needs = true;
        } else if (channelDeclName(b, stmt) == null and actorBindingOf(b, stmt) == null) {
            return false; // a non-spawn, non-channel-decl, non-actor statement: stay static
        }
    }
    return ntasks >= 2 and needs;
}

fn mkLocalE(b: *Builder, idx: u32, ty: hir.Type) BuildError!*hir.Expr {
    const e = try b.a.create(hir.Expr);
    e.* = .{ .local = .{ .idx = idx, .ty = ty } };
    return e;
}
fn mkIntE(b: *Builder, v: i64) BuildError!*hir.Expr {
    const e = try b.a.create(hir.Expr);
    e.* = .{ .int_const = v };
    return e;
}
fn mkBinE(b: *Builder, kind: ops.BinKind, lhs: *hir.Expr, rhs: *hir.Expr) BuildError!*hir.Expr {
    const e = try b.a.create(hir.Expr);
    e.* = .{ .bin = .{ .kind = kind, .lhs = lhs, .rhs = rhs } };
    return e;
}
fn mkLogicalE(b: *Builder, op: ops.LogicalKind, lhs: *hir.Expr, rhs: *hir.Expr) BuildError!*hir.Expr {
    const e = try b.a.create(hir.Expr);
    e.* = .{ .logical = .{ .op = op, .lhs = lhs, .rhs = rhs } };
    return e;
}
fn mkAssignS(b: *Builder, idx: u32, value: *hir.Expr) BuildError!*hir.Stmt {
    const s = try b.a.create(hir.Stmt);
    s.* = .{ .assign = .{ .idx = idx, .value = value } };
    return s;
}

/// Channel readiness: `cursor < vec_len(buffer)` (the buffer has an unread
/// element) — the `recv` suspend test.
fn chanReadyCond(b: *Builder, scope: *Scope, chan: []const u8) BuildError!*hir.Expr {
    const cur_idx = scope.chans.get(chan) orelse return error.Unsupported;
    const loc = scope.find(chan) orelse return error.Unsupported;
    const cur = try mkLocalE(b, cur_idx, .i64);
    const buf = try mkLocalE(b, loc.idx, .ptr);
    const len = try b.a.create(hir.Expr);
    len.* = .{ .vec_len = .{ .vec = buf } };
    return mkBinE(b, .lt, cur, len);
}

/// Send readiness for a channel: `vec_len(buffer) - cursor < capacity` (the
/// buffer has room for another element) — the `send` suspend test. Returns
/// `null` for an unbounded channel (a send is then always ready, no gate).
fn chanSendReadyCond(b: *Builder, scope: *Scope, chan: []const u8) BuildError!?*hir.Expr {
    const cap = scope.chan_caps.get(chan) orelse return null;
    const cur_idx = scope.chans.get(chan) orelse return error.Unsupported;
    const loc = scope.find(chan) orelse return error.Unsupported;
    const buf = try mkLocalE(b, loc.idx, .ptr);
    const len = try b.a.create(hir.Expr);
    len.* = .{ .vec_len = .{ .vec = buf } };
    const unread = try mkBinE(b, .sub, len, try mkLocalE(b, cur_idx, .i64));
    return mkBinE(b, .lt, unread, try mkIntE(b, cap));
}

/// `let x = channel(capacity: N)` → the capacity (the sole v0 argument's
/// const-evaluated int value), or null if the call has no argument (unbounded).
fn channelCapOf(cc: ast.CallExpr) ?i64 {
    var it = cc.args();
    const a0 = it.next() orelse return null;
    const n = switch (a0) {
        .num_lit => |x| x,
        else => return null,
    };
    const tok = n.token() orelse return null;
    if (tok.kind == .FLOAT_LIT) return null;
    const v = consteval.parseIntLit(tok.text) catch return null;
    if (v <= 0) return null; // a non-positive capacity isn't a bound
    return v;
}

// A task lowers to a tiny CFG of pc-numbered blocks. A `plain`/`recv` block
// runs its stmts then jumps to `next`; a `branch` block (a loop head) tests
// `cond` and jumps to `next` (enter body) or `alt` (exit). The pc is the block
// id; `next`/`alt` are block ids. `DONE_PC` is a sentinel for "task complete",
// patched to the terminal id (one past the last block) after all blocks exist.
const DONE_PC: usize = std.math.maxInt(usize);
const SchedBlock = struct {
    kind: enum { plain, recv, branch },
    stmts: []const *hir.Stmt = &.{},
    ready: ?*hir.Expr = null, // recv readiness test
    cond: ?*hir.Expr = null, // branch (loop-head) test
    next: usize, // plain/recv successor, or branch then-target
    alt: usize = 0, // branch else-target
};

/// One source item of a task body: a maximal run of straight-line statements,
/// a single `recv` suspend point, a bounded-channel `send` suspend point (parks
/// on a full buffer), a counted `for` loop, a `while` loop, an `if`/`else`
/// chain, or a `select` (a multi-channel parking suspend point).
const SchedItem = union(enum) { plain: []const ast.Stmt, recv: ast.Stmt, send: ast.Stmt, forl: ast.ForStmt, whilel: ast.WhileStmt, iff: ast.IfStmt, sel: ast.SelectStmt };

/// Context threaded through the per-task CFG lowering.
const SchedCtx = struct {
    b: *Builder,
    scope: *Scope,
    rt: *RtMap,
    chans: *const std.StringHashMapUnmanaged(void),
    blocks: *std.ArrayList(SchedBlock),
    pre: *std.ArrayList(*hir.Stmt), // loop-var inits, emitted once before the loop
};

fn collectStmts(b: *Builder, body: ast.Block) BuildError![]const ast.Stmt {
    var list: std.ArrayList(ast.Stmt) = .empty;
    var it = body.statements();
    while (it.next()) |s| try list.append(b.a, s);
    return list.toOwnedSlice(b.a);
}

fn addBlock(ctx: *SchedCtx, blk: SchedBlock) BuildError!usize {
    try ctx.blocks.append(ctx.b.a, blk);
    return ctx.blocks.items.len - 1;
}

/// Build one straight-line task-body statement with the right builder for the
/// scope context: the callee (void) builder inside a function body, the main
/// builder in `main`. (The scheduler's own locals always go through the
/// scope-aware `declareBodyLocal`, so only the user statements need this split.)
fn buildSchedStmt(ctx: *SchedCtx, s: ast.Stmt, out: *std.ArrayList(*hir.Stmt)) BuildError!void {
    if (ctx.scope.callee) return buildVoidStmt(ctx.b, s, ctx.scope, out);
    return buildMainStmt(ctx.b, s, ctx.scope, ctx.rt, out);
}

/// Where an item's control flow leaves it (patched to the successor's entry):
/// either a block's `.next` or, for a loop head, its `.alt` (loop-exit) field.
const ItemSpan = struct { entry: usize, exit_id: usize, exit_alt: bool };

/// Lower a counted `for i in lo..hi { body }` into head/body/back blocks.
/// HEAD branches `i (<|<=) #hi ? body_entry : <exit>`; the body's tail flows to
/// BACK (`i += 1; goto HEAD`). The loop-exit (`HEAD.alt`) is patched by the
/// caller. The counter + bound are pre-initialized once before the loop.
fn lowerForLoop(ctx: *SchedCtx, fs: ast.ForStmt) BuildError!usize {
    const b = ctx.b;
    const range = (fs.iterable() orelse return error.Unsupported).range;
    const pat = (fs.pattern() orelse return error.Unsupported).bindingName() orelse return error.Unsupported;
    const lo_e = try buildIntExpr(b, range.lo() orelse return error.Unsupported, ctx.scope);
    const hi_e = try buildIntExpr(b, range.hi() orelse return error.Unsupported, ctx.scope);
    // The counter binds the source name (so the body's uses resolve); a `_`
    // loop gets a fresh hidden name.
    const iname = if (std.mem.eql(u8, pat.text, "_")) try std.fmt.allocPrint(b.a, "#schi{d}", .{ctx.blocks.items.len}) else pat.text;
    const hi_name = try std.fmt.allocPrint(b.a, "{s}#schi_hi{d}", .{ iname, ctx.blocks.items.len });
    const hi_idx = try declareBodyLocal(b, ctx.scope, hi_name, false, .i64);
    const i_idx = try declareBodyLocal(b, ctx.scope, iname, true, .i64);
    try ctx.pre.append(b.a, blk: {
        const s = try b.a.create(hir.Stmt);
        s.* = .{ .let = .{ .idx = hi_idx, .value = hi_e } };
        break :blk s;
    });
    try ctx.pre.append(b.a, blk: {
        const s = try b.a.create(hir.Stmt);
        s.* = .{ .let = .{ .idx = i_idx, .value = lo_e } };
        break :blk s;
    });
    // Reserve HEAD + BACK; build the body (left-to-right) flowing to BACK.
    const head_id = try addBlock(ctx, .{ .kind = .branch, .next = 0 });
    const back_id = try addBlock(ctx, .{ .kind = .plain, .next = 0 });
    const body_entry = try lowerTaskSeq(ctx, try collectStmts(b, fs.body() orelse return error.Unsupported), back_id);
    const cond = try mkBinE(b, if (range.inclusive()) .le else .lt, try mkLocalE(b, i_idx, .i64), try mkLocalE(b, hi_idx, .i64));
    ctx.blocks.items[head_id] = .{ .kind = .branch, .cond = cond, .next = body_entry, .alt = 0 };
    const inc = try mkBinE(b, .add, try mkLocalE(b, i_idx, .i64), try mkIntE(b, 1));
    const back_stmts = try b.a.dupe(*hir.Stmt, &.{try mkAssignS(b, i_idx, inc)});
    ctx.blocks.items[back_id] = .{ .kind = .plain, .stmts = back_stmts, .next = head_id };
    return head_id;
}

/// Lower a `while cond { body }` into a head + body. HEAD branches `cond ?
/// body_entry : <exit>`; the body's tail flows back to HEAD (the body must
/// mutate `cond` to terminate). No counter — unlike `for`, nothing is
/// pre-initialized. The loop-exit (`HEAD.alt`) is patched by the caller.
fn lowerWhileLoop(ctx: *SchedCtx, ws: ast.WhileStmt) BuildError!usize {
    const b = ctx.b;
    const cond = try buildIntExpr(b, ws.condition() orelse return error.Unsupported, ctx.scope);
    const head_id = try addBlock(ctx, .{ .kind = .branch, .next = 0 });
    const body_entry = try lowerTaskSeq(ctx, try collectStmts(b, ws.body() orelse return error.Unsupported), head_id);
    ctx.blocks.items[head_id] = .{ .kind = .branch, .cond = cond, .next = body_entry, .alt = 0 };
    return head_id;
}

/// Lower an `if`/`else`/`else if` chain whose branches all flow to `join`.
/// Returns the head (branch) block id. `cond ? then_entry : else_entry`, where
/// the else target is the else body, the nested `else if`, or `join` directly.
fn lowerIfBranch(ctx: *SchedCtx, ifs: ast.IfStmt, join: usize) BuildError!usize {
    const b = ctx.b;
    const cond = try buildIntExpr(b, ifs.condition() orelse return error.Unsupported, ctx.scope);
    const then_entry = try lowerTaskSeq(ctx, try collectStmts(b, ifs.thenBody() orelse return error.Unsupported), join);
    var else_entry: usize = join;
    if (ifs.elseBody()) |eb| {
        else_entry = try lowerTaskSeq(ctx, try collectStmts(b, eb), join);
    } else if (ifs.elseIf()) |ei| {
        else_entry = try lowerIfBranch(ctx, ei, join);
    }
    return addBlock(ctx, .{ .kind = .branch, .cond = cond, .next = then_entry, .alt = else_entry });
}

/// Materialize one item's HIR + block(s), returning its entry pc and the block
/// field that carries control onward. Built **in source order** so a binding
/// (e.g. a recv result) is declared before a later statement reads it.
fn lowerSchedItem(ctx: *SchedCtx, item: SchedItem) BuildError!ItemSpan {
    const b = ctx.b;
    switch (item) {
        .plain => |ss| {
            var list: std.ArrayList(*hir.Stmt) = .empty;
            for (ss) |s| try buildSchedStmt(ctx, s, &list);
            const id = try addBlock(ctx, .{ .kind = .plain, .stmts = try list.toOwnedSlice(b.a), .next = 0 });
            return .{ .entry = id, .exit_id = id, .exit_alt = false };
        },
        .recv => |s| {
            const rs = recvStepOf(b, s, ctx.chans) orelse return error.Unsupported;
            var list: std.ArrayList(*hir.Stmt) = .empty;
            if (!try tryChannelRecv(b, rs.call, rs.name, false, ctx.scope, &list)) return error.Unsupported;
            const ready = try chanReadyCond(b, ctx.scope, rs.chan);
            const id = try addBlock(ctx, .{ .kind = .recv, .stmts = try list.toOwnedSlice(b.a), .ready = ready, .next = 0 });
            return .{ .entry = id, .exit_id = id, .exit_alt = false };
        },
        .send => |s| {
            // A bounded-channel `send`: a suspend block gated on the buffer
            // having room (`vec_len - cursor < capacity`), so it parks when full
            // and resumes after a `recv` frees a slot. The op is the `vec_push`.
            const es = switch (s) {
                .expr_stmt => |x| x,
                else => return error.Unsupported,
            };
            const cc = switch (es.expression() orelse return error.Unsupported) {
                .call => |x| x,
                else => return error.Unsupported,
            };
            const cn = callPathName(b, cc) orelse return error.Unsupported;
            defer b.a.free(cn);
            const dot = std.mem.lastIndexOfScalar(u8, cn, '.') orelse return error.Unsupported;
            const head = ctx.chans.getKey(cn[0..dot]) orelse return error.Unsupported;
            const push = (try tryChannelSend(b, cc, ctx.scope)) orelse return error.Unsupported;
            const ready = (try chanSendReadyCond(b, ctx.scope, head)) orelse return error.Unsupported;
            const id = try addBlock(ctx, .{ .kind = .recv, .stmts = try b.a.dupe(*hir.Stmt, &.{push}), .ready = ready, .next = 0 });
            return .{ .entry = id, .exit_id = id, .exit_alt = false };
        },
        .forl => |fs| {
            const head = try lowerForLoop(ctx, fs);
            return .{ .entry = head, .exit_id = head, .exit_alt = true }; // exit = HEAD.alt
        },
        .whilel => |ws| {
            const head = try lowerWhileLoop(ctx, ws);
            return .{ .entry = head, .exit_id = head, .exit_alt = true }; // exit = HEAD.alt
        },
        .iff => |ifs| {
            // An empty JOIN block reunites the branches; its `next` is the exit.
            const join = try addBlock(ctx, .{ .kind = .plain, .next = 0 });
            const head = try lowerIfBranch(ctx, ifs, join);
            return .{ .entry = head, .exit_id = join, .exit_alt = false };
        },
        .sel => |sel| {
            // A parking select: a recv-kind block gated on `any_ready` (so it
            // parks until an arm is ready), whose body is the first-ready-wins
            // dispatch chain (which then fires exactly one arm).
            const lowered = try lowerSelectArms(b, sel, ctx.scope, ctx.rt);
            const chain = lowered.chain orelse return error.Unsupported;
            const ready = lowered.any_ready orelse return error.Unsupported;
            const id = try addBlock(ctx, .{ .kind = .recv, .stmts = try b.a.dupe(*hir.Stmt, &.{chain}), .ready = ready, .next = 0 });
            return .{ .entry = id, .exit_id = id, .exit_alt = false };
        },
    }
}

/// Lower a statement sequence to CFG blocks, returning the entry pc. Items are
/// built **left-to-right** (so local declarations precede their uses); then
/// each item's exit is patched to the next item's entry (last → `succ`).
fn lowerTaskSeq(ctx: *SchedCtx, stmts: []const ast.Stmt, succ: usize) BuildError!usize {
    const b = ctx.b;
    var items: std.ArrayList(SchedItem) = .empty;
    defer items.deinit(b.a);
    var run: std.ArrayList(ast.Stmt) = .empty;
    defer run.deinit(b.a);
    for (stmts) |s| {
        // The non-plain item for this statement (a suspend point or control
        // flow), or null for a straight-line statement that joins the run. A
        // send only suspends on a *bounded* channel; unbounded sends stay plain.
        const item: ?SchedItem = blk: {
            if (recvStepOf(b, s, ctx.chans) != null) break :blk .{ .recv = s };
            if (sendStepChan(b, s, ctx.chans)) |ch| {
                if (ctx.scope.chan_caps.contains(ch)) break :blk .{ .send = s };
            }
            break :blk switch (s) {
                .for_stmt => |x| .{ .forl = x },
                .while_stmt => |x| .{ .whilel = x },
                .if_stmt => |x| .{ .iff = x },
                .select_stmt => |x| .{ .sel = x },
                else => null,
            };
        };
        if (item) |it| {
            if (run.items.len > 0) try items.append(b.a, .{ .plain = try run.toOwnedSlice(b.a) });
            try items.append(b.a, it);
        } else {
            try run.append(b.a, s);
        }
    }
    if (run.items.len > 0) try items.append(b.a, .{ .plain = try run.toOwnedSlice(b.a) });
    if (items.items.len == 0) return succ;
    var spans: std.ArrayList(ItemSpan) = .empty;
    defer spans.deinit(b.a);
    for (items.items) |item| try spans.append(b.a, try lowerSchedItem(ctx, item));
    for (spans.items, 0..) |span, i| {
        const target = if (i + 1 < spans.items.len) spans.items[i + 1].entry else succ;
        if (span.exit_alt) {
            ctx.blocks.items[span.exit_id].alt = target;
        } else {
            ctx.blocks.items[span.exit_id].next = target;
        }
    }
    return spans.items[0].entry;
}

/// Emit one block as a pc-gated `if`. plain/recv: `if (pc == id [and ready]) {
/// stmts; pc = next; prog = 1 }`. branch: `if (pc == id) { if (cond) pc = next
/// else pc = alt; prog = 1 }`.
fn emitBlockGate(b: *Builder, body: *std.ArrayList(*hir.Stmt), pc_idx: u32, id: usize, prog_idx: u32, blk: SchedBlock) BuildError!void {
    const at = try mkBinE(b, .eq, try mkLocalE(b, pc_idx, .i64), try mkIntE(b, @intCast(id)));
    var items: std.ArrayList(*hir.Stmt) = .empty;
    switch (blk.kind) {
        .plain, .recv => {
            try items.appendSlice(b.a, blk.stmts);
            try items.append(b.a, try mkAssignS(b, pc_idx, try mkIntE(b, @intCast(blk.next))));
        },
        .branch => {
            const then_s = try b.a.create(hir.Stmt);
            then_s.* = .{ .block = try b.a.dupe(*hir.Stmt, &.{try mkAssignS(b, pc_idx, try mkIntE(b, @intCast(blk.next)))}) };
            const else_s = try b.a.create(hir.Stmt);
            else_s.* = .{ .block = try b.a.dupe(*hir.Stmt, &.{try mkAssignS(b, pc_idx, try mkIntE(b, @intCast(blk.alt)))}) };
            const brif = try b.a.create(hir.Stmt);
            brif.* = .{ .if_ = .{ .cond = blk.cond.?, .then_ = then_s, .else_ = else_s } };
            try items.append(b.a, brif);
        },
    }
    try items.append(b.a, try mkAssignS(b, prog_idx, try mkIntE(b, 1)));
    const cond = if (blk.ready) |r| try mkLogicalE(b, .and_, at, r) else at;
    const then_blk = try b.a.create(hir.Stmt);
    then_blk.* = .{ .block = try items.toOwnedSlice(b.a) };
    const ifst = try b.a.create(hir.Stmt);
    ifst.* = .{ .if_ = .{ .cond = cond, .then_ = then_blk, .else_ = null } };
    try body.append(b.a, ifst);
}

/// Lower a scope of cyclic tasks to the round-robin scheduler (see the block
/// comment above). Gated by `scopeNeedsScheduler`.
fn buildScopeScheduled(b: *Builder, blk: ast.Block, scope: *Scope, rt: *RtMap, out: *std.ArrayList(*hir.Stmt)) BuildError!void {
    // Channel names (for recv/send classification).
    var chans: std.StringHashMapUnmanaged(void) = .empty;
    defer chans.deinit(b.a);
    {
        var it = blk.statements();
        while (it.next()) |stmt| {
            if (channelDeclName(b, stmt)) |nm| try chans.put(b.a, nm, {});
        }
    }
    // Emit the setup (channel decls) in order; collect the spawned task bodies.
    var tasks: std.ArrayList(ast.Block) = .empty;
    defer tasks.deinit(b.a);
    {
        var it = blk.statements();
        while (it.next()) |stmt| {
            if (spawnExprOf(stmt)) |sp| {
                try tasks.append(b.a, sp.block() orelse return error.Unsupported);
            } else if (channelDeclName(b, stmt)) |_| {
                // A channel decl: build it directly via `tryChannelNew` so the
                // scheduler is builder-agnostic — it runs in `main` and in callee
                // (void) bodies alike (the main/void statement builders differ).
                const ls = stmt.let_stmt;
                const init = ls.initializer() orelse return error.Unsupported;
                const nm = (ls.pattern() orelse return error.Unsupported).bindingName() orelse return error.Unsupported;
                if (!try tryChannelNew(b, init, nm.text, ls.isVar(), scope, out)) return error.Unsupported;
            } else {
                // An actor-instance construct (`let acc = Actor {}`): build the
                // state record via the full statement builder (records are
                // `main`-only on the v0 floor; the gate keeps callee scopes out).
                try buildMainStmt(b, stmt, scope, rt, out);
            }
        }
    }
    const ntasks = tasks.items.len;
    const pc_idx = try b.a.alloc(u32, ntasks);
    const entry = try b.a.alloc(usize, ntasks);
    const terminal = try b.a.alloc(usize, ntasks);
    // The progress flag (declared first: the per-task gates reference it).
    const prog_idx = try declareBodyLocal(b, scope, "#sched_prog", true, .i64);
    var pre: std.ArrayList(*hir.Stmt) = .empty; // loop-var inits (before the loop)
    defer pre.deinit(b.a);
    var gates: std.ArrayList(*hir.Stmt) = .empty; // per-task block gates (the loop body)
    defer gates.deinit(b.a);
    for (tasks.items, 0..) |task, t| {
        const nm = try std.fmt.allocPrint(b.a, "#sched_pc{d}", .{t});
        pc_idx[t] = try declareBodyLocal(b, scope, nm, true, .i64);
        var blocks: std.ArrayList(SchedBlock) = .empty;
        defer blocks.deinit(b.a);
        var ctx: SchedCtx = .{ .b = b, .scope = scope, .rt = rt, .chans = &chans, .blocks = &blocks, .pre = &pre };
        entry[t] = try lowerTaskSeq(&ctx, try collectStmts(b, task), DONE_PC);
        terminal[t] = blocks.items.len; // pc == terminal ⇒ task complete
        for (blocks.items) |*bl| {
            if (bl.next == DONE_PC) bl.next = terminal[t];
            if (bl.alt == DONE_PC) bl.alt = terminal[t];
        }
        for (blocks.items, 0..) |bl, id| try emitBlockGate(b, &gates, pc_idx[t], id, prog_idx, bl);
    }
    // Setup runs once before the loop: loop-var inits, then pc = entry, prog = 1.
    try out.appendSlice(b.a, pre.items);
    for (0..ntasks) |t| {
        const st = try b.a.create(hir.Stmt);
        st.* = .{ .let = .{ .idx = pc_idx[t], .value = try mkIntE(b, @intCast(entry[t])) } };
        try out.append(b.a, st);
    }
    {
        const st = try b.a.create(hir.Stmt);
        st.* = .{ .let = .{ .idx = prog_idx, .value = try mkIntE(b, 1) } };
        try out.append(b.a, st);
    }
    // Loop body: `prog = 0`, then every task's block gates.
    var body: std.ArrayList(*hir.Stmt) = .empty;
    defer body.deinit(b.a);
    try body.append(b.a, try mkAssignS(b, prog_idx, try mkIntE(b, 0)));
    try body.appendSlice(b.a, gates.items);
    // `while ((pc0 < N0 or pc1 < N1 or …) and prog == 1) { body }`.
    var any: ?*hir.Expr = null;
    for (0..ntasks) |t| {
        const lt = try mkBinE(b, .lt, try mkLocalE(b, pc_idx[t], .i64), try mkIntE(b, @intCast(terminal[t])));
        any = if (any) |a| try mkLogicalE(b, .or_, a, lt) else lt;
    }
    const prog_eq = try mkBinE(b, .eq, try mkLocalE(b, prog_idx, .i64), try mkIntE(b, 1));
    const cond = try mkLogicalE(b, .and_, any orelse return error.Unsupported, prog_eq);
    const body_blk = try b.a.create(hir.Stmt);
    body_blk.* = .{ .block = try body.toOwnedSlice(b.a) };
    const wst = try b.a.create(hir.Stmt);
    wst.* = .{ .while_ = .{ .cond = cond, .body = body_blk } };
    try out.append(b.a, wst);
}

/// `scope { … }` on the v0 cooperative floor (spec/memory.md §"Concurrency
/// platform audit"). A scope is a structured-concurrency arena whose spawned
/// tasks all complete at the closing brace. With no suspension points and a
/// single thread, a valid cooperative schedule is: run each task to
/// completion in *some* order. The default is eager-at-spawn (a task runs at
/// its spawn point) — it handles parent-local dependencies and lets a
/// spawned producer fill a channel before the parent or a later task
/// consumes it.
///
/// The one ordering eager-at-spawn can't serve is a **consumer spawned
/// before its producer**: its `recv` would hit an empty buffer and trap.
/// This is the static slice of the scheduler: a task whose `recv` channel
/// has no sends emitted yet (`taskWouldBlock`) is deferred to the join and
/// run after the eager pass, by which point a later producer has filled the
/// channel — a valid cooperative schedule, no runtime suspension. Tasks
/// whose channel already has data are untouched, so every currently-running
/// program is byte-identical. (Genuinely *cyclic* mutual suspension — two
/// tasks each waiting on the other — still needs the runtime CPS scheduler;
/// so do `catch` arms, `select` parking, and `ask` suspension.)
fn buildScopeStmt(b: *Builder, ss: ast.ScopeStmt, scope: *Scope, rt: *RtMap, out: *std.ArrayList(*hir.Stmt)) BuildError!void {
    var carms = ss.catchArms();
    if (carms.next() != null) return error.Unsupported; // panic-catch needs the EH runtime
    const blk = ss.block() orelse return error.Unsupported;
    // Cyclic tasks — a producer and consumer mutually waiting on each other's
    // channels — can't be served by static ordering (each has effects before
    // its blocking recv that the other depends on). They need the runtime
    // round-robin scheduler (`buildScopeScheduled`); the gate is conservative
    // (≥2 tasks, one that both sends and recvs) so no eager/deferred program is
    // ever routed here.
    if (scopeNeedsScheduler(b, blk, scope)) return buildScopeScheduled(b, blk, scope, rt, out);
    // Channels that have had a send emitted so far (stable scope.chans keys).
    var sent: std.StringHashMapUnmanaged(void) = .empty;
    defer sent.deinit(b.a);
    // Consumer tasks deferred to the join (recv before any producer).
    var deferred: std.ArrayList(ast.SpawnExpr) = .empty;
    defer deferred.deinit(b.a);
    var it = blk.statements();
    while (it.next()) |stmt| {
        if (spawnExprOf(stmt)) |sp| {
            if (taskWouldBlock(b, sp, scope, &sent)) {
                try deferred.append(b.a, sp);
                continue;
            }
            try recordTaskSends(b, sp, scope, &sent);
            try emitSpawnTaskMain(b, sp, scope, rt, out);
        } else {
            if (stmtChanTarget(b, stmt, scope, "send")) |c| try sent.put(b.a, c, {});
            try buildMainStmt(b, stmt, scope, rt, out);
        }
    }
    // Join: run the deferred consumers, in spawn order, now that their
    // producers (emitted above) have filled the channels.
    for (deferred.items) |sp| try emitSpawnTaskMain(b, sp, scope, rt, out);
}

/// C1/C3: a statement-position `match` on an enum value. The
/// scrutinee evaluates once into a hidden local (an i64 tag for an
/// immediate enum, the value's base pointer for a boxed one); arms
/// lower to an if/else chain on tag equality. Patterns: bare unit
/// variant names, payload forms binding fresh locals (`Circle(r)`),
/// and `_`; the match must be exhaustive (every variant covered, or
/// a `_` arm).
fn buildMainMatch(b: *Builder, ms: ast.MatchStmt, scope: *Scope, rt: *RtMap, out: *std.ArrayList(*hir.Stmt)) BuildError!void {
    const scrut = ms.scrutinee() orelse return error.Unsupported;
    const info_opt = try enumOfExpr(b, scope, scrut);
    // C4: a non-enum scrutinee matches integer literals (`match n {
    // 0 -> .., _ -> .. }`); it must be provably an integer, and the
    // match needs a `_` arm (ints aren't enumerable).
    if (info_opt == null and (try exprScalar(b, scrut, scope)) != .i64) return error.Unsupported;
    const boxed = if (info_opt) |info| info.si != null else false;

    const s_idx = try declareMatchScrutinee(b, scope, scrut, boxed, out);

    // Collect the arms: (tag, body) pairs + at most one `_` default.
    var arms: std.ArrayList(LoweredArm) = .empty;
    defer arms.deinit(b.a);
    var default: ?*hir.Stmt = null;
    var seen: u64 = 0;
    var it = ms.arms();
    while (it.next()) |arm| {
        const pat = arm.pattern() orelse return error.Unsupported;
        // An or-pattern (`Red | Yellow -> …`): each alternative is a separate
        // (tag, body) sharing one body. v0: unit/literal alternatives only —
        // no payload bindings (they'd need consistent binders across alts).
        if (pat.kind() == .OR_PATTERN) {
            if (arm.guard() != null) return error.Unsupported; // guards on or-patterns: later
            const body = try buildMatchArmBody(b, arm, scope, rt);
            var alts = pat.alternatives();
            var n: usize = 0;
            while (alts.next()) |alt| {
                n += 1;
                const ap = (if (info_opt) |info|
                    try resolveArmPattern(b, info, alt, scope, s_idx)
                else
                    try resolveLiteralPattern(b, alt)) orelse return error.Unsupported; // no `_` in an or-pattern
                if (ap.prelude.len != 0 or ap.cond != null) return error.Unsupported; // payload binders/conditions: later
                try arms.append(b.a, .{ .tag = ap.tag, .body = body });
                if (info_opt != null) seen |= @as(u64, 1) << @intCast(ap.tag);
            }
            if (n == 0) return error.Unsupported;
            continue;
        }
        // A scalar binder arm (`x [if cond] -> …`): `x` aliases the scrutinee
        // value. Unguarded it is the catch-all default; guarded it is a
        // value-conditioned arm that falls through when the guard fails.
        if (info_opt == null and pat.kind() == .IDENT_PATTERN) {
            const nm = pat.bindingName() orelse return error.Unsupported;
            try aliasLocal(scope, nm.text, s_idx, .i64);
            const body = try buildMatchArmBody(b, arm, scope, rt);
            if (arm.guard()) |gexpr| {
                if (!try exprIsBool(b, gexpr, scope)) return error.Unsupported;
                const guard = try buildIntExpr(b, gexpr, scope);
                try arms.append(b.a, .{ .tag = 0, .body = body, .guard = guard, .any = true });
            } else {
                if (default != null) return error.Unsupported;
                default = body;
            }
            continue;
        }
        // A scalar range-pattern arm (`lo..hi -> …`): a value-range condition,
        // never a tag — like a binder arm, it requires an unguarded fallback.
        if (info_opt == null and pat.kind() == .RANGE_PATTERN) {
            const cond = try buildRangePatternCond(b, scope, pat, arm, s_idx);
            const body = try buildMatchArmBody(b, arm, scope, rt);
            try arms.append(b.a, .{ .tag = 0, .body = body, .guard = cond, .any = true });
            continue;
        }
        // Pattern first: payload bindings must be in scope for the body.
        const rp = if (info_opt) |info|
            try resolveArmPattern(b, info, pat, scope, s_idx)
        else
            try resolveLiteralPattern(b, pat);
        const body = try buildMatchArmBody(b, arm, scope, rt);
        const ap = rp orelse {
            if (arm.guard() != null) return error.Unsupported; // guarded `_`: later
            if (default != null) return error.Unsupported; // two `_` arms
            default = body;
            continue;
        };
        // A guard (`P if cond -> …`) AND-ed onto the tag test; payload-binding
        // arms are out of v0 scope (the prelude loads run inside the body).
        var guard: ?*hir.Expr = null;
        if (arm.guard()) |gexpr| {
            if (ap.prelude.len != 0) return error.Unsupported;
            if (!try exprIsBool(b, gexpr, scope)) return error.Unsupported;
            guard = try buildIntExpr(b, gexpr, scope);
        }
        // A literal sub-pattern condition (`Move(0, y)`) ANDs onto the guard.
        const combined = try andOpt(b, ap.cond, guard);
        try arms.append(b.a, .{ .tag = ap.tag, .body = try prependPrelude(b, ap.prelude, body), .guard = combined });
        // Coverage only counts for enums (a literal can be any i64); a guarded
        // arm may fail, so it never contributes to exhaustiveness.
        if (info_opt != null and combined == null) seen |= @as(u64, 1) << @intCast(ap.tag);
    }
    // Exhaustiveness (spec/grammar.md leaves the rules open; the v0
    // floor requires it structurally): every variant or a default for
    // an enum; literal matches always need the default.
    if (default == null) {
        const info = info_opt orelse return error.Unsupported;
        if (@popCount(seen) < info.variants.len) return error.Unsupported;
    }

    try foldMatchChain(b, s_idx, boxed, arms.items, default, out);
}

/// C4: a literal arm pattern (`0 ->`, `42 ->`) against an integer
/// scrutinee; `null` = wildcard.
fn resolveLiteralPattern(b: *Builder, pat: ast.Pattern) BuildError!?ArmPattern {
    _ = b;
    switch (pat.kind()) {
        .WILD_PATTERN => return null,
        .LITERAL_PATTERN => {
            const tok = firstNonTriviaToken(pat.cst) orelse return error.Unsupported;
            if (tok.kind != .INT_LIT) return error.Unsupported; // str/float literals: later
            const v = consteval.parseIntLit(tok.text) catch return error.Unsupported;
            return .{ .tag = v, .prelude = &.{} };
        },
        else => return error.Unsupported, // binders/ranges on scalars: later
    }
}

fn firstNonTriviaToken(node: *const parser.cst.Node) ?parser.cst.Token {
    for (node.children) |c| switch (c) {
        .token => |t| if (!t.kind.isTrivia()) return t,
        .node => |n| if (firstNonTriviaToken(n)) |t| return t,
    };
    return null;
}

/// Evaluate a match scrutinee once into a hidden local: the tag (i64)
/// for an immediate enum, the value's base pointer for a boxed one.
fn declareMatchScrutinee(b: *Builder, scope: *Scope, scrut: ast.Expr, boxed: bool, out: *std.ArrayList(*hir.Stmt)) BuildError!u32 {
    const sty: hir.Type = if (boxed) .ptr else .i64;
    const s_idx = try declareBodyLocal(b, scope, "#match", false, sty);
    const sval = if (boxed) blk: {
        const rv = (try buildRecExpr(b, scrut, scope)) orelse return error.Unsupported;
        break :blk rv.e;
    } else try buildIntExpr(b, scrut, scope);
    const set = try b.a.create(hir.Stmt);
    set.* = .{ .let = .{ .idx = s_idx, .value = sval } };
    try out.append(b.a, set);
    return s_idx;
}

/// A resolved (non-wildcard) arm pattern: the variant's tag, the statements
/// that bind its payload slots into fresh locals, and an optional condition
/// from literal sub-patterns (`Move(0, y)` — slot 0 must equal 0). The
/// condition is ANDed onto the tag test like a guard, so a conditional
/// payload arm never satisfies exhaustiveness on its own.
const ArmPattern = struct { tag: i64, prelude: []const *hir.Stmt, cond: ?*hir.Expr = null };

/// AND two optional conditions, collapsing the `null`s (an absent condition
/// is "always true"). Returns `null` only when both are absent.
fn andOpt(b: *Builder, lhs: ?*hir.Expr, rhs: ?*hir.Expr) BuildError!?*hir.Expr {
    const l = lhs orelse return rhs;
    const r = rhs orelse return l;
    const c = try b.a.create(hir.Expr);
    c.* = .{ .logical = .{ .op = .and_, .lhs = l, .rhs = r } };
    return c;
}

/// A str-payload arm (`Ok(content)`): one ident sub-pattern binding a
/// str — ptr/len locals loaded from the boxed value's cells 8 and 16.
fn resolveStrArm(b: *Builder, info: *const EnumInfo, pat: ast.Pattern, scope: *Scope, s_idx: u32, tag: u32) BuildError!?ArmPattern {
    _ = info;
    var sub_name: ?[]const u8 = null;
    var n: u32 = 0;
    for (pat.cst.children) |c| switch (c) {
        .node => |sub| {
            const sp = ast.Pattern.cast(sub) orelse continue;
            if (n > 0) return error.Unsupported; // one slot
            switch (sp.kind()) {
                .WILD_PATTERN => {},
                .IDENT_PATTERN => sub_name = (sp.bindingName() orelse return error.Unsupported).text,
                else => return error.Unsupported,
            }
            n += 1;
        },
        .token => {},
    };
    if (n != 1) return error.Unsupported;
    var prelude: std.ArrayList(*hir.Stmt) = .empty;
    if (sub_name) |nm| {
        const ptr_idx = try declareStrBodyLocal(b, scope, nm);
        const len_idx = ptr_idx + 1;
        for ([_]struct { idx: u32, off: u32 }{ .{ .idx = ptr_idx, .off = 8 }, .{ .idx = len_idx, .off = 16 } }) |cell| {
            const base = try b.a.create(hir.Expr);
            base.* = .{ .local = .{ .idx = s_idx, .ty = .ptr } };
            const ld = try b.a.create(hir.Expr);
            ld.* = .{ .field_get = .{ .base = base, .offset = cell.off, .ty = .i64 } };
            const cast = try b.a.create(hir.Expr);
            cast.* = .{ .num_cast = .{ .to = .ptr, .value = ld } };
            const st = try b.a.create(hir.Stmt);
            st.* = .{ .let = .{ .idx = cell.idx, .value = cast } };
            try prelude.append(b.a, st);
        }
    }
    return .{ .tag = @intCast(tag), .prelude = try prelude.toOwnedSlice(b.a) };
}

/// A record-payload arm (`Io(e)`): one ident sub-pattern binding the
/// record's base pointer (field access + dispatch via `scope.recs`).
fn resolveRecArm(b: *Builder, rsi: *const StructInfo, pat: ast.Pattern, scope: *Scope, s_idx: u32, tag: u32) BuildError!?ArmPattern {
    var sub_name: ?[]const u8 = null;
    var n: u32 = 0;
    for (pat.cst.children) |c| switch (c) {
        .node => |sub| {
            const sp = ast.Pattern.cast(sub) orelse continue;
            if (n > 0) return error.Unsupported;
            switch (sp.kind()) {
                .WILD_PATTERN => {},
                .IDENT_PATTERN => sub_name = (sp.bindingName() orelse return error.Unsupported).text,
                else => return error.Unsupported,
            }
            n += 1;
        },
        .token => {},
    };
    if (n != 1) return error.Unsupported;
    var prelude: std.ArrayList(*hir.Stmt) = .empty;
    if (sub_name) |nm| {
        const idx = try declareBodyLocal(b, scope, nm, false, .ptr);
        try scope.recs.put(b.a, nm, rsi);
        const base = try b.a.create(hir.Expr);
        base.* = .{ .local = .{ .idx = s_idx, .ty = .ptr } };
        const ld = try b.a.create(hir.Expr);
        ld.* = .{ .field_get = .{ .base = base, .offset = 8, .ty = .i64 } };
        const cast = try b.a.create(hir.Expr);
        cast.* = .{ .num_cast = .{ .to = .ptr, .value = ld } };
        const st = try b.a.create(hir.Stmt);
        st.* = .{ .let = .{ .idx = idx, .value = cast } };
        try prelude.append(b.a, st);
    }
    return .{ .tag = @intCast(tag), .prelude = try prelude.toOwnedSlice(b.a) };
}

/// Resolve a match-arm pattern against the enum. `null` = wildcard.
fn resolveArmPattern(b: *Builder, info: *const EnumInfo, pat: ast.Pattern, scope: *Scope, s_idx: u32) BuildError!?ArmPattern {
    switch (pat.kind()) {
        .WILD_PATTERN => return null,
        .IDENT_PATTERN => {
            const nm = pat.bindingName() orelse return error.Unsupported;
            const tag = info.variantTag(nm.text) orelse return reject(b, .name_not_found);
            if (info.variants[tag].arity != 0) return error.Unsupported; // bind the payload: `V(x, ..)`
            return .{ .tag = @intCast(tag), .prelude = &.{} };
        },
        .TUPLE_STRUCT_PATTERN, .ENUM_VARIANT_PATTERN => {
            // `Circle(r)` / `Rect(w, _)`: head variant + sub-patterns,
            // one per payload slot. Each ident binds a fresh i64 local
            // loaded from the boxed value. A str payload (`Ok(content)`
            // on a Result<str, _>) binds a str: two .ptr locals read
            // from cells 8/16, narrowed to address width.
            const head = patternHeadName(pat.cst) orelse return error.Unsupported;
            const tag = info.variantTag(head) orelse return reject(b, .name_not_found);
            if (info.variants[tag].kind == .str_) {
                return resolveStrArm(b, info, pat, scope, s_idx, @intCast(tag));
            }
            if (info.variants[tag].kind == .rec) {
                return resolveRecArm(b, info.variants[tag].rec_si.?, pat, scope, s_idx, @intCast(tag));
            }
            const arity = info.variants[tag].arity;
            var prelude: std.ArrayList(*hir.Stmt) = .empty;
            var cond: ?*hir.Expr = null;
            var n: u32 = 0;
            for (pat.cst.children) |c| switch (c) {
                .node => |sub| {
                    const sp = ast.Pattern.cast(sub) orelse continue;
                    if (n == arity) return error.Unsupported; // too many sub-patterns
                    switch (sp.kind()) {
                        .WILD_PATTERN => {},
                        .IDENT_PATTERN => {
                            const snm = sp.bindingName() orelse return error.Unsupported;
                            const idx = try declareBodyLocal(b, scope, snm.text, false, .i64);
                            const base = try b.a.create(hir.Expr);
                            base.* = .{ .local = .{ .idx = s_idx, .ty = .ptr } };
                            const ld = try b.a.create(hir.Expr);
                            ld.* = .{ .field_get = .{ .base = base, .offset = 8 * (n + 1), .ty = .i64 } };
                            const st = try b.a.create(hir.Stmt);
                            st.* = .{ .let = .{ .idx = idx, .value = ld } };
                            try prelude.append(b.a, st);
                        },
                        .LITERAL_PATTERN => {
                            // `Move(0, y)`: slot n must equal an integer literal.
                            // Read the slot directly (no binding) and AND an
                            // equality test onto the arm condition.
                            const lit = firstNonTriviaToken(sp.cst) orelse return error.Unsupported;
                            if (lit.kind != .INT_LIT) return error.Unsupported; // int slots only (v0)
                            const v = consteval.parseIntLit(lit.text) catch return error.Unsupported;
                            const base = try b.a.create(hir.Expr);
                            base.* = .{ .local = .{ .idx = s_idx, .ty = .ptr } };
                            const ld = try b.a.create(hir.Expr);
                            ld.* = .{ .field_get = .{ .base = base, .offset = 8 * (n + 1), .ty = .i64 } };
                            const lv = try b.a.create(hir.Expr);
                            lv.* = .{ .int_const = v };
                            const eq = try b.a.create(hir.Expr);
                            eq.* = .{ .bin = .{ .kind = .eq, .lhs = ld, .rhs = lv } };
                            cond = try andOpt(b, cond, eq);
                        },
                        else => return error.Unsupported, // nested enum/record sub-patterns: later
                    }
                    n += 1;
                },
                .token => {},
            };
            if (n != arity) return error.Unsupported; // too few sub-patterns
            return .{ .tag = @intCast(tag), .prelude = try prelude.toOwnedSlice(b.a), .cond = cond };
        },
        else => return error.Unsupported, // literal patterns: later
    }
}

/// The variant name a payload pattern opens with: the last IDENT
/// before its `(`. A bare `None` arm parses as an ENUM_VARIANT_PATTERN
/// holding just the `KW_NONE` token, so it names a head too.
fn patternHeadName(node: *const parser.cst.Node) ?[]const u8 {
    var head: ?[]const u8 = null;
    for (node.children) |c| switch (c) {
        .token => |t| {
            if (t.kind == .L_PAREN) return head;
            if (t.kind == .IDENT or t.kind == .KW_NONE) head = t.text;
        },
        .node => |n| {
            // A structured path head: its last IDENT.
            if (patternHeadName(n)) |h| head = h;
        },
    };
    return head;
}

/// Payload bindings load before the arm's own statements: merge the
/// prelude into the body block.
fn prependPrelude(b: *Builder, prelude: []const *hir.Stmt, body: *hir.Stmt) BuildError!*hir.Stmt {
    if (prelude.len == 0) return body;
    var all: std.ArrayList(*hir.Stmt) = .empty;
    try all.appendSlice(b.a, prelude);
    try all.appendSlice(b.a, body.block); // arm bodies are blocks by construction
    const out = try b.a.create(hir.Stmt);
    out.* = .{ .block = try all.toOwnedSlice(b.a) };
    return out;
}

/// One lowered match arm: the variant's tag + the body block, plus an
/// optional guard condition (`P if cond -> …`) AND-ed onto the tag test.
/// `any` marks a scalar binder arm (`x if cond -> …`): it matches every
/// value, so its only condition is the guard (no tag comparison).
const LoweredArm = struct { tag: i64, body: *hir.Stmt, guard: ?*hir.Expr = null, any: bool = false };

/// Fold lowered arms back-to-front into an if/else chain comparing the
/// scrutinee local against each tag. The lowering reads branch
/// payloads as blocks, so a nested `if` (the rest of the chain) wraps
/// in a one-statement block.
fn foldMatchChain(b: *Builder, s_idx: u32, boxed: bool, arms: []const LoweredArm, default: ?*hir.Stmt, out: *std.ArrayList(*hir.Stmt)) BuildError!void {
    var chain: ?*hir.Stmt = default;
    var i = arms.len;
    while (i > 0) {
        i -= 1;
        const a = arms[i];
        // A scalar binder arm (`x if cond`) has no tag — it matches any value,
        // gated solely by its guard.
        const cond = if (a.any) a.guard.? else blk: {
            // The tag: the scrutinee local itself (immediate), or a load
            // from the boxed value's slot 0.
            const sread = if (boxed) sb: {
                const base = try b.a.create(hir.Expr);
                base.* = .{ .local = .{ .idx = s_idx, .ty = .ptr } };
                const ld = try b.a.create(hir.Expr);
                ld.* = .{ .field_get = .{ .base = base, .offset = 0, .ty = .i64 } };
                break :sb ld;
            } else sb: {
                const r = try b.a.create(hir.Expr);
                r.* = .{ .local = .{ .idx = s_idx, .ty = .i64 } };
                break :sb r;
            };
            const tagv = try b.a.create(hir.Expr);
            tagv.* = .{ .int_const = a.tag };
            const tagcmp = try b.a.create(hir.Expr);
            tagcmp.* = .{ .bin = .{ .kind = .eq, .lhs = sread, .rhs = tagv } };
            // A guarded arm fires only when its tag matches AND the guard holds;
            // a failing guard falls through to the rest of the chain.
            break :blk if (a.guard) |g| gb: {
                const c = try b.a.create(hir.Expr);
                c.* = .{ .logical = .{ .op = .and_, .lhs = tagcmp, .rhs = g } };
                break :gb c;
            } else tagcmp;
        };
        var else_part = chain;
        if (else_part) |ep| {
            if (ep.* == .if_) {
                const wrap = try b.a.create(hir.Stmt);
                wrap.* = .{ .block = try b.a.dupe(*hir.Stmt, &.{ep}) };
                else_part = wrap;
            }
        }
        const st = try b.a.create(hir.Stmt);
        st.* = .{ .if_ = .{ .cond = cond, .then_ = a.body, .else_ = else_part } };
        chain = st;
    }
    if (chain) |c| try out.append(b.a, c);
}

/// A scalar range-pattern arm (`lo..hi` / `lo..=hi`, optionally `if g`): the
/// match condition `(scrut >= lo) and (scrut <op> hi)` read from the scrutinee
/// local, with the user guard ANDed on if present. v0: integer bounds only.
fn buildRangePatternCond(b: *Builder, scope: *Scope, pat: ast.Pattern, arm: ast.MatchArm, s_idx: u32) BuildError!*hir.Expr {
    const parts = pat.rangeParts() orelse return error.Unsupported;
    const lo_tok = firstNonTriviaToken(parts.lo.cst) orelse return error.Unsupported;
    const hi_tok = firstNonTriviaToken(parts.hi.cst) orelse return error.Unsupported;
    if (lo_tok.kind != .INT_LIT or hi_tok.kind != .INT_LIT) return error.Unsupported;
    const lo = consteval.parseIntLit(lo_tok.text) catch return error.Unsupported;
    const hi = consteval.parseIntLit(hi_tok.text) catch return error.Unsupported;
    if (hi < lo) return error.Unsupported; // an empty range is a bug, not a feature

    const bound = struct {
        fn cmp(bb: *Builder, idx: u32, kind: ops.BinKind, val: i64) BuildError!*hir.Expr {
            const l = try bb.a.create(hir.Expr);
            l.* = .{ .local = .{ .idx = idx, .ty = .i64 } };
            const r = try bb.a.create(hir.Expr);
            r.* = .{ .int_const = val };
            const c = try bb.a.create(hir.Expr);
            c.* = .{ .bin = .{ .kind = kind, .lhs = l, .rhs = r } };
            return c;
        }
    };
    const ge = try bound.cmp(b, s_idx, .ge, lo);
    const hicmp = try bound.cmp(b, s_idx, if (parts.inclusive) .le else .lt, hi);
    var cond = try b.a.create(hir.Expr);
    cond.* = .{ .logical = .{ .op = .and_, .lhs = ge, .rhs = hicmp } };
    if (arm.guard()) |gexpr| {
        if (!try exprIsBool(b, gexpr, scope)) return error.Unsupported;
        const g = try buildIntExpr(b, gexpr, scope);
        const c = try b.a.create(hir.Expr);
        c.* = .{ .logical = .{ .op = .and_, .lhs = cond, .rhs = g } };
        cond = c;
    }
    return cond;
}

/// The scalar a value `match` yields: the first arm's expression type
/// (every arm is checked against it during the build). Scalars only —
/// str/record arms are later rungs.
///
/// Alias every ident binder a pattern introduces (`x`, or the sub-patterns of
/// `Move(x, y)`) to a dummy i64 local, so a value-type probe over an arm whose
/// value uses those binders resolves. Caller restores `scope.locals`.
fn aliasPatternBinders(scope: *Scope, pat: ast.Pattern) BuildError!void {
    switch (pat.kind()) {
        .IDENT_PATTERN => if (pat.bindingName()) |nm| try aliasLocal(scope, nm.text, 0, .i64),
        .TUPLE_STRUCT_PATTERN, .ENUM_VARIANT_PATTERN, .TUPLE_PATTERN => {
            for (pat.cst.children) |c| switch (c) {
                .node => |sub| if (ast.Pattern.cast(sub)) |sp| try aliasPatternBinders(scope, sp),
                .token => {},
            };
        },
        else => {},
    }
}

fn matchValueTy(b: *Builder, me: ast.MatchExpr, scope: *Scope) BuildError!hir.Type {
    var it = me.arms();
    const arm = it.next() orelse return error.Unsupported;
    const e = arm.expression() orelse return error.Unsupported;
    // The first arm's value may reference names its pattern binds (a scalar
    // binder `x`, or payload binders `Move(x, y) -> x + y`). Alias each to an
    // i64 so the value's type can be probed; the aliases are dropped after.
    const saved = scope.locals.items.len;
    defer scope.locals.shrinkRetainingCapacity(saved);
    if (arm.pattern()) |pat| try aliasPatternBinders(scope, pat);
    const sc = try exprScalar(b, e, scope);
    if (sc == .narrow_int or sc == .str) return error.Unsupported;
    return scalarBindTy(sc);
}

/// C2/C3: a value `match` desugared into per-arm assignments of
/// `target_idx` (type `ty`). The same scrutinee/tag/exhaustiveness
/// rules as the statement form; arms are `->` value expressions (a
/// payload pattern's bindings are in scope for its arm's value).
fn buildMatchInto(b: *Builder, me: ast.MatchExpr, scope: *Scope, out: *std.ArrayList(*hir.Stmt), target_idx: u32, ty: hir.Type) BuildError!void {
    // Arm values are scalar expressions (str arms: later), so no RtMap is
    // needed — this is shared by `main` and callee bodies alike.
    const scrut = me.scrutinee() orelse return error.Unsupported;
    const info_opt = try enumOfExpr(b, scope, scrut);
    if (info_opt == null and (try exprScalar(b, scrut, scope)) != .i64) return error.Unsupported;
    const boxed = if (info_opt) |info| info.si != null else false;

    const s_idx = try declareMatchScrutinee(b, scope, scrut, boxed, out);

    var arms: std.ArrayList(LoweredArm) = .empty;
    defer arms.deinit(b.a);
    var default: ?*hir.Stmt = null;
    var seen: u64 = 0;
    var it = me.arms();
    while (it.next()) |arm| {
        const pat = arm.pattern() orelse return error.Unsupported;
        // An or-pattern arm: build the value once, share it across the
        // alternatives' tags (unit/literal alternatives only — see below).
        if (pat.kind() == .OR_PATTERN) {
            if (arm.guard() != null) return error.Unsupported; // guards on or-patterns: later
            const e = arm.expression() orelse return error.Unsupported;
            if (scalarBindTy(try exprScalar(b, e, scope)) != ty) return error.Unsupported;
            const value = try buildIntExpr(b, e, scope);
            const asn = try b.a.create(hir.Stmt);
            asn.* = .{ .assign = .{ .idx = target_idx, .value = value } };
            const body = try b.a.create(hir.Stmt);
            body.* = .{ .block = try b.a.dupe(*hir.Stmt, &.{asn}) };
            var alts = pat.alternatives();
            var n: usize = 0;
            while (alts.next()) |alt| {
                n += 1;
                const ap2 = (if (info_opt) |info|
                    try resolveArmPattern(b, info, alt, scope, s_idx)
                else
                    try resolveLiteralPattern(b, alt)) orelse return error.Unsupported;
                if (ap2.prelude.len != 0 or ap2.cond != null) return error.Unsupported;
                try arms.append(b.a, .{ .tag = ap2.tag, .body = body });
                if (info_opt != null) seen |= @as(u64, 1) << @intCast(ap2.tag);
            }
            if (n == 0) return error.Unsupported;
            continue;
        }
        if (info_opt == null and pat.kind() == .IDENT_PATTERN) {
            const nm = pat.bindingName() orelse return error.Unsupported;
            try aliasLocal(scope, nm.text, s_idx, .i64);
            const e = arm.expression() orelse return error.Unsupported;
            if (scalarBindTy(try exprScalar(b, e, scope)) != ty) return error.Unsupported;
            const value = try buildIntExpr(b, e, scope);
            const asn = try b.a.create(hir.Stmt);
            asn.* = .{ .assign = .{ .idx = target_idx, .value = value } };
            const body = try b.a.create(hir.Stmt);
            body.* = .{ .block = try b.a.dupe(*hir.Stmt, &.{asn}) };
            if (arm.guard()) |gexpr| {
                if (!try exprIsBool(b, gexpr, scope)) return error.Unsupported;
                const guard = try buildIntExpr(b, gexpr, scope);
                try arms.append(b.a, .{ .tag = 0, .body = body, .guard = guard, .any = true });
            } else {
                if (default != null) return error.Unsupported;
                default = body;
            }
            continue;
        }
        if (info_opt == null and pat.kind() == .RANGE_PATTERN) {
            const e = arm.expression() orelse return error.Unsupported;
            if (scalarBindTy(try exprScalar(b, e, scope)) != ty) return error.Unsupported;
            const value = try buildIntExpr(b, e, scope);
            const asn = try b.a.create(hir.Stmt);
            asn.* = .{ .assign = .{ .idx = target_idx, .value = value } };
            const body = try b.a.create(hir.Stmt);
            body.* = .{ .block = try b.a.dupe(*hir.Stmt, &.{asn}) };
            const cond = try buildRangePatternCond(b, scope, pat, arm, s_idx);
            try arms.append(b.a, .{ .tag = 0, .body = body, .guard = cond, .any = true });
            continue;
        }
        // Pattern first: payload bindings must be in scope for the value.
        const rp = if (info_opt) |info|
            try resolveArmPattern(b, info, pat, scope, s_idx)
        else
            try resolveLiteralPattern(b, pat);
        const e = arm.expression() orelse return error.Unsupported; // value arms only
        if (scalarBindTy(try exprScalar(b, e, scope)) != ty) return error.Unsupported;
        const value = try buildIntExpr(b, e, scope);
        const asn = try b.a.create(hir.Stmt);
        asn.* = .{ .assign = .{ .idx = target_idx, .value = value } };
        const body = try b.a.create(hir.Stmt);
        body.* = .{ .block = try b.a.dupe(*hir.Stmt, &.{asn}) };
        const ap = rp orelse {
            if (arm.guard() != null) return error.Unsupported; // guarded `_`: later
            if (default != null) return error.Unsupported; // two `_` arms
            default = body;
            continue;
        };
        // A guard (`P if cond -> …`): build the condition in the arm's scope.
        // Payload-binding arms are out of v0 scope (the prelude loads run in
        // the body, after the guard would read them).
        var guard: ?*hir.Expr = null;
        if (arm.guard()) |gexpr| {
            if (ap.prelude.len != 0) return error.Unsupported;
            if (!try exprIsBool(b, gexpr, scope)) return error.Unsupported;
            guard = try buildIntExpr(b, gexpr, scope);
        }
        // A literal sub-pattern condition (`Move(0, y)`) ANDs onto the guard.
        const combined = try andOpt(b, ap.cond, guard);
        try arms.append(b.a, .{ .tag = ap.tag, .body = try prependPrelude(b, ap.prelude, body), .guard = combined });
        // Coverage only counts for enums (a literal can be any i64); a
        // guarded arm may fail, so it never contributes to exhaustiveness.
        if (info_opt != null and combined == null) seen |= @as(u64, 1) << @intCast(ap.tag);
    }
    // Structural exhaustiveness, like the statement form.
    if (default == null) {
        const info = info_opt orelse return error.Unsupported;
        if (@popCount(seen) < info.variants.len) return error.Unsupported;
    }

    try foldMatchChain(b, s_idx, boxed, arms.items, default, out);
}

/// A match arm's body as one HIR block: a `{ … }` block of statements,
/// or a single `->` expression statement.
fn buildMatchArmBody(b: *Builder, arm: ast.MatchArm, scope: *Scope, rt: *RtMap) BuildError!*hir.Stmt {
    if (arm.block()) |blk| return buildMainBlock(b, blk, scope, rt);
    const e = arm.expression() orelse return error.Unsupported;
    var items: std.ArrayList(*hir.Stmt) = .empty;
    try buildMainExprStmt(b, e, scope, rt, &items);
    const blkst = try b.a.create(hir.Stmt);
    blkst.* = .{ .block = try items.toOwnedSlice(b.a) };
    return blkst;
}

/// Build one of `main`'s expression statements — a statement-position
/// generic call, a host-face call, or `env.out(…)`. Shared by the
/// expr-statement arm and `match` arm bodies.
fn buildMainExprStmt(b: *Builder, expr: ast.Expr, scope: *Scope, rt: *RtMap, out: *std.ArrayList(*hir.Stmt)) BuildError!void {
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
            // `v.push(x)` on a vec binding (the v0 Vec floor).
            if (try tryVecPush(b, call, scope)) |st| {
                try out.append(b.a, st);
                return;
            }
            // `ch.send(x)` on a channel binding — a vec_push onto the buffer.
            if (try tryChannelSend(b, call, scope)) |st| {
                try out.append(b.a, st);
                return;
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
            // `c.bump()` — an actor void handler (tell) on a record binding.
            if (try tryActorTell(b, call, scope)) |st| {
                try out.append(b.a, st);
                return;
            }
            // A statement-position call to a void procedure (`log(5)`): build
            // the call and discard its (absent) result. A non-void call here
            // is rejected — a value may not be left on the stack.
            if (!isEnvOut(b.a, call)) {
                const cname = callPathName(b, call) orelse return reject(b, .unsupported_call);
                defer b.a.free(cname);
                if (std.mem.indexOfScalar(u8, cname, '.') != null) return reject(b, .unsupported_call);
                if (b.resolver.lookup(cname) == null) return reject(b, .name_not_found);
                const id = try registerFunc(b, cname);
                if (b.funcs.items[id].ret != .void) return reject(b, .unsupported_call);
                const e = try b.a.create(hir.Expr);
                e.* = .{ .call = .{ .func = id, .args = try buildCallArgs(b, id, call.args(), scope, null) } };
                const st = try b.a.create(hir.Stmt);
                st.* = .{ .expr = e };
                try out.append(b.a, st);
                return;
            }
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
            } else if ((try exprScalar(b, arg, scope)) == .str) {
                // A str-valued expression (`s.slice(0, 5)`, a binding copy).
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
    if (is.ifLet()) |il| return buildMainIfLet(b, is, il, scope, rt);
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

/// `while let <pattern> = <scrutinee> { … }` in `main`: a loop that
/// re-evaluates the scrutinee each iteration, breaks when the tag
/// doesn't match the pattern's variant, and otherwise runs the body
/// with the payload bindings in scope.
fn buildMainWhileLet(b: *Builder, ws: ast.WhileStmt, il: ast.IfCondLet, scope: *Scope, rt: *RtMap, out: *std.ArrayList(*hir.Stmt)) BuildError!void {
    const scrut = il.scrutinee() orelse return error.Unsupported;
    const info = (try enumOfExpr(b, scope, scrut)) orelse return error.Unsupported;
    const boxed = info.si != null;

    var items: std.ArrayList(*hir.Stmt) = .empty;
    const s_idx = try declareMatchScrutinee(b, scope, scrut, boxed, &items);
    const pat = il.pattern() orelse return error.Unsupported;
    const ap = (try resolveArmPattern(b, info, pat, scope, s_idx)) orelse return error.Unsupported;

    // if (tag != want) break
    const sread = if (boxed) blk: {
        const base = try b.a.create(hir.Expr);
        base.* = .{ .local = .{ .idx = s_idx, .ty = .ptr } };
        const ld = try b.a.create(hir.Expr);
        ld.* = .{ .field_get = .{ .base = base, .offset = 0, .ty = .i64 } };
        break :blk ld;
    } else blk: {
        const r = try b.a.create(hir.Expr);
        r.* = .{ .local = .{ .idx = s_idx, .ty = .i64 } };
        break :blk r;
    };
    const tagv = try b.a.create(hir.Expr);
    tagv.* = .{ .int_const = ap.tag };
    const cond = try b.a.create(hir.Expr);
    cond.* = .{ .bin = .{ .kind = .ne, .lhs = sread, .rhs = tagv } };
    const brk = try b.a.create(hir.Stmt);
    brk.* = .brk;
    const then_blk = try b.a.create(hir.Stmt);
    then_blk.* = .{ .block = try b.a.dupe(*hir.Stmt, &.{brk}) };
    const iff = try b.a.create(hir.Stmt);
    iff.* = .{ .if_ = .{ .cond = cond, .then_ = then_blk, .else_ = null } };
    try items.append(b.a, iff);

    try items.appendSlice(b.a, ap.prelude);
    var bit = (ws.body() orelse return error.Unsupported).statements();
    while (bit.next()) |bstmt| try buildMainStmt(b, bstmt, scope, rt, &items);

    const lbody = try b.a.create(hir.Stmt);
    lbody.* = .{ .block = try items.toOwnedSlice(b.a) };
    const st = try b.a.create(hir.Stmt);
    st.* = .{ .loop_ = lbody };
    try out.append(b.a, st);
}

/// `if let <pattern> = <scrutinee> { … } else { … }` in `main`: a
/// one-arm match. The scrutinee (an enum value) evaluates once; the
/// pattern's variant tag selects the then-block with its payload
/// bindings in scope; anything else falls to the else branch (a block
/// or another `if`/`if let`). Wrapped in a block so the hidden
/// scrutinee local's set rides along.
fn buildMainIfLet(b: *Builder, is: ast.IfStmt, il: ast.IfCondLet, scope: *Scope, rt: *RtMap) BuildError!*hir.Stmt {
    const scrut = il.scrutinee() orelse return error.Unsupported;
    const info = (try enumOfExpr(b, scope, scrut)) orelse return error.Unsupported;
    const boxed = info.si != null;

    var stmts: std.ArrayList(*hir.Stmt) = .empty;
    const s_idx = try declareMatchScrutinee(b, scope, scrut, boxed, &stmts);
    const pat = il.pattern() orelse return error.Unsupported;
    // A wildcard head is pointless here (always taken) — Unsupported.
    const ap = (try resolveArmPattern(b, info, pat, scope, s_idx)) orelse return error.Unsupported;
    const then_blk = try buildMainBlock(b, is.thenBody() orelse return error.Unsupported, scope, rt);
    const then_ = try prependPrelude(b, ap.prelude, then_blk);
    const else_: ?*hir.Stmt = if (is.elseIf()) |eif| blk: {
        const inner = try buildMainIfNode(b, eif, scope, rt);
        const wrap = try b.a.create(hir.Stmt);
        wrap.* = .{ .block = try b.a.dupe(*hir.Stmt, &.{inner}) };
        break :blk wrap;
    } else if (is.elseBody()) |eb|
        try buildMainBlock(b, eb, scope, rt)
    else
        null;
    try foldMatchChain(b, s_idx, boxed, &.{.{ .tag = ap.tag, .body = then_ }}, else_, &stmts);
    const out = try b.a.create(hir.Stmt);
    out.* = .{ .block = try stmts.toOwnedSlice(b.a) };
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

/// Seed a callee body scope with the function's parameters and fill the
/// parallel `params` / `rec_params` lists. Scalars (i64/bool/f64/f32) take one
/// slot; a `str` param takes two (ptr at idx, len at idx+1); a record param is
/// one `.ptr` into the caller's arena (registered in `scope.recs`). Returns
/// whether any param is a record (the caller folds in a record *return*).
/// Shared by the value-, str-, and void-returning callee registrations.
fn collectCalleeParams(
    b: *Builder,
    fd: ast.FnDecl,
    scope: *Scope,
    params: *std.ArrayList(hir.Param),
    rec_params: *std.ArrayList(?*const StructInfo),
) BuildError!bool {
    var any_rec = false;
    if (fd.params()) |ps| {
        var pit = ps.iter();
        while (pit.next()) |p| {
            const pn = (p.name() orelse return error.Unsupported).text;
            // A `fn`-typed parameter is a closure slot — inlined at lowering,
            // so it has no runtime ABI and occupies no local slot.
            if (paramIsFnTyped(p)) continue;
            // A `Vec<…>` parameter: one address-width pointer (like a record),
            // registered as a vec so `for x in xs` / `xs[i]` resolve in the body.
            if (paramIsVec(b, p)) {
                _ = try scope.declare(pn, false, .ptr);
                try scope.vecs.put(b.a, pn, {});
                try params.append(b.a, .{ .name = pn, .ty = .ptr });
                try rec_params.append(b.a, null);
                continue;
            }
            if (try paramScalar(b, p)) |psc| {
                if (psc == .str) {
                    // A `str` param: one hir param (two wasm locals — ptr at
                    // idx, len at idx+1, the str-binding convention).
                    _ = try scope.declare(pn, false, .str);
                    const len_hidden = try std.fmt.allocPrint(b.a, "{s}#len", .{pn});
                    _ = try scope.declare(len_hidden, false, .ptr);
                    try params.append(b.a, .{ .name = pn, .ty = .str });
                    try rec_params.append(b.a, null);
                    continue;
                }
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
            } else if (try enumOfType(b, p.type_())) |einfo| {
                // An immediate (all-unit) enum param: the tag travels as an
                // i64; register it so `match c { … }` resolves bare variants.
                if (einfo.si != null) return error.Unsupported; // boxed: handled above
                _ = try scope.declare(pn, false, .i64);
                try scope.enum_binds.put(b.a, pn, einfo);
                try params.append(b.a, .{ .name = pn, .ty = .i64 });
                try rec_params.append(b.a, null);
            } else return error.Unsupported;
        }
    }
    return any_rec;
}

/// Resolve `name` to a registered i64 function, building it (and anything it
/// calls) the first time. Returns its FuncId. The id and the parameter list
/// are reserved *before* the body is built, so a recursive call inside the
/// body sees the correct arity (not the placeholder's).
fn registerFunc(b: *Builder, name: []const u8) BuildError!hir.FuncId {
    if (b.ids.get(name)) |id| return id;

    const fd = b.resolver.lookup(name) orelse return reject(b, .name_not_found);
    const rec_ret = try structOfRet(b, fd);
    // No return type and no record return: a void-returning procedure (a
    // helper run for its side effects — `env.out`, calls, host faces).
    if (rec_ret == null and fd.returnType() == null) return registerVoidFunc(b, name, fd);
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

    // Parameters occupy local indices 0..n; seed the body scope. Callee
    // bookkeeping: locals are tracked by `scope.declare` alone (no cur_locals
    // mirror).
    var scope = Scope{ .a = b.a, .callee = true };
    var params: std.ArrayList(hir.Param) = .empty;
    var rec_params: std.ArrayList(?*const StructInfo) = .empty;
    const any_rec = (try collectCalleeParams(b, fd, &scope, &params, &rec_params)) or (rec_ret != null);
    // Param-occupied scope slots (a str param takes two: ptr + len).
    scope.n_params = scope.next_idx;
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
    try recordVecParams(b, id, fd);

    // A record-returning function: v0 bodies are one tail statement — a
    // record expression (a literal, a passthrough param, an enum
    // constructor, a record-returning call) or an `if`/`else` chain
    // whose every branch yields the record (`if n > 0 { Some(n) } else
    // { None }`). Leading statements land with a later slice.
    if (rec_ret) |want| {
        const block = try buildRecBody(b, fd.body() orelse return error.Unsupported, &scope, want);
        // Leading statements (incl. the try desugar) declare locals.
        const rec_extra = scope.extra();
        const rec_locals = try b.a.alloc(hir.Type, rec_extra);
        for (rec_locals, 0..) |*t, j| {
        const ty = scope.locals.items[scope.n_params + j].ty;
        t.* = if (ty == .str) .ptr else ty;
    }
        b.funcs.items[id] = .{ .name = owned, .params = param_slice, .ret = .ptr, .locals = rec_locals, .body = block, .ret_size = want.size, .ret_ptr_bearing = enumHasStrPayload(b, want) };
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
    for (locals, 0..) |*t, j| {
        const ty = scope.locals.items[scope.n_params + j].ty;
        t.* = if (ty == .str) .ptr else ty; // a str binding's backing slots are address-width
    }

    b.funcs.items[id] = .{ .name = owned, .params = param_slice, .ret = ret_ty, .locals = locals, .body = body };
    return id;
}

/// Register a void-returning procedure — a helper run for its side effects.
/// Body statements: `env.out(…)`, value `let`/`var` bindings, local
/// reassignment, `if`/`else`, `while`, statement-position calls (void user
/// calls + host faces), and a bare `return`. The body lowers through the
/// entry/void path (every statement is a void inst — see lower.zig's
/// `lowerEntryStmt`, routed by `hf.ret == .void`). v0 boundary: no `match`,
/// records, arrays, or `for` in the body, and no runtime str bindings
/// (`let s = shout(x)`) — str *arguments* to `env.out` are fine.
fn registerVoidFunc(b: *Builder, name: []const u8, fd: ast.FnDecl) BuildError!hir.FuncId {
    const owned = try b.a.dupe(u8, name);
    var scope = Scope{ .a = b.a, .callee = true };
    var params: std.ArrayList(hir.Param) = .empty;
    var rec_params: std.ArrayList(?*const StructInfo) = .empty;
    const any_rec = try collectCalleeParams(b, fd, &scope, &params, &rec_params);
    scope.n_params = scope.next_idx;
    const param_slice = try params.toOwnedSlice(b.a);

    // Reserve the id (with the real params) before the body so a recursive
    // call inside it sees the correct arity.
    const id: hir.FuncId = @intCast(b.funcs.items.len);
    try b.ids.put(b.a, owned, id);
    const dummy = try b.a.create(hir.Stmt);
    dummy.* = .{ .block = &.{} };
    try b.funcs.append(b.a, .{ .name = owned, .params = param_slice, .ret = .void, .body = dummy });
    if (any_rec) {
        try b.fn_recs.put(b.a, id, .{ .params = try rec_params.toOwnedSlice(b.a), .ret = null });
    } else {
        rec_params.deinit(b.a);
    }

    const block = try buildVoidBlock(b, fd.body() orelse return error.Unsupported, &scope);
    const extra = scope.extra();
    const locals = try b.a.alloc(hir.Type, extra);
    for (locals, 0..) |*t, j| {
        const ty = scope.locals.items[scope.n_params + j].ty;
        t.* = if (ty == .str) .ptr else ty; // a str binding's backing slots are address-width
    }
    const vis: hir.Visibility = if (fd.visibility() != null) .public else .private;
    b.funcs.items[id] = .{ .name = owned, .params = param_slice, .ret = .void, .locals = locals, .body = block, .visibility = vis };
    return id;
}

/// Build a `{ … }` block of void-procedure statements into one HIR block.
fn buildVoidBlock(b: *Builder, block: ast.Block, scope: *Scope) BuildError!*hir.Stmt {
    var items: std.ArrayList(*hir.Stmt) = .empty;
    var it = block.statements();
    while (it.next()) |stmt| try buildVoidStmt(b, stmt, scope, &items);
    const out = try b.a.create(hir.Stmt);
    out.* = .{ .block = try items.toOwnedSlice(b.a) };
    return out;
}

/// Build one void-procedure statement. Value-only statements (`let`, `assign`)
/// reuse the callee statement builder; control flow whose bodies may contain
/// side effects (`if`/`while`) recurses through `buildVoidBlock`; expression
/// statements are `env.out`, host-face calls, or void user calls.
fn buildVoidStmt(b: *Builder, stmt: ast.Stmt, scope: *Scope, out: *std.ArrayList(*hir.Stmt)) BuildError!void {
    switch (stmt) {
        .expr_stmt => |es| try buildVoidExprStmt(b, es.expression() orelse return error.Unsupported, scope, out),
        .if_stmt => |is| try out.append(b.a, try buildVoidIfNode(b, is, scope)),
        .match_stmt => |ms| try buildVoidMatch(b, ms, scope, out),
        .while_stmt => |ws| {
            const cond = try buildIntExpr(b, ws.condition() orelse return error.Unsupported, scope);
            const body = try buildVoidBlock(b, ws.body() orelse return error.Unsupported, scope);
            const st = try b.a.create(hir.Stmt);
            st.* = .{ .while_ = .{ .cond = cond, .body = body } };
            try out.append(b.a, st);
        },
        .return_stmt => |rs| {
            if (rs.value() != null) return error.Unsupported; // a void procedure returns no value
            const st = try b.a.create(hir.Stmt);
            st.* = .{ .ret = null };
            try out.append(b.a, st);
        },
        // `let`/`var` bindings and reassignment carry no side effects of their
        // own — the value-callee statement builder handles them identically.
        .let_stmt, .assign_stmt, .break_stmt, .continue_stmt => try out.append(b.a, try buildIntStmt(b, stmt, scope)),
        .scope_stmt => |ss| try buildVoidScopeStmt(b, ss, scope, out),
        else => return error.Unsupported,
    }
}

/// `scope { … }` in a void procedure — the callee analogue of
/// `buildScopeStmt`. Same cooperative-floor lowering (parent flow first,
/// spawned task bodies hoisted to the join), routed through `buildVoidStmt`.
/// Emit one spawned task's body inline at the current point (callee/void
/// position) — the `buildVoidStmt` mirror of `emitSpawnTaskMain`.
fn emitSpawnTaskVoid(b: *Builder, sp: ast.SpawnExpr, scope: *Scope, out: *std.ArrayList(*hir.Stmt)) BuildError!void {
    if (sp.block()) |body| {
        var bit = body.statements();
        while (bit.next()) |bstmt| try buildVoidStmt(b, bstmt, scope, out);
    } else if (sp.scopeStmt()) |inner| {
        try buildVoidScopeStmt(b, inner, scope, out);
    } else return error.Unsupported;
}

fn buildVoidScopeStmt(b: *Builder, ss: ast.ScopeStmt, scope: *Scope, out: *std.ArrayList(*hir.Stmt)) BuildError!void {
    var carms = ss.catchArms();
    if (carms.next() != null) return error.Unsupported; // panic-catch needs the EH runtime
    const blk = ss.block() orelse return error.Unsupported;
    // Cyclic / parking / backpressured tasks need the round-robin scheduler,
    // just as in `main` (`buildScopeStmt`). `buildScopeScheduled` is builder-
    // agnostic (it dispatches on `scope.callee`), so the same lowering serves a
    // scope inside a function body. The gate is conservative — no static
    // eager/deferred program is ever routed here.
    var rt: RtMap = .empty;
    defer rt.deinit(b.a);
    if (scopeNeedsScheduler(b, blk, scope)) return buildScopeScheduled(b, blk, scope, &rt, out);
    // Same consumer-before-producer deferral as the main-position scope
    // (see `buildScopeStmt`): a recv on a not-yet-fed channel is deferred to
    // the join so a later producer fills it first.
    var sent: std.StringHashMapUnmanaged(void) = .empty;
    defer sent.deinit(b.a);
    var deferred: std.ArrayList(ast.SpawnExpr) = .empty;
    defer deferred.deinit(b.a);
    var it = blk.statements();
    while (it.next()) |stmt| {
        if (spawnExprOf(stmt)) |sp| {
            if (taskWouldBlock(b, sp, scope, &sent)) {
                try deferred.append(b.a, sp);
                continue;
            }
            try recordTaskSends(b, sp, scope, &sent);
            try emitSpawnTaskVoid(b, sp, scope, out);
        } else {
            if (stmtChanTarget(b, stmt, scope, "send")) |c| try sent.put(b.a, c, {});
            try buildVoidStmt(b, stmt, scope, out);
        }
    }
    for (deferred.items) |sp| try emitSpawnTaskVoid(b, sp, scope, out);
}

/// A void expression statement: `env.out(…)`, a host-face call, or a
/// statement-position call to another void procedure. Shared by
/// `buildVoidStmt` and `buildVoidMatch`'s single-expression arms.
fn buildVoidExprStmt(b: *Builder, expr: ast.Expr, scope: *Scope, out: *std.ArrayList(*hir.Stmt)) BuildError!void {
    const call = switch (expr) {
        .call => |cc| cc,
        else => return error.Unsupported,
    };
    if (isEnvOut(b.a, call)) {
        try out.append(b.a, try buildVoidEnvOut(b, call, scope));
        return;
    }
    if (try hostFaceName(b, call)) |fname| {
        try out.append(b.a, try buildHostCall(b, fname, call, scope, null));
        return;
    }
    // `ch.send(x)` on a channel binding (vec_push), and `c.bump()` — an actor
    // void handler (tell) — both dispatch on a record/channel binding.
    if (try tryChannelSend(b, call, scope)) |st| {
        try out.append(b.a, st);
        return;
    }
    if (try tryActorTell(b, call, scope)) |st| {
        try out.append(b.a, st);
        return;
    }
    // A statement-position call to another void procedure; its result (there
    // is none) is discarded. A value-returning call here is rejected — nothing
    // may be left on the stack (lower.zig enforces the same on `.expr`).
    const cname = callPathName(b, call) orelse return error.Unsupported;
    defer b.a.free(cname);
    if (std.mem.indexOfScalar(u8, cname, '.') != null) return error.Unsupported;
    const id = try registerFunc(b, cname);
    if (b.funcs.items[id].ret != .void) return reject(b, .unsupported_call);
    const e = try b.a.create(hir.Expr);
    e.* = .{ .call = .{ .func = id, .args = try buildCallArgs(b, id, call.args(), scope, null) } };
    const st = try b.a.create(hir.Stmt);
    st.* = .{ .expr = e };
    try out.append(b.a, st);
}

/// A statement-position `match` in a void procedure — the side-effecting
/// form. Same scrutinee/tag/exhaustiveness machinery as `buildMainMatch`,
/// but each arm body is built through the void statement set (`env.out`,
/// nested control flow, void calls), so no value need be yielded.
fn buildVoidMatch(b: *Builder, ms: ast.MatchStmt, scope: *Scope, out: *std.ArrayList(*hir.Stmt)) BuildError!void {
    const scrut = ms.scrutinee() orelse return error.Unsupported;
    const info_opt = try enumOfExpr(b, scope, scrut);
    if (info_opt == null and (try exprScalar(b, scrut, scope)) != .i64) return error.Unsupported;
    const boxed = if (info_opt) |info| info.si != null else false;

    const s_idx = try declareMatchScrutinee(b, scope, scrut, boxed, out);

    var arms: std.ArrayList(LoweredArm) = .empty;
    defer arms.deinit(b.a);
    var default: ?*hir.Stmt = null;
    var seen: u64 = 0;
    var it = ms.arms();
    while (it.next()) |arm| {
        const pat = arm.pattern() orelse return error.Unsupported;
        if (pat.kind() == .OR_PATTERN) {
            if (arm.guard() != null) return error.Unsupported; // guards on or-patterns: later
            const body = try buildVoidMatchArmBody(b, arm, scope);
            var alts = pat.alternatives();
            var n: usize = 0;
            while (alts.next()) |alt| {
                n += 1;
                const ap2 = (if (info_opt) |info|
                    try resolveArmPattern(b, info, alt, scope, s_idx)
                else
                    try resolveLiteralPattern(b, alt)) orelse return error.Unsupported;
                if (ap2.prelude.len != 0 or ap2.cond != null) return error.Unsupported;
                try arms.append(b.a, .{ .tag = ap2.tag, .body = body });
                if (info_opt != null) seen |= @as(u64, 1) << @intCast(ap2.tag);
            }
            if (n == 0) return error.Unsupported;
            continue;
        }
        if (info_opt == null and pat.kind() == .IDENT_PATTERN) {
            const nm = pat.bindingName() orelse return error.Unsupported;
            try aliasLocal(scope, nm.text, s_idx, .i64);
            const body = try buildVoidMatchArmBody(b, arm, scope);
            if (arm.guard()) |gexpr| {
                if (!try exprIsBool(b, gexpr, scope)) return error.Unsupported;
                const guard = try buildIntExpr(b, gexpr, scope);
                try arms.append(b.a, .{ .tag = 0, .body = body, .guard = guard, .any = true });
            } else {
                if (default != null) return error.Unsupported;
                default = body;
            }
            continue;
        }
        if (info_opt == null and pat.kind() == .RANGE_PATTERN) {
            const cond = try buildRangePatternCond(b, scope, pat, arm, s_idx);
            const body = try buildVoidMatchArmBody(b, arm, scope);
            try arms.append(b.a, .{ .tag = 0, .body = body, .guard = cond, .any = true });
            continue;
        }
        const rp = if (info_opt) |info|
            try resolveArmPattern(b, info, pat, scope, s_idx)
        else
            try resolveLiteralPattern(b, pat);
        const body = try buildVoidMatchArmBody(b, arm, scope);
        const ap = rp orelse {
            if (arm.guard() != null) return error.Unsupported; // guarded `_`: later
            if (default != null) return error.Unsupported; // two `_` arms
            default = body;
            continue;
        };
        var guard: ?*hir.Expr = null;
        if (arm.guard()) |gexpr| {
            if (ap.prelude.len != 0) return error.Unsupported;
            if (!try exprIsBool(b, gexpr, scope)) return error.Unsupported;
            guard = try buildIntExpr(b, gexpr, scope);
        }
        // A literal sub-pattern condition (`Move(0, y)`) ANDs onto the guard.
        const combined = try andOpt(b, ap.cond, guard);
        try arms.append(b.a, .{ .tag = ap.tag, .body = try prependPrelude(b, ap.prelude, body), .guard = combined });
        if (info_opt != null and combined == null) seen |= @as(u64, 1) << @intCast(ap.tag);
    }
    if (default == null) {
        const info = info_opt orelse return error.Unsupported;
        if (@popCount(seen) < info.variants.len) return error.Unsupported;
    }
    try foldMatchChain(b, s_idx, boxed, arms.items, default, out);
}

/// A void match arm's body as one HIR block: a `{ … }` block of void
/// statements, or a single `->` void expression statement.
fn buildVoidMatchArmBody(b: *Builder, arm: ast.MatchArm, scope: *Scope) BuildError!*hir.Stmt {
    if (arm.block()) |blk| return buildVoidBlock(b, blk, scope);
    const e = arm.expression() orelse return error.Unsupported;
    var items: std.ArrayList(*hir.Stmt) = .empty;
    try buildVoidExprStmt(b, e, scope, &items);
    const blkst = try b.a.create(hir.Stmt);
    blkst.* = .{ .block = try items.toOwnedSlice(b.a) };
    return blkst;
}

/// The void-procedure analogue of `buildIfStmtNode`: an `if`/`else(-if)` whose
/// bodies may contain side effects, built through `buildVoidBlock`.
fn buildVoidIfNode(b: *Builder, is: ast.IfStmt, scope: *Scope) BuildError!*hir.Stmt {
    const cond = try buildIntExpr(b, is.condition() orelse return error.Unsupported, scope);
    const then_ = try buildVoidBlock(b, is.thenBody() orelse return error.Unsupported, scope);
    const else_: ?*hir.Stmt = if (is.elseIf()) |eif| blk: {
        const inner = try buildVoidIfNode(b, eif, scope);
        const wrap = try b.a.create(hir.Stmt);
        wrap.* = .{ .block = try b.a.dupe(*hir.Stmt, &.{inner}) };
        break :blk wrap;
    } else if (is.elseBody()) |eb|
        try buildVoidBlock(b, eb, scope)
    else
        null;
    const out = try b.a.create(hir.Stmt);
    out.* = .{ .if_ = .{ .cond = cond, .then_ = then_, .else_ = else_ } };
    return out;
}

/// `env.out(<arg>)` in a void procedure: the same str/bool/float/i64
/// classification as `main`'s form, but without const-folding or runtime
/// str-binding lookups (callee bodies have neither).
fn buildVoidEnvOut(b: *Builder, call: ast.CallExpr, scope: *Scope) BuildError!*hir.Stmt {
    const arg = firstArg(call) orelse return error.Unsupported;
    const st = try b.a.create(hir.Stmt);
    if (arg == .string_lit) {
        // A string literal, possibly interpolated: a fully-constant run folds
        // to `host_out`, otherwise a runtime concat.
        const v = try buildConcat(b, arg.string_lit, scope, true, null);
        st.* = if (v.* == .str_const) .{ .host_out = v } else .{ .host_out_str = v };
    } else if ((try isStrCall(b, arg, scope)) or (try exprScalar(b, arg, scope)) == .str) {
        st.* = .{ .host_out_str = try buildStrExpr(b, arg, scope, null) };
    } else if (try exprIsBool(b, arg, scope)) {
        st.* = .{ .host_out_bool = try buildIntExpr(b, arg, scope) };
    } else if (isFloatSc(try exprScalar(b, arg, scope))) {
        var fv = try buildIntExpr(b, arg, scope);
        if ((try exprScalar(b, arg, scope)) == .f32) {
            const w = try b.a.create(hir.Expr);
            w.* = .{ .num_cast = .{ .to = .f64, .value = fv } };
            fv = w;
        }
        st.* = .{ .host_out_float = fv };
    } else {
        st.* = .{ .host_out_int = try buildIntExpr(b, arg, scope) };
    }
    return st;
}

/// A record-returning body: leading statements (the shared callee-body
/// set, plus the `let x = try …` propagation form) and one
/// record-yielding tail statement, as the function's value block.
fn buildRecBody(b: *Builder, blk: ast.Block, scope: *Scope, want: *const StructInfo) BuildError!*hir.Stmt {
    var ast_stmts: std.ArrayList(ast.Stmt) = .empty;
    defer ast_stmts.deinit(b.a);
    var it = blk.statements();
    while (it.next()) |stmt| try ast_stmts.append(b.a, stmt);
    const n = ast_stmts.items.len;
    if (n == 0) return error.Unsupported;

    var stmts: std.ArrayList(*hir.Stmt) = .empty;
    for (ast_stmts.items[0 .. n - 1]) |stmt| {
        try buildRecSetupStmt(b, stmt, scope, want, &stmts);
    }
    try stmts.append(b.a, try buildRecTailStmt(b, ast_stmts.items[n - 1], scope, want));
    const block = try b.a.create(hir.Stmt);
    block.* = .{ .block = try stmts.toOwnedSlice(b.a) };
    return block;
}

/// A leading (non-tail) statement in a record/enum-returning body: the
/// `let x = try <expr>` propagation form desugars here; everything
/// else is the shared callee-body statement set.
fn buildRecSetupStmt(b: *Builder, stmt: ast.Stmt, scope: *Scope, want: *const StructInfo, out: *std.ArrayList(*hir.Stmt)) BuildError!void {
    if (stmt == .let_stmt) {
        const ls = stmt.let_stmt;
        if (ls.initializer()) |init_expr| {
            if (init_expr == .@"try") {
                return buildTryLet(b, ls, init_expr.@"try", scope, want, out);
            }
        }
    }
    try out.append(b.a, try buildIntStmt(b, stmt, scope));
}

/// `let x = try <expr>` inside a Result-returning body (errors.md
/// §"The `try` keyword", v0 floor): evaluate the operand — a Result
/// value of the same boxed enum — once; on `Err` return the value
/// as-is (same-E only; the `From`-conversion rung is later, and at
/// this floor the boxed representation is identical either way); on
/// `Ok` bind the payload slot (one i64).
fn buildTryLet(b: *Builder, ls: ast.LetStmt, te: ast.TryExpr, scope: *Scope, want: *const StructInfo, out: *std.ArrayList(*hir.Stmt)) BuildError!void {
    const res_info = b.enums.get("Result") orelse return error.Unsupported;
    if (res_info.si == null) return error.Unsupported;
    // `try` requires the *enclosing* function to return Result — the
    // friendly diagnostic (TYP300) is `q64 check`'s. Instantiations
    // share the enum name; the box layout is per-instantiation.
    if (!std.mem.eql(u8, want.name, "Result")) return error.Unsupported;
    const err_tag: i64 = @intCast(res_info.variantTag("Err") orelse return error.Unsupported);
    const operand = te.operand() orelse return error.Unsupported;
    const info = (try enumOfExpr(b, scope, operand)) orelse return error.Unsupported;
    const isi = info.si orelse return error.Unsupported;
    if (!std.mem.eql(u8, isi.name, "Result")) return error.Unsupported; // `try` takes a Result
    const rv = (try buildRecExpr(b, operand, scope)) orelse return error.Unsupported;

    // tmp = <operand>, evaluated once.
    const hidden = try std.fmt.allocPrint(b.a, "#try{d}", .{scope.locals.items.len});
    const tmp_idx = try scope.declare(hidden, false, .ptr);
    const set = try b.a.create(hir.Stmt);
    set.* = .{ .let = .{ .idx = tmp_idx, .value = rv.e } };
    try out.append(b.a, set);

    // if (tmp.#tag == Err) { return tmp }
    const base = try b.a.create(hir.Expr);
    base.* = .{ .local = .{ .idx = tmp_idx, .ty = .ptr } };
    const tag = try b.a.create(hir.Expr);
    tag.* = .{ .field_get = .{ .base = base, .offset = 0, .ty = .i64 } };
    const tagv = try b.a.create(hir.Expr);
    tagv.* = .{ .int_const = err_tag };
    const cond = try b.a.create(hir.Expr);
    cond.* = .{ .bin = .{ .kind = .eq, .lhs = tag, .rhs = tagv } };
    const tmp_read = try b.a.create(hir.Expr);
    tmp_read.* = .{ .local = .{ .idx = tmp_idx, .ty = .ptr } };
    const ret = try b.a.create(hir.Stmt);
    ret.* = .{ .ret = tmp_read };
    const then_blk = try b.a.create(hir.Stmt);
    then_blk.* = .{ .block = try b.a.dupe(*hir.Stmt, &.{ret}) };
    const iff = try b.a.create(hir.Stmt);
    iff.* = .{ .if_ = .{ .cond = cond, .then_ = then_blk, .else_ = null } };
    try out.append(b.a, iff);

    // let x = the Ok payload: an i64 cell, or a str (ptr/len cells 8/16,
    // narrowed to address width) when the instantiation says so.
    const nm = (ls.pattern() orelse return error.Unsupported).bindingName() orelse return error.Unsupported;
    const ok_tag = res_info.variantTag("Ok") orelse return error.Unsupported;
    if (info.variants[ok_tag].kind == .rec) {
        // A record Ok payload: bind the base pointer; field access +
        // dispatch resolve through `recs`.
        const idx = try declareBodyLocal(b, scope, nm.text, false, .ptr);
        try scope.recs.put(b.a, nm.text, info.variants[ok_tag].rec_si.?);
        const base3 = try b.a.create(hir.Expr);
        base3.* = .{ .local = .{ .idx = tmp_idx, .ty = .ptr } };
        const ld3 = try b.a.create(hir.Expr);
        ld3.* = .{ .field_get = .{ .base = base3, .offset = 8, .ty = .i64 } };
        const cast3 = try b.a.create(hir.Expr);
        cast3.* = .{ .num_cast = .{ .to = .ptr, .value = ld3 } };
        const st3 = try b.a.create(hir.Stmt);
        st3.* = .{ .let = .{ .idx = idx, .value = cast3 } };
        try out.append(b.a, st3);
        return;
    }
    if (info.variants[ok_tag].kind == .str_) {
        const ptr_idx = try declareStrBodyLocal(b, scope, nm.text);
        const len_idx = ptr_idx + 1;
        for ([_]struct { idx: u32, off: u32 }{ .{ .idx = ptr_idx, .off = 8 }, .{ .idx = len_idx, .off = 16 } }) |cell| {
            const base2 = try b.a.create(hir.Expr);
            base2.* = .{ .local = .{ .idx = tmp_idx, .ty = .ptr } };
            const ld = try b.a.create(hir.Expr);
            ld.* = .{ .field_get = .{ .base = base2, .offset = cell.off, .ty = .i64 } };
            const cast = try b.a.create(hir.Expr);
            cast.* = .{ .num_cast = .{ .to = .ptr, .value = ld } };
            const st2 = try b.a.create(hir.Stmt);
            st2.* = .{ .let = .{ .idx = cell.idx, .value = cast } };
            try out.append(b.a, st2);
        }
        return;
    }
    const base2 = try b.a.create(hir.Expr);
    base2.* = .{ .local = .{ .idx = tmp_idx, .ty = .ptr } };
    const ld = try b.a.create(hir.Expr);
    ld.* = .{ .field_get = .{ .base = base2, .offset = 8, .ty = .i64 } };
    const idx = try scope.declare(nm.text, ls.isVar(), .i64);
    const bindst = try b.a.create(hir.Stmt);
    bindst.* = .{ .let = .{ .idx = idx, .value = ld } };
    try out.append(b.a, bindst);
}

/// One record-yielding tail statement: a record expression, `return
/// <record>`, or a value `if`/`else` chain (every path must yield the
/// record, so the chain needs a final `else`). The lowering reads the
/// `if_` through `lowerValueIf` with the function's `.ptr` type.
fn buildRecTailStmt(b: *Builder, stmt: ast.Stmt, scope: *Scope, want: *const StructInfo) BuildError!*hir.Stmt {
    switch (stmt) {
        .expr_stmt => |es| return recValueStmt(b, es.expression() orelse return error.Unsupported, scope, want),
        .return_stmt => |rs| return recValueStmt(b, rs.value() orelse return error.Unsupported, scope, want),
        .if_stmt => |is| {
            const cond = try buildIntExpr(b, is.condition() orelse return error.Unsupported, scope);
            const then_ = try buildRecBody(b, is.thenBody() orelse return error.Unsupported, scope, want);
            const else_: *hir.Stmt = if (is.elseIf()) |eif| blk: {
                const inner = try buildRecTailStmt(b, .{ .if_stmt = eif }, scope, want);
                const wrap = try b.a.create(hir.Stmt);
                wrap.* = .{ .block = try b.a.dupe(*hir.Stmt, &.{inner}) };
                break :blk wrap;
            } else if (is.elseBody()) |eb|
                try buildRecBody(b, eb, scope, want)
            else
                return reject(b, .unsupported_call); // a value `if` needs an else
            const out = try b.a.create(hir.Stmt);
            out.* = .{ .if_ = .{ .cond = cond, .then_ = then_, .else_ = else_ } };
            return out;
        },
        .match_stmt => |ms| return buildRecMatch(b, ms, scope, want),
        else => return error.Unsupported,
    }
}

/// A `match` as a record-returning body's tail: every arm is a `->`
/// expression yielding the declared record/enum (`fn flip(o:
/// Option<i64>) -> Option<i64> { match o { Some(v) -> Some(v * 2),
/// None -> Some(0) } }`). Same shape as `buildIntMatch`, with
/// record-valued arms; an exhaustive match without `_` promotes its
/// last arm to the chain's else so every path yields.
fn buildRecMatch(b: *Builder, ms: ast.MatchStmt, scope: *Scope, want: *const StructInfo) BuildError!*hir.Stmt {
    const scrut = ms.scrutinee() orelse return error.Unsupported;
    const info = (try enumOfExpr(b, scope, scrut)) orelse return error.Unsupported;
    const boxed = info.si != null;

    var stmts: std.ArrayList(*hir.Stmt) = .empty;
    const s_idx = try declareMatchScrutinee(b, scope, scrut, boxed, &stmts);

    var arms: std.ArrayList(LoweredArm) = .empty;
    defer arms.deinit(b.a);
    var default: ?*hir.Stmt = null;
    var seen: u64 = 0;
    var it = ms.arms();
    while (it.next()) |arm| {
        const pat = arm.pattern() orelse return error.Unsupported;
        // Pattern first: payload bindings must be in scope for the value.
        const rp = try resolveArmPattern(b, info, pat, scope, s_idx);
        const e = arm.expression() orelse return error.Unsupported; // value arms only
        const vstmt = try recValueStmt(b, e, scope, want);
        const body = try b.a.create(hir.Stmt);
        body.* = .{ .block = try b.a.dupe(*hir.Stmt, &.{vstmt}) };
        const ap = rp orelse {
            if (default != null) return error.Unsupported; // two `_` arms
            default = body;
            continue;
        };
        try arms.append(b.a, .{ .tag = ap.tag, .body = try prependPrelude(b, ap.prelude, body) });
        seen |= @as(u64, 1) << @intCast(ap.tag);
    }
    if (default == null and @popCount(seen) < info.variants.len) return error.Unsupported;
    var arm_slice: []const LoweredArm = arms.items;
    var dflt = default;
    if (dflt == null) {
        dflt = arm_slice[arm_slice.len - 1].body;
        arm_slice = arm_slice[0 .. arm_slice.len - 1];
    }
    try foldMatchChain(b, s_idx, boxed, arm_slice, dflt, &stmts);
    const out = try b.a.create(hir.Stmt);
    out.* = .{ .block = try stmts.toOwnedSlice(b.a) };
    return out;
}

/// Does the enum's box carry a str payload in any variant?
fn enumHasStrPayload(b: *Builder, si: *const StructInfo) bool {
    if (b.enums.get(si.name)) |info| {
        if (info.si == si) {
            for (info.variants) |v| {
                if (v.kind == .str_ or v.kind == .rec) return true;
            }
        }
    } else return false;
    // The si belongs to some instantiation; conservatively treat any
    // Result/Option-family return as pointer-bearing when its box is
    // wider than tag+1 cell would suggest a str slot. Exact: scan all
    // cached instantiations for this si.
    var it = b.enum_insts.valueIterator();
    while (it.next()) |inst| {
        if (inst.*.si == si) {
            for (inst.*.variants) |v| {
                if (v.kind == .str_ or v.kind == .rec) return true;
            }
        }
    }
    return false;
}

/// A cheap non-building probe: the struct a record-valued argument
/// carries (a binding/param in `recs`, or a record literal's path).
fn recvStructQuiet(b: *Builder, scope: *const Scope, e: ast.Expr) ?*const StructInfo {
    switch (e) {
        .path => |p| {
            const txt = p.text(b.a) catch return null;
            defer b.a.free(txt);
            return scope.recs.get(txt);
        },
        .record => |re| {
            const pth = re.path() orelse return null;
            const nm = pth.text(b.a) catch return null;
            defer b.a.free(nm);
            return b.structs.get(nm);
        },
        else => return null,
    }
}

/// Two enum instantiations are layout-compatible when they share the
/// enum (`Err(404)` constructed standalone is the base layout; in a
/// `-> Result<str, i64>` context the tag + int cells coincide, and the
/// declared instantiation's size governs the caller's slide).
fn enumCompatible(b: *Builder, got: *const StructInfo, want: *const StructInfo) bool {
    if (!std.mem.eql(u8, got.name, want.name)) return false;
    return b.enums.contains(got.name);
}

/// Build `e` as a record value of exactly `want`, as a tail statement.
fn recValueStmt(b: *Builder, e: ast.Expr, scope: *Scope, want: *const StructInfo) BuildError!*hir.Stmt {
    const rv = (try buildRecExpr(b, e, scope)) orelse return error.Unsupported;
    if (rv.si != want and !enumCompatible(b, rv.si, want)) return reject(b, .unsupported_call); // a different struct/enum
    const vstmt = try b.a.create(hir.Stmt);
    vstmt.* = .{ .expr = rv.e };
    return vstmt;
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
    var scope = Scope{ .a = b.a, .callee = true };
    var params: std.ArrayList(hir.Param) = .empty;
    if (fd.params()) |ps| {
        var pit = ps.iter();
        while (pit.next()) |p| {
            const psc = (try paramScalar(b, p)) orelse return error.Unsupported;
            if (psc != .str) return error.Unsupported; // all-str params for now
            const pn = (p.name() orelse return error.Unsupported).text;
            // Two scope slots per str param (ptr at idx, len at idx+1) —
            // the raw str-binding convention, shared with mixed
            // signatures and main's bindings.
            _ = try scope.declare(pn, false, .str);
            const len_hidden = try std.fmt.allocPrint(b.a, "{s}#len", .{pn});
            _ = try scope.declare(len_hidden, false, .ptr);
            try params.append(b.a, .{ .name = pn, .ty = .str });
        }
    }
    scope.n_params = scope.next_idx;
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
                        // A str local (a param or a binding — ptr at idx,
                        // len at idx+1) passes through as-is; a numeric
                        // local interpolates as its decimal text
                        // (i64 via __fmt_i64, f64 via __fmt_f64).
                        if (loc.ty == .str) {
                            piece.* = .{ .str_binding = .{ .ptr_idx = loc.idx, .len_idx = loc.idx + 1 } };
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
/// One enum variant: its name and tuple-payload arity (0 = unit).
/// What a variant's payload holds (the v0 floor). `arity` is the
/// physical 8-byte cell count (`ints` n → n, `str_` → 2, `param` → per
/// instantiation).
const PayKind = enum {
    /// N i64 cells (the C3 floor).
    ints,
    /// One str payload: (ptr, len) in two cells (offset 8 / 16).
    str_,
    /// One generic slot (`Some(T)`) — resolved per instantiation;
    /// unresolved uses default to one i64 cell.
    param,
    /// One record slot (`Io(IoError)`): a cell holding the record's
    /// base pointer (`rec_si` names the struct). The payload ALIASES
    /// the stored record (the B2b whole-value boundary).
    rec,
};
const EnumVariant = struct { name: []const u8, arity: u32, kind: PayKind = .ints, pidx: u8 = 0, rec_si: ?*const StructInfo = null };

/// A registered enum: variant names in declaration order (a variant's
/// tag is its index). All-unit enums are *immediate* — a value is its
/// tag, an i64. An enum with tuple payloads is *boxed* — `si` carries
/// the arena representation `{ #tag, #p0 .. }` (spec/memory.md §"Enum
/// representation"), and values ride the record machinery.
const EnumInfo = struct {
    name: []const u8,
    variants: []const EnumVariant,
    si: ?*const StructInfo,

    fn variantTag(self: *const EnumInfo, name: []const u8) ?u32 {
        for (self.variants, 0..) |v, i| {
            if (std.mem.eql(u8, v.name, name)) return @intCast(i);
        }
        return null;
    }
};

const max_enum_payload = 4;

/// Register this file's enums (C1/C3) plus the auto-prelude pair. The
/// v0 floor: unit variants and tuple payloads of up to four fields,
/// each `i64` or one of the enum's type params (a `T` slot is an
/// 8-byte slot at the i64 compute floor); anything else skips the
/// enum — using it surfaces the honest Unsupported.
fn registerEnums(b: *Builder, sf: ast.SourceFile) BuildError!void {
    var it = sf.items();
    while (it.next()) |item| switch (item) {
        .enum_decl => |ed| {
            const nm = ed.name() orelse continue;
            // A generic enum's `<T, …>` header; payload slots may name
            // its params. Beyond-the-floor headers skip the enum.
            const sig: ?sema.fits.GenericSig = if (ed.genericParams()) |gp|
                sema.fits.parseGenericSig(gp) orelse continue
            else
                null;
            var vars: std.ArrayList(EnumVariant) = .empty;
            var ok = true;
            var vit = ed.variants();
            while (vit.next()) |v| {
                const vname = v.name() orelse {
                    ok = false;
                    break;
                };
                const slots = variantSlots(b, v, sig) orelse {
                    ok = false; // record payloads / non-floor fields: later
                    break;
                };
                try vars.append(b.a, .{ .name = vname.text, .arity = slots.arity, .kind = slots.kind, .pidx = slots.pidx, .rec_si = slots.rec_si });
            }
            if (!ok or vars.items.len == 0) {
                vars.deinit(b.a);
                continue;
            }
            try registerEnum(b, nm.text, try vars.toOwnedSlice(b.a));
        },
        else => {},
    };
    // The auto-prelude pair (spec/errors.md §"Result and Option"). A
    // file declaration of the same name shadows it (registered above,
    // so the prelude entry is skipped).
    if (!b.enums.contains("Option")) {
        try registerEnum(b, "Option", try b.a.dupe(EnumVariant, &.{
            .{ .name = "Some", .arity = 1, .kind = .param, .pidx = 0 },
            .{ .name = "None", .arity = 0 },
        }));
    }
    if (!b.enums.contains("Result")) {
        try registerEnum(b, "Result", try b.a.dupe(EnumVariant, &.{
            .{ .name = "Ok", .arity = 1, .kind = .param, .pidx = 0 },
            .{ .name = "Err", .arity = 1, .kind = .param, .pidx = 1 },
        }));
    }
}

/// Register one enum, computing the boxed arena shape — tag at 0,
/// payload slots after (spec/memory.md §"Enum representation (v0)") —
/// when any variant carries a payload.
fn registerEnum(b: *Builder, name: []const u8, vars: []const EnumVariant) BuildError!void {
    var max_arity: u32 = 0;
    for (vars) |v| {
        if (v.arity > max_arity) max_arity = v.arity;
    }
    var si: ?*const StructInfo = null;
    if (max_arity > 0) {
        var fields: std.ArrayList(StructField) = .empty;
        try fields.append(b.a, .{ .name = "#tag", .ty = .i64, .offset = 0 });
        var j: u32 = 0;
        while (j < max_arity) : (j += 1) {
            const fname = try std.fmt.allocPrint(b.a, "#p{d}", .{j});
            try fields.append(b.a, .{ .name = fname, .ty = .i64, .offset = 8 * (j + 1) });
        }
        const s = try b.a.create(StructInfo);
        s.* = .{
            .name = name,
            .fields = try fields.toOwnedSlice(b.a),
            .size = 8 * (max_arity + 1),
            .alignment = 8,
        };
        si = s;
    }
    const info = try b.a.create(EnumInfo);
    info.* = .{ .name = name, .variants = vars, .si = si };
    try b.enums.put(b.a, name, info);
}

/// A variant's payload at the v0 floor: 0 cells for a unit variant;
/// N `i64` slots; ONE `str` slot (two cells); or ONE type-param slot
/// (`Some(T)` — resolved per instantiation). `null` for record
/// payloads, mixed slot kinds, or anything else.
const VariantSlots = struct { arity: u32, kind: PayKind, pidx: u8, rec_si: ?*const StructInfo = null };
fn variantSlots(b: *Builder, v: ast.Variant, sig: ?sema.fits.GenericSig) ?VariantSlots {
    var buf: [4 * max_enum_payload]parser.cst.Token = undefined;
    var n: usize = 0;
    if (!flattenVariantTokens(v.cst, &buf, &n, true)) return null;
    if (n == 0) return .{ .arity = 0, .kind = .ints, .pidx = 0 }; // unit
    // Expect exactly: ( slot (, slot)* ,? )
    if (buf[0].kind != .L_PAREN or buf[n - 1].kind != .R_PAREN) return null;
    // One str / one type-param slot: `(str)` / `(T)`.
    if (n == 3 and buf[1].kind == .IDENT) {
        const t1 = buf[1].text;
        if (std.mem.eql(u8, t1, "str")) return .{ .arity = 2, .kind = .str_, .pidx = 0 };
        if (sig) |sg| {
            for (sg.params[0..sg.n], 0..) |p, i| {
                if (std.mem.eql(u8, t1, p.tname)) return .{ .arity = 1, .kind = .param, .pidx = @intCast(i) };
            }
        }
        // A registered struct: the cell holds the record's base pointer.
        if (b.structs.get(t1)) |rsi| return .{ .arity = 1, .kind = .rec, .pidx = 0, .rec_si = rsi };
    }
    // N i64 cells; a type-param name in a MULTI-slot payload stays at
    // the i64 floor (`Full(T, T)` — per-slot str instantiation is a
    // later slice; the single-slot form above handles `Some(T)`).
    var arity: u32 = 0;
    var i: usize = 1;
    while (i < n - 1) {
        const t = buf[i];
        if (t.kind == .IDENT and (std.mem.eql(u8, t.text, "i64") or paramNameOk(t.text, sig))) {
            arity += 1;
            i += 1;
            if (i < n - 1) {
                if (buf[i].kind != .COMMA) return null;
                i += 1;
            }
        } else return null;
    }
    if (arity == 0 or arity > max_enum_payload) return null;
    return .{ .arity = arity, .kind = .ints, .pidx = 0 };
}

fn paramNameOk(text: []const u8, sig: ?sema.fits.GenericSig) bool {
    const sg = sig orelse return false;
    for (sg.params[0..sg.n]) |p| {
        if (std.mem.eql(u8, text, p.tname)) return true;
    }
    return false;
}

/// The instantiation a path type's generic args pick (`Result<str, i64>`
/// → key "si"): each arg whose trimmed text is `str` maps to 's'.
fn instFromGenericArgs(b: *Builder, info: *const EnumInfo, pt: ast.PathType) BuildError!*const EnumInfo {
    var descs = [_][]const u8{ "i", "i", "i", "i" };
    if (try pt.genericArgsText(b.a)) |raw| {
        defer b.a.free(raw);
        var txt = raw;
        if (txt.len >= 2 and txt[0] == '<') txt = txt[1 .. txt.len - 1];
        var it = std.mem.splitScalar(u8, txt, ',');
        var i: usize = 0;
        while (it.next()) |part| : (i += 1) {
            if (i >= descs.len) break;
            const trimmed = std.mem.trim(u8, part, " \t");
            if (std.mem.eql(u8, trimmed, "str")) {
                descs[i] = "s";
            } else if (b.structs.contains(trimmed)) {
                descs[i] = try std.fmt.allocPrint(b.a, "r:{s}", .{trimmed});
            }
        }
    }
    return instantiateEnum(b, info, &descs);
}

/// The instantiation `T?` picks: `str?` → Option<str>.
fn instFromOptionalInner(b: *Builder, info: *const EnumInfo, ot: ast.OptionalType) BuildError!*const EnumInfo {
    var descs = [_][]const u8{ "i", "i", "i", "i" };
    if (ot.inner()) |inner| {
        if (inner == .path) {
            const nm = try inner.path.name(b.a);
            defer b.a.free(nm);
            if (std.mem.eql(u8, nm, "str")) {
                descs[0] = "s";
            } else if (b.structs.contains(nm)) {
                descs[0] = try std.fmt.allocPrint(b.a, "r:{s}", .{nm});
            }
        }
    }
    return instantiateEnum(b, info, &descs);
}

/// Resolve a generic enum to a concrete instantiation. `skey` holds one
/// 'i'/'s' per type param; the base registry entry IS the all-'i'
/// instantiation (today's behavior). Cached, so equal keys share one
/// EnumInfo (and one si — type identity is pointer identity).
fn instantiateEnum(b: *Builder, info: *const EnumInfo, descs: []const []const u8) BuildError!*const EnumInfo {
    var all_int = true;
    for (descs) |d| {
        if (!std.mem.eql(u8, d, "i")) all_int = false;
    }
    if (all_int) return info;
    const key = try std.fmt.allocPrint(b.a, "{s}\x00{s},{s},{s},{s}", .{ info.name, descs[0], descs[1], descs[2], descs[3] });
    if (b.enum_insts.get(key)) |inst| return inst;
    const vars = try b.a.dupe(EnumVariant, info.variants);
    for (vars) |*v| {
        if (v.kind != .param) continue;
        const d = if (v.pidx < descs.len) descs[v.pidx] else "i";
        if (std.mem.eql(u8, d, "s")) {
            v.kind = .str_;
            v.arity = 2;
        } else if (d.len > 2 and d[0] == 'r') {
            // "r:Name" — a record slot holding the struct's base ptr.
            v.rec_si = b.structs.get(d[2..]);
            if (v.rec_si != null) {
                v.kind = .rec;
                v.arity = 1;
            } else {
                v.kind = .ints;
                v.arity = 1;
            }
        } else {
            v.kind = .ints;
            v.arity = 1;
        }
    }
    var max_arity: u32 = 0;
    for (vars) |v| {
        if (v.arity > max_arity) max_arity = v.arity;
    }
    const sz: u32 = 8 * (max_arity + 1);
    const si = try b.a.create(StructInfo);
    si.* = .{
        .name = info.name,
        .fields = info.si.?.fields, // the #tag field; payload cells are untyped
        .size = sz,
        .alignment = 8,
    };
    const inst = try b.a.create(EnumInfo);
    inst.* = .{ .name = info.name, .variants = vars, .si = si };
    try b.enum_insts.put(b.a, key, inst);
    return inst;
}

/// Flatten a variant's non-trivia tokens (past the name) into `buf`.
/// `top` skips the leading variant-name token (an IDENT, or `KW_NONE`
/// — the prelude `Option.None`); a `{` (record payload) or overflow
/// returns false.
fn flattenVariantTokens(node: *const parser.cst.Node, buf: []parser.cst.Token, n: *usize, top: bool) bool {
    for (node.children) |c| switch (c) {
        .token => |t| {
            if (t.kind.isTrivia()) continue;
            if (t.kind == .L_BRACE) return false; // record payload: later
            if (top and (t.kind == .IDENT or t.kind == .KW_NONE) and n.* == 0) continue; // the variant name
            if (n.* == buf.len) return false;
            buf[n.*] = t;
            n.* += 1;
        },
        .node => |ch| if (!flattenVariantTokens(ch, buf, n, false)) return false,
    };
    return true;
}

/// `Color.Red` → the enum + the variant's declaration-order tag. A
/// bare (dotless) name resolves only against the auto-prelude
/// constructors (`Some`/`None`/`Ok`/`Err`, spec/errors.md §"Result
/// and Option") — via the registry, so a file declaration shadowing
/// `Option`/`Result` wins (and drops the bare form if it lacks the
/// variant).
fn enumVariantTag(b: *Builder, txt: []const u8) ?struct { info: *const EnumInfo, tag: i64 } {
    const dot = std.mem.indexOfScalar(u8, txt, '.') orelse {
        const ename = sema.prelude.ctorEnum(txt) orelse return null;
        const info = b.enums.get(ename) orelse return null;
        const tag = info.variantTag(txt) orelse return null;
        return .{ .info = info, .tag = @intCast(tag) };
    };
    const vname = txt[dot + 1 ..];
    if (std.mem.indexOfScalar(u8, vname, '.') != null) return null;
    const info = b.enums.get(txt[0..dot]) orelse return null;
    const tag = info.variantTag(vname) orelse return null;
    return .{ .info = info, .tag = @intCast(tag) };
}

/// Is this a bare path naming a *boxed* enum's variant (`Shape.Empty`
/// where Shape has payload variants)? Such a value is a record, so the
/// let arm routes it through the record path.
fn isBoxedVariantPath(b: *Builder, e: ast.Expr) bool {
    switch (e) {
        .path => |p| {
            const txt = p.text(b.a) catch return false;
            defer b.a.free(txt);
            const ev = enumVariantTag(b, txt) orelse return false;
            return ev.info.si != null;
        },
        .literal => |le| {
            // The prelude `None` literal (KW_NONE) is Option's unit
            // variant — boxed, since Some carries a payload.
            const t = le.token() orelse return false;
            if (t.kind != .KW_NONE) return false;
            const ev = enumVariantTag(b, "None") orelse return false;
            return ev.info.si != null;
        },
        else => return false,
    }
}

/// The enum a scrutinee expression carries: a `Enum.Variant` value or
/// a binding registered in `Scope.enum_binds`.
fn enumOfExpr(b: *Builder, scope: *const Scope, e: ast.Expr) BuildError!?*const EnumInfo {
    switch (e) {
        .paren => |p| return enumOfExpr(b, scope, p.inner() orelse return null),
        .path => |p| {
            const txt = try p.text(b.a);
            defer b.a.free(txt);
            if (enumVariantTag(b, txt)) |ev| return ev.info;
            if (scope.enum_binds.get(txt)) |info| return info;
            // An enum-typed *param* or record binding (`s: Shape`) —
            // registered in `recs` with the enum's boxed shape.
            if (scope.recs.get(txt)) |si| {
                if (b.enums.get(si.name)) |info| {
                    if (info.si == si) return info;
                }
            }
            return null;
        },
        .literal => |le| {
            // The prelude `None` literal.
            const t = le.token() orelse return null;
            if (t.kind != .KW_NONE) return null;
            const ev = enumVariantTag(b, "None") orelse return null;
            return ev.info;
        },
        .call => |cc| {
            // A payload construction (`Shape.Circle(7)`) or a call to
            // an enum-returning function (`find(5)`).
            const callee = cc.callee() orelse return null;
            const cp = switch (callee) {
                .path => |x| x,
                else => return null,
            };
            const txt = try cp.text(b.a);
            defer b.a.free(txt);
            if (enumVariantTag(b, txt)) |ev| {
                // Mirror enumCtorValue's inference: a str argument to a
                // generic slot picks the str instantiation.
                const variant = ev.info.variants[@intCast(ev.tag)];
                if (variant.kind == .param) {
                    var a1 = cc.args();
                    if (a1.next()) |arg| {
                        if ((try exprScalar(b, arg, scope)) == .str) {
                            var descs = [_][]const u8{ "i", "i", "i", "i" };
                            descs[variant.pidx] = "s";
                            return try instantiateEnum(b, ev.info, &descs);
                        }
                        if (recvStructQuiet(b, scope, arg)) |rsi| {
                            var descs = [_][]const u8{ "i", "i", "i", "i" };
                            descs[variant.pidx] = try std.fmt.allocPrint(b.a, "r:{s}", .{rsi.name});
                            return try instantiateEnum(b, ev.info, &descs);
                        }
                    }
                }
                return ev.info;
            }
            if (std.mem.eql(u8, txt, "env.fs.read")) {
                const base_info = b.enums.get("Result") orelse return null;
                return try instantiateEnum(b, base_info, &.{ "s", "i", "i", "i" });
            }
            if (std.mem.indexOfScalar(u8, txt, '.') == null) {
                if (b.resolver.lookup(txt)) |fd| return enumOfRet(b, fd);
            }
            return null;
        },
        else => return null,
    }
}

/// The boxed enum a function's return type names (`-> Option<i64>`,
/// `-> i64?`, `-> Shape`), so callers can `match` on the call's value.
fn enumOfRet(b: *Builder, fd: ast.FnDecl) BuildError!?*const EnumInfo {
    const rt = fd.returnType() orelse return null;
    const pt = switch (rt.type_() orelse return null) {
        .path => |x| x,
        .optional => |ot| {
            // `T?` ≡ `Option<T>`.
            const info = b.enums.get("Option") orelse return null;
            if (info.si == null) return null;
            return try instFromOptionalInner(b, info, ot);
        },
        else => return null,
    };
    const nm = try pt.name(b.a);
    defer b.a.free(nm);
    const info = b.enums.get(nm) orelse return null;
    if (info.si == null) return null; // immediate enums return as i64: later
    return try instFromGenericArgs(b, info, pt);
}

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
        .actor_decl => |ad| {
            // An actor is a struct of its `state` fields, plus its decl kept
            // for handler dispatch + default construction.
            const nm = ad.name() orelse continue;
            var fields: std.ArrayList(StructField) = .empty;
            var off: u32 = 0;
            var max_align: u32 = 1;
            var ok = true;
            var sit = ad.states();
            while (sit.next()) |s| {
                const fname = s.name() orelse {
                    ok = false;
                    break;
                };
                const fty = (try semaScalar(b, s.type_())) orelse {
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
            try b.actor_decls.put(b.a, nm.text, ad);
        },
        .graph_decl => |gd| {
            if (gd.name()) |nm| try b.graph_decls.put(b.a, nm.text, gd);
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
            const nm = try pt.name(b.a);
            defer b.a.free(nm);
            // A boxed enum value is a record (`-> Option<i64>`,
            // `o: Shape`). Generic args pick the payload-slot kinds
            // (`Result<str, i64>` instantiates Ok with a str slot). An
            // *immediate* (all-unit) enum is an i64 value, not a
            // record — null here, and the scalar path stays honest.
            if (b.enums.get(nm)) |info| {
                if (info.si == null) return null;
                const inst = try instFromGenericArgs(b, info, pt);
                return inst.si;
            }
            if (pt.hasGenericArgs()) return null;
            return b.structs.get(nm);
        },
        .optional => |ot| {
            // `T?` ≡ `Option<T>` (errors.md §"Result and Option").
            const info = b.enums.get("Option") orelse return null;
            if (info.si == null) return null;
            const inst = try instFromOptionalInner(b, info, ot);
            return inst.si;
        },
        .tuple => |tt| {
            // `(i64, i64)` — an anonymous record. v0: i64 elements; the
            // interned layout matches a tuple literal's by element signature.
            var tys: std.ArrayList(hir.Type) = .empty;
            defer tys.deinit(b.a);
            var it = tt.elements();
            while (it.next()) |et| {
                const sc = (try semaScalar(b, et)) orelse return null;
                switch (sc) {
                    .i64, .f64, .f32, .bool => {},
                    else => return null, // str/narrow tuple slots: later
                }
                try tys.append(b.a, sc);
            }
            if (tys.items.len < 2) return null;
            return try tupleStructInfo(b, tys.items);
        },
        else => return null,
    }
}

fn structOfRet(b: *Builder, fd: ast.FnDecl) BuildError!?*const StructInfo {
    const rt = fd.returnType() orelse return null;
    return structOfType(b, rt.type_());
}

/// The enum a type-expr names directly, if any (`c: Color`). Lets a callee
/// give an *immediate* (all-unit) enum param the right ABI — an i64 tag —
/// since `structOfType` returns null for it (only boxed enums are records).
fn enumOfType(b: *Builder, te_opt: ?ast.TypeExpr) BuildError!?*const EnumInfo {
    const te = te_opt orelse return null;
    switch (te) {
        .path => |pt| {
            if (pt.hasGenericArgs()) return null;
            const nm = try pt.name(b.a);
            defer b.a.free(nm);
            return b.enums.get(nm);
        },
        else => return null,
    }
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
/// A bare actor-state field (`n` inside a handler → `self.n`). Returns null
/// unless we're in a handler body (`scope.self_actor` set) and `name` is a
/// single-segment field of the actor's state. State fields are mutable.
fn actorStateField(scope: *const Scope, name: []const u8) ?RecField {
    const si = scope.self_actor orelse return null;
    if (std.mem.indexOfScalar(u8, name, '.') != null) return null;
    const f = si.field(name) orelse return null;
    const loc = scope.find("self") orelse return null;
    return .{ .base_idx = loc.idx, .offset = f.offset, .ty = f.ty, .mutable = true };
}

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
        .call => |cc| {
            if (try genericRetStruct(b, scope, cc)) |si| return si;
            return recCallStruct(b, expr);
        },
        else => return null,
    }
}

/// The struct a *generic* call returns, inferred WITHOUT building (the
/// routing twin of `genericRecCall`): the callee is a generic decl with
/// a `-> T` return, and T's slot peeks from the deciding argument — a
/// record literal names its struct, other shapes resolve through
/// `recvStruct` / the scope's array bindings.
fn genericRetStruct(b: *Builder, scope: *const Scope, cc: ast.CallExpr) BuildError!?*const StructInfo {
    const callee = cc.callee() orelse return null;
    const cpath = switch (callee) {
        .path => |p| p,
        else => return null,
    };
    const cname = try cpath.text(b.a);
    defer b.a.free(cname);
    if (std.mem.indexOfScalar(u8, cname, '.') != null) return null;
    const fd = b.resolver.lookup(cname) orelse return null;
    if (!fd.isGeneric()) return null;
    const sig = parseGenericSig(fd.genericParams().?) orelse return null;
    const rt = fd.returnType() orelse return null;
    const which = sema.fits.typeWhich(rt.type_() orelse return null, sig, b.a) orelse return null;
    const ps = fd.params() orelse return null;
    var pit = ps.iter();
    var ait = cc.args();
    while (pit.next()) |p| {
        const a0 = ait.next() orelse return null;
        if (bareWhich(p, sig, b.a)) |w| {
            if (w != which) continue;
            if (try recordLitStruct(b, a0)) |si| return si;
            return recvStruct(b, scope, a0);
        }
        if (sliceOfWhich(p, sig, b.a)) |w| {
            if (w != which) continue;
            switch (a0) {
                .path => |pp| {
                    const txt = try pp.text(b.a);
                    defer b.a.free(txt);
                    const ai = scope.arrs.get(txt) orelse return null;
                    return switch (ai.elem) {
                        .rec => |r| r,
                        .scalar => null,
                    };
                },
                .array => |ae| {
                    var eit = ae.elements();
                    const e0 = eit.next() orelse return null;
                    if (try recordLitStruct(b, e0)) |si| return si;
                    return recvStruct(b, scope, e0);
                },
                else => return null,
            }
        }
    }
    return null;
}

/// The registered struct a record literal names, if the expression is one.
fn recordLitStruct(b: *Builder, e: ast.Expr) BuildError!?*const StructInfo {
    const re = switch (e) {
        .record => |x| x,
        else => return null,
    };
    const pname = try (re.path() orelse return null).text(b.a);
    defer b.a.free(pname);
    return b.structs.get(pname);
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

    var scope = Scope{ .a = b.a, .callee = true };
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
    for (locals, 0..) |*t, j| {
        const ty = scope.locals.items[scope.n_params + j].ty;
        t.* = if (ty == .str) .ptr else ty; // a str binding's backing slots are address-width
    }
    b.funcs.items[id] = .{ .name = key, .params = param_slice, .ret = ret_ty, .locals = locals, .body = body };
    return id;
}

/// Build (once) an actor handler `Counter.bump` as a callee function taking
/// the actor's state record as an implicit `self` (a `.ptr`). Inside the body,
/// bare state-field names resolve to `self.<field>` (`scope.self_actor`). A
/// handler with no return type is a void procedure (`tell`); one with `-> T`
/// returns a scalar (`ask`). Keyed `Name.handler` like a fit method, so the
/// existing dotted-call dispatch finds it.
fn registerActorHandler(b: *Builder, si: *const StructInfo, mname: []const u8) BuildError!?hir.FuncId {
    const key = try std.fmt.allocPrint(b.a, "{s}.{s}", .{ si.name, mname });
    if (b.ids.get(key)) |id| return id;
    const ad = b.actor_decls.get(si.name) orelse return null;
    var hit = ad.handlers();
    const handle = while (hit.next()) |h| {
        const hn = h.name() orelse continue;
        if (std.mem.eql(u8, hn.text, mname)) break h;
    } else return null;
    const body_blk = handle.body() orelse return error.Unsupported;

    const ret_ty: hir.Type = if (handle.returnType()) |rt| blk: {
        const rs = (try semaScalar(b, rt.type_())) orelse return error.Unsupported;
        break :blk switch (rs) {
            .bool, .i64, .f64, .f32 => rs,
            else => return error.Unsupported, // str/record handler returns: later
        };
    } else .void;

    var scope = Scope{ .a = b.a, .callee = true, .self_actor = si };
    var params: std.ArrayList(hir.Param) = .empty;
    var rec_params: std.ArrayList(?*const StructInfo) = .empty;
    _ = try scope.declare("self", false, .ptr);
    try scope.recs.put(b.a, "self", si);
    try params.append(b.a, .{ .name = "self", .ty = .ptr });
    try rec_params.append(b.a, si);
    if (handle.params()) |ps| {
        var pit = ps.iter();
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
    }
    scope.n_params = @intCast(params.items.len);
    const param_slice = try params.toOwnedSlice(b.a);

    const id: hir.FuncId = @intCast(b.funcs.items.len);
    try b.ids.put(b.a, key, id);
    const dummy = try b.a.create(hir.Stmt);
    dummy.* = .{ .block = &.{} };
    try b.funcs.append(b.a, .{ .name = key, .params = param_slice, .ret = ret_ty, .body = dummy });
    try b.fn_recs.put(b.a, id, .{ .params = try rec_params.toOwnedSlice(b.a), .ret = null });

    const block = if (ret_ty == .void)
        try buildVoidBlock(b, body_blk, &scope)
    else
        try buildIntBlock(b, body_blk, &scope);
    const extra = scope.extra();
    const locals = try b.a.alloc(hir.Type, extra);
    for (locals, 0..) |*t, j| {
        const ty = scope.locals.items[scope.n_params + j].ty;
        t.* = if (ty == .str) .ptr else ty;
    }
    b.funcs.items[id] = .{ .name = key, .params = param_slice, .ret = ret_ty, .locals = locals, .body = block };
    return id;
}

/// Build (once) a `graph` as an eagerly-run function (Phase 4 v0). The body's
/// `let` stage bindings execute in order; the **last binding is the pipeline's
/// output** (the terminal stage), returned as the graph's value. Reuses the
/// callee value-body machinery — eager dataflow is sequential stage calls on
/// the cooperative floor (continuous streaming is the deep follow-up).
fn registerGraph(b: *Builder, name: []const u8) BuildError!?hir.FuncId {
    if (b.ids.get(name)) |id| return id;
    const gd = b.graph_decls.get(name) orelse return null;
    const body_blk = gd.body() orelse return error.Unsupported;
    const rt = gd.returnType() orelse return error.Unsupported; // v0: a graph declares a scalar output
    const rs = (try semaScalar(b, rt.type_())) orelse return error.Unsupported;
    const ret_ty: hir.Type = switch (rs) {
        .bool, .i64, .f64, .f32 => rs,
        else => return error.Unsupported,
    };

    const owned = try b.a.dupe(u8, name);
    var scope = Scope{ .a = b.a, .callee = true };
    var params: std.ArrayList(hir.Param) = .empty;
    if (gd.params()) |ps| {
        var pit = ps.iter();
        while (pit.next()) |p| {
            const psc = (try paramScalar(b, p)) orelse return error.Unsupported;
            const pty: hir.Type = switch (psc) {
                .bool, .i64, .f64, .f32 => psc,
                else => return error.Unsupported,
            };
            const pn = (p.name() orelse return error.Unsupported).text;
            _ = try scope.declare(pn, false, pty);
            try params.append(b.a, .{ .name = pn, .ty = pty });
        }
    }
    scope.n_params = @intCast(params.items.len);
    const param_slice = try params.toOwnedSlice(b.a);

    const id: hir.FuncId = @intCast(b.funcs.items.len);
    try b.ids.put(b.a, owned, id);
    const dummy = try b.a.create(hir.Stmt);
    dummy.* = .{ .block = &.{} };
    try b.funcs.append(b.a, .{ .name = owned, .params = param_slice, .ret = ret_ty, .body = dummy });

    var items: std.ArrayList(*hir.Stmt) = .empty;
    var last_name: ?[]const u8 = null;
    var sit = body_blk.statements();
    while (sit.next()) |s| {
        try items.append(b.a, try buildIntStmt(b, s, &scope));
        if (s == .let_stmt) {
            if (s.let_stmt.pattern()) |p| {
                if (p.bindingName()) |tok| last_name = tok.text;
            }
        }
    }
    // The terminal stage is the graph's output.
    const ln = last_name orelse return error.Unsupported; // empty graph body
    const loc = scope.find(ln) orelse return error.Unsupported;
    const rd = try b.a.create(hir.Expr);
    rd.* = .{ .local = .{ .idx = loc.idx, .ty = loc.ty } };
    const ret = try b.a.create(hir.Stmt);
    ret.* = .{ .ret = rd };
    try items.append(b.a, ret);
    const block = try b.a.create(hir.Stmt);
    block.* = .{ .block = try items.toOwnedSlice(b.a) };

    const extra = scope.extra();
    const locals = try b.a.alloc(hir.Type, extra);
    for (locals, 0..) |*t, j| {
        const ty = scope.locals.items[scope.n_params + j].ty;
        t.* = if (ty == .str) .ptr else ty;
    }
    b.funcs.items[id] = .{ .name = owned, .params = param_slice, .ret = ret_ty, .locals = locals, .body = block };
    return id;
}

/// `c.bump()` — a statement-position call to an actor's *void* handler (a
/// `tell`). Returns the discard-result statement, or null if `call` isn't a
/// void-handler dispatch on an actor binding.
fn tryActorTell(b: *Builder, call: ast.CallExpr, scope: *Scope) BuildError!?*hir.Stmt {
    const cname = (callPathName(b, call)) orelse return null;
    defer b.a.free(cname);
    const dot = std.mem.indexOfScalar(u8, cname, '.') orelse return null;
    const head = cname[0..dot];
    const mname = cname[dot + 1 ..];
    if (std.mem.indexOfScalar(u8, mname, '.') != null) return null;
    const si = scope.recs.get(head) orelse return null;
    const loc = scope.find(head) orelse return null;
    const fid = (try registerActorHandler(b, si, mname)) orelse return null;
    if (b.funcs.items[fid].ret != .void) return null; // a value handler isn't a tell
    const recv = try b.a.create(hir.Expr);
    recv.* = .{ .local = .{ .idx = loc.idx, .ty = .ptr } };
    const e = try b.a.create(hir.Expr);
    e.* = .{ .call = .{ .func = fid, .args = try buildCallArgs(b, fid, call.args(), scope, recv) } };
    const st = try b.a.create(hir.Stmt);
    st.* = .{ .expr = e };
    return st;
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
const bareWhich = sema.fits.bareWhich;

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
    // first `[T]` / bare `T` arg (and must stay consistent at later ones).
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
        } else if (bareWhich(p, sig, b.a)) |which| {
            // A bare `T` argument: a record value (passed as its base
            // pointer — the B2b ABI, so "by value" costs nothing new)
            // or a scalar.
            const aslot: TSlot, const value: *hir.Expr = if (try buildRecExpr(b, a0, scope)) |rv|
                .{ .{ .elem = .{ .rec = rv.si }, .stride = rv.si.size }, rv.e }
            else blk: {
                const sc = scalarBindTy(try exprScalar(b, a0, scope));
                switch (sc) {
                    .bool, .i64, .f64, .f32 => {},
                    else => return error.Unsupported,
                }
                break :blk .{ .{ .elem = .{ .scalar = sc }, .stride = fieldWidth(sc).?.size }, try buildIntExpr(b, a0, scope) };
            };
            if (slots[which]) |prev| {
                if (!elemEql(prev.elem, aslot.elem)) return reject(b, .unsupported_call); // T must infer consistently
            } else {
                slots[which] = aslot;
            }
            try args.append(b.a, value);
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
    // Every type param must have an inference source (a `[T]` or bare
    // `T` param).
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

    // `-> T` returns the slot's type — a scalar by value, a record as
    // its base pointer (`ret_rec` carries which struct, for fn_recs).
    var ret_rec: ?*const StructInfo = null;
    const ret_ty: hir.Type = if (fd.returnType()) |rt| blk: {
        if (rt.type_()) |rte| if (sema.fits.typeWhich(rte, sig, b.a)) |which| {
            break :blk switch (slots[which].?.elem) {
                .scalar => |t| t,
                .rec => |si| rblk: {
                    ret_rec = si;
                    break :rblk .ptr;
                },
            };
        };
        const rs = (try fnRetScalar(b, fd)) orelse return error.Unsupported; // str, concrete records: later
        break :blk switch (rs) {
            .bool, .i64, .f64, .f32 => rs,
            else => return error.Unsupported,
        };
    } else .void;

    var scope = Scope{ .a = b.a };
    var params: std.ArrayList(hir.Param) = .empty;
    var rec_params: std.ArrayList(?*const StructInfo) = .empty;
    var any_rec = false;
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
            try rec_params.appendNTimes(b.a, null, 2);
            try scope.arrs.put(b.a, pn, .{
                .ptr_idx = ptr_idx,
                .count = .{ .local_idx = cnt_idx },
                .stride = slot.stride,
                .elem = slot.elem,
            });
        } else if (sema.fits.bareWhich(p, sig, b.a)) |which| {
            // A bare `T` param: a record T is a `.ptr` registered in
            // `recs` (field access + fit dispatch resolve); a scalar T
            // is a plain scalar local.
            switch (slots[which].?.elem) {
                .rec => |si| {
                    _ = try scope.declare(pn, false, .ptr);
                    try scope.recs.put(b.a, pn, si);
                    try params.append(b.a, .{ .name = pn, .ty = .ptr });
                    try rec_params.append(b.a, si);
                    any_rec = true;
                },
                .scalar => |t| {
                    _ = try scope.declare(pn, false, t);
                    try params.append(b.a, .{ .name = pn, .ty = t });
                    try rec_params.append(b.a, null);
                },
            }
        } else {
            const psc = (try paramScalar(b, p)) orelse return error.Unsupported;
            const pty: hir.Type = switch (psc) {
                .bool, .i64, .f64, .f32 => psc,
                else => return error.Unsupported,
            };
            _ = try scope.declare(pn, false, pty);
            try params.append(b.a, .{ .name = pn, .ty = pty });
            try rec_params.append(b.a, null);
        }
    }
    scope.n_params = @intCast(params.items.len);
    const param_slice = try params.toOwnedSlice(b.a);

    const id: hir.FuncId = @intCast(b.funcs.items.len);
    try b.ids.put(b.a, key, id);
    const dummy = try b.a.create(hir.Stmt);
    dummy.* = .{ .block = &.{} };
    try b.funcs.append(b.a, .{ .name = key, .params = param_slice, .ret = ret_ty, .body = dummy, .is_screen = true });
    if (ret_rec != null or any_rec) {
        try b.fn_recs.put(b.a, id, .{ .params = try rec_params.toOwnedSlice(b.a), .ret = ret_rec });
    } else {
        rec_params.deinit(b.a);
    }

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
            // typed as the declared return — a record value for a record
            // `-> T`, a scalar otherwise. The lowering reads it as the
            // value block's tail (lowerIntBlock).
            const e: ast.Expr, const is_ret: bool = switch (stmt) {
                .expr_stmt => |es| .{ es.expression() orelse return error.Unsupported, false },
                .return_stmt => |rs| .{ rs.value() orelse return error.Unsupported, true },
                else => return error.Unsupported, // a value `if` tail: later
            };
            const value: *hir.Expr = if (ret_rec) |want| rblk: {
                const rv = (try buildRecExpr(b, e, &scope)) orelse return error.Unsupported;
                if (rv.si != want) return reject(b, .unsupported_call); // a different struct
                break :rblk rv.e;
            } else sblk: {
                if (scalarBindTy(try exprScalar(b, e, &scope)) != ret_ty) return error.Unsupported;
                break :sblk try buildIntExpr(b, e, &scope);
            };
            const st = try b.a.create(hir.Stmt);
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
        .ret_size = if (ret_rec) |w| w.size else 0,
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
const RecValue = struct { e: *hir.Expr, si: *const StructInfo };

/// Synthesize a `StructInfo` for a tuple value: fields named "0", "1", … laid
/// out like a struct (declaration order, natural alignment). A tuple is just
/// an anonymous record, so it reuses the whole record ABI (record_alloc,
/// field_get/_set, `recs` dispatch). v0: i64 elements.
fn tupleStructInfo(b: *Builder, tys: []const hir.Type) BuildError!*const StructInfo {
    // Key by element-type signature so identical tuple types share one layout.
    var key: std.ArrayList(u8) = .empty;
    for (tys, 0..) |ty, i| {
        if (i != 0) try key.append(b.a, ',');
        try key.appendSlice(b.a, @tagName(ty));
    }
    const sig = try key.toOwnedSlice(b.a);
    if (b.tuple_sis.get(sig)) |si| return si;

    const fields = try b.a.alloc(StructField, tys.len);
    var off: u32 = 0;
    var max_align: u32 = 1;
    for (tys, 0..) |ty, i| {
        const w = fieldWidth(ty) orelse return error.Unsupported;
        off = std.mem.alignForward(u32, off, w.alignment);
        fields[i] = .{ .name = try std.fmt.allocPrint(b.a, "{d}", .{i}), .ty = ty, .offset = off };
        off += w.size;
        if (w.alignment > max_align) max_align = w.alignment;
    }
    const si = try b.a.create(StructInfo);
    si.* = .{
        .name = "(tuple)",
        .fields = fields,
        .size = std.mem.alignForward(u32, off, max_align),
        .alignment = max_align,
    };
    try b.tuple_sis.put(b.a, sig, si);
    return si;
}

fn buildRecExpr(b: *Builder, expr: ast.Expr, scope: *Scope) BuildError!?RecValue {
    switch (expr) {
        .paren => |p| return buildRecExpr(b, p.inner() orelse return error.Unsupported, scope),
        .tuple => |te| {
            // `(e1, e2, …)` — an anonymous record allocated in the scope arena.
            // v0: i64 elements. The synthesized `si` rides in `recs` so `t.0`
            // and `let (a, b) = t` resolve through the record machinery.
            var tys: std.ArrayList(hir.Type) = .empty;
            var eit = te.elements();
            while (eit.next()) |el| {
                const sc = try exprScalar(b, el, scope);
                if (sc == .narrow_int or sc == .str or sc == .unknown) return error.Unsupported; // str/narrow: later
                try tys.append(b.a, scalarBindTy(sc));
            }
            if (tys.items.len < 2) return error.Unsupported; // `()` / `(x)` aren't tuples
            const si = try tupleStructInfo(b, tys.items);
            var inits: std.ArrayList(hir.FieldInit) = .empty;
            var eit2 = te.elements();
            var i: usize = 0;
            while (eit2.next()) |el| : (i += 1) {
                try inits.append(b.a, .{ .offset = si.fields[i].offset, .ty = si.fields[i].ty, .value = try buildIntExpr(b, el, scope) });
            }
            const out = try b.a.create(hir.Expr);
            out.* = .{ .record_alloc = .{ .size = si.size, .alignment = si.alignment, .inits = try inits.toOwnedSlice(b.a) } };
            return .{ .e = out, .si = si };
        },
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
            // Actor construction (`Counter {}` / partial): fill any state
            // field not explicitly set with its `state … = <default>` value.
            if (b.actor_decls.get(pname)) |ad| {
                var sit = ad.states();
                while (sit.next()) |s| {
                    const sname = (s.name() orelse continue).text;
                    const f = si.field(sname) orelse continue;
                    var found = false;
                    for (inits.items) |ini| {
                        if (ini.offset == f.offset) {
                            found = true;
                            break;
                        }
                    }
                    if (found) continue;
                    const dval = s.value() orelse return error.Unsupported; // no default → must be explicit
                    if (narrowRange(f.ty) != null) {
                        try inits.append(b.a, .{ .offset = f.offset, .ty = f.ty, .value = try buildNarrowValue(b, f.ty, dval) });
                    } else {
                        if (scalarBindTy(try exprScalar(b, dval, scope)) != f.ty) return error.Unsupported;
                        try inits.append(b.a, .{ .offset = f.offset, .ty = f.ty, .value = try buildIntExpr(b, dval, scope) });
                    }
                    seen += 1;
                }
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
            // C3: a *unit* variant of a boxed enum is still an arena
            // value ({tag} only), so all of the enum's values share one
            // representation.
            if (enumVariantTag(b, txt)) |ev| {
                if (ev.info.si) |esi| return .{ .e = try enumAlloc(b, esi, ev.tag, &.{}), .si = esi };
            }
            const si = scope.recs.get(txt) orelse return null;
            const loc = scope.find(txt) orelse return null;
            const out = try b.a.create(hir.Expr);
            out.* = .{ .local = .{ .idx = loc.idx, .ty = .ptr } };
            return .{ .e = out, .si = si };
        },
        .literal => |le| {
            // The prelude `None` (lexed KW_NONE, so a literal — not a
            // path): a unit variant of the possibly-shadowed Option.
            const t = le.token() orelse return null;
            if (t.kind != .KW_NONE) return null;
            const ev = enumVariantTag(b, "None") orelse return null;
            const esi = ev.info.si orelse return null;
            return .{ .e = try enumAlloc(b, esi, ev.tag, &.{}), .si = esi };
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
            // `env.fs.read(path)` yields a boxed Result<str, i64>
            // (spec/env.md §"Wire ABI: fs.read").
            if (callPathName(b, cc)) |fsname| {
                defer b.a.free(fsname);
                if (std.mem.eql(u8, fsname, "Vec.from")) return null;
                if (std.mem.eql(u8, fsname, "env.fs.read")) {
                    var fa = cc.args();
                    const parg = fa.next() orelse return error.Unsupported;
                    if (fa.next() != null) return error.Unsupported;
                    const base_info = b.enums.get("Result") orelse return error.Unsupported;
                    const inst = try instantiateEnum(b, base_info, &.{ "s", "i", "i", "i" });
                    const e2 = try b.a.create(hir.Expr);
                    e2.* = .{ .fs_read = .{ .path = try buildStrExpr(b, parg, scope, null) } };
                    return .{ .e = e2, .si = inst.si.? };
                }
            }
            // C3: a payload-variant construction (`Shape.Circle(7)`):
            // allocate the boxed value {tag, p0 ..} in the scope arena.
            if (try enumCtorValue(b, cc, scope)) |ev| return ev;
            // A generic callee whose `-> T` resolved to a record: infer,
            // stamp, and read the instance's record return (fn_recs).
            if (try genericRecCall(b, cc, scope)) |gv| return gv;
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

/// C3: a payload-variant construction call (`Shape.Circle(7)`): the
/// callee names a boxed enum's variant; arity-checked i64 arguments
/// fill the payload slots. Yields the arena value.
fn enumCtorValue(b: *Builder, cc: ast.CallExpr, scope: *Scope) BuildError!?RecValue {
    const callee = cc.callee() orelse return null;
    const cp = switch (callee) {
        .path => |x| x,
        else => return null,
    };
    const txt = try cp.text(b.a);
    defer b.a.free(txt);
    const ev = enumVariantTag(b, txt) orelse return null;
    if (ev.info.si == null) return null; // an immediate enum has no ctor calls
    // A str argument to a generic slot instantiates the enum (`Ok(s)` →
    // Result<str, _>); a declared `str` slot takes it directly.
    const variant = ev.info.variants[@intCast(ev.tag)];
    if (variant.kind == .param or variant.kind == .str_ or variant.kind == .rec) {
        var a1 = cc.args();
        const arg = a1.next() orelse return reject(b, .unsupported_call);
        if (a1.next() != null) return reject(b, .unsupported_call);
        const is_str = (try exprScalar(b, arg, scope)) == .str;
        if (variant.kind == .str_ and !is_str) return error.Unsupported;
        if (is_str) {
            var inst = ev.info;
            if (variant.kind == .param) {
                var descs = [_][]const u8{ "i", "i", "i", "i" };
                descs[variant.pidx] = "s";
                inst = try instantiateEnum(b, ev.info, &descs);
            }
            const esi2 = inst.si.?;
            const sval = try buildStrExpr(b, arg, scope, null);
            return .{ .e = try enumAllocStr(b, esi2, ev.tag, sval), .si = esi2 };
        }
        // A record argument: the cell holds its base pointer (the
        // payload aliases the record — the B2b whole-value boundary).
        if (variant.kind == .rec or variant.kind == .param) {
            if (try buildRecExpr(b, arg, scope)) |rv| {
                var inst = ev.info;
                if (variant.kind == .param) {
                    var descs = [_][]const u8{ "i", "i", "i", "i" };
                    descs[variant.pidx] = try std.fmt.allocPrint(b.a, "r:{s}", .{rv.si.name});
                    inst = try instantiateEnum(b, ev.info, &descs);
                } else if (variant.rec_si != rv.si) return reject(b, .unsupported_call);
                const esi4 = inst.si.?;
                var pvals = [_]*hir.Expr{rv.e};
                return .{ .e = try enumAlloc(b, esi4, ev.tag, &pvals), .si = esi4 };
            }
            if (variant.kind == .rec) return error.Unsupported;
        }
        // An int argument to a generic slot: the base (all-int) info.
        const esi3 = ev.info.si.?;
        var ivals = [_]*hir.Expr{try buildIntExpr(b, arg, scope)};
        return .{ .e = try enumAlloc(b, esi3, ev.tag, &ivals), .si = esi3 };
    }
    const esi = ev.info.si.?;
    const arity = variant.arity;
    var vals: std.ArrayList(*hir.Expr) = .empty;
    defer vals.deinit(b.a);
    var ait = cc.args();
    while (ait.next()) |a| {
        if (vals.items.len == arity) return reject(b, .unsupported_call); // too many
        const sc = try exprScalar(b, a, scope);
        if (scalarBindTy(sc) != .i64) return error.Unsupported; // i64 payloads only (v0)
        try vals.append(b.a, try buildIntExpr(b, a, scope));
    }
    if (vals.items.len != arity) return reject(b, .unsupported_call);
    return .{ .e = try enumAlloc(b, esi, ev.tag, vals.items), .si = esi };
}

/// Allocate a boxed enum value carrying one str payload: {tag} + the
/// value's (ptr, len) widened into cells at offsets 8 / 16.
fn enumAllocStr(b: *Builder, esi: *const StructInfo, tag: i64, sval: *hir.Expr) BuildError!*hir.Expr {
    var inits: std.ArrayList(hir.FieldInit) = .empty;
    const tagv = try b.a.create(hir.Expr);
    tagv.* = .{ .int_const = tag };
    try inits.append(b.a, .{ .offset = 0, .ty = .i64, .value = tagv });
    const sinits = try b.a.dupe(hir.StrFieldInit, &.{.{ .offset = 8, .value = sval }});
    const out = try b.a.create(hir.Expr);
    out.* = .{ .record_alloc = .{ .size = esi.size, .alignment = esi.alignment, .inits = try inits.toOwnedSlice(b.a), .str_inits = sinits } };
    return out;
}

/// Allocate a boxed enum value: {tag, payloadâ¦} in the scope arena.
fn enumAlloc(b: *Builder, esi: *const StructInfo, tag: i64, payload: []const *hir.Expr) BuildError!*hir.Expr {
    var inits: std.ArrayList(hir.FieldInit) = .empty;
    const tagv = try b.a.create(hir.Expr);
    tagv.* = .{ .int_const = tag };
    try inits.append(b.a, .{ .offset = 0, .ty = .i64, .value = tagv });
    for (payload, 0..) |v, j| {
        try inits.append(b.a, .{ .offset = @intCast(8 * (j + 1)), .ty = .i64, .value = v });
    }
    const out = try b.a.create(hir.Expr);
    out.* = .{ .record_alloc = .{ .size = esi.size, .alignment = esi.alignment, .inits = try inits.toOwnedSlice(b.a) } };
    return out;
}

/// A call to a generic declaration whose `-> T` infers to a *record*:
/// stamp it and yield the record-valued call. `null` when the callee
/// isn't a generic with a type-param return, or T inferred to a scalar
/// (the scalar path builds it — the stamp dedups).
fn genericRecCall(b: *Builder, cc: ast.CallExpr, scope: *Scope) BuildError!?RecValue {
    const callee = cc.callee() orelse return null;
    const cpath = switch (callee) {
        .path => |p| p,
        else => return null,
    };
    const cname = try cpath.text(b.a);
    defer b.a.free(cname);
    if (std.mem.indexOfScalar(u8, cname, '.') != null) return null;
    const fd = b.resolver.lookup(cname) orelse return null;
    if (!fd.isGeneric()) return null;
    // Cheap syntactic pre-check: only a `-> T` return can be a record here.
    const sig = parseGenericSig(fd.genericParams().?) orelse return null;
    const rt = fd.returnType() orelse return null;
    if (sema.fits.typeWhich(rt.type_() orelse return null, sig, b.a) == null) return null;
    const e = try buildGenericCall(b, cname, fd, cc, scope);
    const frec = b.fn_recs.get(e.call.func) orelse return null; // scalar T: not a record value
    const si = frec.ret orelse return null;
    return .{ .e = e, .si = si };
}

/// `Vec.from([…])` as a `let`/`var` initializer (the v0 Vec floor,
/// spec/types.md §Growable): bind a fresh header and push each literal
/// element (i64 expressions). Returns false when the initializer isn't
/// the form; growth/representation live in the `__vec_*` helpers.
fn tryVecFrom(b: *Builder, init_expr: ast.Expr, name: []const u8, mutable: bool, scope: *Scope, out: *std.ArrayList(*hir.Stmt)) BuildError!bool {
    const cc = switch (init_expr) {
        .call => |x| x,
        else => return false,
    };
    const cname = (callPathName(b, cc)) orelse return false;
    defer b.a.free(cname);
    if (!std.mem.eql(u8, cname, "Vec.from")) return false;
    var ait = cc.args();
    const arg = ait.next() orelse return error.Unsupported;
    if (ait.next() != null) return error.Unsupported;
    const arr = switch (arg) {
        .array => |x| x,
        else => return error.Unsupported, // Vec.from takes a slice literal
    };

    // let v = vec_new()
    const v_idx = try declareBodyLocal(b, scope, name, mutable, .ptr);
    try scope.vecs.put(b.a, name, {});
    const nv = try b.a.create(hir.Expr);
    nv.* = .vec_new;
    const bind = try b.a.create(hir.Stmt);
    bind.* = .{ .let = .{ .idx = v_idx, .value = nv } };
    try out.append(b.a, bind);

    // one vec_push per element
    var eit = arr.elements();
    while (eit.next()) |el| {
        const vref = try b.a.create(hir.Expr);
        vref.* = .{ .local = .{ .idx = v_idx, .ty = .ptr } };
        const st = try b.a.create(hir.Stmt);
        st.* = .{ .vec_push = .{ .vec = vref, .value = try buildIntExpr(b, el, scope) } };
        try out.append(b.a, st);
    }
    return true;
}

/// `let ch = channel(...)` — concurrency v0. A channel is a Vec buffer plus an
/// i64 read cursor: `send` pushes, `recv` reads `buf[cursor]` then bumps the
/// cursor (FIFO). v0 has no suspension (producer-before-consumer ordering, and
/// capacity ≥ messages); suspend-on-empty/full arrives with the scheduler.
fn tryChannelNew(b: *Builder, init_expr: ast.Expr, name: []const u8, mutable: bool, scope: *Scope, out: *std.ArrayList(*hir.Stmt)) BuildError!bool {
    const cc = switch (init_expr) {
        .call => |x| x,
        else => return false,
    };
    const cname = (callPathName(b, cc)) orelse return false;
    defer b.a.free(cname);
    if (!std.mem.eql(u8, cname, "channel")) return false;
    // A bounded channel: `channel(capacity: N)` — the (sole, v0) argument is the
    // capacity. Record it so the scheduler can park a `send` when the buffer is
    // full. `channel()` (no arg) stays unbounded (no entry in `chan_caps`).
    if (channelCapOf(cc)) |cap| try scope.chan_caps.put(b.a, name, cap);
    // The buffer: a Vec under `name`.
    const v_idx = try declareBodyLocal(b, scope, name, mutable, .ptr);
    try scope.vecs.put(b.a, name, {});
    const nv = try b.a.create(hir.Expr);
    nv.* = .vec_new;
    const bind = try b.a.create(hir.Stmt);
    bind.* = .{ .let = .{ .idx = v_idx, .value = nv } };
    try out.append(b.a, bind);
    // The read cursor: `name#cur` = 0.
    const cur_name = try std.fmt.allocPrint(b.a, "{s}#cur", .{name});
    const cur_idx = try declareBodyLocal(b, scope, cur_name, true, .i64);
    try scope.chans.put(b.a, name, cur_idx);
    const zero = try b.a.create(hir.Expr);
    zero.* = .{ .int_const = 0 };
    const cbind = try b.a.create(hir.Stmt);
    cbind.* = .{ .let = .{ .idx = cur_idx, .value = zero } };
    try out.append(b.a, cbind);
    return true;
}

/// `ch.send(x)` on a channel binding — a `vec_push` onto the buffer.
fn tryChannelSend(b: *Builder, call: ast.CallExpr, scope: *Scope) BuildError!?*hir.Stmt {
    const cname = (callPathName(b, call)) orelse return null;
    defer b.a.free(cname);
    const dot = std.mem.lastIndexOfScalar(u8, cname, '.') orelse return null;
    if (!std.mem.eql(u8, cname[dot + 1 ..], "send")) return null;
    const head = cname[0..dot];
    if (!scope.chans.contains(head)) return null;
    const loc = scope.find(head) orelse return null;
    var ait = call.args();
    const a0 = ait.next() orelse return error.Unsupported;
    if (ait.next() != null) return error.Unsupported; // v0: one value per send
    const vref = try b.a.create(hir.Expr);
    vref.* = .{ .local = .{ .idx = loc.idx, .ty = .ptr } };
    const st = try b.a.create(hir.Stmt);
    st.* = .{ .vec_push = .{ .vec = vref, .value = try buildIntExpr(b, a0, scope) } };
    return st;
}

/// `let v = ch.recv()` on a channel binding — `v = buf[cursor]; cursor += 1`.
fn tryChannelRecv(b: *Builder, init_expr: ast.Expr, name: []const u8, mutable: bool, scope: *Scope, out: *std.ArrayList(*hir.Stmt)) BuildError!bool {
    const cc = switch (init_expr) {
        .call => |x| x,
        else => return false,
    };
    const cname = (callPathName(b, cc)) orelse return false;
    defer b.a.free(cname);
    const dot = std.mem.lastIndexOfScalar(u8, cname, '.') orelse return false;
    if (!std.mem.eql(u8, cname[dot + 1 ..], "recv")) return false;
    const head = cname[0..dot];
    const cur_idx = scope.chans.get(head) orelse return false;
    const loc = scope.find(head) orelse return false;
    // `let _ = ch.recv()` / bare `ch.recv()` — discard: consume the slot (bump
    // the cursor) without binding. Reading the value has no side effect, so the
    // `vec_get` is simply skipped.
    if (!std.mem.eql(u8, name, "_")) {
        // v = buf[cursor]
        const vref = try b.a.create(hir.Expr);
        vref.* = .{ .local = .{ .idx = loc.idx, .ty = .ptr } };
        const curref = try b.a.create(hir.Expr);
        curref.* = .{ .local = .{ .idx = cur_idx, .ty = .i64 } };
        const get = try b.a.create(hir.Expr);
        get.* = .{ .vec_get = .{ .vec = vref, .idx = curref } };
        const v_idx = try declareBodyLocal(b, scope, name, mutable, .i64);
        const bind = try b.a.create(hir.Stmt);
        bind.* = .{ .let = .{ .idx = v_idx, .value = get } };
        try out.append(b.a, bind);
    }
    // cursor += 1
    const curref2 = try b.a.create(hir.Expr);
    curref2.* = .{ .local = .{ .idx = cur_idx, .ty = .i64 } };
    const one = try b.a.create(hir.Expr);
    one.* = .{ .int_const = 1 };
    const inc = try b.a.create(hir.Expr);
    inc.* = .{ .bin = .{ .kind = .add, .lhs = curref2, .rhs = one } };
    const setc = try b.a.create(hir.Stmt);
    setc.* = .{ .assign = .{ .idx = cur_idx, .value = inc } };
    try out.append(b.a, setc);
    return true;
}

/// map/filter method name → is-filter (true=filter, false=map), or null.
fn mapFilterKind(method: []const u8) ?bool {
    if (std.mem.eql(u8, method, "filter")) return true;
    if (std.mem.eql(u8, method, "map")) return false;
    return null;
}

/// The single lambda argument of a `map`/`filter` call, or null.
fn mapFilterLambda(args: anytype) ?ast.LambdaExpr {
    var it = args;
    const a0 = it.next() orelse return null;
    if (it.next() != null) return null;
    return switch (a0) {
        .lambda => |l| l,
        else => null,
    };
}

/// A fresh hidden temp-vec name for an iterator method chain.
fn freshTmp(b: *Builder) BuildError![]const u8 {
    const n = b.vec_tmp;
    b.vec_tmp += 1;
    return std.fmt.allocPrint(b.a, "#chain{d}", .{n});
}

/// Resolve a vec-producing receiver to a binding name, materializing inner
/// `map`/`filter` stages into hidden `#chainN` temps (so `xs.filter(p).map(f)`
/// works). Returns null when it isn't a vec source.
fn vecReceiverName(b: *Builder, expr: ast.Expr, scope: *Scope, out: *std.ArrayList(*hir.Stmt)) BuildError!?[]const u8 {
    switch (expr) {
        .path => |p| {
            const nm = try p.text(b.a);
            if (scope.vecs.contains(nm)) return nm;
            b.a.free(nm);
            return null;
        },
        .call => |cc| {
            // `<vecname>.map|filter(lam)` — the receiver is a plain name.
            const cn = (callPathName(b, cc)) orelse return null;
            defer b.a.free(cn);
            const dot = std.mem.lastIndexOfScalar(u8, cn, '.') orelse return null;
            const is_filter = mapFilterKind(cn[dot + 1 ..]) orelse return null;
            if (!scope.vecs.contains(cn[0..dot])) return null;
            const lam = mapFilterLambda(cc.args()) orelse return null;
            const tmp = try freshTmp(b);
            try buildMapFilterInto(b, cn[0..dot], tmp, true, is_filter, lam, scope, out);
            return tmp;
        },
        .method => |me| {
            const is_filter = mapFilterKind((me.method() orelse return null).text) orelse return null;
            const inner = (try vecReceiverName(b, me.receiver() orelse return null, scope, out)) orelse return null;
            const lam = mapFilterLambda(me.args()) orelse return null;
            const tmp = try freshTmp(b);
            try buildMapFilterInto(b, inner, tmp, true, is_filter, lam, scope, out);
            return tmp;
        },
        else => return null,
    }
}

/// `let d = xs.map(|x| body)` / `xs.filter(|x| pred)`, and chains thereof
/// (`xs.filter(p).map(f)`) — the v0 Vec floor. Inner stages materialize into
/// hidden temps (`vecReceiverName`); the final stage builds into `dname`.
fn tryVecMap(b: *Builder, init_expr: ast.Expr, dname: []const u8, mutable: bool, scope: *Scope, out: *std.ArrayList(*hir.Stmt)) BuildError!bool {
    switch (init_expr) {
        .call => |cc| {
            const cn = (callPathName(b, cc)) orelse return false;
            defer b.a.free(cn);
            const dot = std.mem.lastIndexOfScalar(u8, cn, '.') orelse return false;
            const is_filter = mapFilterKind(cn[dot + 1 ..]) orelse return false;
            if (!scope.vecs.contains(cn[0..dot])) return false;
            const lam = mapFilterLambda(cc.args()) orelse return reject(b, .unsupported_call);
            try buildMapFilterInto(b, cn[0..dot], dname, mutable, is_filter, lam, scope, out);
            return true;
        },
        .method => |me| {
            const is_filter = mapFilterKind((me.method() orelse return false).text) orelse return false;
            const inner = (try vecReceiverName(b, me.receiver() orelse return false, scope, out)) orelse return false;
            const lam = mapFilterLambda(me.args()) orelse return reject(b, .unsupported_call);
            try buildMapFilterInto(b, inner, dname, mutable, is_filter, lam, scope, out);
            return true;
        },
        else => return false,
    }
}

/// Build the map/filter loop from source vec `src_name` into a fresh vec
/// binding `dname`: `var d = Vec.new(); for x in src { d.push(body) }` (map)
/// or `{ if pred { d.push(x) } }` (filter). The loop variable is the lambda
/// parameter, so the body resolves it and any captured local by scoping.
fn buildMapFilterInto(b: *Builder, src: []const u8, dname: []const u8, mutable: bool, is_filter: bool, lam: ast.LambdaExpr, scope: *Scope, out: *std.ArrayList(*hir.Stmt)) BuildError!void {
    const body = lambdaBodyExpr(lam) orelse return error.Unsupported; // expr body only (v0)
    var pit = lam.params();
    const xname = (pit.next() orelse return error.Unsupported).text;
    if (pit.next() != null) return error.Unsupported; // exactly one parameter

    const sloc = scope.find(src) orelse return error.Unsupported;

    // var d = Vec.new()
    const d_idx = try declareBodyLocal(b, scope, dname, mutable, .ptr);
    try scope.vecs.put(b.a, dname, {});
    const nv = try b.a.create(hir.Expr);
    nv.* = .vec_new;
    const bind = try b.a.create(hir.Stmt);
    bind.* = .{ .let = .{ .idx = d_idx, .value = nv } };
    try out.append(b.a, bind);

    // for x in src { d.push(body) } — index loop over the source's length.
    const hidden = try std.fmt.allocPrint(b.a, "{s}#idx", .{xname});
    const i_idx = try declareBodyLocal(b, scope, hidden, true, .i64);
    const x_idx = try declareBodyLocal(b, scope, xname, false, .i64);
    const zero = try b.a.create(hir.Expr);
    zero.* = .{ .int_const = 0 };
    const st0 = try b.a.create(hir.Stmt);
    st0.* = .{ .let = .{ .idx = i_idx, .value = zero } };
    try out.append(b.a, st0);

    var items: std.ArrayList(*hir.Stmt) = .empty;
    { // x = src[i]
        const sref = try b.a.create(hir.Expr);
        sref.* = .{ .local = .{ .idx = sloc.idx, .ty = .ptr } };
        const iref = try b.a.create(hir.Expr);
        iref.* = .{ .local = .{ .idx = i_idx, .ty = .i64 } };
        const get = try b.a.create(hir.Expr);
        get.* = .{ .vec_get = .{ .vec = sref, .idx = iref } };
        const setx = try b.a.create(hir.Stmt);
        setx.* = .{ .assign = .{ .idx = x_idx, .value = get } };
        try items.append(b.a, setx);
    }
    { // d.push(<body>)  /  if <pred> { d.push(x) }
        const dref = try b.a.create(hir.Expr);
        dref.* = .{ .local = .{ .idx = d_idx, .ty = .ptr } };
        if (is_filter) {
            // filter: push the element when the predicate holds.
            const xref = try b.a.create(hir.Expr);
            xref.* = .{ .local = .{ .idx = x_idx, .ty = .i64 } };
            const push = try b.a.create(hir.Stmt);
            push.* = .{ .vec_push = .{ .vec = dref, .value = xref } };
            const then_items = try b.a.alloc(*hir.Stmt, 1);
            then_items[0] = push;
            const then_blk = try b.a.create(hir.Stmt);
            then_blk.* = .{ .block = then_items };
            const cond = try buildIntExpr(b, body, scope);
            const iff = try b.a.create(hir.Stmt);
            iff.* = .{ .if_ = .{ .cond = cond, .then_ = then_blk, .else_ = null } };
            try items.append(b.a, iff);
        } else {
            // map: push the transformed value.
            const val = try buildIntExpr(b, body, scope);
            const push = try b.a.create(hir.Stmt);
            push.* = .{ .vec_push = .{ .vec = dref, .value = val } };
            try items.append(b.a, push);
        }
    }
    { // i = i + 1
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

    const iref2 = try b.a.create(hir.Expr);
    iref2.* = .{ .local = .{ .idx = i_idx, .ty = .i64 } };
    const sref2 = try b.a.create(hir.Expr);
    sref2.* = .{ .local = .{ .idx = sloc.idx, .ty = .ptr } };
    const lenx = try b.a.create(hir.Expr);
    lenx.* = .{ .vec_len = .{ .vec = sref2 } };
    const cond = try b.a.create(hir.Expr);
    cond.* = .{ .bin = .{ .kind = .lt, .lhs = iref2, .rhs = lenx } };
    const wst = try b.a.create(hir.Stmt);
    wst.* = .{ .while_ = .{ .cond = cond, .body = body_blk } };
    try out.append(b.a, wst);
}

/// `let total = xs.reduce(init, |acc, x| body)` (the v0 Vec floor): fold the
/// vec to a scalar. Desugars to `var total = init; for x in xs { total =
/// body }` — the let binding *is* the accumulator (init-seeded, mutated each
/// step), the loop variable IS the lambda's second parameter, and the first
/// parameter (`acc`) is substituted to the accumulator. Returns false when
/// the initializer isn't `<vec>.reduce(<init>, <lambda>)`. i64 (v0).
fn tryVecReduce(b: *Builder, init_expr: ast.Expr, dname: []const u8, mutable: bool, scope: *Scope, out: *std.ArrayList(*hir.Stmt)) BuildError!bool {
    const cc = switch (init_expr) {
        .call => |x| x,
        else => return false,
    };
    const cname = (callPathName(b, cc)) orelse return false;
    defer b.a.free(cname);
    const dot = std.mem.lastIndexOfScalar(u8, cname, '.') orelse return false;
    const src = cname[0..dot];
    if (!std.mem.eql(u8, cname[dot + 1 ..], "reduce")) return false;
    if (!scope.vecs.contains(src)) return false;

    var ait = cc.args();
    const init_arg = ait.next() orelse return error.Unsupported;
    const lam_arg = ait.next() orelse return reject(b, .unsupported_call); // reduce(init, |acc,x| …)
    if (ait.next() != null) return error.Unsupported;
    const lam = switch (lam_arg) {
        .lambda => |l| l,
        else => return reject(b, .unsupported_call),
    };
    const body = lambdaBodyExpr(lam) orelse return error.Unsupported;
    var pit = lam.params();
    const acc_param = (pit.next() orelse return error.Unsupported).text;
    const x_param = (pit.next() orelse return error.Unsupported).text;
    if (pit.next() != null) return error.Unsupported; // exactly two parameters

    const sloc = scope.find(src) orelse return error.Unsupported;

    // var total = init   (the accumulator IS the binding)
    const init_val = try buildIntExpr(b, init_arg, scope);
    const acc_idx = try declareBodyLocal(b, scope, dname, true, .i64);
    const seed = try b.a.create(hir.Stmt);
    seed.* = .{ .let = .{ .idx = acc_idx, .value = init_val } };
    try out.append(b.a, seed);

    // for x in src { total = body }  — `acc` resolves to the accumulator.
    const hidden = try std.fmt.allocPrint(b.a, "{s}#idx", .{x_param});
    const i_idx = try declareBodyLocal(b, scope, hidden, true, .i64);
    const x_idx = try declareBodyLocal(b, scope, x_param, false, .i64);
    const zero = try b.a.create(hir.Expr);
    zero.* = .{ .int_const = 0 };
    const st0 = try b.a.create(hir.Stmt);
    st0.* = .{ .let = .{ .idx = i_idx, .value = zero } };
    try out.append(b.a, st0);

    var items: std.ArrayList(*hir.Stmt) = .empty;
    { // x = src[i]
        const sref = try b.a.create(hir.Expr);
        sref.* = .{ .local = .{ .idx = sloc.idx, .ty = .ptr } };
        const iref = try b.a.create(hir.Expr);
        iref.* = .{ .local = .{ .idx = i_idx, .ty = .i64 } };
        const get = try b.a.create(hir.Expr);
        get.* = .{ .vec_get = .{ .vec = sref, .idx = iref } };
        const setx = try b.a.create(hir.Stmt);
        setx.* = .{ .assign = .{ .idx = x_idx, .value = get } };
        try items.append(b.a, setx);
    }
    { // total = <body>, with `acc` substituted to the accumulator
        const accref = try b.a.create(hir.Expr);
        accref.* = .{ .local = .{ .idx = acc_idx, .ty = .i64 } };
        try scope.subst.put(b.a, acc_param, accref);
        const newval = try buildIntExpr(b, body, scope);
        _ = scope.subst.remove(acc_param);
        const setacc = try b.a.create(hir.Stmt);
        setacc.* = .{ .assign = .{ .idx = acc_idx, .value = newval } };
        try items.append(b.a, setacc);
    }
    { // i = i + 1
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

    const iref2 = try b.a.create(hir.Expr);
    iref2.* = .{ .local = .{ .idx = i_idx, .ty = .i64 } };
    const sref2 = try b.a.create(hir.Expr);
    sref2.* = .{ .local = .{ .idx = sloc.idx, .ty = .ptr } };
    const lenx = try b.a.create(hir.Expr);
    lenx.* = .{ .vec_len = .{ .vec = sref2 } };
    const cond = try b.a.create(hir.Expr);
    cond.* = .{ .bin = .{ .kind = .lt, .lhs = iref2, .rhs = lenx } };
    const wst = try b.a.create(hir.Stmt);
    wst.* = .{ .while_ = .{ .cond = cond, .body = body_blk } };
    try out.append(b.a, wst);
    _ = mutable;
    return true;
}

/// `for x in v { … }` over a vec binding: an index loop reading the
/// live length each test (`while i < vec_len(v) { x = v[i]; …; i += 1 }`),
/// so a body that pushes still terminates against the grown bound.
fn buildForVec(b: *Builder, fs: ast.ForStmt, vname: []const u8, xname: []const u8, scope: *Scope, rt: *RtMap, out: *std.ArrayList(*hir.Stmt)) BuildError!void {
    const vloc = scope.find(vname) orelse return error.Unsupported;
    const hidden = try std.fmt.allocPrint(b.a, "{s}#idx", .{xname});
    const i_idx = try declareBodyLocal(b, scope, hidden, true, .i64);
    const x_idx = try declareBodyLocal(b, scope, xname, false, .i64);

    // let i = 0
    const zero = try b.a.create(hir.Expr);
    zero.* = .{ .int_const = 0 };
    const st0 = try b.a.create(hir.Stmt);
    st0.* = .{ .let = .{ .idx = i_idx, .value = zero } };
    try out.append(b.a, st0);

    // body: x = v[i]; <source body>; i = i + 1
    var items: std.ArrayList(*hir.Stmt) = .empty;
    {
        const vref = try b.a.create(hir.Expr);
        vref.* = .{ .local = .{ .idx = vloc.idx, .ty = .ptr } };
        const iref = try b.a.create(hir.Expr);
        iref.* = .{ .local = .{ .idx = i_idx, .ty = .i64 } };
        const get = try b.a.create(hir.Expr);
        get.* = .{ .vec_get = .{ .vec = vref, .idx = iref } };
        const setx = try b.a.create(hir.Stmt);
        setx.* = .{ .assign = .{ .idx = x_idx, .value = get } };
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
    // while i < v.len (read live)
    const iref2 = try b.a.create(hir.Expr);
    iref2.* = .{ .local = .{ .idx = i_idx, .ty = .i64 } };
    const vref2 = try b.a.create(hir.Expr);
    vref2.* = .{ .local = .{ .idx = vloc.idx, .ty = .ptr } };
    const lenx = try b.a.create(hir.Expr);
    lenx.* = .{ .vec_len = .{ .vec = vref2 } };
    const cond = try b.a.create(hir.Expr);
    cond.* = .{ .bin = .{ .kind = .lt, .lhs = iref2, .rhs = lenx } };
    const st = try b.a.create(hir.Stmt);
    st.* = .{ .while_ = .{ .cond = cond, .body = body_blk } };
    try out.append(b.a, st);
}

/// `for i in lo..hi { body }` (or `lo..=hi`): the loop variable is the
/// counter. The bounds evaluate once (the upper bound into a hidden local);
/// then `let i = lo; while i < hi { body; i = i + 1 }` (`<=` for inclusive).
fn buildForRange(b: *Builder, fs: ast.ForStmt, range: ast.RangeExpr, xname: []const u8, scope: *Scope, rt: *RtMap, out: *std.ArrayList(*hir.Stmt)) BuildError!void {
    const lo_e = try buildIntExpr(b, range.lo() orelse return error.Unsupported, scope);
    const hi_e = try buildIntExpr(b, range.hi() orelse return error.Unsupported, scope);
    const hidden_hi = try std.fmt.allocPrint(b.a, "{s}#hi", .{xname});
    const hi_idx = try declareBodyLocal(b, scope, hidden_hi, false, .i64);
    const i_idx = try declareBodyLocal(b, scope, xname, true, .i64);

    // let #hi = hi  (evaluate the bound once)
    const sthi = try b.a.create(hir.Stmt);
    sthi.* = .{ .let = .{ .idx = hi_idx, .value = hi_e } };
    try out.append(b.a, sthi);
    // let i = lo
    const sti0 = try b.a.create(hir.Stmt);
    sti0.* = .{ .let = .{ .idx = i_idx, .value = lo_e } };
    try out.append(b.a, sti0);

    // body: <source body>; i = i + 1
    var items: std.ArrayList(*hir.Stmt) = .empty;
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

    // while i (< | <=) #hi
    const iref2 = try b.a.create(hir.Expr);
    iref2.* = .{ .local = .{ .idx = i_idx, .ty = .i64 } };
    const hiref = try b.a.create(hir.Expr);
    hiref.* = .{ .local = .{ .idx = hi_idx, .ty = .i64 } };
    const cond = try b.a.create(hir.Expr);
    cond.* = .{ .bin = .{ .kind = if (range.inclusive()) .le else .lt, .lhs = iref2, .rhs = hiref } };
    const st = try b.a.create(hir.Stmt);
    st.* = .{ .while_ = .{ .cond = cond, .body = body_blk } };
    try out.append(b.a, st);
}

/// `for i in lo..hi { … }` inside a *callee* body — same counted-loop
/// desugar as `buildForRange`, but the body builds through `buildIntStmt`
/// (value statements) and the whole thing returns as one block.
fn buildIntForRange(b: *Builder, fs: ast.ForStmt, range: ast.RangeExpr, xname: []const u8, scope: *Scope) BuildError!*hir.Stmt {
    const lo_e = try buildIntExpr(b, range.lo() orelse return error.Unsupported, scope);
    const hi_e = try buildIntExpr(b, range.hi() orelse return error.Unsupported, scope);
    const hidden_hi = try std.fmt.allocPrint(b.a, "{s}#hi", .{xname});
    const hi_idx = try declareBodyLocal(b, scope, hidden_hi, false, .i64);
    const i_idx = try declareBodyLocal(b, scope, xname, true, .i64);

    var items: std.ArrayList(*hir.Stmt) = .empty;
    const sthi = try b.a.create(hir.Stmt);
    sthi.* = .{ .let = .{ .idx = hi_idx, .value = hi_e } };
    try items.append(b.a, sthi);
    const sti0 = try b.a.create(hir.Stmt);
    sti0.* = .{ .let = .{ .idx = i_idx, .value = lo_e } };
    try items.append(b.a, sti0);

    // while i (< | <=) #hi { <body>; i = i + 1 }
    var binner: std.ArrayList(*hir.Stmt) = .empty;
    var bit = (fs.body() orelse return error.Unsupported).statements();
    while (bit.next()) |bs| try binner.append(b.a, try buildIntStmt(b, bs, scope));
    {
        const iref = try b.a.create(hir.Expr);
        iref.* = .{ .local = .{ .idx = i_idx, .ty = .i64 } };
        const one = try b.a.create(hir.Expr);
        one.* = .{ .int_const = 1 };
        const inc = try b.a.create(hir.Expr);
        inc.* = .{ .bin = .{ .kind = .add, .lhs = iref, .rhs = one } };
        const sti = try b.a.create(hir.Stmt);
        sti.* = .{ .assign = .{ .idx = i_idx, .value = inc } };
        try binner.append(b.a, sti);
    }
    const body_blk = try b.a.create(hir.Stmt);
    body_blk.* = .{ .block = try binner.toOwnedSlice(b.a) };

    const iref2 = try b.a.create(hir.Expr);
    iref2.* = .{ .local = .{ .idx = i_idx, .ty = .i64 } };
    const hiref = try b.a.create(hir.Expr);
    hiref.* = .{ .local = .{ .idx = hi_idx, .ty = .i64 } };
    const cond = try b.a.create(hir.Expr);
    cond.* = .{ .bin = .{ .kind = if (range.inclusive()) .le else .lt, .lhs = iref2, .rhs = hiref } };
    const wst = try b.a.create(hir.Stmt);
    wst.* = .{ .while_ = .{ .cond = cond, .body = body_blk } };
    try items.append(b.a, wst);

    const out = try b.a.create(hir.Stmt);
    out.* = .{ .block = try items.toOwnedSlice(b.a) };
    return out;
}

/// `for x in xs { … }` over a vec inside a *callee* body — the index loop
/// `let i = 0; while i < xs.len { x = xs[i]; <body>; i = i+1 }`, body built
/// through `buildIntStmt`, returned as one block. (i64 elements, v0 floor.)
fn buildIntForVec(b: *Builder, fs: ast.ForStmt, vname: []const u8, xname: []const u8, scope: *Scope) BuildError!*hir.Stmt {
    const vloc = scope.find(vname) orelse return error.Unsupported;
    const hidden = try std.fmt.allocPrint(b.a, "{s}#idx", .{xname});
    const i_idx = try declareBodyLocal(b, scope, hidden, true, .i64);
    const x_idx = try declareBodyLocal(b, scope, xname, false, .i64);

    var items: std.ArrayList(*hir.Stmt) = .empty;
    const zero = try b.a.create(hir.Expr);
    zero.* = .{ .int_const = 0 };
    const st0 = try b.a.create(hir.Stmt);
    st0.* = .{ .let = .{ .idx = i_idx, .value = zero } };
    try items.append(b.a, st0);

    // body: x = xs[i]; <source body>; i = i + 1
    var binner: std.ArrayList(*hir.Stmt) = .empty;
    {
        const vref = try b.a.create(hir.Expr);
        vref.* = .{ .local = .{ .idx = vloc.idx, .ty = .ptr } };
        const iref = try b.a.create(hir.Expr);
        iref.* = .{ .local = .{ .idx = i_idx, .ty = .i64 } };
        const get = try b.a.create(hir.Expr);
        get.* = .{ .vec_get = .{ .vec = vref, .idx = iref } };
        const setx = try b.a.create(hir.Stmt);
        setx.* = .{ .assign = .{ .idx = x_idx, .value = get } };
        try binner.append(b.a, setx);
    }
    var bit = (fs.body() orelse return error.Unsupported).statements();
    while (bit.next()) |bs| try binner.append(b.a, try buildIntStmt(b, bs, scope));
    {
        const iref = try b.a.create(hir.Expr);
        iref.* = .{ .local = .{ .idx = i_idx, .ty = .i64 } };
        const one = try b.a.create(hir.Expr);
        one.* = .{ .int_const = 1 };
        const inc = try b.a.create(hir.Expr);
        inc.* = .{ .bin = .{ .kind = .add, .lhs = iref, .rhs = one } };
        const sti = try b.a.create(hir.Stmt);
        sti.* = .{ .assign = .{ .idx = i_idx, .value = inc } };
        try binner.append(b.a, sti);
    }
    const body_blk = try b.a.create(hir.Stmt);
    body_blk.* = .{ .block = try binner.toOwnedSlice(b.a) };

    // while i < xs.len (live header read)
    const iref2 = try b.a.create(hir.Expr);
    iref2.* = .{ .local = .{ .idx = i_idx, .ty = .i64 } };
    const vref2 = try b.a.create(hir.Expr);
    vref2.* = .{ .local = .{ .idx = vloc.idx, .ty = .ptr } };
    const lenx = try b.a.create(hir.Expr);
    lenx.* = .{ .vec_len = .{ .vec = vref2 } };
    const cond = try b.a.create(hir.Expr);
    cond.* = .{ .bin = .{ .kind = .lt, .lhs = iref2, .rhs = lenx } };
    const wst = try b.a.create(hir.Stmt);
    wst.* = .{ .while_ = .{ .cond = cond, .body = body_blk } };
    try items.append(b.a, wst);

    const out = try b.a.create(hir.Stmt);
    out.* = .{ .block = try items.toOwnedSlice(b.a) };
    return out;
}

/// A statement-position `v.push(x)` on a vec binding, or null.
fn tryVecPush(b: *Builder, call: ast.CallExpr, scope: *Scope) BuildError!?*hir.Stmt {
    const cname = (callPathName(b, call)) orelse return null;
    defer b.a.free(cname);
    const dot = std.mem.lastIndexOfScalar(u8, cname, '.') orelse return null;
    if (!std.mem.eql(u8, cname[dot + 1 ..], "push")) return null;
    if (!scope.vecs.contains(cname[0..dot])) return null;
    const loc = scope.find(cname[0..dot]) orelse return null;
    var ait = call.args();
    const arg = ait.next() orelse return error.Unsupported;
    if (ait.next() != null) return error.Unsupported;
    const vref = try b.a.create(hir.Expr);
    vref.* = .{ .local = .{ .idx = loc.idx, .ty = .ptr } };
    const st = try b.a.create(hir.Stmt);
    st.* = .{ .vec_push = .{ .vec = vref, .value = try buildIntExpr(b, arg, scope) } };
    return st;
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
    const ParamKind = union(enum) { int, float: hir.Type, bool_, str_, rec: *const StructInfo, vec };
    const np = b.funcs.items[id].params.len;
    const kinds = try b.a.alloc(ParamKind, np);
    const frec = b.fn_recs.get(id);
    const vflags = b.fn_vec_params.get(id);
    for (b.funcs.items[id].params, 0..) |p, k| {
        kinds[k] = switch (p.ty) {
            .bool => .bool_,
            .i64 => .int,
            .f64 => .{ .float = .f64 },
            .f32 => .{ .float = .f32 },
            .str => .str_,
            // A `.ptr` param is a vec or a record (str callees never get here).
            .ptr => if (vflags != null and k < vflags.?.len and vflags.?[k])
                .vec
            else
                .{ .rec = (frec orelse return error.Unsupported).params[k] orelse return error.Unsupported },
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
                if (rv.si != want and !enumCompatible(b, rv.si, want)) return reject(b, .unsupported_call); // a different struct
                try args.append(b.a, rv.e);
            },
            .vec => {
                // Pass a vec binding's base pointer (the arg is a vec name).
                const vn = switch (a) {
                    .path => |pp| try pp.text(b.a),
                    else => return reject(b, .unsupported_call),
                };
                defer b.a.free(vn);
                if (!scope.vecs.contains(vn)) return reject(b, .unsupported_call);
                const loc = scope.find(vn) orelse return reject(b, .unsupported_call);
                const vref = try b.a.create(hir.Expr);
                vref.* = .{ .local = .{ .idx = loc.idx, .ty = .ptr } };
                try args.append(b.a, vref);
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
            .str_ => {
                // A constant folds, a binding/param passes by reference
                // (main's str bindings are scope-visible).
                try args.append(b.a, try buildStrArg(b, a, scope, null));
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
        .fieldType = ExprTypeBridge.fieldType,
        .fnRet = ExprTypeBridge.fnRet,
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

/// The native float-math builtin named by a method (`sqrt`/`abs`/`floor`/
/// `ceil`) — each a single wasm instruction on a float operand — or null.
fn floatBuiltinKind(method: []const u8) ?ops.UnKind {
    if (std.mem.eql(u8, method, "abs")) return .fabs;
    if (std.mem.eql(u8, method, "sqrt")) return .fsqrt;
    if (std.mem.eql(u8, method, "floor")) return .ffloor;
    if (std.mem.eql(u8, method, "ceil")) return .fceil;
    if (std.mem.eql(u8, method, "trunc")) return .ftrunc;
    if (std.mem.eql(u8, method, "nearest")) return .fnearest;
    return null;
}

/// True when a parameter is `fn`-typed (`f: fn(i64) -> i64`) — a closure
/// slot, inlined at lowering (no runtime ABI). Relies on slice 3a's
/// structured `FN_TYPE` parsing.
fn paramIsFnTyped(p: ast.Param) bool {
    const ty = p.type_() orelse return false;
    return ty == .raw and ty.raw.cst.kind == .FN_TYPE;
}

/// True when a parameter is `Vec<…>`-typed (passed as a `.ptr`, iterated
/// as a vec in the callee body).
fn paramIsVec(b: *Builder, p: ast.Param) bool {
    const ty = p.type_() orelse return false;
    if (ty != .path) return false;
    const nm = ty.path.name(b.a) catch return false;
    defer b.a.free(nm);
    return std.mem.eql(u8, nm, "Vec");
}

/// Build the vec-param flags (parallel to the hir param list) for `fd`, and
/// record them on `id` if any parameter is a vec. Call after the params are
/// collected (it re-scans `fd`, skipping the inlined `fn`-typed params).
fn recordVecParams(b: *Builder, id: hir.FuncId, fd: ast.FnDecl) BuildError!void {
    const ps = fd.params() orelse return;
    var flags: std.ArrayList(bool) = .empty;
    var any = false;
    var it = ps.iter();
    while (it.next()) |p| {
        if (paramIsFnTyped(p)) continue; // not a runtime param
        const is_vec = paramIsVec(b, p);
        if (is_vec) any = true;
        try flags.append(b.a, is_vec);
    }
    if (any) {
        try b.fn_vec_params.put(b.a, id, try flags.toOwnedSlice(b.a));
    } else {
        flags.deinit(b.a);
    }
}

/// Does `fd` have a `fn`-typed parameter (i.e. is it higher-order)?
fn hasFnParam(fd: ast.FnDecl) bool {
    const ps = fd.params() orelse return false;
    var it = ps.iter();
    while (it.next()) |p| if (paramIsFnTyped(p)) return true;
    return false;
}

/// A lambda's body as an `Expr` (null when it's a block — deferred in v0).
fn lambdaBodyExpr(lam: ast.LambdaExpr) ?ast.Expr {
    const bn = lam.body() orelse return null;
    return ast.Expr.cast(bn);
}

/// A lambda's runtime capture: a free scalar variable resolved at the
/// call site, threaded into the stamped instance as an extra parameter.
const Capture = struct { name: []const u8, ty: hir.Type, idx: u32 };

fn isLambdaParam(lam: ast.LambdaExpr, name: []const u8) bool {
    var it = lam.params();
    while (it.next()) |p| if (std.mem.eql(u8, p.text, name)) return true;
    return false;
}

/// Collect the lambda's runtime captures: single-segment identifiers in its
/// body that aren't its parameters and resolve to a *scalar local* in the
/// call-site `caller` scope. (A const `let` folds and isn't a local, so it
/// keeps folding; a `var` / call-bound value is captured.) Deduped, in
/// first-seen order. v0: scalar captures only.
fn collectCaptures(b: *Builder, node: *const parser.cst.Node, lam: ast.LambdaExpr, caller: *const Scope, out: *std.ArrayList(Capture)) BuildError!void {
    if (node.kind == .PATH_EXPR) {
        var head: ?[]const u8 = null;
        var dotted = false;
        for (node.children) |c| switch (c) {
            .token => |t| {
                if (t.kind.isTrivia()) continue;
                if (t.kind == .DOT) dotted = true else if (t.kind == .IDENT and head == null) head = t.text;
            },
            .node => {},
        };
        if (!dotted) if (head) |h| {
            if (!isLambdaParam(lam, h)) {
                if (caller.find(h)) |loc| switch (loc.ty) {
                    .i64, .f64, .f32, .bool => {
                        var seen = false;
                        for (out.items) |cap| if (std.mem.eql(u8, cap.name, h)) {
                            seen = true;
                            break;
                        };
                        if (!seen) try out.append(b.a, .{ .name = h, .ty = loc.ty, .idx = loc.idx });
                    },
                    else => {}, // non-scalar capture deferred (the body ref will reject honestly)
                };
            }
        };
    }
    for (node.children) |c| switch (c) {
        .node => |n| try collectCaptures(b, n, lam, caller, out),
        .token => {},
    };
}

fn firstTokOffset(node: *const parser.cst.Node) u32 {
    for (node.children) |c| switch (c) {
        .token => |t| if (!t.kind.isTrivia()) return t.offset,
        .node => |n| return firstTokOffset(n),
    };
    return 0;
}

/// **Closures, slice 3b — inline a `hof_name(args)` call.** Builds the bound
/// lambda's body with its parameters substituted by the (built) `args`. v0:
/// the lambda body is one expression; arguments are shared into the body, so
/// they should be simple (a local / const) when a parameter is used more than
/// once.
fn inlineLambda(b: *Builder, lam: ast.LambdaExpr, call: ast.CallExpr, scope: *Scope) BuildError!*hir.Expr {
    const body = lambdaBodyExpr(lam) orelse return error.Unsupported; // block body deferred
    var bound: std.ArrayList([]const u8) = .empty;
    defer bound.deinit(b.a);
    var pit = lam.params();
    var ait = call.args();
    while (pit.next()) |pn| {
        const a0 = ait.next() orelse return reject(b, .unsupported_call); // too few args
        const av = try buildIntExpr(b, a0, scope);
        try scope.subst.put(b.a, pn.text, av);
        try bound.append(b.a, pn.text);
    }
    if (ait.next() != null) return reject(b, .unsupported_call); // too many args
    const result = try buildIntExpr(b, body, scope);
    for (bound.items) |nm| _ = scope.subst.remove(nm);
    return result;
}

/// **Closures, slice 3b — a higher-order call** `apply(|n| …, x)`. The
/// `fn`-typed parameter takes the lambda (inlined); the rest are ordinary
/// arguments. Stamps a specialized instance of the callee per lambda and
/// returns a direct call to it (the spec's zero-cost, no-env-box model).
fn buildHofCall(b: *Builder, fname: []const u8, fd: ast.FnDecl, call: ast.CallExpr, scope: *Scope) BuildError!*hir.Expr {
    const ps = fd.params() orelse return error.Unsupported;
    var lam: ?ast.LambdaExpr = null;
    var fpname: ?[]const u8 = null;
    var args: std.ArrayList(*hir.Expr) = .empty;
    var pit = ps.iter();
    var ait = call.args();
    while (pit.next()) |p| {
        const a0 = ait.next() orelse return reject(b, .unsupported_call);
        if (paramIsFnTyped(p)) {
            if (lam != null) return error.Unsupported; // v0: one fn-typed param
            switch (a0) {
                .lambda => |l| lam = l,
                else => return reject(b, .unsupported_call), // must pass a lambda literal (v0)
            }
            fpname = (p.name() orelse return error.Unsupported).text;
        } else {
            try args.append(b.a, try buildIntExpr(b, a0, scope));
        }
    }
    if (ait.next() != null) return reject(b, .unsupported_call);
    const the_lam = lam orelse return error.Unsupported;

    // Runtime captures: free scalar locals referenced in the lambda body. They
    // ride into the stamped instance as extra parameters (capture by value —
    // a sound alias for a downward-only, non-mutating closure), so append the
    // captured values to the call here, after the ordinary arguments.
    var captures: std.ArrayList(Capture) = .empty;
    defer captures.deinit(b.a);
    if (the_lam.body()) |lbody| try collectCaptures(b, lbody, the_lam, scope, &captures);
    for (captures.items) |cap| {
        const cv = try b.a.create(hir.Expr);
        cv.* = .{ .local = .{ .idx = cap.idx, .ty = cap.ty } };
        try args.append(b.a, cv);
    }

    const fid = try stampHof(b, fname, fd, fpname orelse return error.Unsupported, the_lam, captures.items);
    const e = try b.a.create(hir.Expr);
    e.* = .{ .call = .{ .func = fid, .args = try args.toOwnedSlice(b.a) } };
    return e;
}

/// Stamp a specialized instance of higher-order `fd` for the given lambda:
/// the `fn`-typed parameter is dropped (inlined in the body), the rest stay
/// runtime parameters. Deduped per (callee, lambda site).
fn stampHof(b: *Builder, fname: []const u8, fd: ast.FnDecl, fpname: []const u8, lam: ast.LambdaExpr, captures: []const Capture) BuildError!hir.FuncId {
    const key = try std.fmt.allocPrint(b.a, "{s}#L{d}", .{ fname, firstTokOffset(lam.cst) });
    if (b.ids.get(key)) |id| {
        b.a.free(key);
        return id;
    }
    const rs = (try fnRetScalar(b, fd)) orelse return error.Unsupported;
    const ret_ty: hir.Type = switch (rs) {
        .bool, .i64, .f64, .f32 => rs,
        else => return error.Unsupported, // v0: scalar-returning HOFs
    };

    var scope = Scope{ .a = b.a, .callee = true };
    scope.hof_name = fpname;
    scope.hof_lambda = lam;
    var params: std.ArrayList(hir.Param) = .empty;
    var rec_params: std.ArrayList(?*const StructInfo) = .empty;
    _ = try collectCalleeParams(b, fd, &scope, &params, &rec_params); // skips the fn param
    rec_params.deinit(b.a);
    // Captures follow the ordinary parameters (matching the call site's
    // appended capture values), readable in the body by name.
    for (captures) |cap| {
        _ = try scope.declare(cap.name, false, cap.ty);
        try params.append(b.a, .{ .name = cap.name, .ty = cap.ty });
    }
    scope.n_params = scope.next_idx;
    const param_slice = try params.toOwnedSlice(b.a);

    const id: hir.FuncId = @intCast(b.funcs.items.len);
    try b.ids.put(b.a, key, id);
    const dummy = try b.a.create(hir.Stmt);
    dummy.* = .{ .block = &.{} };
    try b.funcs.append(b.a, .{ .name = key, .params = param_slice, .ret = ret_ty, .body = dummy });

    const body = try buildIntBlock(b, fd.body() orelse return error.Unsupported, &scope);
    const extra = scope.extra();
    const locals = try b.a.alloc(hir.Type, extra);
    for (locals, 0..) |*t, j| {
        const ty = scope.locals.items[scope.n_params + j].ty;
        t.* = if (ty == .str) .ptr else ty;
    }
    b.funcs.items[id] = .{ .name = key, .params = param_slice, .ret = ret_ty, .locals = locals, .body = body };
    return id;
}

/// The native binary float-math builtin named by a method (`min`/`max`/
/// `copysign`) — one wasm instruction on two same-type float operands.
fn floatBinBuiltinKind(method: []const u8) ?ops.BinKind {
    if (std.mem.eql(u8, method, "min")) return .fmin;
    if (std.mem.eql(u8, method, "max")) return .fmax;
    if (std.mem.eql(u8, method, "copysign")) return .fcopysign;
    return null;
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
            // `s.len` parses as one dotted path: the i64 byte length of a
            // str local (spec/types.md §Strings).
            if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| {
                if (std.mem.eql(u8, name[dot + 1 ..], "len")) {
                    if (self.scope.find(name[0..dot])) |head| {
                        if (head.ty == .str) return .i64;
                    }
                }
            }
            // `p.x` on a materialized record, or a bare actor-state field
            // (`n` in a handler → `self.n`): the field's declared type.
            const rf = (findRecField(self.scope, name) catch return null) orelse
                actorStateField(self.scope, name) orelse return null;
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

    fn fieldType(ctx: *anyopaque, base: ast.Expr, field: []const u8) std.mem.Allocator.Error!?sema.exprtype.ScalarType {
        const self: *ExprTypeBridge = @ptrCast(@alignCast(ctx));
        // Resolve the base to a record/tuple binding (`t.0`, `p.field`); other
        // bases (calls, index) type their field on a later slice.
        const bp = switch (base) {
            .path => |p| p,
            else => return null,
        };
        const nm = try bp.text(self.b.a);
        defer self.b.a.free(nm);
        const si = self.scope.recs.get(nm) orelse return null;
        const f = si.field(field) orelse return null;
        return switch (f.ty) {
            .bool => .bool,
            .i64 => .i64,
            .f64 => .f64,
            .f32 => .f32,
            .u8, .i8, .u16, .i16, .u32, .i32 => .narrow_int,
            else => .unknown,
        };
    }

    fn fnRet(ctx: *anyopaque, name: []const u8) std.mem.Allocator.Error!?sema.exprtype.ScalarType {
        const self: *ExprTypeBridge = @ptrCast(@alignCast(ctx));
        if (std.mem.indexOfScalar(u8, name, '.') != null) return null;
        if (castTarget(name)) |ct| return switch (ct) {
            .f32 => .f32,
            .f64 => .f64,
            else => .i64,
        };
        const fd = self.b.resolver.lookup(name) orelse return null;
        const rt = (fnRetScalar(self.b, fd) catch return null) orelse return null;
        return switch (rt) {
            .i64 => .i64,
            .f64 => .f64,
            .f32 => .f32,
            .bool => .bool,
            .str => .str,
            else => null,
        };
    }

    fn callRet(ctx: *anyopaque, name: []const u8, call: ast.CallExpr) std.mem.Allocator.Error!?sema.exprtype.ScalarType {
        const self: *ExprTypeBridge = @ptrCast(@alignCast(ctx));
        // A `graph` call (`pipeline(...)`) types as the graph's declared output.
        if (self.b.graph_decls.get(name)) |gd| {
            const rt = gd.returnType() orelse return null;
            const ht = (semaScalar(self.b, rt.type_()) catch null) orelse return null;
            return switch (ht) {
                .i64 => .i64,
                .f64 => .f64,
                .f32 => .f32,
                .bool => .bool,
                else => null,
            };
        }
        // A builtin numeric cast types as its target (`f32(x)` is f32).
        if (castTarget(name)) |ct| {
            return switch (ct) {
                .f32 => .f32,
                .f64 => .f64,
                else => .i64,
            };
        }
        // A dotted call on a record binding (`r.wide()`): the fit
        // method's declared return type — or a str method on a str
        // local (`s.contains(…)` parses as one dotted callee path).
        if (std.mem.indexOfScalar(u8, name, '.')) |dot| {
            const mname = name[dot + 1 ..];
            if (std.mem.indexOfScalar(u8, mname, '.') != null) return null;
            // `h.await()` types as the handle's result — the receiver's type.
            if (std.mem.eql(u8, mname, "await")) {
                if (self.scope.find(name[0..dot])) |head| {
                    return switch (head.ty) {
                        .bool => .bool,
                        .f64 => .f64,
                        .f32 => .f32,
                        else => .i64,
                    };
                }
                return null;
            }
            // A native float-math builtin (`x.sqrt()`, `x.min(y)`) types as
            // its float receiver: f64 stays f64, f32 stays f32.
            if (floatBuiltinKind(mname) != null or floatBinBuiltinKind(mname) != null) {
                if (self.scope.find(name[0..dot])) |head| {
                    if (head.ty == .f64) return .f64;
                    if (head.ty == .f32) return .f32;
                }
            }
            if (self.scope.find(name[0..dot])) |head| {
                if (head.ty == .str) return sema.exprtype.strMethodType(mname);
            }
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
        if (fd.isGeneric()) {
            if (try self.genericRet(fd, call)) |t| return t;
            // A concrete return on a generic still types below.
        }
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

    /// The scalar a generic `-> T` call returns, inferred from the
    /// deciding argument (a bare `T` arg's scalar type, or a `[T]`
    /// arg's element type). Null when T isn't decidable here (record
    /// Ts, unprovable shapes — the builder rejects those honestly).
    fn genericRet(self: *ExprTypeBridge, fd: ast.FnDecl, call: ast.CallExpr) std.mem.Allocator.Error!?sema.exprtype.ScalarType {
        const sig = parseGenericSig(fd.genericParams().?) orelse return null;
        const rt = fd.returnType() orelse return null;
        const which = sema.fits.typeWhich(rt.type_() orelse return null, sig, self.b.a) orelse return null;
        const ps = fd.params() orelse return null;
        var pit = ps.iter();
        var ait = call.args();
        while (pit.next()) |p| {
            const a0 = ait.next() orelse return null;
            if (bareWhich(p, sig, self.b.a)) |w| {
                if (w != which) continue;
                return switch ((try scalarOrNull(self, a0)) orelse return null) {
                    .bool, .i64, .f64, .f32 => |sc| sc,
                    else => null,
                };
            }
            if (sliceOfWhich(p, sig, self.b.a)) |w| {
                if (w != which) continue;
                switch (a0) {
                    .path => |pp| {
                        // An array binding: its element type.
                        const txt = try pp.text(self.b.a);
                        defer self.b.a.free(txt);
                        const ai = self.scope.arrs.get(txt) orelse return null;
                        return switch (ai.elem) {
                            .scalar => |t| switch (t) {
                                .bool => .bool,
                                .i64 => .i64,
                                .f64 => .f64,
                                .f32 => .f32,
                                else => null,
                            },
                            .rec => null,
                        };
                    },
                    .array => |ae| {
                        // An array literal: its first element's type.
                        var eit = ae.elements();
                        const e0 = eit.next() orelse return null;
                        return switch ((try scalarOrNull(self, e0)) orelse return null) {
                            .bool, .i64, .f64, .f32 => |sc| sc,
                            else => null,
                        };
                    },
                    else => return null,
                }
            }
        }
        return null;
    }

    /// `exprScalar` mapped onto the total typing contract: a rejected/
    /// unsupported shape types as "don't know", never an error.
    fn scalarOrNull(self: *ExprTypeBridge, e: ast.Expr) std.mem.Allocator.Error!?sema.exprtype.ScalarType {
        return exprScalar(self.b, e, self.scope) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
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
    /// Enum-typed bindings (C1): name → the enum; the tag lives in an
    /// i64 local under the same name. `match` reads this to resolve
    /// bare variant names in arm patterns.
    enum_binds: std.StringHashMapUnmanaged(*const EnumInfo) = .empty,
    /// Vec bindings (the v0 floor, spec/types.md §Growable): name →
    /// present. The header base pointer lives in `locals` under the
    /// same name (a `.ptr`); elements are i64.
    vecs: std.StringHashMapUnmanaged(void) = .empty,
    /// Channel bindings (concurrency v0): name → the i64 read-cursor local
    /// index. The buffer is a Vec under the same name (also in `vecs`):
    /// `send` is a `vec_push`, `recv` reads `buf[cursor]` then bumps the
    /// cursor. v0 FIFO. recv suspends on empty; a *bounded* channel (below)
    /// suspends `send` on full — both in the round-robin scheduler.
    chans: std.StringHashMapUnmanaged(u32) = .empty,
    /// Bounded channels: name → capacity (a positive count). Absent ⇒
    /// unbounded (`send` never blocks). A bounded channel's `send` parks in
    /// the scheduler when the buffer holds `capacity` unread elements
    /// (`vec_len - cursor >= capacity`); recv frees a slot by bumping cursor.
    chan_caps: std.StringHashMapUnmanaged(i64) = .empty,
    /// Inside an actor handler body, the actor's state struct — so a bare field
    /// name (`n`) resolves to `self.n` (read, write, and type), the implicit-
    /// self convention. `self` itself is registered in `recs`.
    self_actor: ?*const StructInfo = null,
    /// True for a plain callee body (registerFunc), whose locals are
    /// tracked by `declare` alone — entry-style bodies (`main`,
    /// stamped generics) mirror every local into `b.cur_locals` too.
    /// `declareBodyLocal` picks the right bookkeeping.
    callee: bool = false,
    /// Closure inlining (slice 3b): while building a higher-order function's
    /// stamped body, `hof_name` is its `fn`-typed parameter and `hof_lambda`
    /// the lambda bound to it at the call site — a call `hof_name(args)` in the
    /// body inlines the lambda. `subst` maps a lambda parameter name to the
    /// (already-built) argument expression during that inlining.
    hof_name: ?[]const u8 = null,
    hof_lambda: ?ast.LambdaExpr = null,
    subst: std.StringHashMapUnmanaged(*hir.Expr) = .empty,

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

/// Declare a str-valued body binding: a scope entry typed `.str` at the
/// ptr slot (name resolution) backed by TWO address-width locals
/// (ptr at idx, len at idx+1) in either bookkeeping mode.
fn declareStrBodyLocal(b: *Builder, scope: *Scope, name: []const u8) BuildError!u32 {
    const hidden = try std.fmt.allocPrint(b.a, "{s}#len", .{name});
    if (scope.callee) {
        const idx = try scope.declare(name, false, .str);
        _ = try scope.declare(hidden, false, .ptr);
        return idx;
    }
    scope.next_idx = @intCast(b.cur_locals.items.len);
    const idx = try scope.declare(name, false, .str);
    try b.cur_locals.append(b.a, .ptr);
    _ = try scope.declare(hidden, false, .ptr);
    try b.cur_locals.append(b.a, .ptr);
    return idx;
}

/// Declare a body local with the right bookkeeping for the context:
/// entry-style bodies (`main`, stamped generics) mirror each local into
/// `b.cur_locals`; a plain callee body tracks them in the scope alone.
/// Bind a name to an *existing* local slot (no new slot): a scalar match's
/// `x` ident pattern aliases the scrutinee local so the guard and body can
/// read its value. Idempotent across arms — every alias points at `idx`.
fn aliasLocal(scope: *Scope, name: []const u8, idx: u32, ty: hir.Type) BuildError!void {
    try scope.locals.append(scope.a, .{ .name = name, .idx = idx, .mutable = false, .ty = ty });
}

fn declareBodyLocal(b: *Builder, scope: *Scope, name: []const u8, mutable: bool, ty: hir.Type) BuildError!u32 {
    if (scope.callee) return scope.declare(name, mutable, ty);
    scope.next_idx = @intCast(b.cur_locals.items.len);
    const idx = try scope.declare(name, mutable, ty);
    try b.cur_locals.append(b.a, ty);
    return idx;
}

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
            const lpat = ls.pattern() orelse return error.Unsupported;
            // `let P { x, y } = rec` / `let (a, b) = (…)` — destructuring; the
            // binding statements ride in one block (callee bodies are i64-typed).
            if (lpat.kind() == .RECORD_STRUCT_PATTERN or lpat.kind() == .TUPLE_PATTERN) {
                var items: std.ArrayList(*hir.Stmt) = .empty;
                if (lpat.kind() == .RECORD_STRUCT_PATTERN)
                    try buildRecordDestructure(b, lpat, init_expr, scope, &items)
                else
                    try buildTupleDestructure(b, lpat, init_expr, scope, ls.isVar(), &items);
                out.* = .{ .block = try items.toOwnedSlice(b.a) };
                return out;
            }
            const nm = lpat.bindingName() orelse return error.Unsupported;
            // The bind-the-match form (`let label = match s { … }`) in a callee:
            // same desugar as `main`'s C2 — a hidden result local assigned per
            // arm, then the name reads it. The whole thing rides in one block.
            if (init_expr == .match) return buildIntMatchLet(b, ls, init_expr.match, nm, scope);
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
            const op = as.op() orelse return error.Unsupported;
            const rhs_ast = as.value() orelse return error.Unsupported;
            if (scope.find(tname)) |loc| {
                if (!loc.mutable) return reject(b, .immutable_assign); // a `let` binding or a parameter
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
            } else if (actorStateField(scope, tname)) |rf| {
                // `n = …` on a bare actor-state field → a field_set on self.
                if (rf.ty != .i64 and rf.ty != .bool and rf.ty != .f64 and rf.ty != .f32) return error.Unsupported;
                const rhs_sc = try exprScalar(b, rhs_ast, scope);
                if (op.kind == .EQ) {
                    if (scalarBindTy(rhs_sc) != rf.ty) return error.Unsupported;
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
                out.* = .{ .field_set = .{ .base = base, .offset = rf.offset, .ty = rf.ty, .value = value } };
            } else return error.Unsupported;
        },
        .if_stmt => |is| return buildIfStmtNode(b, is, scope),
        .match_stmt => |ms| return buildIntMatch(b, ms, scope),
        .while_stmt => |ws| {
            const cond = try buildIntExpr(b, ws.condition() orelse return error.Unsupported, scope);
            const body = try buildIntBlock(b, ws.body() orelse return error.Unsupported, scope);
            out.* = .{ .while_ = .{ .cond = cond, .body = body } };
        },
        .loop_stmt => |lp| out.* = .{ .loop_ = try buildIntBlock(b, lp.body() orelse return error.Unsupported, scope) },
        .for_stmt => |fs| {
            const pat = (fs.pattern() orelse return error.Unsupported).bindingName() orelse return error.Unsupported;
            const iter = fs.iterable() orelse return error.Unsupported;
            if (iter == .range) return buildIntForRange(b, fs, iter.range, pat.text, scope);
            // `for x in xs` over a vec parameter/binding.
            if (iter == .path) {
                const nm = try iter.path.text(b.a);
                defer b.a.free(nm);
                if (scope.vecs.contains(nm)) return buildIntForVec(b, fs, nm, pat.text, scope);
            }
            return error.Unsupported; // array `for` in a callee body: a follow-on
        },
        .break_stmt => |bs| {
            if (bs.value() != null) return error.Unsupported; // value-break not supported
            out.* = .brk;
        },
        .continue_stmt => out.* = .cont,
        else => return error.Unsupported,
    }
    return out;
}

/// A `match` in a callee body — the value form: every arm is a `->`
/// expression of one scalar type, lowered to a value `if` chain. The
/// hidden scrutinee set + the chain ride in one block; as the body's
/// tail the lowering reads it as a nested value block. The scrutinee
/// may be an enum value (incl. an enum-typed *param*) or a provable
/// i64 (literal arms). Statement-position matches with side-effecting
/// arm bodies are a later rung.
fn buildIntMatch(b: *Builder, ms: ast.MatchStmt, scope: *Scope) BuildError!*hir.Stmt {
    const scrut = ms.scrutinee() orelse return error.Unsupported;
    const info_opt = try enumOfExpr(b, scope, scrut);
    if (info_opt == null and (try exprScalar(b, scrut, scope)) != .i64) return error.Unsupported;
    const boxed = if (info_opt) |info| info.si != null else false;

    var stmts: std.ArrayList(*hir.Stmt) = .empty;
    const s_idx = try declareMatchScrutinee(b, scope, scrut, boxed, &stmts);

    var arms: std.ArrayList(LoweredArm) = .empty;
    defer arms.deinit(b.a);
    var default: ?*hir.Stmt = null;
    var seen: u64 = 0;
    var vty: ?hir.Type = null;
    var it = ms.arms();
    while (it.next()) |arm| {
        const pat = arm.pattern() orelse return error.Unsupported;
        if (pat.kind() == .OR_PATTERN) {
            if (arm.guard() != null) return error.Unsupported; // guards on or-patterns: later
            const e = arm.expression() orelse return error.Unsupported;
            const sc = scalarBindTy(try exprScalar(b, e, scope));
            if (vty) |t| {
                if (sc != t) return error.Unsupported;
            } else vty = sc;
            const value = try buildIntExpr(b, e, scope);
            const vstmt = try b.a.create(hir.Stmt);
            vstmt.* = .{ .expr = value };
            const body = try b.a.create(hir.Stmt);
            body.* = .{ .block = try b.a.dupe(*hir.Stmt, &.{vstmt}) };
            var alts = pat.alternatives();
            var n: usize = 0;
            while (alts.next()) |alt| {
                n += 1;
                const ap2 = (if (info_opt) |info|
                    try resolveArmPattern(b, info, alt, scope, s_idx)
                else
                    try resolveLiteralPattern(b, alt)) orelse return error.Unsupported;
                if (ap2.prelude.len != 0 or ap2.cond != null) return error.Unsupported;
                try arms.append(b.a, .{ .tag = ap2.tag, .body = body });
                if (info_opt != null) seen |= @as(u64, 1) << @intCast(ap2.tag);
            }
            if (n == 0) return error.Unsupported;
            continue;
        }
        if (info_opt == null and pat.kind() == .IDENT_PATTERN) {
            const nm = pat.bindingName() orelse return error.Unsupported;
            try aliasLocal(scope, nm.text, s_idx, .i64);
            const e = arm.expression() orelse return error.Unsupported;
            const sc = scalarBindTy(try exprScalar(b, e, scope));
            if (vty) |t| {
                if (sc != t) return error.Unsupported;
            } else vty = sc;
            const value = try buildIntExpr(b, e, scope);
            const vstmt = try b.a.create(hir.Stmt);
            vstmt.* = .{ .expr = value };
            const body = try b.a.create(hir.Stmt);
            body.* = .{ .block = try b.a.dupe(*hir.Stmt, &.{vstmt}) };
            if (arm.guard()) |gexpr| {
                if (!try exprIsBool(b, gexpr, scope)) return error.Unsupported;
                const guard = try buildIntExpr(b, gexpr, scope);
                try arms.append(b.a, .{ .tag = 0, .body = body, .guard = guard, .any = true });
            } else {
                if (default != null) return error.Unsupported;
                default = body;
            }
            continue;
        }
        if (info_opt == null and pat.kind() == .RANGE_PATTERN) {
            const e = arm.expression() orelse return error.Unsupported;
            const sc = scalarBindTy(try exprScalar(b, e, scope));
            if (vty) |t| {
                if (sc != t) return error.Unsupported;
            } else vty = sc;
            const value = try buildIntExpr(b, e, scope);
            const vstmt = try b.a.create(hir.Stmt);
            vstmt.* = .{ .expr = value };
            const body = try b.a.create(hir.Stmt);
            body.* = .{ .block = try b.a.dupe(*hir.Stmt, &.{vstmt}) };
            const cond = try buildRangePatternCond(b, scope, pat, arm, s_idx);
            try arms.append(b.a, .{ .tag = 0, .body = body, .guard = cond, .any = true });
            continue;
        }
        // Pattern first: payload bindings must be in scope for the value.
        const rp = if (info_opt) |info|
            try resolveArmPattern(b, info, pat, scope, s_idx)
        else
            try resolveLiteralPattern(b, pat);
        const e = arm.expression() orelse return error.Unsupported; // value arms only
        const sc = scalarBindTy(try exprScalar(b, e, scope));
        if (vty) |t| {
            if (sc != t) return error.Unsupported; // arms must agree on one type
        } else vty = sc;
        const value = try buildIntExpr(b, e, scope);
        const vstmt = try b.a.create(hir.Stmt);
        vstmt.* = .{ .expr = value };
        const body = try b.a.create(hir.Stmt);
        body.* = .{ .block = try b.a.dupe(*hir.Stmt, &.{vstmt}) };
        const ap = rp orelse {
            if (arm.guard() != null) return error.Unsupported; // guarded `_`: later
            if (default != null) return error.Unsupported; // two `_` arms
            default = body;
            continue;
        };
        var guard: ?*hir.Expr = null;
        if (arm.guard()) |gexpr| {
            if (ap.prelude.len != 0) return error.Unsupported;
            if (!try exprIsBool(b, gexpr, scope)) return error.Unsupported;
            guard = try buildIntExpr(b, gexpr, scope);
        }
        // A literal sub-pattern condition (`Move(0, y)`) ANDs onto the guard.
        const combined = try andOpt(b, ap.cond, guard);
        try arms.append(b.a, .{ .tag = ap.tag, .body = try prependPrelude(b, ap.prelude, body), .guard = combined });
        if (info_opt != null and combined == null) seen |= @as(u64, 1) << @intCast(ap.tag);
    }
    if (default == null) {
        const info = info_opt orelse return error.Unsupported;
        if (@popCount(seen) < info.variants.len) return error.Unsupported;
    }
    // A *value* chain must yield on every path. An exhaustive match
    // without `_` makes the last arm's test redundant — it becomes the
    // chain's else.
    var arm_slice: []const LoweredArm = arms.items;
    var dflt = default;
    if (dflt == null) {
        dflt = arm_slice[arm_slice.len - 1].body;
        arm_slice = arm_slice[0 .. arm_slice.len - 1];
    }
    try foldMatchChain(b, s_idx, boxed, arm_slice, dflt, &stmts);
    const out = try b.a.create(hir.Stmt);
    out.* = .{ .block = try stmts.toOwnedSlice(b.a) };
    return out;
}

/// `let x = match s { … }` in a callee body — the bind-the-match form.
/// Mirrors `main`'s C2 path through `buildMatchInto`: a hidden mutable
/// `#mres` local is assigned the chosen arm's value, then the named binding
/// reads it (the name is NOT in scope inside the arms — an initializer can't
/// see itself). The scrutinee set, the assignment chain, and the bind all
/// ride in one block; the binding stays visible to later statements because
/// `scope.declare` registers it in the shared body scope.
fn buildIntMatchLet(b: *Builder, ls: ast.LetStmt, me: ast.MatchExpr, nm: parser.cst.Token, scope: *Scope) BuildError!*hir.Stmt {
    const mty = try matchValueTy(b, me, scope);
    var stmts: std.ArrayList(*hir.Stmt) = .empty;
    const res_idx = try declareBodyLocal(b, scope, "#mres", true, mty);
    try buildMatchInto(b, me, scope, &stmts, res_idx, mty);
    const bidx = try declareBodyLocal(b, scope, nm.text, ls.isVar(), mty);
    const read = try b.a.create(hir.Expr);
    read.* = .{ .local = .{ .idx = res_idx, .ty = mty } };
    const bst = try b.a.create(hir.Stmt);
    bst.* = .{ .let = .{ .idx = bidx, .value = read } };
    try stmts.append(b.a, bst);
    const out = try b.a.create(hir.Stmt);
    out.* = .{ .block = try stmts.toOwnedSlice(b.a) };
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
            // Closure inlining (slice 3b): a lambda parameter resolves to the
            // argument expression substituted at the inlined call site.
            if (scope.subst.get(txt)) |se| return se;
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
            // `xs.len` of an array binding is its compile-time count;
            // `v.len` of a vec is a live header read (i64).
            if (std.mem.lastIndexOfScalar(u8, txt, '.')) |dotl| {
                if (std.mem.eql(u8, txt[dotl + 1 ..], "len")) {
                    if (scope.arrs.get(txt[0..dotl])) |ai| {
                        return countExpr(b, ai.count);
                    }
                    if (scope.vecs.contains(txt[0..dotl])) {
                        const loc = scope.find(txt[0..dotl]) orelse return error.Unsupported;
                        const vref = try b.a.create(hir.Expr);
                        vref.* = .{ .local = .{ .idx = loc.idx, .ty = .ptr } };
                        out.* = .{ .vec_len = .{ .vec = vref } };
                        return out;
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
            } else if (actorStateField(scope, txt)) |rf| {
                // A bare actor-state field (`n` in a handler → `self.n`).
                return recFieldExpr(b, rf);
            } else if (b.globals.get(txt)) |gi| {
                out.* = .{ .global_get = gi };       // module-level `state`
            } else if (enumVariantTag(b, txt)) |ev| {
                if (ev.info.si != null) return error.Unsupported; // boxed: a record value, not an int
                out.* = .{ .int_const = ev.tag };    // `Color.Red` → its tag
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
        .pipe => |pe| {
            // `lhs |> f(args)` ≡ `f(lhs, args)`: the piped value becomes the
            // first argument. `lhs |> f` (bare path) is `f(lhs)`. Chains are
            // left-associative, so `x |> a |> b` is `b(a(x))` naturally.
            const lhs = pe.lhs() orelse return error.Unsupported;
            const rhs = pe.rhs() orelse return error.Unsupported;
            const lval = try buildIntExpr(b, lhs, scope);
            switch (rhs) {
                .call => |rc| {
                    const fname = (callPathName(b, rc)) orelse return error.Unsupported;
                    defer b.a.free(fname);
                    if (std.mem.indexOfScalar(u8, fname, '.') != null) return error.Unsupported; // method targets: later
                    if (b.resolver.lookup(fname) == null) return reject(b, .name_not_found);
                    const id = try registerFunc(b, fname);
                    out.* = .{ .call = .{ .func = id, .args = try buildCallArgs(b, id, rc.args(), scope, lval) } };
                    return out;
                },
                .path => |p| {
                    const fname = try p.text(b.a);
                    defer b.a.free(fname);
                    if (std.mem.indexOfScalar(u8, fname, '.') != null) return error.Unsupported;
                    if (b.resolver.lookup(fname) == null) return reject(b, .name_not_found);
                    const id = try registerFunc(b, fname);
                    const empty = ast.ArgIter{ .children = &.{} };
                    out.* = .{ .call = .{ .func = id, .args = try buildCallArgs(b, id, empty, scope, lval) } };
                    return out;
                },
                else => return error.Unsupported,
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
            // `h.await()` — `await` isn't a keyword, so it parses as a call to
            // the dotted path `h.await`. On the v0 cooperative floor a task
            // that doesn't itself suspend has already completed (eager handle),
            // so `await` reads the handle's result. Task-internal suspension
            // (the CPS transform) is the next slice.
            if (std.mem.lastIndexOfScalar(u8, cname, '.')) |dot| {
                if (std.mem.eql(u8, cname[dot + 1 ..], "await")) {
                    const head = cname[0..dot];
                    if (scope.find(head)) |loc| {
                        const r = try b.a.create(hir.Expr);
                        r.* = .{ .local = .{ .idx = loc.idx, .ty = loc.ty } };
                        return r;
                    }
                }
            }
            // Closure inlining (slice 3b): a call to the enclosing HOF's
            // `fn`-typed parameter inlines the bound lambda's body.
            if (scope.hof_name) |hn| {
                if (std.mem.eql(u8, cname, hn)) return inlineLambda(b, scope.hof_lambda.?, cc, scope);
            }
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
            // Native float-math builtins parse as a dotted call on a float
            // local: `x.sqrt()`, `x.abs()`, `x.floor()`, `x.ceil()` — one wasm
            // instruction, result type = the operand's float type. Zero args.
            if (std.mem.lastIndexOfScalar(u8, cname, '.')) |dot| {
                const head = cname[0..dot];
                if (std.mem.indexOfScalar(u8, head, '.') == null) {
                    if (floatBuiltinKind(cname[dot + 1 ..])) |uk| {
                        if (scope.find(head)) |loc| {
                            if (loc.ty == .f64 or loc.ty == .f32) {
                                var fit = cc.args();
                                if (fit.next() != null) return reject(b, .unsupported_call); // niladic
                                const operand = try b.a.create(hir.Expr);
                                operand.* = .{ .local = .{ .idx = loc.idx, .ty = loc.ty } };
                                out.* = .{ .un = .{ .kind = uk, .operand = operand } };
                                return out;
                            }
                        }
                    }
                    // Binary float-math builtins: `x.min(y)`, `x.max(y)`,
                    // `x.copysign(y)` — both operands the same float type.
                    if (floatBinBuiltinKind(cname[dot + 1 ..])) |bk| {
                        if (scope.find(head)) |loc| {
                            if (loc.ty == .f64 or loc.ty == .f32) {
                                var bit = cc.args();
                                const a0 = bit.next() orelse return reject(b, .unsupported_call);
                                if (bit.next() != null) return reject(b, .unsupported_call); // exactly one
                                const want: sema.exprtype.ScalarType = if (loc.ty == .f64) .f64 else .f32;
                                if ((try exprScalar(b, a0, scope)) != want) return error.Unsupported; // no mixing
                                const lhs = try b.a.create(hir.Expr);
                                lhs.* = .{ .local = .{ .idx = loc.idx, .ty = loc.ty } };
                                const rhs = try buildIntExpr(b, a0, scope);
                                out.* = .{ .bin = .{ .kind = bk, .lhs = lhs, .rhs = rhs } };
                                return out;
                            }
                        }
                    }
                }
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
                        // A fit method, or an actor's value handler (`c.get()`).
                        const fid = (try registerFitMethod(b, si, mname)) orelse
                            (try registerActorHandler(b, si, mname)) orelse
                            return reject(b, .name_not_found);
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
                // Higher-order call (`apply(|n| …, x)`): specialize per lambda.
                if (hasFnParam(gfd)) {
                    const he = try buildHofCall(b, cname, gfd, cc, scope);
                    switch (b.funcs.items[he.call.func].ret) {
                        .i64, .bool, .f64, .f32 => {},
                        else => return reject(b, .unsupported_call),
                    }
                    return he;
                }
                if (gfd.isGeneric()) {
                    const ge = try buildGenericCall(b, cname, gfd, cc, scope);
                    switch (b.funcs.items[ge.call.func].ret) {
                        .i64, .bool, .f64, .f32 => {},
                        else => return reject(b, .unsupported_call),
                    }
                    return ge;
                }
            }
            // A `graph` called by name (`pipeline(args)`) runs its stages
            // eagerly and yields the terminal stage's value (Phase 4 v0).
            if (b.graph_decls.contains(cname)) {
                const gid = (try registerGraph(b, cname)) orelse return reject(b, .name_not_found);
                out.* = .{ .call = .{ .func = gid, .args = try buildCallArgs(b, gid, cc.args(), scope, null) } };
                return out;
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
        .tuple_field => |tf| {
            // `t.0` — index a tuple value. The tuple is an anonymous record
            // (fields "0", "1", …), so a field_get at the indexed slot. v0:
            // i64 elements.
            const idx_tok = tf.index() orelse return error.Unsupported;
            const tbase = tf.base() orelse return error.Unsupported;
            const rv = (try buildRecExpr(b, tbase, scope)) orelse return error.Unsupported;
            const f = rv.si.field(idx_tok.text) orelse return error.Unsupported; // out of range
            out.* = .{ .field_get = .{ .base = rv.e, .offset = f.offset, .ty = f.ty } };
            return out;
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
                // `v[i]` on a vec binding: bounds-checked in __vec_get.
                if (scope.vecs.contains(bn)) {
                    const loc = scope.find(bn) orelse return error.Unsupported;
                    const vref = try b.a.create(hir.Expr);
                    vref.* = .{ .local = .{ .idx = loc.idx, .ty = .ptr } };
                    const idx = try buildIntExpr(b, ix.index() orelse return error.Unsupported, scope);
                    out.* = .{ .vec_get = .{ .vec = vref, .idx = idx } };
                    return out;
                }
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
            // `h.await()` — suspend until the task completes, yield its result.
            // On the v0 cooperative floor a task that doesn't itself suspend
            // has already run to completion (eager handle), so the handle *is*
            // its result: await reads it. (Task-internal suspension — a task
            // that awaits mid-body — needs the CPS transform; that's the next
            // slice.) v0: scalar results.
            if (std.mem.eql(u8, mname, "await")) {
                return buildIntExpr(b, me.receiver() orelse return error.Unsupported, scope);
            }
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
    // shout's body is a concat of its parameter and the literal "!" —
    // the param piece is a str_binding at its two wasm slots (ptr=0,
    // len=1), the uniform str-value form.
    try testing.expect(std.mem.indexOf(u8, dump, "fn shout -> str") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "concat[str_binding[0,1]") != null);
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

test "float-math builtins: x.sqrt()/x.abs() lower to the float un ops; non-float rejected" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    try tr.addLib("pub fn root(x: f64) -> f64 { x.sqrt() }\npub fn mag(x: f64) -> f64 { x.abs() }\npub fn lo(a: f64, b: f64) -> f64 { a.min(b) }\n");

    var mod = (try buildFromSource(testing.allocator,
        "fn main {\n env.out(root(16.0))\n env.out(mag(-3.5))\n env.out(lo(1.0, 2.0))\n}\n", tr.resolver())) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "fsqrt") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "fabs") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "fmin") != null);

    // The same method on a non-float (i64) receiver isn't a builtin — it
    // falls through to dispatch and finds no such method.
    var tr2 = TestResolver{ .a = testing.allocator };
    defer tr2.deinit();
    try tr2.addLib("pub fn bad(n: i64) -> i64 { n.sqrt() }\n");
    const m2 = try buildFromSource(testing.allocator, "fn main {\n env.out(bad(4))\n}\n", tr2.resolver());
    try testing.expect(m2 == null);
}

test "closures: a higher-order fn specializes per lambda (inlined call)" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    try tr.addLib("pub fn apply(f: fn(i64) -> i64, x: i64) -> i64 { f(x) }\n");

    var mod = (try buildFromSource(testing.allocator,
        "fn main {\n env.out(apply(|n| n * 2, 21))\n env.out(apply(|n| n + 1, 5))\n}\n", tr.resolver())) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // Two stamped specializations (one per lambda), and the inlined bodies
    // (`n*2` → a mul, `n+1` → an add) rather than a call to `f`.
    try testing.expect(std.mem.indexOf(u8, dump, "apply#L") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "mul") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "add") != null);

    // A non-lambda argument to a fn-typed parameter is rejected.
    var tr2 = TestResolver{ .a = testing.allocator };
    defer tr2.deinit();
    try tr2.addLib("pub fn apply(f: fn(i64) -> i64, x: i64) -> i64 { f(x) }\n");
    const m2 = try buildFromSource(testing.allocator, "fn main {\n env.out(apply(7, 5))\n}\n", tr2.resolver());
    try testing.expect(m2 == null);
}

test "closures: a lambda captures a runtime local (capture-by-extra-param)" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    try tr.addLib("pub fn apply(f: fn(i64) -> i64, x: i64) -> i64 { f(x) }\n");
    // `g` is a runtime `var` local — captured into the stamped instance.
    var mod = (try buildFromSource(testing.allocator,
        "fn main {\n var g = 4\n env.out(apply(|n| n + g, 10))\n}\n", tr.resolver())) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // The capture rides as an extra param `g`, and the body adds it.
    try testing.expect(std.mem.indexOf(u8, dump, "apply#L") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "add") != null);
}

test "Vec.map: a closure-mapped vec (vec_new + per-element push)" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    var mod = (try buildFromSource(testing.allocator,
        "fn main {\n var v = Vec.from([1, 2, 3])\n let d = v.map(|x| x * 10)\n env.out(d[0])\n}\n", tr.resolver())) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // `d` is a fresh vec (vec_new) filled by a loop pushing the mapped value.
    try testing.expect(std.mem.indexOf(u8, dump, "vec_new") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "vec_push") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "mul") != null);
}

test "match or-patterns: A | B -> body expands to multiple tags sharing the body" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    var mod = (try buildFromSource(testing.allocator,
        "enum Light { Red, Yellow, Green }\nfn main {\n var l = Light.Yellow\n match l {\n Red | Yellow -> env.out(\"caution\"),\n Green -> env.out(\"go\"),\n }\n}\n", tr.resolver())) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // The or-arm expands into the tag-comparison chain (an `if`).
    try testing.expect(std.mem.indexOf(u8, dump, "if") != null);

    // An integer-literal or-pattern in a value `let = match`.
    var tr2 = TestResolver{ .a = testing.allocator };
    defer tr2.deinit();
    var m2 = (try buildFromSource(testing.allocator,
        "fn main {\n var n = 2\n let c = match n { 1 | 2 | 3 -> 10, _ -> 20 }\n env.out(c)\n}\n", tr2.resolver())) orelse
        return error.TestUnexpectedResult;
    defer m2.deinit();
    const d2 = try print.hirToString(testing.allocator, &m2);
    defer testing.allocator.free(d2);
    try testing.expect(std.mem.indexOf(u8, d2, "if") != null);
}

test "match guards: P if cond gates an arm with a logical-and on the tag test" {
    // A scalar binder guard (`x if x > 10`): the binder aliases the scrutinee,
    // and an unguarded `_` provides the exhaustive fallback.
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    var mod = (try buildFromSource(testing.allocator,
        "fn main {\n var n = 15\n let r = match n { x if x > 10 -> x * 2, _ -> 0 }\n env.out(r)\n}\n", tr.resolver())) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // The binder arm matches any value, so its condition is the bare guard.
    try testing.expect(std.mem.indexOf(u8, dump, "if") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "mul") != null);

    // A literal arm with a guard ANDs the tag comparison with the condition.
    var tr2 = TestResolver{ .a = testing.allocator };
    defer tr2.deinit();
    var m2 = (try buildFromSource(testing.allocator,
        "fn main {\n var n = 1\n var ready = true\n match n { 1 if ready -> env.out(\"a\"), _ -> env.out(\"b\") }\n}\n", tr2.resolver())) orelse
        return error.TestUnexpectedResult;
    defer m2.deinit();
    const d2 = try print.hirToString(testing.allocator, &m2);
    defer testing.allocator.free(d2);
    try testing.expect(std.mem.indexOf(u8, d2, "and_") != null);
}

test "match guards: a guarded arm never satisfies exhaustiveness on its own" {
    // `Yellow if hurry` does not cover Yellow (the guard may fail), so without
    // a plain Yellow (or `_`) arm the match is honestly unsupported.
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const res = try buildFromSource(testing.allocator,
        "enum Light { Red, Yellow, Green }\nfn main {\n var hurry = true\n var l = Light.Yellow\n match l {\n Yellow if hurry -> env.out(\"a\"),\n Red -> env.out(\"r\"),\n Green -> env.out(\"g\"),\n }\n}\n", tr.resolver());
    try testing.expect(res == null);
}

test "match range patterns: lo..hi lowers to a bounded value test (ge + lt/le)" {
    // `0..60` is exclusive (ge + lt); `60..=100` is inclusive (ge + le). Both
    // need an unguarded `_` fallback — a range never satisfies exhaustiveness.
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    var mod = (try buildFromSource(testing.allocator,
        "fn main {\n var n = 70\n let g = match n { 0..60 -> 0, 60..=100 -> 1, _ -> 9 }\n env.out(g)\n}\n", tr.resolver())) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // The bounded test is two comparisons joined by a logical and.
    try testing.expect(std.mem.indexOf(u8, dump, "and_") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "if") != null);
}

test "match range patterns: a range arm alone is not exhaustive" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const res = try buildFromSource(testing.allocator,
        "fn main {\n var n = 1\n let g = match n { 0..10 -> 0 }\n env.out(g)\n}\n", tr.resolver());
    try testing.expect(res == null);
}

test "match literal sub-patterns: Move(0, y) tests slot 0 and binds y" {
    // A literal sub-pattern adds a slot-equality condition (a logical and onto
    // the tag test); the conditional arm falls through to the binder arm.
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    var mod = (try buildFromSource(testing.allocator,
        "enum Msg { Move(i64, i64), Quit }\nfn main {\n var m = Msg.Move(0, 7)\n let r = match m { Move(0, y) -> y, Move(x, y) -> x + y, Quit -> 0 }\n env.out(r)\n}\n", tr.resolver())) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "and_") != null);

    // A conditional payload arm alone doesn't cover its variant: without the
    // unconditional Move(x, y) (or `_`) the match is non-exhaustive.
    var tr2 = TestResolver{ .a = testing.allocator };
    defer tr2.deinit();
    const res = try buildFromSource(testing.allocator,
        "enum Msg { Move(i64, i64), Quit }\nfn main {\n var m = Msg.Move(0, 7)\n let r = match m { Move(0, y) -> y, Quit -> 0 }\n env.out(r)\n}\n", tr2.resolver());
    try testing.expect(res == null);
}

test "Vec method chaining: xs.filter(...).map(...) materializes the inner stage" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    var mod = (try buildFromSource(testing.allocator,
        "fn main {\n var v = Vec.from([1, 2, 3, 4])\n let r = v.filter(|x| x > 1).map(|y| y * 2)\n env.out(r[0])\n}\n", tr.resolver())) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // Two stages → two fresh vecs (the inner filter into a temp, the outer map
    // into the binding), so more than one vec_new + both an `if` and a `mul`.
    try testing.expect(std.mem.indexOf(u8, dump, "vec_new") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "if") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "mul") != null);
}

test "Vec.filter: a predicate-filtered vec (vec_new + guarded push)" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    var mod = (try buildFromSource(testing.allocator,
        "fn main {\n var v = Vec.from([1, 2, 3, 4])\n let d = v.filter(|x| x > 2)\n env.out(d[0])\n}\n", tr.resolver())) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // The element is pushed under an `if` guarding the predicate.
    try testing.expect(std.mem.indexOf(u8, dump, "vec_new") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "vec_push") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "if") != null);
}

test "Vec.reduce: a closure fold to a scalar (accumulator + per-element update)" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    var mod = (try buildFromSource(testing.allocator,
        "fn main {\n var v = Vec.from([1, 2, 3, 4])\n let total = v.reduce(0, |acc, x| acc + x)\n env.out(total)\n}\n", tr.resolver())) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // A scalar accumulator updated by a loop reading the elements.
    try testing.expect(std.mem.indexOf(u8, dump, "vec_get") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "add") != null);
}

test "Vec parameter: a callee iterates a Vec passed by the caller" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    try tr.addLib("pub fn total(xs: Vec<i64>) -> i64 {\n var s = 0\n for x in xs { s = s + x }\n s\n}\n");
    var mod = (try buildFromSource(testing.allocator,
        "fn main {\n var v = Vec.from([1, 2, 3])\n env.out(total(v))\n}\n", tr.resolver())) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // The callee iterates the vec param (vec_get/vec_len in `total`).
    try testing.expect(std.mem.indexOf(u8, dump, "fn total") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "vec_get") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "vec_len") != null);
}

test "for-range in a callee body: `for i in 1..=n` counted loop" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    try tr.addLib("pub fn sum_to(n: i64) -> i64 {\n var s = 0\n for i in 1..=n { s = s + i }\n s\n}\n");
    var mod = (try buildFromSource(testing.allocator,
        "fn main {\n env.out(sum_to(5))\n}\n", tr.resolver())) orelse return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // The range `for` desugared to a `while` inside `sum_to`.
    try testing.expect(std.mem.indexOf(u8, dump, "fn sum_to") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "while") != null);
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

test "record destructuring: `let P { x, y } = p` binds fields (main + callee, rename + partial)" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src =
        \\struct P { x: i64, y: i64 }
        \\
        \\fn dist2(p: P) -> i64 {
        \\    let P { x, y } = p
        \\    x * x + y * y
        \\}
        \\
        \\fn main {
        \\    let p = P { x: 3, y: 4 }
        \\    let P { x, y } = p
        \\    env.out(x + y)
        \\    let P { x: a, y: b } = p
        \\    env.out(a * b)
        \\    env.out(dist2(p))
        \\}
        \\
    ;
    var mod = (try buildLocal(testing.allocator, &tr, src)) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // Each field is a field_get off the stashed base pointer.
    try testing.expect(std.mem.indexOf(u8, dump, "field_get") != null);

    // A field the struct doesn't have is an honest NameNotFound.
    var tr2 = TestResolver{ .a = testing.allocator };
    defer tr2.deinit();
    try testing.expect((try buildLocal(testing.allocator, &tr2,
        \\struct P { x: i64, y: i64 }
        \\fn main {
        \\    let p = P { x: 1, y: 2 }
        \\    let P { z } = p
        \\    env.out(z)
        \\}
        \\
    )) == null);
}

test "tuple destructuring: `let (a, b) = (e1, e2)` binds elements (main + callee)" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src =
        \\fn combine(n: i64) -> i64 {
        \\    let (lo, hi) = (n - 1, n + 1)
        \\    lo * hi
        \\}
        \\fn main {
        \\    let (a, b) = (3, 4)
        \\    env.out(a + b)
        \\    var m = 5
        \\    let (p, q) = (m * 2, m + 100)
        \\    env.out(p + q)
        \\    env.out(combine(6))
        \\}
        \\
    ;
    var mod = (try buildLocal(testing.allocator, &tr, src)) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();

    // Arity mismatch and a non-literal RHS (needs first-class tuples) reject.
    var tr2 = TestResolver{ .a = testing.allocator };
    defer tr2.deinit();
    try testing.expect((try buildLocal(testing.allocator, &tr2,
        \\fn main {
        \\    let (a, b) = (1, 2, 3)
        \\    env.out(a)
        \\}
        \\
    )) == null);
    // Destructuring a tuple *binding* (a first-class tuple value) builds.
    var tr3 = TestResolver{ .a = testing.allocator };
    defer tr3.deinit();
    var m3 = (try buildLocal(testing.allocator, &tr3,
        \\fn main {
        \\    let pair = (3, 4)
        \\    let (a, b) = pair
        \\    env.out(a + b)
        \\}
        \\
    )) orelse return error.TestUnexpectedResult;
    m3.deinit();
}

test "first-class tuples: literal binding, `.N` index, and destructure-from-binding" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src =
        \\fn main {
        \\    let t = (3, 4)
        \\    env.out(t.0 + t.1)
        \\    let (a, b) = t
        \\    env.out(a * b)
        \\    var m = 5
        \\    let pair = (m * 2, m + 1)
        \\    env.out(pair.0 + pair.1)
        \\}
        \\
    ;
    var mod = (try buildLocal(testing.allocator, &tr, src)) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // A tuple materializes like a 2-cell record; `.N` is a field_get.
    try testing.expect(std.mem.indexOf(u8, dump, "record_alloc size=16 align=8") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "field_get") != null);

    // An out-of-range index is honestly unsupported.
    var tr2 = TestResolver{ .a = testing.allocator };
    defer tr2.deinit();
    try testing.expect((try buildLocal(testing.allocator, &tr2,
        \\fn main {
        \\    let t = (3, 4)
        \\    env.out(t.2)
        \\}
        \\
    )) == null);
}

test "graph v0: a named pipeline runs eagerly; terminal stage is the output" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    var mod = (try buildLocal(testing.allocator, &tr,
        \\fn src(seed: i64) -> i64 { seed }
        \\fn dbl(n: i64) -> i64 { n * 2 }
        \\graph pipeline(seed: i64) -> i64 {
        \\    let a = src(seed)
        \\    let b = a |> dbl
        \\}
        \\fn main {
        \\    env.out(pipeline(20))
        \\}
        \\
    )) orelse return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // The graph lowers to a function returning its terminal binding.
    try testing.expect(std.mem.indexOf(u8, dump, "fn pipeline -> i64") != null);
}

test "actors v0: handlers lower to self-taking functions; tell/ask dispatch" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    var mod = (try buildLocal(testing.allocator, &tr,
        \\actor Counter {
        \\    state n: i64 = 0
        \\    handle bump() { n = n + 1 }
        \\    handle get() -> i64 { n }
        \\}
        \\fn main {
        \\    var c = Counter {}
        \\    c.bump()
        \\    env.out(c.get())
        \\}
        \\
    )) orelse return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // bump is a void handler (field_set on self); get returns i64.
    try testing.expect(std.mem.indexOf(u8, dump, "fn Counter.bump -> void") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "fn Counter.get -> i64") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "field_set") != null);

    // An actor passed to a callee mutates the shared state (tell in a callee).
    var tr2 = TestResolver{ .a = testing.allocator };
    defer tr2.deinit();
    var m2 = (try buildLocal(testing.allocator, &tr2,
        \\actor C { state n: i64 = 0
        \\    handle bump() { n = n + 1 }
        \\    handle get() -> i64 { n }
        \\}
        \\fn work(c: C) { c.bump() }
        \\fn main {
        \\    var c = C {}
        \\    work(c)
        \\    env.out(c.get())
        \\}
        \\
    )) orelse return error.TestUnexpectedResult;
    m2.deinit();
}

test "pipe operator: x |> f(args) lowers to f(x, args), chains left-assoc" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    var mod = (try buildLocal(testing.allocator, &tr,
        \\fn dbl(n: i64) -> i64 { n * 2 }
        \\fn add(a: i64, b: i64) -> i64 { a + b }
        \\fn main {
        \\    env.out(3 |> dbl |> add(100))
        \\}
        \\
    )) orelse return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // Both stages become ordinary calls; the piped value is the first arg.
    try testing.expect(std.mem.indexOf(u8, dump, "call") != null);

    // A pipe into a non-function rejects honestly.
    var tr2 = TestResolver{ .a = testing.allocator };
    defer tr2.deinit();
    try testing.expect((try buildLocal(testing.allocator, &tr2,
        \\fn main {
        \\    let x = 5
        \\    env.out(3 |> x)
        \\}
        \\
    )) == null);
}

test "select v0: first-ready arm over channel recv lowers to an if/else chain" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    var mod = (try buildLocal(testing.allocator, &tr,
        \\fn main {
        \\    scope {
        \\        let a = channel(capacity: 4)
        \\        let b = channel(capacity: 4)
        \\        spawn { b.send(99) }
        \\        select {
        \\            v = a.recv() -> env.out(v),
        \\            w = b.recv() -> env.out(w + 1),
        \\        }
        \\    }
        \\}
        \\
    )) orelse return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // Each arm's readiness is a `vec_len` test; the choice is an if-chain.
    try testing.expect(std.mem.indexOf(u8, dump, "vec_len") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "if") != null);
}

test "select v0: a send arm is always-ready (vec_push) and races with recv arms" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    // `a` is empty so its recv arm is not ready; the send arm is always ready
    // (unbounded channel), so the lowering has both a `vec_len` readiness test
    // (the recv arm) and a `vec_push` (the send arm's op).
    var mod = (try buildLocal(testing.allocator, &tr,
        \\fn main {
        \\    scope {
        \\        let a = channel()
        \\        let b = channel()
        \\        select {
        \\            v = a.recv() -> env.out(v),
        \\            b.send(42) -> env.out(99),
        \\        }
        \\    }
        \\}
        \\
    )) orelse return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "vec_len") != null); // recv arm readiness
    try testing.expect(std.mem.indexOf(u8, dump, "vec_push") != null); // send arm op
    try testing.expect(std.mem.indexOf(u8, dump, "if") != null);
}

test "channels v0: channel() + send/recv lower to a Vec buffer + read cursor" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    var mod = (try buildLocal(testing.allocator, &tr,
        \\fn main {
        \\    scope {
        \\        let ch = channel(capacity: 8)
        \\        ch.send(10)
        \\        ch.send(20)
        \\        spawn {
        \\            let a = ch.recv()
        \\            let b = ch.recv()
        \\            env.out(a + b)
        \\        }
        \\    }
        \\}
        \\
    )) orelse return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // send is a vec_push; recv is a vec_get off the cursor.
    try testing.expect(std.mem.indexOf(u8, dump, "vec_push") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "vec_get") != null);
}

test "scope scheduling: a consumer spawned before its producer is deferred to the join" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    // The consumer task `recv`s before any `send` has been emitted, so on the
    // cooperative floor it would trap on an empty buffer. It is deferred to the
    // scope join; the producer (spawned later) is emitted first and fills the
    // channel. So in the lowered body the producer's `vec_push` precedes the
    // consumer's `vec_get`, despite the reverse source order.
    var mod = (try buildLocal(testing.allocator, &tr,
        \\fn main {
        \\    scope {
        \\        let ch = channel()
        \\        spawn {
        \\            let a = ch.recv()
        \\            let b = ch.recv()
        \\            env.out(a + b)
        \\        }
        \\        spawn {
        \\            ch.send(10)
        \\            ch.send(20)
        \\        }
        \\    }
        \\}
        \\
    )) orelse return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    const push_at = std.mem.indexOf(u8, dump, "vec_push") orelse return error.TestUnexpectedResult;
    const get_at = std.mem.indexOf(u8, dump, "vec_get") orelse return error.TestUnexpectedResult;
    // Producer emitted before consumer: the buffer is filled before it is read.
    try testing.expect(push_at < get_at);

    // Control: a producer spawned *before* its consumer is untouched — the
    // consumer's channel already has data, so it runs eager-at-spawn (no
    // deferral), preserving source order. Still producer-then-consumer.
    var tr2 = TestResolver{ .a = testing.allocator };
    defer tr2.deinit();
    var m2 = (try buildLocal(testing.allocator, &tr2,
        \\fn main {
        \\    scope {
        \\        let ch = channel()
        \\        spawn {
        \\            ch.send(10)
        \\            ch.send(20)
        \\        }
        \\        spawn {
        \\            let a = ch.recv()
        \\            let b = ch.recv()
        \\            env.out(a + b)
        \\        }
        \\    }
        \\}
        \\
    )) orelse return error.TestUnexpectedResult;
    defer m2.deinit();
    const dump2 = try print.hirToString(testing.allocator, &m2);
    defer testing.allocator.free(dump2);
    const push2 = std.mem.indexOf(u8, dump2, "vec_push") orelse return error.TestUnexpectedResult;
    const get2 = std.mem.indexOf(u8, dump2, "vec_get") orelse return error.TestUnexpectedResult;
    try testing.expect(push2 < get2);
}

test "scope scheduling: cyclic ping-pong tasks lower to a round-robin scheduler loop" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    // P sends `a` then recvs `b`; Q recvs `a` then sends `b` — a mutual wait no
    // static order can serve. It lowers to a `while` loop (the scheduler) whose
    // body has pc-gated segments and a `vec_len` recv-readiness test.
    var mod = (try buildLocal(testing.allocator, &tr,
        \\fn main {
        \\    scope {
        \\        let a = channel()
        \\        let b = channel()
        \\        spawn {
        \\            a.send(1)
        \\            let r = b.recv()
        \\            env.out(r)
        \\        }
        \\        spawn {
        \\            let x = a.recv()
        \\            b.send(x + 10)
        \\        }
        \\    }
        \\}
        \\
    )) orelse return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // The scheduler is a while loop; recv suspend points test `vec_len`; both
    // tasks' ops appear (the producer push, the recv get).
    try testing.expect(std.mem.indexOf(u8, dump, "while") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "vec_len") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "vec_push") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "vec_get") != null);

    // Control: an acyclic producer/consumer pair (no task both sends and recvs)
    // stays on the static deferral path — no scheduler loop.
    var tr2 = TestResolver{ .a = testing.allocator };
    defer tr2.deinit();
    var m2 = (try buildLocal(testing.allocator, &tr2,
        \\fn main {
        \\    scope {
        \\        let ch = channel()
        \\        spawn {
        \\            let p = ch.recv()
        \\            env.out(p)
        \\        }
        \\        spawn {
        \\            ch.send(5)
        \\        }
        \\    }
        \\}
        \\
    )) orelse return error.TestUnexpectedResult;
    defer m2.deinit();
    const dump2 = try print.hirToString(testing.allocator, &m2);
    defer testing.allocator.free(dump2);
    try testing.expect(std.mem.indexOf(u8, dump2, "while") == null); // static, not scheduled
}

test "scope scheduling: a recv inside a for-loop is a suspend point (request/reply)" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    // Client loops { send req; recv resp; emit }, server loops { recv req; send
    // resp } — the recv inside each loop is a real suspend point, so the loop
    // lowers to a branch head + a back-edge (`i += 1` then re-test) around the
    // recv gate, all inside the one scheduler `while`.
    var mod = (try buildLocal(testing.allocator, &tr,
        \\fn main {
        \\    scope {
        \\        let req = channel()
        \\        let resp = channel()
        \\        spawn {
        \\            for i in 1..=3 {
        \\                req.send(i)
        \\                let r = resp.recv()
        \\                env.out(r)
        \\            }
        \\        }
        \\        spawn {
        \\            for j in 1..=3 {
        \\                let x = req.recv()
        \\                resp.send(x * 10)
        \\            }
        \\        }
        \\    }
        \\}
        \\
    )) orelse return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // The scheduler while, the loop counters (`le` head test = inclusive range),
    // the recv readiness (`vec_len`), and both channel ops are present.
    try testing.expect(std.mem.indexOf(u8, dump, "while") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "le") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "vec_len") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "vec_push") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "vec_get") != null);
}

test "scope scheduling: while loops and if/else are schedulable control flow" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    // A `recv` inside a `while` (the consumer) routes the scope to the scheduler
    // even though it isn't a mutual cycle (the static path can't lower a recv
    // inside control flow). The producer's `while` is a recv-free loop.
    var mod = (try buildLocal(testing.allocator, &tr,
        \\fn main {
        \\    scope {
        \\        let ch = channel()
        \\        spawn {
        \\            var n = 1
        \\            while n <= 3 {
        \\                ch.send(n)
        \\                n = n + 1
        \\            }
        \\        }
        \\        spawn {
        \\            var got = 0
        \\            while got < 3 {
        \\                let x = ch.recv()
        \\                env.out(x)
        \\                got = got + 1
        \\            }
        \\        }
        \\    }
        \\}
        \\
    )) orelse return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "while") != null); // the scheduler loop
    try testing.expect(std.mem.indexOf(u8, dump, "vec_get") != null); // the recv-in-while

    // An `if`/`else` inside a task body is schedulable (a branch into then/else
    // that rejoins) — here choosing which value the server replies with.
    var tr2 = TestResolver{ .a = testing.allocator };
    defer tr2.deinit();
    var m2 = (try buildLocal(testing.allocator, &tr2,
        \\fn main {
        \\    scope {
        \\        let req = channel()
        \\        let resp = channel()
        \\        spawn {
        \\            req.send(2)
        \\            let r = resp.recv()
        \\            env.out(r)
        \\        }
        \\        spawn {
        \\            let x = req.recv()
        \\            if x % 2 == 0 {
        \\                resp.send(x * 100)
        \\            } else {
        \\                resp.send(x)
        \\            }
        \\        }
        \\    }
        \\}
        \\
    )) orelse return error.TestUnexpectedResult;
    defer m2.deinit();
    const dump2 = try print.hirToString(testing.allocator, &m2);
    defer testing.allocator.free(dump2);
    try testing.expect(std.mem.indexOf(u8, dump2, "while") != null); // scheduler loop
    try testing.expect(std.mem.indexOf(u8, dump2, "rem") != null); // the `x % 2` branch test
}

test "scope scheduling: a select inside a task parks until an arm is ready" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    // The consumer loops a `select` over two channels; it routes to the
    // scheduler (a select is a parking suspend point) and the select block is
    // gated on `any_ready` (the OR of the arms' readiness) so it parks when
    // neither channel has data.
    var mod = (try buildLocal(testing.allocator, &tr,
        \\fn main {
        \\    scope {
        \\        let a = channel()
        \\        let b = channel()
        \\        spawn { a.send(1) }
        \\        spawn { b.send(2) }
        \\        spawn {
        \\            var got = 0
        \\            while got < 2 {
        \\                select {
        \\                    v = a.recv() -> env.out(v)
        \\                    w = b.recv() -> env.out(w)
        \\                }
        \\                got = got + 1
        \\            }
        \\        }
        \\    }
        \\}
        \\
    )) orelse return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "while") != null); // the scheduler loop
    // The park predicate ORs the arms' readiness (`vec_len` tests joined by or_).
    try testing.expect(std.mem.indexOf(u8, dump, "or_") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "vec_len") != null);
}

test "scope scheduling: a send on a bounded channel parks on a full buffer" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    // A bounded `channel(capacity: 1)`: the producer's `send` is a suspend point
    // gated on the buffer having room (`vec_len - cursor < capacity`), so a
    // straight-line producer/consumer pair routes to the scheduler — even though
    // neither task both sends and recvs — and the producer parks when the buffer
    // is full. The room test prints as `(vec_len(buf) sub cursor) lt 1`.
    var mod = (try buildLocal(testing.allocator, &tr,
        \\fn main {
        \\    scope {
        \\        let ch = channel(capacity: 1)
        \\        spawn {
        \\            ch.send(1)
        \\            ch.send(2)
        \\        }
        \\        spawn {
        \\            let a = ch.recv()
        \\            let b = ch.recv()
        \\        }
        \\    }
        \\}
        \\
    )) orelse return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "while") != null); // the scheduler loop
    try testing.expect(std.mem.indexOf(u8, dump, "sub") != null); // the room (unread-count) test
    try testing.expect(std.mem.indexOf(u8, dump, "vec_push") != null); // the gated send op

    // Control: the *unbounded* `channel()` variant of the same shape has no
    // backpressure — the producer (send-only) and consumer (top-level recvs)
    // stay on the static eager/deferred path, no scheduler loop.
    var tr2 = TestResolver{ .a = testing.allocator };
    defer tr2.deinit();
    var m2 = (try buildLocal(testing.allocator, &tr2,
        \\fn main {
        \\    scope {
        \\        let ch = channel()
        \\        spawn {
        \\            ch.send(1)
        \\            ch.send(2)
        \\        }
        \\        spawn {
        \\            let a = ch.recv()
        \\            let b = ch.recv()
        \\        }
        \\    }
        \\}
        \\
    )) orelse return error.TestUnexpectedResult;
    defer m2.deinit();
    const dump2 = try print.hirToString(testing.allocator, &m2);
    defer testing.allocator.free(dump2);
    try testing.expect(std.mem.indexOf(u8, dump2, "while") == null); // static, not scheduled
}

test "scope scheduling: the round-robin scheduler runs inside a callee body" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    // A cyclic ping-pong inside a *function* body (not `main`) must route to the
    // scheduler too. `buildScopeScheduled` is builder-agnostic (it dispatches on
    // `scope.callee`), so the scheduler `while` loop appears in the callee.
    var mod = (try buildLocal(testing.allocator, &tr,
        \\fn run() {
        \\    scope {
        \\        let a = channel()
        \\        let b = channel()
        \\        spawn {
        \\            a.send(1)
        \\            let r = b.recv()
        \\            env.out(r)
        \\        }
        \\        spawn {
        \\            let x = a.recv()
        \\            b.send(x + 10)
        \\        }
        \\    }
        \\}
        \\fn main { run() }
        \\
    )) orelse return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "while") != null); // the scheduler loop, in the callee
    try testing.expect(std.mem.indexOf(u8, dump, "vec_len") != null); // recv-readiness suspend test
}

test "scope scheduling: a tell/ask on an actor is a step inside a scheduled task" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    // The consumer recvs from a channel (a suspend point → the scope routes to
    // the scheduler) AND asks an actor. The synchronous handler call must be
    // accepted as a cooperative step — without it the ask makes the task
    // unschedulable and the cyclic scope traps. The actor's `call` appears
    // inside the scheduler `while`.
    var mod = (try buildLocal(testing.allocator, &tr,
        \\actor Adder {
        \\    state total: i64 = 0
        \\    handle add(k: i64) -> i64 { total = total + k; total }
        \\}
        \\fn main {
        \\    scope {
        \\        let feed = channel()
        \\        let done = channel()
        \\        let acc = Adder {}
        \\        spawn {
        \\            feed.send(10)
        \\            let _a = done.recv()
        \\        }
        \\        spawn {
        \\            let x = feed.recv()
        \\            let r = acc.add(x)
        \\            env.out(r)
        \\            done.send(1)
        \\        }
        \\    }
        \\}
        \\
    )) orelse return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "while") != null); // the scheduler loop
    try testing.expect(std.mem.indexOf(u8, dump, "call") != null); // the synchronous handler call (the ask)
}

test "scope scheduling: a discard recv (let _ = / bare recv) is a suspend point" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    // `let _ = b.recv()` consumes a slot without binding — it must still be a
    // detected suspend point (gated on `vec_len`) so a cyclic task that waits on
    // a reply it doesn't name schedules instead of trapping. The lowering bumps
    // the cursor with no `vec_get` (the value is discarded).
    var mod = (try buildLocal(testing.allocator, &tr,
        \\fn main {
        \\    scope {
        \\        let a = channel()
        \\        let b = channel()
        \\        spawn {
        \\            a.send(1)
        \\            let _ = b.recv()
        \\            env.out(42)
        \\        }
        \\        spawn {
        \\            let x = a.recv()
        \\            b.send(x + 10)
        \\        }
        \\    }
        \\}
        \\
    )) orelse return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "while") != null); // routed to the scheduler
    try testing.expect(std.mem.indexOf(u8, dump, "vec_len") != null); // the discard recv's readiness gate
}

test "structured concurrency v0: let h = spawn { e } + h.await() (eager handle)" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    var mod = (try buildLocal(testing.allocator, &tr,
        \\fn compute(n: i64) -> i64 { n * n }
        \\fn main {
        \\    let h1 = spawn { compute(6) }
        \\    let h2 = spawn { compute(7) }
        \\    env.out(h1.await() + h2.await())
        \\}
        \\
    )) orelse return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // The handle is the task's eager result (a `compute` call bound to a
    // local); `h.await()` reads the local — no separate task funcref.
    try testing.expect(std.mem.indexOf(u8, dump, "call") != null);

    // A multi-statement task body is lowered as a value block (leading
    // statements for effect, the tail expression the handle's value).
    var tr2 = TestResolver{ .a = testing.allocator };
    defer tr2.deinit();
    var m2 = (try buildLocal(testing.allocator, &tr2,
        \\fn main {
        \\    let h = spawn { let x = 1
        \\        x + 2 }
        \\    env.out(h.await())
        \\}
        \\
    )) orelse return error.TestUnexpectedResult;
    m2.deinit();
}

test "structured concurrency v0: scope runs spawn bodies eager-at-spawn" {
    // The cooperative floor: each task runs to completion at its spawn point
    // (a valid no-preemption schedule) — tasks see the scope's locals.
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    var mod = (try buildLocal(testing.allocator, &tr,
        \\fn main {
        \\    scope {
        \\        let base = 100
        \\        spawn { env.out(base + 1) }
        \\        env.out("parent")
        \\        spawn { env.out(base + 2) }
        \\    }
        \\}
        \\
    )) orelse return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // Both spawned task bodies are lowered (`base` const-folds, so the bodies
    // print 101 and 102); the runtime *ordering* (parent before tasks) is
    // checked end-to-end by link-roundtrip.
    try testing.expect(std.mem.indexOf(u8, dump, "101") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "102") != null);

    // `catch` arms need the EH runtime — honestly unsupported on the v0 floor.
    var tr2 = TestResolver{ .a = testing.allocator };
    defer tr2.deinit();
    try testing.expect((try buildLocal(testing.allocator, &tr2,
        \\fn main {
        \\    scope {
        \\        spawn { work() }
        \\    } catch (e: Panic) {
        \\        env.out("caught")
        \\    }
        \\}
        \\
    )) == null);
}

test "f64/bool fields + tuple slots: record destructure, tuple elements, params/returns" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src =
        \\struct V { x: f64, y: f64 }
        \\fn scale(p: (f64, f64), k: f64) -> (f64, f64) {
        \\    (p.0 * k, p.1 * k)
        \\}
        \\fn main {
        \\    let v = V { x: 1.5, y: 2.5 }
        \\    let V { x, y } = v
        \\    env.out(x + y)
        \\    let mixed = (true, 3.5)
        \\    env.out(mixed.0)
        \\    env.out(mixed.1)
        \\    let (q, r) = scale((1.5, 2.0), 3.0)
        \\    env.out(q + r)
        \\}
        \\
    ;
    var mod = (try buildLocal(testing.allocator, &tr, src)) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // The tuple slot is typed: `mixed.1` (f64) goes to the float host path,
    // distinct from `mixed.0` (the bool/int path).
    try testing.expect(std.mem.indexOf(u8, dump, "host_out_float") != null);
    // `scale` takes a tuple param and returns a tuple — both `.ptr` records.
    try testing.expect(std.mem.indexOf(u8, dump, "fn scale -> ptr") != null);
}

test "tuple params + returns: -> (i64, i64), p.N, let (q, r) = call, tuple args" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src =
        \\fn divmod(a: i64, b: i64) -> (i64, i64) {
        \\    (a / b, a % b)
        \\}
        \\fn sum2(p: (i64, i64)) -> i64 {
        \\    p.0 + p.1
        \\}
        \\fn main {
        \\    let (q, r) = divmod(17, 5)
        \\    env.out(q + r)
        \\    let t = (8, 9)
        \\    env.out(sum2(t))
        \\    env.out(sum2((100, 23)))
        \\}
        \\
    ;
    var mod = (try buildLocal(testing.allocator, &tr, src)) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // The tuple type interns to one layout, so divmod returns a 16-byte record
    // and sum2 takes a `.ptr` — a tuple binding and a tuple literal both pass.
    try testing.expect(std.mem.indexOf(u8, dump, "fn divmod -> ptr") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "fn sum2 -> i64") != null);
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

test "B5: bare `T` params + `-> T` returns (records by ptr, scalars by value)" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src =
        \\face D { fn fmt(self) -> str }
        \\struct Color { r: i64 }
        \\fit Color : D { fn fmt(self) -> str { "c{self.r}" } }
        \\fn show<T: D>(x: T) {
        \\    env.out(x.fmt())
        \\}
        \\fn twice<T>(x: T) -> T {
        \\    x + x
        \\}
        \\fn first<T>(items: [T]) -> T {
        \\    items[0]
        \\}
        \\fn main {
        \\    show(Color { r: 7 })
        \\    env.out(twice(21))
        \\    env.out(twice(1.5))
        \\    env.out(first([10, 20]))
        \\}
        \\
    ;
    var mod = (try buildLocal(testing.allocator, &tr, src)) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // A bare record T is a `.ptr` param; `-> T` follows the slot's scalar.
    try testing.expect(std.mem.indexOf(u8, dump, "fn show<Color> -> void") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "fn twice<i64> -> i64") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "fn twice<f64> -> f64") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "fn first<i64> -> i64") != null);
}

test "B5: method dispatch directly on a generic call expression" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src =
        \\face Display { fn fmt(self) -> str }
        \\face Sized { fn area(self) -> i64 }
        \\struct Color { r: i64, g: i64 }
        \\fit Color : Display { fn fmt(self) -> str { "rgb({self.r}, {self.g})" } }
        \\fit Color : Sized { fn area(self) -> i64 { self.r * self.g } }
        \\fn first<T>(items: [T]) -> T {
        \\    items[0]
        \\}
        \\fn idr<T>(x: T) -> T {
        \\    x
        \\}
        \\fn main {
        \\    env.out(first([Color { r: 9, g: 8 }]).fmt())
        \\    env.out(first([Color { r: 9, g: 8 }]).area())
        \\    env.out(idr(Color { r: 2, g: 3 }).fmt())
        \\    let cs = [Color { r: 4, g: 5 }]
        \\    env.out(first(cs).area())
        \\}
        \\
    ;
    var mod = (try buildLocal(testing.allocator, &tr, src)) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // The routing predicate (recvStruct → genericRetStruct) sees the
    // struct WITHOUT building, so both the str (host_out_str) and i64
    // (host_out_int) method paths dispatch on the call expression.
    try testing.expect(std.mem.indexOf(u8, dump, "fn first<Color> -> ptr") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "fn idr<Color> -> ptr") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "fn Color.fmt -> str") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "fn Color.area -> i64") != null);
}

test "B5: record `-> T` returns bind and dispatch (first<Color> -> ptr)" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src =
        \\face D { fn fmt(self) -> str }
        \\struct Color { r: i64 }
        \\fit Color : D { fn fmt(self) -> str { "c{self.r}" } }
        \\fn first<T>(items: [T]) -> T {
        \\    items[0]
        \\}
        \\fn idr<T>(x: T) -> T {
        \\    x
        \\}
        \\fn main {
        \\    let c = first([Color { r: 9 }, Color { r: 1 }])
        \\    env.out(c.fmt())
        \\    env.out(c.r)
        \\    let d = idr(c)
        \\    env.out(d.r)
        \\}
        \\
    ;
    var mod = (try buildLocal(testing.allocator, &tr, src)) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // The instance returns the record's base pointer; fn_recs carries
    // which struct, so the binding dispatches and reads fields.
    try testing.expect(std.mem.indexOf(u8, dump, "fn first<Color> -> ptr") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "fn idr<Color> -> ptr") != null);
}

test "B5: printing a whole record value stays unsupported" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src =
        \\struct P { v: i64 }
        \\fn first<T>(items: [T]) -> T {
        \\    items[0]
        \\}
        \\fn main {
        \\    env.out(first([P { v: 1 }]))
        \\}
        \\
    ;
    try testing.expect((try buildLocal(testing.allocator, &tr, src)) == null);
}

test "B5: a scalar to a bounded bare `T` is rejected (no scalar fits)" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src =
        \\face D { fn fmt(self) -> str }
        \\fn show<T: D>(x: T) {
        \\    env.out(x.fmt())
        \\}
        \\fn main {
        \\    show(42)
        \\}
        \\
    ;
    try tr.addLib(src);
    const r = try rejectFromSource(testing.allocator, src, tr.resolver());
    try testing.expectEqual(hir.Reject.unsupported_call, r.?);
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

test "C1: match on an all-unit enum — tags, wildcard, exhaustive chain" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src =
        \\enum Light { Red, Yellow, Green }
        \\fn main {
        \\    var l = Light.Yellow
        \\    match l {
        \\        Red -> env.out("stop"),
        \\        Yellow -> env.out("slow"),
        \\        Green -> env.out("go"),
        \\    }
        \\    l = Light.Green
        \\    match l {
        \\        Red -> env.out("stop"),
        \\        _ -> {
        \\            env.out("moving")
        \\        },
        \\    }
        \\}
        \\
    ;
    var mod = (try buildLocal(testing.allocator, &tr, src)) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // `Light.Yellow` is its declaration-order tag; arms compare the
    // hidden scrutinee local against each tag.
    try testing.expect(std.mem.indexOf(u8, dump, "let local#0 = 1") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "eq 0)") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "eq 2)") != null);
}

test "C1: a non-exhaustive match (no wildcard) is honestly unsupported" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src =
        \\enum L { A, B, C }
        \\fn main {
        \\    match L.A {
        \\        A -> env.out("a"),
        \\        B -> env.out("b"),
        \\    }
        \\}
        \\
    ;
    try testing.expect((try buildLocal(testing.allocator, &tr, src)) == null);
}

test "C1: an arm naming a non-variant rejects NameNotFound" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src =
        \\enum L { A, B }
        \\fn main {
        \\    match L.A {
        \\        Nope -> env.out("x"),
        \\        _ -> env.out("y"),
        \\    }
        \\}
        \\
    ;
    try tr.addLib(src);
    const r = try rejectFromSource(testing.allocator, src, tr.resolver());
    try testing.expectEqual(hir.Reject.name_not_found, r.?);
}

test "C2: value match — let and assign positions, i64 and f64 yields" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src =
        \\enum Light { Red, Yellow, Green }
        \\fn main {
        \\    var l = Light.Yellow
        \\    let secs = match l {
        \\        Red -> 30,
        \\        Yellow -> 5,
        \\        Green -> 45,
        \\    }
        \\    env.out("wait {secs}s")
        \\    let rate = match l {
        \\        Red -> 0.0,
        \\        _ -> 1.5,
        \\    }
        \\    env.out(rate)
        \\    var n = 0
        \\    n = match l {
        \\        Red -> 1,
        \\        _ -> 2,
        \\    }
        \\    env.out(n)
        \\}
        \\
    ;
    var mod = (try buildLocal(testing.allocator, &tr, src)) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // The desugar assigns the result local in every arm and the
    // binding reads it; the f64 match keeps its float type.
    try testing.expect(std.mem.indexOf(u8, dump, "host_out_float") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "host_out_str") != null);
}

test "C2: mixed arm types and non-exhaustive value match are unsupported" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    // i64 vs f64 arms never mix.
    try testing.expect((try buildLocal(testing.allocator, &tr,
        \\enum L { A, B }
        \\fn main {
        \\    let x = match L.A {
        \\        A -> 1,
        \\        B -> 2.5,
        \\    }
        \\    env.out(x)
        \\}
        \\
    )) == null);
    var tr2 = TestResolver{ .a = testing.allocator };
    defer tr2.deinit();
    // A value match must cover every variant or have a `_`.
    try testing.expect((try buildLocal(testing.allocator, &tr2,
        \\enum L { A, B, C }
        \\fn main {
        \\    let x = match L.A {
        \\        A -> 1,
        \\        B -> 2,
        \\    }
        \\    env.out(x)
        \\}
        \\
    )) == null);
}

test "C3: payload variants — construction, bindings, value match, boxed unit" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src =
        \\enum Shape { Empty, Circle(i64), Rect(i64, i64) }
        \\fn main {
        \\    let s = Shape.Circle(7)
        \\    match s {
        \\        Empty -> env.out("none"),
        \\        Circle(r) -> env.out(r * 2),
        \\        Rect(w, h) -> env.out(w + h),
        \\    }
        \\    let area = match Shape.Rect(3, 4) {
        \\        Empty -> 0,
        \\        Circle(r) -> r * r,
        \\        Rect(w, _) -> w * 10,
        \\    }
        \\    env.out(area)
        \\    let e = Shape.Empty
        \\    match e {
        \\        Empty -> env.out("empty"),
        \\        _ -> env.out("not"),
        \\    }
        \\}
        \\
    ;
    var mod = (try buildLocal(testing.allocator, &tr, src)) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // The boxed value is an arena record {tag, p0, p1}: size 24 for
    // Shape (max arity 2); payload bindings load slots 8/16.
    try testing.expect(std.mem.indexOf(u8, dump, "record_alloc size=24 align=8") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "field_get") != null);
}

test "C3: payload arity and sub-pattern mismatches reject honestly" {
    // Too few construction args.
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src1 =
        \\enum S { A(i64, i64) }
        \\fn main {
        \\    let s = S.A(1)
        \\    match s { A(x, y) -> env.out(x + y) }
        \\}
        \\
    ;
    try tr.addLib(src1);
    const r = try rejectFromSource(testing.allocator, src1, tr.resolver());
    try testing.expectEqual(hir.Reject.unsupported_call, r.?);
    // A payload variant matched bare (no sub-patterns) is unsupported.
    var tr2 = TestResolver{ .a = testing.allocator };
    defer tr2.deinit();
    try testing.expect((try buildLocal(testing.allocator, &tr2,
        \\enum S { A(i64), B }
        \\fn main {
        \\    match S.A(1) {
        \\        A -> env.out("a"),
        \\        B -> env.out("b"),
        \\    }
        \\}
        \\
    )) == null);
}

test "C4: literal patterns on an integer scrutinee (statement + value)" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    var mod = (try buildLocal(testing.allocator, &tr,
        \\fn main {
        \\    var n = 1
        \\    match n {
        \\        0 -> env.out("zero"),
        \\        1 -> env.out("one"),
        \\        _ -> env.out("many"),
        \\    }
        \\    let label = match n + 41 {
        \\        42 -> 200,
        \\        _ -> 300,
        \\    }
        \\    env.out(label)
        \\}
        \\
    )) orelse return error.TestUnexpectedResult;
    defer mod.deinit();
    // A literal match without `_` is honestly unsupported.
    var tr2 = TestResolver{ .a = testing.allocator };
    defer tr2.deinit();
    try testing.expect((try buildLocal(testing.allocator, &tr2,
        \\fn main {
        \\    var n = 1
        \\    match n {
        \\        0 -> env.out("zero"),
        \\        1 -> env.out("one"),
        \\    }
        \\}
        \\
    )) == null);
}

test "prelude Option/Result: bare + qualified constructors, match, None literal" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src =
        \\fn main {
        \\    let o = Some(40)
        \\    let n = match o {
        \\        Some(v) -> v + 2,
        \\        None -> 0,
        \\    }
        \\    env.out(n)
        \\    let e = None
        \\    match e {
        \\        Some(v) -> env.out(v),
        \\        None -> env.out("none"),
        \\    }
        \\    match Result.Ok(7) {
        \\        Ok(v) -> env.out(v),
        \\        Err(c) -> env.out(c),
        \\    }
        \\    let r = Err(3)
        \\    let code = match r {
        \\        Ok(_) -> 0,
        \\        Err(c) -> c * 100,
        \\    }
        \\    env.out(code)
        \\}
        \\
    ;
    var mod = (try buildLocal(testing.allocator, &tr, src)) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // Option/Result box to {tag, p0}: size 16, align 8.
    try testing.expect(std.mem.indexOf(u8, dump, "record_alloc size=16 align=8") != null);
}

test "prelude Option: non-exhaustive match is honestly unsupported" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    try testing.expect((try buildLocal(testing.allocator, &tr,
        \\fn main {
        \\    let o = Some(5)
        \\    match o {
        \\        Some(v) -> env.out(v),
        \\    }
        \\}
        \\
    )) == null);
}

test "generic enum: a type-param payload slot registers at the i64 floor" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src =
        \\enum BoxE<T> { Full(T, T), Empty }
        \\fn main {
        \\    let bx = BoxE.Full(4, 5)
        \\    match bx {
        \\        Full(x, y) -> env.out(x + y),
        \\        Empty -> env.out(0),
        \\    }
        \\}
        \\
    ;
    var mod = (try buildLocal(testing.allocator, &tr, src)) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // Two T slots box to {tag, p0, p1}: size 24.
    try testing.expect(std.mem.indexOf(u8, dump, "record_alloc size=24 align=8") != null);
}

test "prelude shadowing: a file `enum Option` wins; missing variants drop the bare form" {
    // The file's Option declares Some/None and works through the same
    // machinery (the pre-existing parser hang on a `None` variant is
    // the regression here).
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    var mod = (try buildLocal(testing.allocator, &tr,
        \\enum Option { Some(i64), None }
        \\fn main {
        \\    let o = Option.Some(40)
        \\    match o {
        \\        Some(v) -> env.out(v + 2),
        \\        None -> env.out(0),
        \\    }
        \\}
        \\
    )) orelse return error.TestUnexpectedResult;
    defer mod.deinit();
    // A shadowing Option *without* a Some variant drops bare `Some` —
    // the call resolves as an unknown function (NameNotFound).
    const src2 =
        \\enum Option { Just(i64), None }
        \\fn main {
        \\    let o = Some(5)
        \\    env.out(1)
        \\}
        \\
    ;
    var tr2 = TestResolver{ .a = testing.allocator };
    defer tr2.deinit();
    try tr2.addLib(src2);
    const r = try rejectFromSource(testing.allocator, src2, tr2.resolver());
    try testing.expectEqual(hir.Reject.name_not_found, r.?);
}

test "enum returns: -> Option / -> Result / -> Shape with value-if bodies" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src =
        \\enum Shape { Empty, Circle(i64) }
        \\fn find(n: i64) -> Option<i64> {
        \\    if n > 0 { Some(n) } else { None }
        \\}
        \\fn classify(n: i64) -> Result<i64, i64> {
        \\    if n >= 10 { Ok(n) } else if n >= 0 { Ok(n * 10) } else { Err(1) }
        \\}
        \\fn pick(n: i64) -> Shape {
        \\    Shape.Circle(n)
        \\}
        \\fn main {
        \\    let o = find(5)
        \\    match o {
        \\        Some(v) -> env.out(v),
        \\        None -> env.out("none"),
        \\    }
        \\    match find(0 - 3) {
        \\        Some(v) -> env.out(v),
        \\        None -> env.out("none"),
        \\    }
        \\    let code = match classify(4) {
        \\        Ok(v) -> v,
        \\        Err(c) -> 0 - c,
        \\    }
        \\    env.out(code)
        \\    match pick(7) {
        \\        Circle(d) -> env.out(d),
        \\        Empty -> env.out("empty"),
        \\    }
        \\}
        \\
    ;
    var mod = (try buildLocal(testing.allocator, &tr, src)) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // The callee returns the boxed value's base pointer.
    try testing.expect(std.mem.indexOf(u8, dump, "fn find") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "-> ptr") != null);
}

test "enum returns: honest rejections — missing else, wrong enum" {
    // A value `if` without an `else` has a path yielding no value.
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src1 =
        \\fn find(n: i64) -> Option<i64> {
        \\    if n > 0 { Some(n) }
        \\}
        \\fn main {
        \\    let o = find(5)
        \\    env.out(1)
        \\}
        \\
    ;
    try tr.addLib(src1);
    const r1 = try rejectFromSource(testing.allocator, src1, tr.resolver());
    try testing.expectEqual(hir.Reject.unsupported_call, r1.?);
    // A body yielding a different enum than declared.
    var tr2 = TestResolver{ .a = testing.allocator };
    defer tr2.deinit();
    const src2 =
        \\fn find(n: i64) -> Option<i64> {
        \\    Ok(n)
        \\}
        \\fn main {
        \\    let o = find(5)
        \\    env.out(1)
        \\}
        \\
    ;
    try tr2.addLib(src2);
    const r2 = try rejectFromSource(testing.allocator, src2, tr2.resolver());
    try testing.expectEqual(hir.Reject.unsupported_call, r2.?);
}

test "if let: one-arm match in main — payload bind, else, else-if-let chain" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    const src =
        \\fn find(n: i64) -> Option<i64> {
        \\    if n > 0 { Some(n) } else { None }
        \\}
        \\fn main {
        \\    if let Some(v) = find(21) {
        \\        env.out(v * 2)
        \\    } else {
        \\        env.out("nothing")
        \\    }
        \\    let r = Err(9)
        \\    if let Err(c) = r {
        \\        env.out(c)
        \\    }
        \\    if let Some(x) = find(3) {
        \\        env.out(x)
        \\    } else if let None = find(4) {
        \\        env.out(0)
        \\    }
        \\}
        \\
    ;
    var mod = (try buildLocal(testing.allocator, &tr, src)) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // The desugar reads the boxed tag and binds the payload slot.
    try testing.expect(std.mem.indexOf(u8, dump, "field_get") != null);

    // An `if let` on a non-enum scrutinee is honestly unsupported.
    var tr2 = TestResolver{ .a = testing.allocator };
    defer tr2.deinit();
    try testing.expect((try buildLocal(testing.allocator, &tr2,
        \\fn main {
        \\    let n = 5
        \\    if let Some(v) = n {
        \\        env.out(v)
        \\    }
        \\}
        \\
    )) == null);
}

test "T? sugar: `-> i64?` is `-> Option<i64>` (errors.md)" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    var mod = (try buildLocal(testing.allocator, &tr,
        \\fn find(n: i64) -> i64? {
        \\    if n > 0 { Some(n) } else { None }
        \\}
        \\fn main {
        \\    if let Some(v) = find(21) {
        \\        env.out(v * 2)
        \\    } else {
        \\        env.out("nothing")
        \\    }
        \\    match find(0 - 1) {
        \\        Some(v) -> env.out(v),
        \\        None -> env.out("none"),
        \\    }
        \\}
        \\
    )) orelse return error.TestUnexpectedResult;
    defer mod.deinit();
}

test "try: Err propagates, Ok binds the payload (errors.md v0 floor)" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    var mod = (try buildLocal(testing.allocator, &tr,
        \\fn half(n: i64) -> Result<i64, i64> {
        \\    if n % 2 == 0 { Ok(n / 2) } else { Err(n) }
        \\}
        \\fn quarter(n: i64) -> Result<i64, i64> {
        \\    let h = try half(n)
        \\    let q = try half(h)
        \\    Ok(q)
        \\}
        \\fn main {
        \\    match quarter(12) {
        \\        Ok(v) -> env.out(v),
        \\        Err(e) -> env.out(e),
        \\    }
        \\}
        \\
    )) orelse return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // The desugar: bind the Result, test the tag, early-return on Err.
    try testing.expect(std.mem.indexOf(u8, dump, "ret local") != null);

    // `try` outside a Result-returning function is unsupported (the
    // TYP300 wire is `q64 check`'s).
    var tr2 = TestResolver{ .a = testing.allocator };
    defer tr2.deinit();
    try testing.expect((try buildLocal(testing.allocator, &tr2,
        \\fn half(n: i64) -> Result<i64, i64> {
        \\    Ok(n / 2)
        \\}
        \\fn f(n: i64) -> Option<i64> {
        \\    let h = try half(n)
        \\    Some(h)
        \\}
        \\fn main {
        \\    let o = f(4)
        \\    env.out(1)
        \\}
        \\
    )) == null);
    // `try` of a non-Result value is unsupported.
    var tr3 = TestResolver{ .a = testing.allocator };
    defer tr3.deinit();
    try testing.expect((try buildLocal(testing.allocator, &tr3,
        \\fn g(n: i64) -> Option<i64> {
        \\    Some(n)
        \\}
        \\fn f(n: i64) -> Result<i64, i64> {
        \\    let h = try g(n)
        \\    Ok(h)
        \\}
        \\fn main {
        \\    let r = f(4)
        \\    env.out(1)
        \\}
        \\
    )) == null);
}

test "callee-body match: enum params + value if-chain tails" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    var mod = (try buildLocal(testing.allocator, &tr,
        \\enum Shape { Empty, Circle(i64), Rect(i64, i64) }
        \\fn area(s: Shape) -> i64 {
        \\    match s {
        \\        Empty -> 0,
        \\        Circle(r) -> r * r * 3,
        \\        Rect(w, h) -> w * h,
        \\    }
        \\}
        \\fn unwrap_or(o: Option<i64>, d: i64) -> i64 {
        \\    match o {
        \\        Some(v) -> v,
        \\        None -> d,
        \\    }
        \\}
        \\fn main {
        \\    env.out(area(Shape.Circle(4)))
        \\    env.out(unwrap_or(Some(7), 0 - 1))
        \\}
        \\
    )) orelse return error.TestUnexpectedResult;
    defer mod.deinit();
    // Honest rejections: a non-exhaustive callee match, and arms that
    // disagree on the yielded type.
    var tr2 = TestResolver{ .a = testing.allocator };
    defer tr2.deinit();
    try testing.expect((try buildLocal(testing.allocator, &tr2,
        \\fn unwrap(o: Option<i64>) -> i64 {
        \\    match o {
        \\        Some(v) -> v,
        \\    }
        \\}
        \\fn main {
        \\    env.out(unwrap(Some(7)))
        \\}
        \\
    )) == null);
    var tr3 = TestResolver{ .a = testing.allocator };
    defer tr3.deinit();
    try testing.expect((try buildLocal(testing.allocator, &tr3,
        \\fn f(o: Option<i64>) -> i64 {
        \\    match o {
        \\        Some(v) -> v,
        \\        None -> 1.5,
        \\    }
        \\}
        \\fn main {
        \\    env.out(f(Some(7)))
        \\}
        \\
    )) == null);
}

test "callee-body match: immediate (all-unit) enum param — i64 tag ABI" {
    // An all-unit enum is an i64 tag, not a boxed record. As a callee param it
    // must still register so `match c { … }` resolves bare variants — in both
    // the value-`let` and statement-return forms.
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    var mod = (try buildLocal(testing.allocator, &tr,
        \\enum Color { Red, Green, Blue }
        \\fn rank(c: Color) -> i64 {
        \\    let r = match c {
        \\        Red -> 1,
        \\        Green -> 2,
        \\        Blue -> 3,
        \\    }
        \\    r
        \\}
        \\fn tag(c: Color) -> i64 {
        \\    match c {
        \\        Red -> 10,
        \\        Green -> 20,
        \\        Blue -> 30,
        \\    }
        \\}
        \\fn main {
        \\    env.out(rank(Color.Green))
        \\    env.out(tag(Color.Blue))
        \\}
        \\
    )) orelse return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // Both callees build (the tag rides as an i64); before the fix an
    // immediate-enum param made the whole function unsupported.
    try testing.expect(std.mem.indexOf(u8, dump, "fn rank -> i64") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "fn tag -> i64") != null);
}

test "void procedures: env.out / while / if-else / value let / void call from main" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    var mod = (try buildLocal(testing.allocator, &tr,
        \\fn line(n: i64) {
        \\    let doubled = n * 2
        \\    env.out(doubled)
        \\}
        \\fn count_down(n: i64) {
        \\    var i = n
        \\    while i > 0 {
        \\        line(i)
        \\        i = i - 1
        \\    }
        \\    if n > 0 { env.out("done") } else { env.out("nothing") }
        \\}
        \\fn main {
        \\    count_down(3)
        \\}
        \\
    )) orelse return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // Both procedures register as void functions, callable from main and
    // from each other.
    try testing.expect(std.mem.indexOf(u8, dump, "fn line -> void") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "fn count_down -> void") != null);
    // A void call in *value* position (`env.out(line(1))`) is rejected — a
    // value may not be left on the stack.
    var tr2 = TestResolver{ .a = testing.allocator };
    defer tr2.deinit();
    try testing.expect((try buildLocal(testing.allocator, &tr2,
        \\fn line(n: i64) { env.out(n) }
        \\fn main {
        \\    env.out(line(1))
        \\}
        \\
    )) == null);
    // A `return <value>` inside a void procedure is rejected.
    var tr3 = TestResolver{ .a = testing.allocator };
    defer tr3.deinit();
    try testing.expect((try buildLocal(testing.allocator, &tr3,
        \\fn p(n: i64) { return n }
        \\fn main {
        \\    p(1)
        \\}
        \\
    )) == null);
}

test "void procedures: statement-position match (enum payloads, block arms, literals)" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    var mod = (try buildLocal(testing.allocator, &tr,
        \\enum Shape { Empty, Circle(i64), Rect(i64, i64) }
        \\fn describe(s: Shape) {
        \\    match s {
        \\        Empty -> env.out("empty"),
        \\        Circle(r) -> env.out(r * r * 3),
        \\        Rect(w, h) -> {
        \\            env.out("rect")
        \\            env.out(w * h)
        \\        },
        \\    }
        \\}
        \\fn grade(n: i64) {
        \\    match n {
        \\        0 -> env.out("zero"),
        \\        _ -> env.out("many"),
        \\    }
        \\}
        \\fn main {
        \\    describe(Shape.Rect(3, 5))
        \\    grade(0)
        \\}
        \\
    )) orelse return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "fn describe -> void") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "fn grade -> void") != null);
    // A non-exhaustive void match (no wildcard, missing a variant) is rejected.
    var tr2 = TestResolver{ .a = testing.allocator };
    defer tr2.deinit();
    try testing.expect((try buildLocal(testing.allocator, &tr2,
        \\fn report(o: Option<i64>) {
        \\    match o {
        \\        Some(v) -> env.out(v),
        \\    }
        \\}
        \\fn main { report(None) }
        \\
    )) == null);
}

test "callee-body match: `let x = match …` bind form (enum + literal scrutinees)" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    var mod = (try buildLocal(testing.allocator, &tr,
        \\fn classify(n: i64) -> i64 {
        \\    let label = match n {
        \\        0 -> 100,
        \\        1 -> 200,
        \\        _ -> 999,
        \\    }
        \\    label + 1
        \\}
        \\fn unwrap_or(o: Option<i64>, d: i64) -> i64 {
        \\    let v = match o {
        \\        Some(x) -> x,
        \\        None -> d,
        \\    }
        \\    v * 10
        \\}
        \\fn main {
        \\    env.out(classify(7))
        \\    env.out(unwrap_or(Some(5), 0))
        \\}
        \\
    )) orelse return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // The bind reads the hidden result local, then the body uses it — so the
    // chosen arm's value reaches `label + 1` / `v * 10`.
    try testing.expect(std.mem.indexOf(u8, dump, "fn classify") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "fn unwrap_or") != null);
    // Mixed arm types are still rejected in the bind form, same as the tail.
    var tr2 = TestResolver{ .a = testing.allocator };
    defer tr2.deinit();
    try testing.expect((try buildLocal(testing.allocator, &tr2,
        \\fn f(o: Option<i64>) -> i64 {
        \\    let v = match o {
        \\        Some(x) -> x,
        \\        None -> 1.5,
        \\    }
        \\    v
        \\}
        \\fn main {
        \\    env.out(f(Some(7)))
        \\}
        \\
    )) == null);
}

test "record-returning match tails: Option -> Option / Option -> Result" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    var mod = (try buildLocal(testing.allocator, &tr,
        \\fn flip(o: Option<i64>) -> Option<i64> {
        \\    match o {
        \\        Some(v) -> Some(v * 2),
        \\        None -> Some(0),
        \\    }
        \\}
        \\fn to_result(o: Option<i64>, e: i64) -> Result<i64, i64> {
        \\    match o {
        \\        Some(v) -> Ok(v),
        \\        None -> Err(e),
        \\    }
        \\}
        \\fn main {
        \\    match flip(Some(21)) {
        \\        Some(v) -> env.out(v),
        \\        None -> env.out("none"),
        \\    }
        \\    match to_result(None, 7) {
        \\        Ok(v) -> env.out(v),
        \\        Err(c) -> env.out(c),
        \\    }
        \\}
        \\
    )) orelse return error.TestUnexpectedResult;
    defer mod.deinit();
    // An arm yielding the wrong enum rejects (Result body, Option arm).
    var tr2 = TestResolver{ .a = testing.allocator };
    defer tr2.deinit();
    const src2 =
        \\fn f(o: Option<i64>) -> Result<i64, i64> {
        \\    match o {
        \\        Some(v) -> Ok(v),
        \\        None -> Some(0),
        \\    }
        \\}
        \\fn main {
        \\    let r = f(Some(1))
        \\    env.out(1)
        \\}
        \\
    ;
    try tr2.addLib(src2);
    const r = try rejectFromSource(testing.allocator, src2, tr2.resolver());
    try testing.expectEqual(hir.Reject.unsupported_call, r.?);
}

test "str methods: len/index/slice/contains/starts_with/index_of + mixed signatures" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    var mod = (try buildLocal(testing.allocator, &tr,
        \\fn length_of(s: str) -> i64 {
        \\    s.len
        \\}
        \\fn has(s: str, sub: str) -> bool {
        \\    s.contains(sub)
        \\}
        \\fn id(x: str) -> str {
        \\    x
        \\}
        \\fn main {
        \\    let s = id("hello world")
        \\    env.out(s.len)
        \\    env.out(s[0])
        \\    env.out(s.slice(0, 5))
        \\    env.out(s.contains("world"))
        \\    env.out(s.starts_with("hell"))
        \\    env.out(s.index_of(32))
        \\    env.out(length_of(s))
        \\    env.out(has(s, "wor"))
        \\    let t = s.slice(6, 11)
        \\    env.out(t.len)
        \\    if s.contains("world") {
        \\        env.out("yes")
        \\    }
        \\}
        \\
    )) orelse return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "str_len") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "slice") != null);
}

test "str params: a second str param reads its own wasm slots (2, 3)" {
    // The latent bug the two-slot unification fixed: under the one-slot
    // convention, a passthrough of the SECOND str param read slots
    // (1, 2) instead of (2, 3).
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    try tr.addLib("pub fn second(a: str, b: str) -> str { b }\n");
    var mod = (try buildFromSource(testing.allocator, "fn main {\n env.out(second(\"x\", \"y\"))\n}\n", tr.resolver())) orelse
        return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "str_binding[2,3]") != null);
}

test "Vec v0 floor: from/push/len/index/for, growth, honest boundaries" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    var mod = (try buildLocal(testing.allocator, &tr,
        \\fn main {
        \\    var v = Vec.from([10, 20, 30])
        \\    env.out(v.len)
        \\    env.out(v[0])
        \\    v.push(40)
        \\    var sum = 0
        \\    for x in v {
        \\        sum = sum + x
        \\    }
        \\    env.out(sum)
        \\}
        \\
    )) orelse return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "vec_new") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "vec_push") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "vec_len") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "vec_get") != null);
    // A vec crossing a function boundary is honestly unsupported
    // (growth inside a callee would allocate into a dying frame).
    var tr2 = TestResolver{ .a = testing.allocator };
    defer tr2.deinit();
    try testing.expect((try buildLocal(testing.allocator, &tr2,
        \\fn sum_of(n: i64) -> i64 {
        \\    n
        \\}
        \\fn main {
        \\    var v = Vec.from([1, 2])
        \\    env.out(sum_of(v))
        \\}
        \\
    )) == null);
}

test "env.fs.read: a Result<str, i64> @fs capability face" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    var mod = (try buildLocal(testing.allocator, &tr,
        \\fn main {
        \\    match env.fs.read("config.txt") {
        \\        Ok(content) -> env.out(content.len),
        \\        Err(code) -> env.out(code),
        \\    }
        \\}
        \\
    )) orelse return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "fs_read") != null);
    // The effect pass marks main @fs (closed over @io).
    try testing.expect(std.mem.indexOf(u8, dump, "@fs") != null);
}

test "str enum payloads: Result<str, i64>, Msg.Text(str), Option<str>, try" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    var mod = (try buildLocal(testing.allocator, &tr,
        \\enum Msg { Text(str), Code(i64), Nothing }
        \\fn lookup(n: i64) -> Result<str, i64> {
        \\    if n > 0 { Ok("found it") } else { Err(404) }
        \\}
        \\fn chain(n: i64) -> Result<str, i64> {
        \\    let s = try lookup(n)
        \\    Ok(s)
        \\}
        \\fn main {
        \\    match lookup(1) {
        \\        Ok(content) -> env.out(content),
        \\        Err(code) -> env.out(code),
        \\    }
        \\    let m = Msg.Text("boxed")
        \\    match m {
        \\        Text(t) -> env.out(t.len),
        \\        Code(c) -> env.out(c),
        \\        Nothing -> env.out("none"),
        \\    }
        \\    match chain(5) {
        \\        Ok(s) -> env.out(s),
        \\        Err(c) -> env.out(c),
        \\    }
        \\}
        \\
    )) orelse return error.TestUnexpectedResult;
    defer mod.deinit();
    const dump = try print.hirToString(testing.allocator, &mod);
    defer testing.allocator.free(dump);
    // The Ok(str) instantiation boxes to {tag, ptr, len} = 24 bytes.
    try testing.expect(std.mem.indexOf(u8, dump, "record_alloc size=24") != null);
}
