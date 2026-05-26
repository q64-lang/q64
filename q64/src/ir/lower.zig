//! HIR → MIR lowering (the middle boundary of the Q64 IR).
//!
//! Imports `hir`/`mir` only — NEVER the Binaryen C API. Turns the semantic
//! HIR into the executable MIR: this is where the `str` ABI, the region/
//! allocator model, interpolation→arena plans, and int→string formatting
//! become explicit. The MIR it produces is the direct input to a backend.
//!
//! Migration status: v0 lowers the literal `env.out` path — each
//! `host_out(str_const "X")` becomes the bytes `"X\n"` in the memory image
//! plus a `host_out_const` op (env.out's trailing newline is added here,
//! since it is an execution-time detail of the capability ABI). Later phases
//! lower i64 bodies, calls, and the string-concat arena ops.

const std = @import("std");
const hir = @import("hir.zig");
const mir = @import("mir.zig");

pub const Error = std.mem.Allocator.Error;

/// Lower a whole HIR module to MIR. The result owns its own arena.
pub fn lower(gpa: std.mem.Allocator, h: *const hir.Module) Error!mir.Module {
    var mod = mir.Module.init(gpa);
    const a = mod.alloc();

    var data: std.ArrayList(u8) = .empty;

    const funcs = try a.alloc(mir.Func, h.funcs.len);
    for (h.funcs, 0..) |hf, i| {
        const is_entry = (h.entry != null and h.entry.? == i);
        const body = try lowerStmt(a, hf.body, &data);
        funcs[i] = .{
            .name = if (is_entry) "start" else try a.dupeZ(u8, hf.name),
            .ret = .void,
            // Structured is the only form the lowering produces; the `cfg`
            // escape hatch on Body is for a future basic-block backend.
            .body = .{ .structured = body },
            .linkage = if (is_entry) .entry else .local,
        };
    }

    mod.funcs = funcs;
    mod.entry = h.entry;
    mod.data = try data.toOwnedSlice(a);
    return mod;
}

fn lowerStmt(a: std.mem.Allocator, s: *const hir.Stmt, data: *std.ArrayList(u8)) Error!*mir.Inst {
    switch (s.*) {
        .block => |items| {
            const out = try a.alloc(*mir.Inst, items.len);
            for (items, 0..) |child, i| out[i] = try lowerStmt(a, child, data);
            return mk(a, .void, .{ .block = out });
        },
        .host_out => |e| {
            // env.out("X") writes "X\n": fold the value + newline into the
            // memory image and reference it as a constant.
            const bytes = switch (e.*) {
                .str_const => |b| b,
            };
            const off: u32 = @intCast(data.items.len);
            try data.appendSlice(a, bytes);
            try data.append(a, '\n');
            const len: u32 = @intCast(bytes.len + 1);
            return mk(a, .void, .{ .host_out_const = .{ .off = off, .len = len } });
        },
    }
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

fn lowerSource(gpa: std.mem.Allocator, source: []const u8) !?mir.Module {
    const pr = try parser.parse.parse(gpa, source, "<test>");
    defer pr.deinit(gpa);
    const sf = parser.ast.SourceFile.cast(pr.root) orelse return null;
    var h = (try build_hir.tryBuild(gpa, sf)) orelse return null;
    defer h.deinit();
    return try lower(gpa, &h);
}

test "lower: literals fold into the memory image with newlines" {
    var m = (try lowerSource(testing.allocator, "fn main {\n env.out(\"one\")\n env.out(\"two\")\n}\n")) orelse
        return error.TestUnexpectedResult;
    defer m.deinit();

    // "one\n" then "two\n" laid out contiguously at offset 0.
    try testing.expectEqualStrings("one\ntwo\n", m.data);
    try testing.expect(m.entry != null);

    const dump = try print.mirToString(testing.allocator, &m);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "host_out_const off=0 len=4") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "host_out_const off=4 len=4") != null);
}
