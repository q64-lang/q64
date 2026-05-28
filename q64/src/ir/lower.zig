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
    const ctx = Ctx{ .a = a, .data = &data, .nl_off = &nl_off };

    const funcs = try a.alloc(mir.Func, h.funcs.len);
    for (h.funcs, 0..) |hf, i| {
        const is_entry = (h.entry != null and h.entry.? == i);
        if (is_entry) {
            const locals = try a.alloc(mir.ValueType, hf.locals.len);
            for (hf.locals, 0..) |t, j| locals[j] = mapType(t);
            funcs[i] = .{
                .name = "start",
                .ret = .void,
                .locals = locals,
                .body = .{ .structured = try lowerEntry(ctx, hf.body) },
                .linkage = .entry,
            };
        } else {
            funcs[i] = try lowerCallee(ctx, hf);
        }
    }

    mod.funcs = funcs;
    mod.entry = h.entry;
    mod.data = try data.toOwnedSlice(a);
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
            const off: u32 = @intCast(ctx.data.items.len);
            try ctx.data.appendSlice(ctx.a, bytes);
            try ctx.data.append(ctx.a, '\n');
            return mk(ctx.a, .void, .{ .host_out_const = .{ .off = off, .len = @intCast(bytes.len + 1) } });
        },
        .host_out_int => |e| {
            const nl = try ctx.newline();
            return mk(ctx.a, .void, .{ .host_out_int = .{ .value = try lowerExpr(ctx, e), .nl_off = nl } });
        },
        .host_out_str => |e| {
            const nl = try ctx.newline();
            return mk(ctx.a, .void, .{ .host_out_str = .{ .value = try lowerStrExpr(ctx, e), .nl_off = nl } });
        },
        .str_let => |sl| return mk(ctx.a, .void, .{ .str_bind = .{ .ptr_idx = sl.ptr_idx, .len_idx = sl.len_idx, .value = try lowerStrExpr(ctx, sl.value) } }),
        .let => |l| return mk(ctx.a, .void, .{ .local_set = .{ .idx = l.idx, .value = try lowerExpr(ctx, l.value) } }),
        else => unreachable, // main has no value/tail statements
    }
}

fn lowerCallee(ctx: Ctx, hf: hir.Func) Error!mir.Func {
    const params = try ctx.a.alloc(mir.ValueType, hf.params.len);
    for (hf.params, 0..) |p, i| params[i] = mapType(p.ty);
    const locals = try ctx.a.alloc(mir.ValueType, hf.locals.len);
    for (hf.locals, 0..) |t, i| locals[i] = mapType(t);

    const body = switch (hf.ret) {
        .str => try lowerStrExpr(ctx, singleTail(hf.body) orelse return error.Unsupported),
        else => try lowerIntBlock(ctx, hf.body, true),
    };

    return .{
        .name = try ctx.a.dupeZ(u8, hf.name),
        .params = params,
        .ret = mapType(hf.ret),
        .locals = locals,
        .body = .{ .structured = body },
        .linkage = .local,
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

/// Lower a `str`-valued expression to a `str`-typed MIR instruction.
fn lowerStrExpr(ctx: Ctx, e: *const hir.Expr) Error!*mir.Inst {
    switch (e.*) {
        .str_const => |bytes| {
            const off: u32 = @intCast(ctx.data.items.len);
            try ctx.data.appendSlice(ctx.a, bytes);
            return mk(ctx.a, .str, .{ .str_const_val = .{ .off = off, .len = @intCast(bytes.len) } });
        },
        .local => |idx| return mk(ctx.a, .str, .{ .str_param = idx }),
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
fn lowerIntBlock(ctx: Ctx, blk: *const hir.Stmt, want_value: bool) Error!*mir.Inst {
    const stmts = switch (blk.*) {
        .block => |s| s,
        else => return error.Unsupported,
    };

    var items: std.ArrayList(*mir.Inst) = .empty;
    const n = stmts.len;
    const tail_at: ?usize = if (want_value and n > 0) n - 1 else null;

    for (stmts, 0..) |s, i| {
        if (tail_at != null and i == tail_at.?) continue;
        try lowerSetupStmt(ctx, s, &items);
    }

    if (!want_value) return mk(ctx.a, .void, .{ .block = try items.toOwnedSlice(ctx.a) });

    const tail = if (tail_at) |t| stmts[t] else return error.Unsupported;

    // A diverging `loop` tail: emit it, then `unreachable` so the block types
    // as i64 (it must exit via `return`).
    if (tail.* == .loop_) {
        try items.append(ctx.a, try lowerLoop(ctx, tail.loop_));
        try items.append(ctx.a, try mk(ctx.a, .void, .@"unreachable"));
        return mk(ctx.a, .i64, .{ .block = try items.toOwnedSlice(ctx.a) });
    }

    const tail_val: *mir.Inst = switch (tail.*) {
        .expr => |e| try lowerExpr(ctx, e),
        .ret => |e| try lowerExpr(ctx, e orelse return error.Unsupported),
        .if_ => |iff| try lowerValueIf(ctx, iff),
        else => return error.Unsupported,
    };

    if (items.items.len == 0) return tail_val;
    try items.append(ctx.a, tail_val);
    return mk(ctx.a, .i64, .{ .block = try items.toOwnedSlice(ctx.a) });
}

fn lowerSetupStmt(ctx: Ctx, s: *const hir.Stmt, items: *std.ArrayList(*mir.Inst)) Error!void {
    switch (s.*) {
        .let => |l| try items.append(ctx.a, try mk(ctx.a, .void, .{ .local_set = .{ .idx = l.idx, .value = try lowerExpr(ctx, l.value) } })),
        .assign => |as| try items.append(ctx.a, try mk(ctx.a, .void, .{ .local_set = .{ .idx = as.idx, .value = try lowerExpr(ctx, as.value) } })),
        .while_ => |w| try items.append(ctx.a, try mk(ctx.a, .void, .{ .while_ = .{ .cond = try lowerCond(ctx, w.cond), .body = try lowerIntBlock(ctx, w.body, false) } })),
        .loop_ => try items.append(ctx.a, try lowerLoop(ctx, s.loop_)),
        .if_ => |iff| try items.append(ctx.a, try lowerVoidIf(ctx, iff)),
        .ret => |e| try items.append(ctx.a, try mk(ctx.a, .void, .{ .ret = if (e) |val| try lowerExpr(ctx, val) else null })),
        .brk => try items.append(ctx.a, try mk(ctx.a, .void, .br)),
        .cont => try items.append(ctx.a, try mk(ctx.a, .void, .br_cont)),
        else => return error.Unsupported, // a non-tail bare expr has no value consumer
    }
}

fn lowerLoop(ctx: Ctx, body_blk: *const hir.Stmt) Error!*mir.Inst {
    return mk(ctx.a, .void, .{ .loop = try lowerIntBlock(ctx, body_blk, false) });
}

fn lowerValueIf(ctx: Ctx, iff: anytype) Error!*mir.Inst {
    const cond = try lowerCond(ctx, iff.cond);
    const then_ = try lowerIntBlock(ctx, iff.then_, true);
    const else_ = try lowerIntBlock(ctx, iff.else_ orelse return error.Unsupported, true);
    return mk(ctx.a, .i64, .{ .if_ = .{ .cond = cond, .then_ = then_, .else_ = else_ } });
}

fn lowerVoidIf(ctx: Ctx, iff: anytype) Error!*mir.Inst {
    const cond = try lowerCond(ctx, iff.cond);
    const then_ = try lowerIntBlock(ctx, iff.then_, false);
    const else_: ?*mir.Inst = if (iff.else_) |eb| try lowerIntBlock(ctx, eb, false) else null;
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
        .local => |idx| return mk(ctx.a, .i64, .{ .local_get = idx }),
        .un => |u| return mk(ctx.a, .i64, .{ .un = .{ .kind = u.kind, .operand = try lowerExpr(ctx, u.operand) } }),
        .bin => |bx| {
            const ty: mir.ValueType = if (isCmp(bx.kind)) .i32 else .i64;
            return mk(ctx.a, ty, .{ .bin = .{
                .kind = bx.kind,
                .lhs = try lowerExpr(ctx, bx.lhs),
                .rhs = try lowerExpr(ctx, bx.rhs),
            } });
        },
        .call => |cl| {
            const args = try ctx.a.alloc(*mir.Inst, cl.args.len);
            for (cl.args, 0..) |arg, i| args[i] = try lowerExpr(ctx, arg);
            return mk(ctx.a, .i64, .{ .call = .{ .func = cl.func, .args = args } });
        },
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
    var h = (try build_hir.tryBuild(testing.allocator, sf, noLib)).?;
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
    var h = (try build_hir.tryBuild(testing.allocator, sf, tr.resolver())).?;
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
    var h = (try build_hir.tryBuild(testing.allocator, sf, tr.resolver())).?;
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
