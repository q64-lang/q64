//! Effect pass — infers each function's **capability effect set** over the
//! built HIR (spec/effects.md). A capability ("this function may do X")
//! propagates **up** the call graph: a caller's set is the union of its own
//! direct faces and every (transitive) callee's set. The result is
//! implication-closed (`@stdout` ⇒ `@io`, …), sorted finest-grained first, and
//! written back into `hir.Func.effects`.
//!
//! Backend-neutral: this is a pure-Zig HIR pass (no Binaryen, no codegen
//! dependency). The component/WIT lift reads the populated sets as the import
//! side of each function's world; `q64 show effects` prints them.
//!
//! v0 scope: detects the faces the HIR models today — any `env.out` form
//! (`host_out*`) is `@stdout`, and a `qview.*` host call is `@ui`. Other host
//! faces map through `faceEffect` as they land. The assert/observation markers
//! (`@pure`, `@realtime`, `@cancel`) are a separate, later pass.

const std = @import("std");
const hir = @import("hir.zig");

const Set = std.EnumSet(hir.Effect);

/// Run the pass over `m`, populating `Func.effects` for every function. Sets are
/// arena-allocated from the module, so they free with it. Safe to call once,
/// after HIR construction.
pub fn analyze(m: *hir.Module) std.mem.Allocator.Error!void {
    const n = m.funcs.len;
    if (n == 0) return;
    const a = m.alloc();

    // Per-function direct faces and call-graph edges, gathered in one walk.
    const direct = try a.alloc(Set, n);
    const edges = try a.alloc(std.ArrayListUnmanaged(hir.FuncId), n);
    for (direct, edges) |*d, *e| {
        d.* = Set.initEmpty();
        e.* = .empty;
    }
    for (m.funcs, direct, edges) |f, *d, *e| try collectStmt(a, f.body, d, e);

    // Fixpoint: a function carries its direct faces plus every callee's set.
    // The graph may recurse or form cycles (mutual recursion), so iterate to a
    // fixed point — monotone union over a finite lattice, so it terminates.
    const out = try a.alloc(Set, n);
    for (out, direct) |*o, d| o.* = d;
    var changed = true;
    while (changed) {
        changed = false;
        for (out, edges) |*o, e| {
            for (e.items) |callee| {
                const before = o.count();
                o.setUnion(out[callee]);
                if (o.count() != before) changed = true;
            }
        }
    }

    // Close implications and materialize the sorted slice per function.
    for (m.funcs, out) |*f, *o| {
        close(o);
        f.effects = try toSlice(a, o.*);
    }
}

/// Add every effect implied (transitively) by a member of the set.
fn close(s: *Set) void {
    var changed = true;
    while (changed) {
        changed = false;
        var it = s.iterator();
        while (it.next()) |eff| {
            if (eff.implies()) |imp| {
                if (!s.contains(imp)) {
                    s.insert(imp);
                    changed = true;
                }
            }
        }
    }
}

/// EnumSet → an arena-owned slice in enum (sort) order: finest-grained first,
/// `@io` last.
fn toSlice(a: std.mem.Allocator, s: Set) std.mem.Allocator.Error![]const hir.Effect {
    const count = s.count();
    if (count == 0) return &.{};
    const buf = try a.alloc(hir.Effect, count);
    var i: usize = 0;
    var it = s.iterator(); // EnumSet iterates in declaration order
    while (it.next()) |eff| : (i += 1) buf[i] = eff;
    return buf;
}

/// Map a host-call face name (`qview.text`, …) to the capability it discloses.
/// The first dotted segment is the face. Unrecognized faces fall back to the
/// `@io` umbrella — honest: an unknown host call does *some* I/O.
fn faceEffect(name: []const u8) hir.Effect {
    const face = name[0 .. std.mem.indexOfScalar(u8, name, '.') orelse name.len];
    if (std.mem.eql(u8, face, "qview")) return .ui;
    return .io;
}

fn collectStmt(
    a: std.mem.Allocator,
    stmt: *const hir.Stmt,
    d: *Set,
    e: *std.ArrayListUnmanaged(hir.FuncId),
) std.mem.Allocator.Error!void {
    switch (stmt.*) {
        .block => |stmts| for (stmts) |s| try collectStmt(a, s, d, e),
        // Every `env.out` form writes stdout.
        .host_out, .host_out_int, .host_out_float, .host_out_str, .host_out_bool => |expr| {
            d.insert(.stdout);
            try collectExpr(a, expr, d, e);
        },
        .host_call => |hc| {
            d.insert(faceEffect(hc.name));
            for (hc.args) |arg| try collectExpr(a, arg, d, e);
        },
        .global_set => |gs| try collectExpr(a, gs.value, d, e),
        .expr => |expr| try collectExpr(a, expr, d, e),
        .ret => |maybe| if (maybe) |expr| try collectExpr(a, expr, d, e),
        .let => |l| try collectExpr(a, l.value, d, e),
        .assign => |as| try collectExpr(a, as.value, d, e),
        .str_let => |sl| try collectExpr(a, sl.value, d, e),
        .field_set => |fs| {
            try collectExpr(a, fs.base, d, e);
            try collectExpr(a, fs.value, d, e);
        },
        .vec_push => |vp| {
            try collectExpr(a, vp.vec, d, e);
            try collectExpr(a, vp.value, d, e);
        },
        .if_ => |iff| {
            try collectExpr(a, iff.cond, d, e);
            try collectStmt(a, iff.then_, d, e);
            if (iff.else_) |els| try collectStmt(a, els, d, e);
        },
        .while_ => |w| {
            try collectExpr(a, w.cond, d, e);
            try collectStmt(a, w.body, d, e);
        },
        .loop_ => |body| try collectStmt(a, body, d, e),
        .brk, .cont => {},
    }
}

fn collectExpr(
    a: std.mem.Allocator,
    expr: *const hir.Expr,
    d: *Set,
    e: *std.ArrayListUnmanaged(hir.FuncId),
) std.mem.Allocator.Error!void {
    switch (expr.*) {
        .call => |call| {
            try e.append(a, call.func);
            for (call.args) |arg| try collectExpr(a, arg, d, e);
        },
        // A foreign WIT import reaches across the component boundary; we can't
        // see what it does, so disclose the honest `@io` umbrella (same rule as
        // an unrecognized host face).
        .foreign_call => |fc| {
            d.insert(.io);
            for (fc.args) |arg| try collectExpr(a, arg, d, e);
        },
        .bin => |b| {
            try collectExpr(a, b.lhs, d, e);
            try collectExpr(a, b.rhs, d, e);
        },
        .un => |u| try collectExpr(a, u.operand, d, e),
        .logical => |l| {
            try collectExpr(a, l.lhs, d, e);
            try collectExpr(a, l.rhs, d, e);
        },
        .concat => |pieces| for (pieces) |p| try collectExpr(a, p, d, e),
        .fmt_int, .fmt_float => |inner| try collectExpr(a, inner, d, e),
        .num_cast => |nc| try collectExpr(a, nc.value, d, e),
        .bitcast => |bc| try collectExpr(a, bc.value, d, e),
        .str_len => |s| try collectExpr(a, s, d, e),
        .str_index => |si| {
            try collectExpr(a, si.str, d, e);
            try collectExpr(a, si.idx, d, e);
        },
        .str_eq => |se| {
            try collectExpr(a, se.lhs, d, e);
            try collectExpr(a, se.rhs, d, e);
        },
        .str_slice => |sl| {
            try collectExpr(a, sl.str, d, e);
            try collectExpr(a, sl.start, d, e);
            try collectExpr(a, sl.end, d, e);
        },
        .str_index_of => |m| {
            try collectExpr(a, m.str, d, e);
            try collectExpr(a, m.byte, d, e);
        },
        .fs_read => |fr| {
            d.insert(.fs);
            try collectExpr(a, fr.path, d, e);
        },
        .kv_increment => |kv| {
            d.insert(.kv);
            if (kv.key) |k| try collectExpr(a, k, d, e);
            try collectExpr(a, kv.delta, d, e);
        },
        .chan_recv => |h| {
            d.insert(.wire); // a remote channel receive crosses the wire
            try collectExpr(a, h, d, e);
        },
        .chan_take => |h| {
            d.insert(.wire);
            try collectExpr(a, h, d, e);
        },
        .chan_open => d.insert(.wire),
        .vec_new => {},
        .vec_len => |vl| try collectExpr(a, vl.vec, d, e),
        .vec_get => |vg| {
            try collectExpr(a, vg.vec, d, e);
            try collectExpr(a, vg.idx, d, e);
        },
        .str_starts_with => |m| {
            try collectExpr(a, m.str, d, e);
            try collectExpr(a, m.prefix, d, e);
        },
        .str_contains => |m| {
            try collectExpr(a, m.str, d, e);
            try collectExpr(a, m.sub, d, e);
        },
        .record_alloc => |ra| for (ra.inits) |fi| try collectExpr(a, fi.value, d, e),
        .field_get => |fg| try collectExpr(a, fg.base, d, e),
        .array_lit => |al| for (al.inits) |iv| try collectExpr(a, iv, d, e),
        .elem_ptr => |ep| {
            try collectExpr(a, ep.base, d, e);
            try collectExpr(a, ep.index, d, e);
        },
        .bounds_check => |bc| {
            try collectExpr(a, bc.index, d, e);
            try collectExpr(a, bc.count, d, e);
        },
        // Leaves: no calls, no faces.
        .str_const, .int_const, .float_const, .bool_const, .local, .global_get, .str_binding => {},
    }
}

const testing = std.testing;

test "Effect.implies: fine-grained capabilities imply @io; peers and @io do not" {
    try testing.expectEqual(hir.Effect.io, hir.Effect.stdout.implies().?);
    try testing.expectEqual(hir.Effect.io, hir.Effect.network.implies().?);
    try testing.expect(hir.Effect.ui.implies() == null); // peer surface
    try testing.expect(hir.Effect.audio.implies() == null);
    try testing.expect(hir.Effect.io.implies() == null); // umbrella implies nothing
}

test "Effect.marker / witImports" {
    try testing.expectEqualStrings("@stdout", hir.Effect.stdout.marker());
    try testing.expectEqualStrings("wasi:cli/stdout", hir.Effect.stdout.witImports()[0]);
    try testing.expectEqualStrings("q64:host/ui", hir.Effect.ui.witImports()[0]);
    // `env.kv` maps to a PAIR: `store` (the adapter opens the bucket) + `atomics`
    // (the qube's `increment`) — spec/env.md §"Env ↔ WASI Preview 3".
    try testing.expectEqual(@as(usize, 2), hir.Effect.kv.witImports().len);
    try testing.expectEqualStrings("wasi:keyvalue/store", hir.Effect.kv.witImports()[0]);
    try testing.expectEqualStrings("wasi:keyvalue/atomics", hir.Effect.kv.witImports()[1]);
    try testing.expectEqual(@as(usize, 0), hir.Effect.io.witImports().len); // umbrella: no single import
    try testing.expectEqual(@as(usize, 0), hir.Effect.wire.witImports().len); // import is the remote world
}

test "close: @stdout pulls in @io transitively" {
    var s = Set.initEmpty();
    s.insert(.stdout);
    close(&s);
    try testing.expect(s.contains(.stdout));
    try testing.expect(s.contains(.io));
    try testing.expectEqual(@as(usize, 2), s.count());
}
