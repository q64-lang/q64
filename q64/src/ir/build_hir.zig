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

pub const ModuleResolver = hir.ModuleResolver;

/// `Unsupported` — a construct the IR path doesn't represent yet; the caller
/// reports an honest `UnsupportedExpression`. `Rejected` — a definite semantic
/// error was recorded in `Builder.reject`; the caller reports its diagnostic.
const BuildError = error{ Unsupported, Rejected } || std.mem.Allocator.Error;

/// A runtime `str` binding in `main`: its `(ptr, len)` live in two `_start`
/// i64 locals.
const StrBinding = struct { ptr_idx: u32, len_idx: u32 };
const RtMap = std.StringHashMapUnmanaged(StrBinding);

const Builder = struct {
    a: std.mem.Allocator,
    resolver: ModuleResolver,
    eval: consteval.Evaluator,
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
    var b = Builder{ .a = a, .resolver = resolver, .eval = .{ .a = a, .resolver = resolver } };
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
    while (it.next()) |stmt| switch (stmt) {
        .let_stmt => |ls| {
            const init_expr = ls.initializer() orelse return error.Unsupported;
            const nm = (ls.pattern() orelse return error.Unsupported).bindingName() orelse return error.Unsupported;
            // A `let` initializer that const-folds (incl. a const-bodied call,
            // e.g. `let v = version()`) becomes a compile-time binding.
            b.eval.fold_calls = true;
            const folded = try tryConst(b, init_expr);
            b.eval.fold_calls = false;
            if (folded) |bytes| {
                try b.eval.bind(nm.text, bytes);
                continue;
            }
            // Otherwise a runtime str binding (`let g = shout("hi")`): build
            // the str value and store its (ptr, len) into two new locals.
            if (init_expr == .string_lit or (try isStrCall(b, init_expr))) {
                const value = if (init_expr == .string_lit)
                    try buildConcat(b, init_expr.string_lit, &mscope, false, rt)
                else
                    try buildStrExpr(b, init_expr, &mscope, rt);
                const ptr_idx: u32 = @intCast(b.main_locals.items.len);
                // The (ptr, len) backing locals are address-width pointers
                // (i32 on wasm32, i64 on wasm64) — `.ptr`, not `.i64`.
                try b.main_locals.append(b.a, .ptr);
                try b.main_locals.append(b.a, .ptr);
                try b.main_rt.put(b.a, nm.text, .{ .ptr_idx = ptr_idx, .len_idx = ptr_idx + 1 });
                const st = try b.a.create(hir.Stmt);
                st.* = .{ .str_let = .{ .ptr_idx = ptr_idx, .len_idx = ptr_idx + 1, .value = value } };
                try stmts.append(b.a, st);
            } else {
                // A runtime i64 binding (`let a = double(21)`, `let b = a + 1`).
                // A boolean initializer (`let x = a > 0`) would need a bool
                // local; locals are i64-only today, so reject it honestly
                // rather than emit an i32-into-i64 store.
                if (try exprIsBool(b, init_expr)) return error.Unsupported;
                // Build the initializer first so it can't see its own name,
                // then allocate a single i64 local and register in mscope so
                // later i64 expressions can resolve it. The local index is the
                // current size of `main_locals` (str bindings take two slots
                // each, i64 bindings take one — the same shared index space).
                mscope.next_idx = @intCast(b.main_locals.items.len);
                const value = try buildIntExpr(b, init_expr, &mscope);
                const idx = try mscope.declare(nm.text, ls.isVar(), .i64);
                try b.main_locals.append(b.a, .i64);
                const st = try b.a.create(hir.Stmt);
                st.* = .{ .let = .{ .idx = idx, .value = value } };
                try stmts.append(b.a, st);
            }
        },
        .expr_stmt => |es| {
            const expr = es.expression() orelse return error.Unsupported;
            const call = switch (expr) {
                .call => |cc| cc,
                else => return error.Unsupported,
            };
            // A host face call other than env.out (e.g. `qview.text(24, 80, 0)`):
            // all-i64 args, no return. The backend declares the matching import.
            if (try hostFaceName(b, call)) |fname| {
                var args: std.ArrayList(*hir.Expr) = .empty;
                var ait = call.args();
                while (ait.next()) |a| try args.append(b.a, try buildIntExpr(b, a, &mscope));
                const st = try b.a.create(hir.Stmt);
                st.* = .{ .host_call = .{ .name = fname, .args = try args.toOwnedSlice(b.a) } };
                try stmts.append(b.a, st);
                continue;
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
                const v = try buildConcat(b, arg.string_lit, &mscope, false, rt);
                st.* = if (v.* == .str_const) .{ .host_out = v } else .{ .host_out_str = v };
            } else if (try isStrCall(b, arg)) {
                // A real call to a str-returning function.
                st.* = .{ .host_out_str = try buildStrExpr(b, arg, &mscope, rt) };
            } else if (try exprIsBool(b, arg)) {
                // A boolean: a comparison, `&&`/`||`/`!`, a literal, or a
                // `-> bool` call. Printed as "true" / "false".
                st.* = .{ .host_out_bool = try buildIntExpr(b, arg, &mscope) };
            } else {
                // Otherwise an i64 expression (a call to an i64 function).
                const e = try buildIntExpr(b, arg, &mscope);
                st.* = .{ .host_out_int = e };
            }
            try stmts.append(b.a, st);
        },
        else => return error.Unsupported,
    };

    const block = try b.a.create(hir.Stmt);
    block.* = .{ .block = try stmts.toOwnedSlice(b.a) };
    b.funcs.items[0] = .{ .name = "main", .ret = .void, .body = block, .visibility = .public, .locals = try b.main_locals.toOwnedSlice(b.a) };
    b.entry = 0;

    try buildScreenFuncs(b, sf);
}

/// Build every non-main, void-returning top-level `fn` as an exported screen
/// handler (e.g. `pub fn on_press(id: i64) { … }`, or a backend twin's
/// `pub fn inc() { count = count + 1 }`).
fn buildScreenFuncs(b: *Builder, sf: ast.SourceFile) BuildError!void {
    var it = sf.items();
    while (it.next()) |item| switch (item) {
        .fn_decl => |fd| {
            const nm = fd.name() orelse continue;
            if (std.mem.eql(u8, nm.text, "main")) continue;
            if (fd.returnType() != null) continue; // void-returning handlers only
            // Only the public surface is an exported screen/twin handler the
            // host invokes (`pub fn on_press`, `pub fn inc`). A private
            // no-return-type function is a helper — folded into a caller (e.g.
            // `fn version { "9.9.9" }` used in interpolation) or emitted
            // on demand via `registerFunc` — not a screen function.
            if (fd.visibility() == null) continue;
            try buildScreenFunc(b, fd);
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
    if (fd.params()) |ps| {
        var pit = ps.iter();
        while (pit.next()) |p| {
            if (!(try paramIsI64(b.a, p))) return error.Unsupported;
            const pn = (p.name() orelse return error.Unsupported).text;
            _ = try scope.declare(pn, false, .i64);
            try params.append(b.a, .{ .name = pn, .ty = .i64 });
        }
    }
    scope.n_params = @intCast(params.items.len);

    var stmts: std.ArrayList(*hir.Stmt) = .empty;
    var it = (fd.body() orelse return error.Unsupported).statements();
    while (it.next()) |stmt| switch (stmt) {
        .expr_stmt => |es| {
            const call = switch (es.expression() orelse return error.Unsupported) {
                .call => |cc| cc,
                else => return error.Unsupported,
            };
            const fname = (try hostFaceName(b, call)) orelse return error.Unsupported;
            try stmts.append(b.a, try buildHostCall(b, fname, call, &scope));
        },
        .assign_stmt => |as| {
            const tgt = switch (as.target() orelse return error.Unsupported) {
                .path => |p| p,
                else => return error.Unsupported,
            };
            const tname = try tgt.text(b.a);
            defer b.a.free(tname);
            const gi = b.globals.get(tname) orelse return error.Unsupported; // global assign only
            const rhs = try buildIntExpr(b, as.value() orelse return error.Unsupported, &scope);
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
            try stmts.append(b.a, st);
        },
        else => return error.Unsupported,
    };

    const block = try b.a.create(hir.Stmt);
    block.* = .{ .block = try stmts.toOwnedSlice(b.a) };
    const extra = scope.extra();
    const locals = try b.a.alloc(hir.Type, extra);
    for (locals) |*t| t.* = .i64;
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

/// Build a `qview.*` host-call statement: all-i64 args via `buildIntExpr`.
fn buildHostCall(b: *Builder, fname: []const u8, call: ast.CallExpr, scope: *Scope) BuildError!*hir.Stmt {
    var args: std.ArrayList(*hir.Expr) = .empty;
    var ait = call.args();
    while (ait.next()) |a| try args.append(b.a, try buildIntExpr(b, a, scope));
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
    if (try returnsStr(b.a, fd)) return registerStrFunc(b, name, fd);
    // An i64 or a `-> bool` (i32 0/1) value function; both have i64 params and
    // a value body built by `buildIntBlock`.
    const ret_ty: hir.Type = if (try returnsBool(b.a, fd)) .bool else if (try returnsI64(b.a, fd)) .i64 else return error.Unsupported;

    const owned = try b.a.dupe(u8, name);

    // Parameters (all i64) occupy local indices 0..n; seed the body scope.
    var scope = Scope{ .a = b.a };
    var params: std.ArrayList(hir.Param) = .empty;
    if (fd.params()) |ps| {
        var pit = ps.iter();
        while (pit.next()) |p| {
            if (!(try paramIsI64(b.a, p))) return error.Unsupported;
            const pn = (p.name() orelse return error.Unsupported).text;
            _ = try scope.declare(pn, false, .i64);
            try params.append(b.a, .{ .name = pn, .ty = .i64 });
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

    const body = try buildIntBlock(b, fd.body() orelse return error.Unsupported, &scope);
    // A value-producing i64 function whose tail is an `if` with no `else` has a
    // path that yields no value → UnsupportedCall (matches the legacy emitter,
    // which rejects a value `if` lacking an else).
    if (tailIsValueIfNoElse(body)) return reject(b, .unsupported_call);
    const extra = scope.extra();
    const locals = try b.a.alloc(hir.Type, extra);
    for (locals) |*t| t.* = .i64;

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
            if (!(try paramIsStr(b.a, p))) return error.Unsupported; // all-str params for now
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
                out.* = .{ .local = loc.idx };
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
            const id = try registerFunc(b, cname);
            if (b.funcs.items[id].ret != .str) return error.Unsupported;
            var args: std.ArrayList(*hir.Expr) = .empty;
            var ait = cc.args();
            while (ait.next()) |a| try args.append(b.a, try buildStrArg(b, a, scope, rt));
            if (args.items.len != b.funcs.items[id].params.len) return reject(b, .unsupported_call);
            out.* = .{ .call = .{ .func = id, .args = try args.toOwnedSlice(b.a) } };
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
                out.* = .{ .local = loc.idx };
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
                            piece.* = .{ .local = loc.idx };
                        } else {
                            const lref = try b.a.create(hir.Expr);
                            lref.* = .{ .local = loc.idx };
                            piece.* = .{ .fmt_int = lref };
                        }
                        try pieces.append(b.a, piece);
                    } else if (rtBinding(rt, ptext)) |bnd| {
                        try flush(b, &lit, &pieces);
                        const e = try b.a.create(hir.Expr);
                        e.* = .{ .str_binding = .{ .ptr_idx = bnd.ptr_idx, .len_idx = bnd.len_idx } };
                        try pieces.append(b.a, e);
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
    return returnsStr(b.a, fd);
}

fn returnsStr(a: std.mem.Allocator, fd: ast.FnDecl) BuildError!bool {
    const rt = fd.returnType() orelse return false;
    const te = rt.type_() orelse return false;
    return typeNamed(a, te, "str");
}

fn returnsBool(a: std.mem.Allocator, fd: ast.FnDecl) BuildError!bool {
    const rt = fd.returnType() orelse return false;
    const te = rt.type_() orelse return false;
    return typeNamed(a, te, "bool");
}

/// Syntactic check: does `arg` denote a boolean value? Covers the boolean
/// expression grammar (comparison / `&&` / `||` / `!` / `true` / `false`) and
/// a call to a `-> bool` function. Used to route `env.out` to the bool path.
fn exprIsBool(b: *Builder, arg: ast.Expr) BuildError!bool {
    switch (arg) {
        .literal => |lit| {
            const t = lit.token() orelse return false;
            return t.kind == .KW_TRUE or t.kind == .KW_FALSE;
        },
        .paren => |p| return exprIsBool(b, p.inner() orelse return false),
        .unary => |u| return (u.op() orelse return false).kind == .BANG,
        .bin => |bx| return isBoolOp((bx.op() orelse return false).kind),
        .call => return isBoolCall(b, arg),
        else => return false,
    }
}

fn isBoolOp(k: parser.cst.SyntaxKind) bool {
    return switch (k) {
        .EQ_EQ, .BANG_EQ, .L_ANGLE, .R_ANGLE, .LT_EQ, .GT_EQ, .AMP_AMP, .PIPE_PIPE => true,
        else => false,
    };
}

fn isBoolCall(b: *Builder, arg: ast.Expr) BuildError!bool {
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
    return returnsBool(b.a, fd);
}

fn paramIsStr(a: std.mem.Allocator, p: ast.Param) BuildError!bool {
    const te = p.type_() orelse return false;
    return typeNamed(a, te, "str");
}

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
            // Locals are i64-only; a boolean initializer would need a bool
            // local, so reject it rather than store an i32 into an i64 slot.
            if (try exprIsBool(b, init_expr)) return error.Unsupported;
            // Build the initializer before declaring, so it can't see itself.
            const value = try buildIntExpr(b, init_expr, scope);
            const idx = try scope.declare(nm.text, ls.isVar(), .i64);
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
            const rhs = try buildIntExpr(b, as.value() orelse return error.Unsupported, scope);
            const op = as.op() orelse return error.Unsupported;
            const value = if (op.kind == .EQ) rhs else blk: {
                const k = compoundOp(op) orelse return error.Unsupported;
                const lhs = try b.a.create(hir.Expr);
                lhs.* = .{ .local = loc.idx };
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
            if (scope.find(txt)) |loc| {
                if (loc.ty != .i64) return error.Unsupported; // a str local in an i64 context
                out.* = .{ .local = loc.idx };
            } else if (b.globals.get(txt)) |gi| {
                out.* = .{ .global_get = gi };       // module-level `state`
            } else return error.Unsupported;
        },
        .unary => |u| {
            const kind = unKind(u.op() orelse return error.Unsupported) orelse return error.Unsupported;
            out.* = .{ .un = .{ .kind = kind, .operand = try buildIntExpr(b, u.operand() orelse return error.Unsupported, scope) } };
        },
        .bin => |bx| {
            const op_tok = bx.op() orelse return error.Unsupported;
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
            const id = try registerFunc(b, cname);
            // An i64 or bool (i32 0/1) callee produces a value usable here; a
            // str callee does not belong in an i64/bool expression.
            switch (b.funcs.items[id].ret) {
                .i64, .bool => {},
                else => return reject(b, .unsupported_call),
            }
            var args: std.ArrayList(*hir.Expr) = .empty;
            var ait = cc.args();
            while (ait.next()) |a| try args.append(b.a, try buildIntExpr(b, a, scope));
            if (args.items.len != b.funcs.items[id].params.len) return reject(b, .unsupported_call);
            out.* = .{ .call = .{ .func = id, .args = try args.toOwnedSlice(b.a) } };
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

fn returnsI64(a: std.mem.Allocator, fd: ast.FnDecl) BuildError!bool {
    const rt = fd.returnType() orelse return false;
    const te = rt.type_() orelse return false;
    return typeNamed(a, te, "i64");
}

fn paramIsI64(a: std.mem.Allocator, p: ast.Param) BuildError!bool {
    const te = p.type_() orelse return false;
    return typeNamed(a, te, "i64");
}

fn typeNamed(a: std.mem.Allocator, te: ast.TypeExpr, name: []const u8) BuildError!bool {
    const p = switch (te) {
        .path => |x| x,
        else => return false,
    };
    const nm = try p.name(a);
    defer a.free(nm);
    return std.mem.eql(u8, nm, name);
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
    try testing.expect(std.mem.indexOf(u8, dump, "local#0") != null); // passthrough param ref
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
