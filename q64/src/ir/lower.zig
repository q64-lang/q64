//! HIR → MIR lowering (the middle boundary of the Q64 IR).
//!
//! Imports `hir`/`mir` only — NEVER the Binaryen C API. Turns the semantic
//! HIR into the executable MIR: this is where the `str` ABI, the region
//! model, and int→string formatting become explicit. The MIR it produces is
//! the direct input to a backend.
//!
//! Migration status: lowers the literal `env.out` path and i64 functions
//! (arithmetic + calls) with their `env.out(<i64>)` uses. Control flow and
//! the string-concat arena ops land in later phases.

const std = @import("std");
const hir = @import("hir.zig");
const mir = @import("mir.zig");

/// `Unsupported` means a valid-but-not-yet-lowerable shape (e.g. a function
/// body whose tail isn't a value); the codegen router treats it as a signal
/// to fall back to the legacy emitter.
pub const Error = error{Unsupported} || std.mem.Allocator.Error;

/// Reserved internal name for the entry function in MIR. It carries a `#`
/// prefix — illegal in a q64 identifier (`[A-Za-z_][A-Za-z0-9_]*`) — so it can
/// never collide with a user function the program defines (e.g. `fn start`),
/// while staying distinct in `show mir`. The name is a backend handle only:
/// calls resolve by `FuncId`, and the entry always exports as `_start`
/// regardless of this name.
pub const entry_name = "#start";

const Ctx = struct {
    a: std.mem.Allocator,
    data: *std.ArrayList(u8),
    nl_off: *?u32,
    /// The HIR functions, so a `call` can recover its callee's return type
    /// (an i64 vs a bool/i32 result) instead of assuming i64.
    funcs: []const hir.Func,

    /// The shared trailing-newline byte env.out writes after a formatted
    /// value; materialized once into the memory image.
    fn newline(self: Ctx) Error!u32 {
        if (self.nl_off.*) |off| return off;
        const off: u32 = @intCast(self.data.items.len);
        try self.data.append(self.a, '\n');
        self.nl_off.* = off;
        return off;
    }
};

/// Lower a whole HIR module to MIR. The result owns its own arena.
pub fn lower(gpa: std.mem.Allocator, h: *const hir.Module) Error!mir.Module {
    var mod = mir.Module.init(gpa);
    errdefer mod.deinit();
    const a = mod.alloc();

    var data: std.ArrayList(u8) = .empty;
    var nl_off: ?u32 = null;
    const ctx = Ctx{ .a = a, .data = &data, .nl_off = &nl_off, .funcs = h.funcs };

    const funcs = try a.alloc(mir.Func, h.funcs.len);
    for (h.funcs, 0..) |hf, i| {
        const is_entry = (h.entry != null and h.entry.? == i);
        // The entry, any `is_screen` function (e.g. `on_press`), and any
        // void-returning procedure share the void lowering: their bodies are
        // statement sequences (host_out / host_call / call / let / if / while),
        // which `lowerEntryStmt` handles. The rest are i64/str value callees.
        if (is_entry or hf.is_screen or hf.ret == .void) {
            const params = try a.alloc(mir.ValueType, hf.params.len);
            for (hf.params, 0..) |p, j| params[j] = mapType(p.ty);
            const locals = try a.alloc(mir.ValueType, hf.locals.len);
            for (hf.locals, 0..) |t, j| locals[j] = mapType(t);
            // A *value-returning* screen func (a stamped generic with
            // `-> i64` etc.) lowers its body as a value block: the same
            // entry statement set, with the last statement as the value
            // tail. The entry and void handlers stay the void lowering.
            const vty: ?mir.ValueType = if (!is_entry and hf.ret != .void) mapType(hf.ret) else null;
            funcs[i] = .{
                .name = if (is_entry) entry_name else try a.dupeZ(u8, hf.name),
                .params = params,
                .ret = vty orelse .void,
                .locals = locals,
                .body = .{ .structured = if (vty) |t| try lowerIntBlock(ctx, hf.body, t) else try lowerEntry(ctx, hf.body) },
                .linkage = if (is_entry) .entry else .local,
                .exported = (!is_entry and hf.visibility == .public),
                .ret_size = hf.ret_size,
                .ret_ptr_bearing = hf.ret_ptr_bearing,
            };
        } else {
            funcs[i] = try lowerCallee(ctx, hf);
        }
    }

    mod.funcs = funcs;
    mod.entry = h.entry;
    mod.data = try data.toOwnedSlice(a);
    mod.globals = try a.dupe(i64, h.globals);
    mod.global_names = try a.dupe([]const u8, h.global_names);
    mod.init_fn = h.init_fn;
    return mod;
}

fn lowerEntry(ctx: Ctx, body: *const hir.Stmt) Error!*mir.Inst {
    const items = switch (body.*) {
        .block => |b| b,
        else => unreachable, // main is always a block
    };
    const out = try ctx.a.alloc(*mir.Inst, items.len);
    for (items, 0..) |s, i| out[i] = try lowerEntryStmt(ctx, s);
    return mk(ctx.a, .void, .{ .block = out });
}

fn lowerEntryStmt(ctx: Ctx, s: *const hir.Stmt) Error!*mir.Inst {
    switch (s.*) {
        .host_out => |h| {
            // env.out("X") writes "X\n": fold value + newline into `data`.
            const bytes = switch (h.value.*) {
                .str_const => |b| b,
                else => unreachable,
            };
            return hostOutConst(ctx, bytes, h.stream);
        },
        .host_out_int => |h| {
            const nl = try ctx.newline();
            return mk(ctx.a, .void, .{ .host_out_int = .{ .value = try lowerExpr(ctx, h.value), .nl_off = nl, .stream = mapStream(h.stream) } });
        },
        .host_out_float => |h| {
            const nl = try ctx.newline();
            return mk(ctx.a, .void, .{ .host_out_float = .{ .value = try lowerExpr(ctx, h.value), .nl_off = nl, .stream = mapStream(h.stream) } });
        },
        .host_out_str => |h| {
            const nl = try ctx.newline();
            return mk(ctx.a, .void, .{ .host_out_str = .{ .value = try lowerStrExpr(ctx, h.value), .nl_off = nl, .stream = mapStream(h.stream) } });
        },
        .host_out_bool => |h| {
            // `env.out(<bool>)` → `if e { out("true") } else { out("false") }`.
            const cond = try lowerCond(ctx, h.value);
            return mk(ctx.a, .void, .{ .if_ = .{
                .cond = cond,
                .then_ = try hostOutConst(ctx, "true", h.stream),
                .else_ = try hostOutConst(ctx, "false", h.stream),
            } });
        },
        .host_exit => |e| return mk(ctx.a, .void, .{ .host_exit = .{ .code = try lowerExpr(ctx, e) } }),
        .time_sleep_ns => |e| return mk(ctx.a, .void, .{ .time_sleep_ns = .{ .ns = try lowerExpr(ctx, e) } }),
        .panic => |maybe| {
            // Write the message (if any) to stderr, then trap. The host
            // surfaces the trap as exit 1.
            var items: std.ArrayList(*mir.Inst) = .empty;
            if (maybe) |msg| switch (msg.*) {
                .str_const => |bytes| try items.append(ctx.a, try hostOutConst(ctx, bytes, .err)),
                else => {
                    const nl = try ctx.newline();
                    try items.append(ctx.a, try mk(ctx.a, .void, .{ .host_out_str = .{ .value = try lowerStrExpr(ctx, msg), .nl_off = nl, .stream = .err } }));
                },
            };
            try items.append(ctx.a, try mk(ctx.a, .void, .@"unreachable"));
            return mk(ctx.a, .void, .{ .block = try items.toOwnedSlice(ctx.a) });
        },
        .host_call => |hc| {
            // A `str`-valued argument lowers to a (ptr, len) str inst; any other
            // is an i64. The backend reads each arg's `.ty` to push 2 or 1 wasm
            // operands (and to declare the matching import param types).
            const args = try ctx.a.alloc(*mir.Inst, hc.args.len);
            for (hc.args, 0..) |a, i| args[i] = if (isStrExpr(a)) try lowerStrExpr(ctx, a) else try lowerExpr(ctx, a);
            return mk(ctx.a, .void, .{ .host_call = .{ .name = hc.name, .args = args } });
        },
        .global_set => |gs| return mk(ctx.a, .void, .{ .global_set = .{ .idx = gs.idx, .value = try lowerExpr(ctx, gs.value) } }),
        .str_let => |sl| return mk(ctx.a, .void, .{ .str_bind = .{ .ptr_idx = sl.ptr_idx, .len_idx = sl.len_idx, .value = try lowerStrExpr(ctx, sl.value) } }),
        .field_set => |fs| return mk(ctx.a, .void, .{ .field_set = .{ .base = try lowerExpr(ctx, fs.base), .offset = fs.offset, .width = storageOf(fs.ty).width, .value = try lowerExpr(ctx, fs.value) } }),
        .let => |l| return mk(ctx.a, .void, .{ .local_set = .{ .idx = l.idx, .value = try lowerExpr(ctx, l.value) } }),
        // Void control flow — shared by `main` and function-body setup
        // statements (a non-tail `if`/`while`/`loop`/assign/break/continue).
        .assign => |a| return mk(ctx.a, .void, .{ .local_set = .{ .idx = a.idx, .value = try lowerExpr(ctx, a.value) } }),
        .while_ => |w| return mk(ctx.a, .void, .{ .while_ = .{ .cond = try lowerCond(ctx, w.cond), .body = try lowerIntBlock(ctx, w.body, null) } }),
        .loop_ => return lowerLoop(ctx, s.loop_),
        .if_ => |iff| return lowerVoidIf(ctx, iff),
        .ret => |e| return mk(ctx.a, .void, .{ .ret = if (e) |val| try lowerExpr(ctx, val) else null }),
        .brk => return mk(ctx.a, .void, .br),
        .cont => return mk(ctx.a, .void, .br_cont),
        .vec_push => |vp| return mk(ctx.a, .void, .{ .vec_push = .{ .vec = try lowerExpr(ctx, vp.vec), .value = try lowerExpr(ctx, vp.value), .cell4 = vp.cell4 } }),
        .vec_set => |vs| return mk(ctx.a, .void, .{ .vec_set = .{ .vec = try lowerExpr(ctx, vs.vec), .idx = try lowerExpr(ctx, vs.idx), .value = try lowerExpr(ctx, vs.value), .cell4 = vs.cell4 } }),
        // A statement-position block (an `if let` desugar: the hidden
        // scrutinee set + the tag test ride together).
        .block => |items| {
            const insts = try ctx.a.alloc(*mir.Inst, items.len);
            for (items, 0..) |st, i| insts[i] = try lowerEntryStmt(ctx, st);
            return mk(ctx.a, .void, .{ .block = insts });
        },
        // A statement-position call to a void function (a stamped generic
        // instance, `print_all<Color>(...)`). Value-producing expression
        // statements stay unsupported (nothing may be left on the stack).
        .expr => |e| {
            if (e.* != .call) return error.Unsupported;
            if (ctx.funcs[e.call.func].ret != .void) return error.Unsupported;
            return lowerExpr(ctx, e);
        },
    }
}

/// Map an HIR stream tag to its MIR twin (the two enums are kept distinct so
/// `mir` does not import `hir`).
fn mapStream(s: hir.Stream) mir.Stream {
    return switch (s) {
        .out => .out,
        .err => .err,
    };
}

/// Fold `bytes` + a trailing newline into the data image and emit the host
/// write of that constant run on `stream` (the `env.out("X")` / `env.err("X")`
/// shape).
fn hostOutConst(ctx: Ctx, bytes: []const u8, stream: hir.Stream) Error!*mir.Inst {
    const off: u32 = @intCast(ctx.data.items.len);
    try ctx.data.appendSlice(ctx.a, bytes);
    try ctx.data.append(ctx.a, '\n');
    return mk(ctx.a, .void, .{ .host_out_const = .{ .off = off, .len = @intCast(bytes.len + 1), .stream = mapStream(stream) } });
}

fn lowerCallee(ctx: Ctx, hf: hir.Func) Error!mir.Func {
    const params = try ctx.a.alloc(mir.ValueType, hf.params.len);
    for (hf.params, 0..) |p, i| params[i] = mapType(p.ty);
    const locals = try ctx.a.alloc(mir.ValueType, hf.locals.len);
    for (hf.locals, 0..) |t, i| locals[i] = mapType(t);

    const body = switch (hf.ret) {
        // A bare str tail (`"…"` / interpolation / str call) folds directly; a
        // str value chain (`match env.kv.… { Ok(_) -> "a" … }`) rides the
        // str-aware value-block path (setup stmts + a pair-typed if-chain).
        .str => if (singleTail(hf.body)) |t| try lowerStrExpr(ctx, t) else try lowerIntBlock(ctx, hf.body, .str),
        else => try lowerIntBlock(ctx, hf.body, mapType(hf.ret)),
    };

    return .{
        .name = try ctx.a.dupeZ(u8, hf.name),
        .params = params,
        .ret = mapType(hf.ret),
        .locals = locals,
        .body = .{ .structured = body },
        .linkage = .local,
        // A public value-returning function (a library export) is exported by
        // name so a host — or the component lift — can reach it.
        .exported = (hf.visibility == .public),
        .ret_size = hf.ret_size,
        .ret_ptr_bearing = hf.ret_ptr_bearing,
    };
}

/// The single tail expression of a one-statement body block.
fn singleTail(body: *const hir.Stmt) ?*hir.Expr {
    const items = switch (body.*) {
        .block => |b| b,
        else => return null,
    };
    if (items.len != 1) return null;
    return switch (items[0].*) {
        .expr => |e| e,
        else => null,
    };
}

/// Does this HIR expression yield a `str` value? Used to route host-call
/// arguments to the str path (a (ptr, len) pair) vs the i64 path. A bare
/// `local` is str only when its binding type is `str`; `fmt_int` is the str of
/// an i64 (only appears inside concat today, but classify it as str for safety).
fn isStrExpr(e: *const hir.Expr) bool {
    return switch (e.*) {
        .str_const, .concat, .str_binding, .fmt_int, .fmt_float, .str_slice => true,
        .local => |l| l.ty == .str,
        else => false,
    };
}

/// Lower a `str`-valued expression to a `str`-typed MIR instruction.
fn lowerStrExpr(ctx: Ctx, e: *const hir.Expr) Error!*mir.Inst {
    switch (e.*) {
        .str_const => |bytes| {
            const off: u32 = @intCast(ctx.data.items.len);
            try ctx.data.appendSlice(ctx.a, bytes);
            return mk(ctx.a, .str, .{ .str_const_val = .{ .off = off, .len = @intCast(bytes.len) } });
        },
        .local => |l| return mk(ctx.a, .str, .{ .str_param = l.idx }),
        .call => |cl| {
            // Mixed argument kinds: a str value lowers to its (ptr, len)
            // pair, anything else (an i64, a record's `.ptr` receiver in
            // a fit-method call) through the scalar path.
            const args = try ctx.a.alloc(*mir.Inst, cl.args.len);
            for (cl.args, 0..) |arg, i| args[i] = if (isStrExpr(arg)) try lowerStrExpr(ctx, arg) else try lowerExpr(ctx, arg);
            return mk(ctx.a, .str, .{ .call = .{ .func = cl.func, .args = args } });
        },
        .concat => |pieces| {
            const ps = try ctx.a.alloc(*mir.Inst, pieces.len);
            for (pieces, 0..) |p, i| ps[i] = try lowerStrExpr(ctx, p);
            return mk(ctx.a, .str, .{ .str_concat = ps });
        },
        .str_binding => |sb| return mk(ctx.a, .str, .{ .str_binding = .{ .ptr_idx = sb.ptr_idx, .len_idx = sb.len_idx } }),
        .fmt_int => |inner| return mk(ctx.a, .str, .{ .fmt_int_to_str = try lowerExpr(ctx, inner) }),
        .fmt_float => |inner| return mk(ctx.a, .str, .{ .fmt_float_to_str = try lowerExpr(ctx, inner) }),
        // `s.slice(a, b)` -> str (ptr+a, b-a). str operand + two i64 bounds.
        .str_slice => |sl| return mk(ctx.a, .str, .{ .str_slice = .{ .str = try lowerStrExpr(ctx, sl.str), .start = try lowerExpr(ctx, sl.start), .end = try lowerExpr(ctx, sl.end) } }),
        // A `[str]` literal yields the `(data_ptr, count)` pair (str-shaped).
        .strlist_make => |inits| {
            const xs = try ctx.a.alloc(*mir.Inst, inits.len);
            for (inits, 0..) |it, i| xs[i] = try lowerStrExpr(ctx, it);
            return mk(ctx.a, .str, .{ .strlist_make = xs });
        },
        // `xs[i]` yields the i-th str element (a str value).
        .strlist_get => |g| return mk(ctx.a, .str, .{ .strlist_get = .{ .list = try lowerStrExpr(ctx, g.list), .idx = try lowerExpr(ctx, g.idx) } }),
        // `env.args` materializes the args as a `[str]` (str-shaped) value.
        .host_args => return mk(ctx.a, .str, .host_args),
        // `env.envvars.get(key)` yields the variable's value as a str.
        .envvar_get => |key| return mk(ctx.a, .str, .{ .envvar_get = .{ .key = try lowerStrExpr(ctx, key) } }),
        else => return error.Unsupported,
    }
}

/// Lower an i64 function block. With `want_value` the block yields an i64 —
/// its last statement is the tail (an expression, `return`, value-`if`, or a
/// diverging `loop`); earlier statements are setup. Mirrors the legacy
/// `emitIntBlock`. Returns `Unsupported` when a tail produces no value.
/// Lower a value/void block. `value_ty` is the type the block must produce
/// (the enclosing function's return type, or an `if`'s type) — `null` lowers
/// it as a void block (a loop/while body, a void `if` branch).
fn lowerIntBlock(ctx: Ctx, blk: *const hir.Stmt, value_ty: ?mir.ValueType) Error!*mir.Inst {
    const stmts = switch (blk.*) {
        .block => |s| s,
        else => return error.Unsupported,
    };

    var items: std.ArrayList(*mir.Inst) = .empty;
    const n = stmts.len;
    const tail_at: ?usize = if (value_ty != null and n > 0) n - 1 else null;

    for (stmts, 0..) |s, i| {
        if (tail_at != null and i == tail_at.?) continue;
        try lowerSetupStmt(ctx, s, &items);
    }

    const vty = value_ty orelse return mk(ctx.a, .void, .{ .block = try items.toOwnedSlice(ctx.a) });

    const tail = if (tail_at) |t| stmts[t] else return error.Unsupported;

    // A diverging `loop` tail: emit it, then `unreachable` so the block types
    // as the value type (it must exit via `return`).
    if (tail.* == .loop_) {
        try items.append(ctx.a, try lowerLoop(ctx, tail.loop_));
        try items.append(ctx.a, try mk(ctx.a, .void, .@"unreachable"));
        return mk(ctx.a, vty, .{ .block = try items.toOwnedSlice(ctx.a) });
    }

    const tail_val: *mir.Inst = switch (tail.*) {
        // A `str` value chain threads `str` through the tail (and, via
        // `lowerValueIf`, both if-branches) so a str-returning `match` lowers to
        // a pair-typed if-chain, not an i64 one.
        .expr => |e| if (vty == .str) try lowerStrExpr(ctx, e) else try lowerExpr(ctx, e),
        .ret => |e| if (vty == .str) try lowerStrExpr(ctx, e orelse return error.Unsupported) else try lowerExpr(ctx, e orelse return error.Unsupported),
        .if_ => |iff| try lowerValueIf(ctx, iff, vty),
        // A nested value block (a callee-tail `match` desugar: the
        // hidden scrutinee set + the value if-chain).
        .block => try lowerIntBlock(ctx, tail, vty),
        else => return error.Unsupported,
    };

    if (items.items.len == 0) return tail_val;
    try items.append(ctx.a, tail_val);
    return mk(ctx.a, vty, .{ .block = try items.toOwnedSlice(ctx.a) });
}

/// Lower a non-tail (void) statement. Shared with `lowerEntryStmt`, which
/// covers the same control-flow set plus `main`'s host statements.
fn lowerSetupStmt(ctx: Ctx, s: *const hir.Stmt, items: *std.ArrayList(*mir.Inst)) Error!void {
    try items.append(ctx.a, try lowerEntryStmt(ctx, s));
}

fn lowerLoop(ctx: Ctx, body_blk: *const hir.Stmt) Error!*mir.Inst {
    return mk(ctx.a, .void, .{ .loop = try lowerIntBlock(ctx, body_blk, null) });
}

fn lowerValueIf(ctx: Ctx, iff: anytype, vty: mir.ValueType) Error!*mir.Inst {
    const cond = try lowerCond(ctx, iff.cond);
    const then_ = try lowerIntBlock(ctx, iff.then_, vty);
    const else_ = try lowerIntBlock(ctx, iff.else_ orelse return error.Unsupported, vty);
    return mk(ctx.a, vty, .{ .if_ = .{ .cond = cond, .then_ = then_, .else_ = else_ } });
}

fn lowerVoidIf(ctx: Ctx, iff: anytype) Error!*mir.Inst {
    const cond = try lowerCond(ctx, iff.cond);
    const then_ = try lowerIntBlock(ctx, iff.then_, null);
    const else_: ?*mir.Inst = if (iff.else_) |eb| try lowerIntBlock(ctx, eb, null) else null;
    return mk(ctx.a, .void, .{ .if_ = .{ .cond = cond, .then_ = then_, .else_ = else_ } });
}

/// A condition lowers to an i32 (0/1). A comparison already yields i32; any
/// other i64 expression is truthiness-tested (`x != 0`).
fn lowerCond(ctx: Ctx, e: *const hir.Expr) Error!*mir.Inst {
    const inst = try lowerExpr(ctx, e);
    if (inst.ty == .i32) return inst;
    const zero = try mk(ctx.a, .i64, .{ .const_i64 = 0 });
    return mk(ctx.a, .i32, .{ .bin = .{ .kind = .ne, .lhs = inst, .rhs = zero } });
}

fn lowerExpr(ctx: Ctx, e: *const hir.Expr) Error!*mir.Inst {
    switch (e.*) {
        // `env.fs.read` yields a boxed Result<str, i64> base pointer.
        .fs_read => |fr| return mk(ctx.a, .ptr, .{ .fs_read = .{ .path = try lowerStrExpr(ctx, fr.path) } }),
        .kv_increment => |kv| return mk(ctx.a, .i64, .{ .kv_increment = .{
            .key = if (kv.key) |k| try lowerStrExpr(ctx, k) else null,
            .delta = try lowerExpr(ctx, kv.delta),
        } }),
        // set/get yield a boxed Result value (a `.ptr` to the arena box), like
        // fs_read — the whole result is decoded and boxed by the codegen.
        .kv_set => |kv| return mk(ctx.a, .ptr, .{ .kv_set = .{
            .key = try lowerStrExpr(ctx, kv.key),
            .value = try lowerStrExpr(ctx, kv.value),
        } }),
        .kv_get => |kv| return mk(ctx.a, .ptr, .{ .kv_get = .{ .key = try lowerStrExpr(ctx, kv.key) } }),
        .blob_put => |bl| return mk(ctx.a, .ptr, .{ .blob_put = .{
            .key = try lowerStrExpr(ctx, bl.key),
            .value = try lowerStrExpr(ctx, bl.value),
        } }),
        .blob_get => |bl| return mk(ctx.a, .ptr, .{ .blob_get = .{ .key = try lowerStrExpr(ctx, bl.key) } }),
        .blob_delete => |bl| return mk(ctx.a, .ptr, .{ .blob_delete = .{ .key = try lowerStrExpr(ctx, bl.key) } }),
        .db_execute => |db| return mk(ctx.a, .ptr, .{ .db_execute = .{ .sql = try lowerStrExpr(ctx, db.sql) } }),
        .db_query_value => |db| return mk(ctx.a, .ptr, .{ .db_query_value = .{ .sql = try lowerStrExpr(ctx, db.sql) } }),
        .db_query_text => |db| return mk(ctx.a, .ptr, .{ .db_query_text = .{ .sql = try lowerStrExpr(ctx, db.sql) } }),
        .config_get => |cf| return mk(ctx.a, .ptr, .{ .config_get = .{ .key = try lowerStrExpr(ctx, cf.key) } }),
        .time_monotonic_ns => return mk(ctx.a, .i64, .{ .time_monotonic_ns = {} }),
        .random_u64 => return mk(ctx.a, .i64, .{ .random_u64 = {} }),
        .time_resolution_ns => return mk(ctx.a, .i64, .{ .time_resolution_ns = {} }),
        .time_unix_ns => return mk(ctx.a, .i64, .{ .time_unix_ns = {} }),
        .chan_recv => |h| return mk(ctx.a, .i64, .{ .chan_recv = try lowerExpr(ctx, h) }),
        .chan_take => |h| return mk(ctx.a, .i64, .{ .chan_take = try lowerExpr(ctx, h) }),
        .chan_open => |name| return mk(ctx.a, .i64, .{ .chan_open = name }),
        .int_const => |v| return mk(ctx.a, .i64, .{ .const_i64 = v }),
        .float_const => |v| return mk(ctx.a, .f64, .{ .const_f64 = v }),
        .num_cast => |nc| return mk(ctx.a, mapType(nc.to), .{ .num_cast = try lowerExpr(ctx, nc.value) }),
        .bitcast => |bc| return mk(ctx.a, mapType(bc.to), .{ .bitcast = try lowerExpr(ctx, bc.value) }),
        .bool_const => |v| return mk(ctx.a, .i32, .{ .const_i32 = @intFromBool(v) }),
        .local => |l| return mk(ctx.a, mapType(l.ty), .{ .local_get = l.idx }),
        .global_get => |idx| return mk(ctx.a, .i64, .{ .global_get = idx }),
        .vec_new => return mk(ctx.a, .ptr, .vec_new),
        .vec_len => |vl| return mk(ctx.a, .i64, .{ .vec_len = .{ .vec = try lowerExpr(ctx, vl.vec) } }),
        .vec_ptr => |vp| return mk(ctx.a, .i64, .{ .vec_ptr = .{ .vec = try lowerExpr(ctx, vp.vec) } }),
        .vec_get => |vg| return mk(ctx.a, if (vg.cell4) .f32 else .i64, .{ .vec_get = .{ .vec = try lowerExpr(ctx, vg.vec), .idx = try lowerExpr(ctx, vg.idx), .cell4 = vg.cell4 } }),
        .simd_splat => |s| return mk(ctx.a, .v128, .{ .simd_splat = .{
            .shape = s.shape,
            .operand = try lowerExpr(ctx, s.operand),
        } }),
        // Extract yields the lane scalar: f32 for f32x4; i64 for i32x4 (the
        // backend sign-extends the i32 lane to the i64 compute floor).
        .simd_extract => |s| return mk(ctx.a, switch (s.shape) {
            .f32x4 => mir.ValueType.f32,
            .i32x4 => mir.ValueType.i64,
        }, .{ .simd_extract = .{
            .shape = s.shape,
            .vec = try lowerExpr(ctx, s.vec),
            .lane = s.lane,
        } }),
        .simd_bin => |s| return mk(ctx.a, .v128, .{ .simd_bin = .{
            .kind = s.kind,
            .shape = s.shape,
            .lhs = try lowerExpr(ctx, s.lhs),
            .rhs = try lowerExpr(ctx, s.rhs),
        } }),
        .un => |u| {
            // `not` yields a boolean (i32 0/1); `neg` preserves the
            // operand's numeric type (f64 stays f64); `bit_not` is i64.
            const operand = try lowerExpr(ctx, u.operand);
            const ty: mir.ValueType = switch (u.kind) {
                .not => .i32,
                // `neg` and the float-math builtins keep the operand's type.
                .neg, .fabs, .fsqrt, .ffloor, .fceil, .ftrunc, .fnearest => operand.ty,
                else => .i64,
            };
            return mk(ctx.a, ty, .{ .un = .{ .kind = u.kind, .operand = operand } });
        },
        .bin => |bx| {
            // A comparison yields i32 (0/1) whatever the operand type;
            // arithmetic keeps the operands' numeric type (the builder
            // guarantees both sides agree — no implicit conversion).
            const lhs = try lowerExpr(ctx, bx.lhs);
            const rhs = try lowerExpr(ctx, bx.rhs);
            const ty: mir.ValueType = if (isCmp(bx.kind)) .i32 else lhs.ty;
            return mk(ctx.a, ty, .{ .bin = .{ .kind = bx.kind, .lhs = lhs, .rhs = rhs } });
        },
        .logical => |lg| {
            // Short-circuit via a value `if_` (i32 0/1): `a && b` is
            // `if a { b } else { 0 }`; `a || b` is `if a { 1 } else { b }`.
            // Both operands are truthiness-tested so `b` need not be a 0/1.
            const lhs = try lowerCond(ctx, lg.lhs);
            const rhs = try lowerCond(ctx, lg.rhs);
            const lit = switch (lg.op) {
                .and_ => @as(i32, 0), // the false short-circuit result
                .or_ => @as(i32, 1), // the true short-circuit result
            };
            const konst = try mk(ctx.a, .i32, .{ .const_i32 = lit });
            const branches = switch (lg.op) {
                .and_ => .{ rhs, konst }, // then = rhs, else = 0
                .or_ => .{ konst, rhs }, // then = 1,   else = rhs
            };
            return mk(ctx.a, .i32, .{ .if_ = .{ .cond = lhs, .then_ = branches[0], .else_ = branches[1] } });
        },
        .call => |cl| {
            // A `str` argument lowers on the str path (a (ptr, len) pair
            // inst the backend expands to two operands) — mixed-signature
            // callees (`fn length_of(s: str) -> i64`) take both kinds.
            const args = try ctx.a.alloc(*mir.Inst, cl.args.len);
            for (cl.args, 0..) |arg, i| args[i] = if (isStrExpr(arg)) try lowerStrExpr(ctx, arg) else try lowerExpr(ctx, arg);
            // The call's value type follows the callee's return type (i64, or
            // i32 for a `-> bool`), so it validates against the callee sig.
            return mk(ctx.a, mapType(ctx.funcs[cl.func].ret), .{ .call = .{ .func = cl.func, .args = args } });
        },
        .foreign_call => |fc| {
            // A foreign import takes/returns scalars only (the canonical-ABI
            // boundary the WIT lift enforces): every arg lowers on the scalar
            // path, and the inst's value type is the import's WIT result type.
            const args = try ctx.a.alloc(*mir.Inst, fc.args.len);
            for (fc.args, 0..) |arg, i| args[i] = try lowerExpr(ctx, arg);
            return mk(ctx.a, mapType(fc.ret), .{ .foreign_call = .{ .module = fc.module, .field = fc.field, .args = args } });
        },
        // A materialized record: alloc in the scope arena, store the fields,
        // yield the base pointer. The store width rides on each value's type.
        .record_alloc => |ra| {
            const inits = try ctx.a.alloc(mir.FieldInit, ra.inits.len);
            for (ra.inits, 0..) |fi, i| inits[i] = .{ .offset = fi.offset, .width = storageOf(fi.ty).width, .value = try lowerExpr(ctx, fi.value) };
            const sinits = try ctx.a.alloc(mir.StrFieldInit, ra.str_inits.len);
            for (ra.str_inits, 0..) |si, i| sinits[i] = .{ .offset = si.offset, .value = try lowerStrExpr(ctx, si.value) };
            return mk(ctx.a, .ptr, .{ .record_make = .{ .size = ra.size, .alignment = ra.alignment, .inits = inits, .str_inits = sinits } });
        },
        .array_lit => |al| {
            const inits = try ctx.a.alloc(*mir.Inst, al.inits.len);
            for (al.inits, 0..) |e2, i| inits[i] = try lowerExpr(ctx, e2);
            return mk(ctx.a, .ptr, .{ .array_make = .{
                .stride = al.stride,
                .alignment = al.alignment,
                .elem_width = storageOf(al.elem_ty).width,
                .copy_bytes = al.copy_bytes,
                .inits = inits,
            } });
        },
        .elem_ptr => |ep| return mk(ctx.a, .ptr, .{ .elem_ptr = .{ .base = try lowerExpr(ctx, ep.base), .index = try lowerExpr(ctx, ep.index), .stride = ep.stride } }),
        .bounds_check => |bc| return mk(ctx.a, .i64, .{ .bounds_check = .{ .index = try lowerExpr(ctx, bc.index), .count = try lowerExpr(ctx, bc.count) } }),
        // A field read through the base pointer: the storage width and
        // signedness come from the declared field type; a narrow integer
        // widens (sign-/zero-extended) into the i64 compute floor.
        .field_get => |fg| {
            const st = storageOf(fg.ty);
            return mk(ctx.a, mapType(fg.ty), .{ .field_get = .{ .base = try lowerExpr(ctx, fg.base), .offset = fg.offset, .width = st.width, .signed = st.signed } });
        },
        // `s.len` — lower the str operand to its (ptr, len) value; the backend
        // reads the len component and zero-extends it to i64.
        // `[str]` values are str-shaped (a `(data_ptr, count)` pair); route to
        // the str lowering (a strlist in an i64 position is a type error caught
        // earlier).
        .strlist_make, .strlist_get, .host_args, .envvar_get => return lowerStrExpr(ctx, e),
        .str_len => |s| return mk(ctx.a, .i64, .{ .str_len = try lowerStrExpr(ctx, s) }),
        // `s[i]` — str operand to (ptr, len), idx to i64; backend loads the byte.
        .str_index => |si| return mk(ctx.a, .i64, .{ .str_index = .{ .str = try lowerStrExpr(ctx, si.str), .idx = try lowerExpr(ctx, si.idx) } }),
        // `a == b` on strs — both to (ptr, len); backend calls __str_eq -> i32.
        .str_eq => |se| return mk(ctx.a, .i32, .{ .str_eq = .{ .lhs = try lowerStrExpr(ctx, se.lhs), .rhs = try lowerStrExpr(ctx, se.rhs) } }),
        // str methods that yield i64/bool: index_of (i64), starts_with/contains (i32).
        .str_index_of => |m| return mk(ctx.a, .i64, .{ .str_index_of = .{ .str = try lowerStrExpr(ctx, m.str), .byte = try lowerExpr(ctx, m.byte) } }),
        .str_starts_with => |m| return mk(ctx.a, .i32, .{ .str_starts_with = .{ .str = try lowerStrExpr(ctx, m.str), .prefix = try lowerStrExpr(ctx, m.prefix) } }),
        .str_contains => |m| return mk(ctx.a, .i32, .{ .str_contains = .{ .str = try lowerStrExpr(ctx, m.str), .sub = try lowerStrExpr(ctx, m.sub) } }),
        .str_const, .concat, .str_binding, .fmt_int, .fmt_float, .str_slice => unreachable, // str values never reach the scalar path
    }
}

fn isCmp(k: hir.ops.BinKind) bool {
    return switch (k) {
        .eq, .ne, .lt, .le, .gt, .ge => true,
        else => false,
    };
}

fn mapType(t: hir.Type) mir.ValueType {
    return switch (t) {
        .i64 => .i64,
        .i32, .u32, .i16, .u16, .i8, .u8 => .i64, // narrow ints compute as i64 (storage width is a field concern)
        .f32 => .f32,
        .f64 => .f64,
        .f32x4, .i32x4 => .v128, // both lane shapes share the one wasm SIMD type
        .str => .str,
        .bool => .i32, // a boolean is an i32 0/1 at the executable tier
        .ptr => .ptr,
        .void => .void,
    };
}

/// The storage width (bytes) and load signedness of a field type, per
/// spec/memory.md §"Linear struct layout".
fn storageOf(t: hir.Type) struct { width: u8, signed: bool } {
    return switch (t) {
        .i64 => .{ .width = 8, .signed = true },
        .f64 => .{ .width = 8, .signed = true },
        .f32 => .{ .width = 4, .signed = true },
        .i32 => .{ .width = 4, .signed = true },
        .u32 => .{ .width = 4, .signed = false },
        .i16 => .{ .width = 2, .signed = true },
        .u16 => .{ .width = 2, .signed = false },
        .i8 => .{ .width = 1, .signed = true },
        .u8 => .{ .width = 1, .signed = false },
        .bool => .{ .width = 1, .signed = false },
        // SIMD values are not v0 field types (no record/array storage yet).
        .f32x4, .i32x4 => .{ .width = 16, .signed = false },
        .str, .ptr, .void => .{ .width = 8, .signed = true }, // not field types; unreachable in practice
    };
}

fn mk(a: std.mem.Allocator, ty: mir.ValueType, op: mir.Op) Error!*mir.Inst {
    const inst = try a.create(mir.Inst);
    inst.* = .{ .ty = ty, .op = op };
    return inst;
}

// ---------------------------------------------------------------------
// Tests (pure Zig — no Binaryen).
// ---------------------------------------------------------------------
const testing = std.testing;
const parser = @import("parser");
const build_hir = @import("build_hir.zig");
const print = @import("print.zig");

test "lower: literals fold into the memory image with newlines" {
    const noLib: hir.ModuleResolver = .{ .ctx = undefined, .lookupFn = struct {
        fn f(_: *anyopaque, _: u32, _: []const u8) ?hir.Resolved {
            return null;
        }
    }.f };
    const pr = try parser.parse.parse(testing.allocator, "fn main {\n env.out(\"one\")\n env.out(\"two\")\n}\n", "<t>");
    defer pr.deinit(testing.allocator);
    const sf = parser.ast.SourceFile.cast(pr.root).?;
    var h = switch (try build_hir.tryBuild(testing.allocator, sf, noLib, &.{})) {
        .module => |m| m,
        else => return error.TestUnexpectedResult,
    };
    defer h.deinit();

    var m = try lower(testing.allocator, &h);
    defer m.deinit();
    try testing.expectEqualStrings("one\ntwo\n", m.data);
    const dump = try print.mirToString(testing.allocator, &m);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "host_out_const off=0 len=4") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "host_out_const off=4 len=4") != null);
}

test "lower: a [str] literal lowers to strlist_make + strlist_get" {
    const noLib: hir.ModuleResolver = .{ .ctx = undefined, .lookupFn = struct {
        fn f(_: *anyopaque, _: u32, _: []const u8) ?hir.Resolved {
            return null;
        }
    }.f };
    const pr = try parser.parse.parse(testing.allocator, "fn main {\n let xs = [\"a\", \"b\"]\n env.out(xs[1])\n}\n", "<t>");
    defer pr.deinit(testing.allocator);
    const sf = parser.ast.SourceFile.cast(pr.root).?;
    var h = switch (try build_hir.tryBuild(testing.allocator, sf, noLib, &.{})) {
        .module => |m| m,
        else => return error.TestUnexpectedResult,
    };
    defer h.deinit();

    var m = try lower(testing.allocator, &h);
    defer m.deinit();
    const dump = try print.mirToString(testing.allocator, &m);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "strlist_make n=2") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "strlist_get") != null);
}

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
    fn lookup(ctx: *anyopaque, scope: u32, name: []const u8) ?hir.Resolved {
        _ = scope;
        const self: *TestResolver = @ptrCast(@alignCast(ctx));
        for (self.results.items) |r| {
            const sf = parser.ast.SourceFile.cast(r.root) orelse continue;
            var it = sf.items();
            while (it.next()) |item| switch (item) {
                .fn_decl => |fd| {
                    const nm = fd.name() orelse continue;
                    if (std.mem.eql(u8, nm.text, name)) return .{ .fd = fd, .scope = 0 };
                },
                else => {},
            };
        }
        return null;
    }
    fn resolver(self: *TestResolver) hir.ModuleResolver {
        return .{ .ctx = self, .lookupFn = TestResolver.lookup };
    }
};

test "lower: an i64 binding in main becomes a local_set in _start" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    try tr.addLib("pub fn double(n: i64) -> i64 { n + n }\n");

    const pr = try parser.parse.parse(testing.allocator,
        "fn main {\n let a = double(21)\n env.out(a)\n}\n", "<t>");
    defer pr.deinit(testing.allocator);
    const sf = parser.ast.SourceFile.cast(pr.root).?;
    var h = switch (try build_hir.tryBuild(testing.allocator, sf, tr.resolver(), &.{})) {
        .module => |m| m,
        else => return error.TestUnexpectedResult,
    };
    defer h.deinit();

    var m = try lower(testing.allocator, &h);
    defer m.deinit();
    const dump = try print.mirToString(testing.allocator, &m);
    defer testing.allocator.free(dump);
    // The entry has a `local_set 0` from the call's result, then a host_out_int.
    try testing.expect(std.mem.indexOf(u8, dump, "local_set 0") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "host_out_int") != null);
}

test "lower: i64 binding interpolation lowers to fmt_int_to_str inside str_concat" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    try tr.addLib("pub fn double(n: i64) -> i64 { n + n }\n");

    const pr = try parser.parse.parse(testing.allocator,
        "fn main {\n let a = double(21)\n env.out(\"a={a}\")\n}\n", "<t>");
    defer pr.deinit(testing.allocator);
    const sf = parser.ast.SourceFile.cast(pr.root).?;
    var h = switch (try build_hir.tryBuild(testing.allocator, sf, tr.resolver(), &.{})) {
        .module => |m| m,
        else => return error.TestUnexpectedResult,
    };
    defer h.deinit();

    var m = try lower(testing.allocator, &h);
    defer m.deinit();
    const dump = try print.mirToString(testing.allocator, &m);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "str_concat") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "fmt_int_to_str") != null);
    // The fmt_int_to_str wraps a local_get of the binding's local (idx 0).
    try testing.expect(std.mem.indexOf(u8, dump, "local_get 0") != null);
}

test "lower: `!` in an if-condition lowers to a `un not` over the comparison" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    try tr.addLib("pub fn nonzero(n: i64) -> i64 { if !(n == 0) { 1 } else { 0 } }\n");

    const pr = try parser.parse.parse(testing.allocator,
        "fn main {\n env.out(nonzero(7))\n}\n", "<t>");
    defer pr.deinit(testing.allocator);
    const sf = parser.ast.SourceFile.cast(pr.root).?;
    var h = switch (try build_hir.tryBuild(testing.allocator, sf, tr.resolver(), &.{})) {
        .module => |m| m,
        else => return error.TestUnexpectedResult,
    };
    defer h.deinit();

    var m = try lower(testing.allocator, &h);
    defer m.deinit();
    const dump = try print.mirToString(testing.allocator, &m);
    defer testing.allocator.free(dump);
    // The `!` survives lowering as a `un not`, wrapping the `bin eq`. The
    // condition is used directly (lowerCond keeps an i32 as-is — see the
    // `un not` result type), so there is no extra `!= 0` truthiness wrap.
    try testing.expect(std.mem.indexOf(u8, dump, "un not") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "bin eq") != null);
}

test "lower: `&&` lowers to a short-circuit `if_` with a const_i32 false leaf" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    try tr.addLib("pub fn both(a: i64, b: i64) -> i64 { if a > 0 && b > 0 { 1 } else { 0 } }\n");

    const pr = try parser.parse.parse(testing.allocator,
        "fn main {\n env.out(both(1, 1))\n}\n", "<t>");
    defer pr.deinit(testing.allocator);
    const sf = parser.ast.SourceFile.cast(pr.root).?;
    var h = switch (try build_hir.tryBuild(testing.allocator, sf, tr.resolver(), &.{})) {
        .module => |m| m,
        else => return error.TestUnexpectedResult,
    };
    defer h.deinit();

    var m = try lower(testing.allocator, &h);
    defer m.deinit();
    const dump = try print.mirToString(testing.allocator, &m);
    defer testing.allocator.free(dump);
    // The `&&` becomes a value `if : i32` whose else-leaf is the false 0/1
    // constant — there is no backend binary op for it.
    try testing.expect(std.mem.indexOf(u8, dump, "if : i32") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "const_i32 0") != null);
}

test "lower: env.out(<bool>) interns true/false and lowers to a void if" {
    var tr = TestResolver{ .a = testing.allocator };
    defer tr.deinit();
    try tr.addLib("pub fn is_even(n: i64) -> bool { n % 2 == 0 }\n");

    const pr = try parser.parse.parse(testing.allocator,
        "fn main {\n env.out(is_even(4))\n}\n", "<t>");
    defer pr.deinit(testing.allocator);
    const sf = parser.ast.SourceFile.cast(pr.root).?;
    var h = switch (try build_hir.tryBuild(testing.allocator, sf, tr.resolver(), &.{})) {
        .module => |m| m,
        else => return error.TestUnexpectedResult,
    };
    defer h.deinit();

    var m = try lower(testing.allocator, &h);
    defer m.deinit();
    // "true" and "false" (with trailing newlines) are folded into the image.
    try testing.expect(std.mem.indexOf(u8, m.data, "true\n") != null);
    try testing.expect(std.mem.indexOf(u8, m.data, "false\n") != null);
    // The callee lowers with an i32 (bool) return type.
    var saw_bool_ret = false;
    for (m.funcs) |f| {
        if (std.mem.eql(u8, f.name, "is_even")) saw_bool_ret = (f.ret == .i32);
    }
    try testing.expect(saw_bool_ret);
}

test "lower: a materialized record lowers to record_make + field_get loads" {
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
        \\}
        \\
    ;
    try tr.addLib(src);
    const pr = try parser.parse.parse(testing.allocator, src, "<t>");
    defer pr.deinit(testing.allocator);
    const sf = parser.ast.SourceFile.cast(pr.root).?;
    var h = switch (try build_hir.tryBuild(testing.allocator, sf, tr.resolver(), &.{})) {
        .module => |m| m,
        else => return error.TestUnexpectedResult,
    };
    defer h.deinit();

    var m = try lower(testing.allocator, &h);
    defer m.deinit();
    const dump = try print.mirToString(testing.allocator, &m);
    defer testing.allocator.free(dump);
    // The literal allocates 16 aligned bytes; field reads are typed loads.
    try testing.expect(std.mem.indexOf(u8, dump, "record_make size=16 align=8") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "field_get +8 : i64") != null);
}
