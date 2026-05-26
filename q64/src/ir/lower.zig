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

pub const Error = std.mem.Allocator.Error;

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
    const a = mod.alloc();

    var data: std.ArrayList(u8) = .empty;
    var nl_off: ?u32 = null;
    const ctx = Ctx{ .a = a, .data = &data, .nl_off = &nl_off };

    const funcs = try a.alloc(mir.Func, h.funcs.len);
    for (h.funcs, 0..) |hf, i| {
        const is_entry = (h.entry != null and h.entry.? == i);
        if (is_entry) {
            funcs[i] = .{
                .name = "start",
                .ret = .void,
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
        else => unreachable, // main has no value/tail statements
    }
}

fn lowerCallee(ctx: Ctx, hf: hir.Func) Error!mir.Func {
    const params = try ctx.a.alloc(mir.ValueType, hf.params.len);
    for (hf.params, 0..) |p, i| params[i] = mapType(p.ty);
    const locals = try ctx.a.alloc(mir.ValueType, hf.locals.len);
    for (hf.locals, 0..) |t, i| locals[i] = mapType(t);

    // v0 callee body is a single `value` tail expression.
    const tail = singleValue(hf.body) orelse unreachable;
    const body = try lowerExpr(ctx, tail);

    return .{
        .name = try ctx.a.dupeZ(u8, hf.name),
        .params = params,
        .ret = mapType(hf.ret),
        .locals = locals,
        .body = .{ .structured = body },
        .linkage = .local,
    };
}

fn singleValue(body: *const hir.Stmt) ?*hir.Expr {
    const items = switch (body.*) {
        .block => |b| b,
        else => return null,
    };
    if (items.len != 1) return null;
    return switch (items[0].*) {
        .value => |e| e,
        else => null,
    };
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
        .str_const => unreachable, // strings only appear under host_out
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
        .void => .void,
        .str => unreachable, // str locals/params land with the string-ABI phase
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
