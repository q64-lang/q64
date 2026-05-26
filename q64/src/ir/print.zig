//! Text dumpers for HIR and MIR — for golden tests and a future
//! `q64 show hir|mir`. Pure Zig; no Binaryen. The format is for humans and
//! tests, not a stable serialization.

const std = @import("std");
const hir = @import("hir.zig");
const mir = @import("mir.zig");

const Buf = std.ArrayList(u8);
const Error = std.mem.Allocator.Error;

pub fn hirToString(gpa: std.mem.Allocator, m: *const hir.Module) Error![]u8 {
    var out: Buf = .empty;
    errdefer out.deinit(gpa);
    for (m.funcs, 0..) |f, i| {
        const marker = if (m.entry != null and m.entry.? == i) " [entry]" else "";
        try app(gpa, &out, "fn {s} -> {s}{s}\n", .{ f.name, @tagName(f.ret), marker });
        try hirStmt(gpa, &out, f.body, 1);
    }
    return out.toOwnedSlice(gpa);
}

fn hirStmt(gpa: std.mem.Allocator, out: *Buf, s: *const hir.Stmt, depth: usize) Error!void {
    try indent(gpa, out, depth);
    switch (s.*) {
        .block => |items| {
            try app(gpa, out, "block\n", .{});
            for (items) |child| try hirStmt(gpa, out, child, depth + 1);
        },
        .host_out => |e| switch (e.*) {
            .str_const => |b| try app(gpa, out, "host_out \"{s}\"\n", .{b}),
        },
    }
}

pub fn mirToString(gpa: std.mem.Allocator, m: *const mir.Module) Error![]u8 {
    var out: Buf = .empty;
    errdefer out.deinit(gpa);
    try app(gpa, &out, "data.len={d}\n", .{m.data.len});
    for (m.funcs, 0..) |f, i| {
        const marker = if (m.entry != null and m.entry.? == i) " [entry]" else "";
        try app(gpa, &out, "fn {s} -> {s}{s}\n", .{ f.name, @tagName(f.ret), marker });
        try mirInst(gpa, &out, f.body, 1);
    }
    return out.toOwnedSlice(gpa);
}

fn mirInst(gpa: std.mem.Allocator, out: *Buf, inst: *const mir.Inst, depth: usize) Error!void {
    try indent(gpa, out, depth);
    switch (inst.op) {
        .block => |items| {
            try app(gpa, out, "block\n", .{});
            for (items) |child| try mirInst(gpa, out, child, depth + 1);
        },
        .host_out_const => |hc| try app(gpa, out, "host_out_const off={d} len={d}\n", .{ hc.off, hc.len }),
    }
}

fn indent(gpa: std.mem.Allocator, out: *Buf, depth: usize) Error!void {
    var n: usize = 0;
    while (n < depth) : (n += 1) try out.appendSlice(gpa, "  ");
}

fn app(gpa: std.mem.Allocator, out: *Buf, comptime fmt: []const u8, args: anytype) Error!void {
    const s = try std.fmt.allocPrint(gpa, fmt, args);
    defer gpa.free(s);
    try out.appendSlice(gpa, s);
}
