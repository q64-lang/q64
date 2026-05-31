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
        // The entry and any `is_screen` function (e.g. `on_press`) share the
        // entry lowering: their bodies are screen statements (host_call / global
        // assign / let), which `lowerEntryStmt` handles. Other functions are
        // i64/str callees.
        if (is_entry or hf.is_screen) {
            const params = try a.alloc(mir.ValueType, hf.params.len);
            for (hf.params, 0..) |p, j| params[j] = mapType(p.ty);
            const locals = try a.alloc(mir.ValueType, hf.locals.len);
            for (hf.locals, 0..) |t, j| locals[j] = mapType(t);
            funcs[i] = .{
                .name = if (is_entry) "start" else try a.dupeZ(u8, hf.name),
                .params = params,
                .ret = .void,
                .locals = locals,
                .body = .{ .structured = try lowerEntry(ctx, hf.body) },
                .linkage = if (is_entry) .entry else .local,
                .exported = (!is_entry and hf.visibility == .public),
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
        .host_out => |e| {
            // env.out("X") writes "X\n": fold value + newline into `data`.
            const bytes = switch (e.*) {
                .str_const => |b| b,
                else => unreachable,
            };
            return hostOutConst(ctx, bytes);
        },
        .host_out_int => |e| {
            const nl = try ctx.newline();
            return mk(ctx.a, .void, .{ .host_out_int = .{ .value = try lowerExpr(ctx, e), .nl_off = nl } });
        },
        .host_out_str => |e| {
            const nl = try ctx.newline();
            return mk(ctx.a, .void, .{ .host_out_str = .{ .value = try lowerStrExpr(ctx, e), .nl_off = nl } });
        },
        .host_out_bool => |e| {
            // `env.out(<bool>)` → `if e { out("true") } else { out("false") }`.
            const cond = try lowerCond(ctx, e);
            return mk(ctx.a, .void, .{ .if_ = .{
                .cond = cond,
                .then_ = try hostOutConst(ctx, "true"),
                .else_ = try hostOutConst(ctx, "false"),
            } });
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
        else => return error.Unsupported, // a value/tail-only statement (e.g. bare expr)
    }
}

/// Fold `bytes` + a trailing newline into the data image and emit the
/// `env.out` of that constant run (the `env.out("X")` shape).
fn hostOutConst(ctx: Ctx, bytes: []const u8) Error!*mir.Inst {
    const off: u32 = @intCast(ctx.data.items.len);
    try ctx.data.appendSlice(ctx.a, bytes);
    try ctx.data.append(ctx.a, '\n');
    return mk(ctx.a, .void, .{ .host_out_const = .{ .off = off, .len = @intCast(bytes.len + 1) } });
}

fn lowerCallee(ctx: Ctx, hf: hir.Func) Error!mir.Func {
    const params = try ctx.a.alloc(mir.ValueType, hf.params.len);
    for (hf.params, 0..) |p, i| params[i] = mapType(p.ty);
    const locals = try ctx.a.alloc(mir.ValueType, hf.locals.len);
    for (hf.locals, 0..) |t, i| locals[i] = mapType(t);

    const body = switch (hf.ret) {
        .str => try lowerStrExpr(ctx, singleTail(hf.body) orelse return error.Unsupported),
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
        .str_const, .concat, .str_binding, .fmt_int => true,
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
            const args = try ctx.a.alloc(*mir.Inst, cl.args.len);
            for (cl.args, 0..) |arg, i| args[i] = try lowerStrExpr(ctx, arg);
            return mk(ctx.a, .str, .{ .call = .{ .func = cl.func, .args = args } });
        },
        .concat => |pieces| {
            const ps = try ctx.a.alloc(*mir.Inst, pieces.len);
            for (pieces, 0..) |p, i| ps[i] = try lowerStrExpr(ctx, p);
            return mk(ctx.a, .str, .{ .str_concat = ps });
        },
        .str_binding => |sb| return mk(ctx.a, .str, .{ .str_binding = .{ .ptr_idx = sb.ptr_idx, .len_idx = sb.len_idx } }),
        .fmt_int => |inner| return mk(ctx.a, .str, .{ .fmt_int_to_str = try lowerExpr(ctx, inner) }),
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
        .expr => |e| try lowerExpr(ctx, e),
        .ret => |e| try lowerExpr(ctx, e orelse return error.Unsupported),
        .if_ => |iff| try lowerValueIf(ctx, iff, vty),
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
        .int_const => |v| return mk(ctx.a, .i64, .{ .const_i64 = v }),
        .bool_const => |v| return mk(ctx.a, .i32, .{ .const_i32 = @intFromBool(v) }),
        .local => |l| return mk(ctx.a, mapType(l.ty), .{ .local_get = l.idx }),
        .global_get => |idx| return mk(ctx.a, .i64, .{ .global_get = idx }),
        .un => |u| {
            // `not` yields a boolean (i32 0/1); `neg`/`bit_not` preserve i64.
            const ty: mir.ValueType = if (u.kind == .not) .i32 else .i64;
            return mk(ctx.a, ty, .{ .un = .{ .kind = u.kind, .operand = try lowerExpr(ctx, u.operand) } });
        },
        .bin => |bx| {
            const ty: mir.ValueType = if (isCmp(bx.kind)) .i32 else .i64;
            return mk(ctx.a, ty, .{ .bin = .{
                .kind = bx.kind,
                .lhs = try lowerExpr(ctx, bx.lhs),
                .rhs = try lowerExpr(ctx, bx.rhs),
            } });
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
            const args = try ctx.a.alloc(*mir.Inst, cl.args.len);
            for (cl.args, 0..) |arg, i| args[i] = try lowerExpr(ctx, arg);
            // The call's value type follows the callee's return type (i64, or
            // i32 for a `-> bool`), so it validates against the callee sig.
            return mk(ctx.a, mapType(ctx.funcs[cl.func].ret), .{ .call = .{ .func = cl.func, .args = args } });
        },
        // `s.len` — lower the str operand to its (ptr, len) value; the backend
        // reads the len component and zero-extends it to i64.
        .str_len => |s| return mk(ctx.a, .i64, .{ .str_len = try lowerStrExpr(ctx, s) }),
        // `s[i]` — str operand to (ptr, len), idx to i64; backend loads the byte.
        .str_index => |si| return mk(ctx.a, .i64, .{ .str_index = .{ .str = try lowerStrExpr(ctx, si.str), .idx = try lowerExpr(ctx, si.idx) } }),
        // `a == b` on strs — both to (ptr, len); backend calls __str_eq -> i32.
        .str_eq => |se| return mk(ctx.a, .i32, .{ .str_eq = .{ .lhs = try lowerStrExpr(ctx, se.lhs), .rhs = try lowerStrExpr(ctx, se.rhs) } }),
        .str_const, .concat, .str_binding, .fmt_int => unreachable, // str values never reach the i64 path
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
        .i32 => .i32,
        .f64 => .f64,
        .str => .str,
        .bool => .i32, // a boolean is an i32 0/1 at the executable tier
        .ptr => .ptr,
        .void => .void,
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
        fn f(_: *anyopaque, _: []const u8) ?parser.ast.FnDecl {
            return null;
        }
    }.f };
    const pr = try parser.parse.parse(testing.allocator, "fn main {\n env.out(\"one\")\n env.out(\"two\")\n}\n", "<t>");
    defer pr.deinit(testing.allocator);
    const sf = parser.ast.SourceFile.cast(pr.root).?;
    var h = switch (try build_hir.tryBuild(testing.allocator, sf, noLib)) {
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
    fn lookup(ctx: *anyopaque, name: []const u8) ?parser.ast.FnDecl {
        const self: *TestResolver = @ptrCast(@alignCast(ctx));
        for (self.results.items) |r| {
            const sf = parser.ast.SourceFile.cast(r.root) orelse continue;
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
    var h = switch (try build_hir.tryBuild(testing.allocator, sf, tr.resolver())) {
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
    var h = switch (try build_hir.tryBuild(testing.allocator, sf, tr.resolver())) {
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
    var h = switch (try build_hir.tryBuild(testing.allocator, sf, tr.resolver())) {
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
    var h = switch (try build_hir.tryBuild(testing.allocator, sf, tr.resolver())) {
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
    var h = switch (try build_hir.tryBuild(testing.allocator, sf, tr.resolver())) {
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
