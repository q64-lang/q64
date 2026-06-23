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
        const is_entry = (m.entry != null and m.entry.? == i);
        const marker = if (is_entry) " [entry]" else "";
        // Surface the visibility slot the component/WIT lift will read: a
        // non-entry `pub` function is part of the exported surface (e.g. a
        // public screen/twin handler). The entry carries `[entry]` instead.
        const vis = if (f.visibility == .public and !is_entry) "pub " else "";
        try app(gpa, &out, "{s}fn {s} -> {s}{s}", .{ vis, f.name, @tagName(f.ret), marker });
        // Surface the inferred capability effect set the WIT lift reads as the
        // function's imports (`@stdout + @io`); omitted when the set is empty.
        try hirEffects(gpa, &out, f.effects);
        try app(gpa, &out, "\n", .{});
        try hirStmt(gpa, &out, f.body, 1);
    }
    return out.toOwnedSlice(gpa);
}

/// Append the effect set as ` @a + @b` (leading space), or nothing when empty.
fn hirEffects(gpa: std.mem.Allocator, out: *Buf, effs: []const hir.Effect) Error!void {
    for (effs, 0..) |eff, i| {
        try app(gpa, out, "{s}{s}", .{ if (i == 0) " " else " + ", eff.marker() });
    }
}

fn hirStmt(gpa: std.mem.Allocator, out: *Buf, s: *const hir.Stmt, depth: usize) Error!void {
    try indent(gpa, out, depth);
    switch (s.*) {
        .block => |items| {
            try app(gpa, out, "block\n", .{});
            for (items) |child| try hirStmt(gpa, out, child, depth + 1);
        },
        .host_out => |e| {
            try app(gpa, out, "host_out ", .{});
            try hirExpr(gpa, out, e);
            try app(gpa, out, "\n", .{});
        },
        .host_out_int => |e| {
            try app(gpa, out, "host_out_int ", .{});
            try hirExpr(gpa, out, e);
            try app(gpa, out, "\n", .{});
        },
        .host_out_float => |e| {
            try app(gpa, out, "host_out_float ", .{});
            try hirExpr(gpa, out, e);
            try app(gpa, out, "\n", .{});
        },
        .host_out_str => |e| {
            try app(gpa, out, "host_out_str ", .{});
            try hirExpr(gpa, out, e);
            try app(gpa, out, "\n", .{});
        },
        .host_out_bool => |e| {
            try app(gpa, out, "host_out_bool ", .{});
            try hirExpr(gpa, out, e);
            try app(gpa, out, "\n", .{});
        },
        .host_call => |hc| {
            try app(gpa, out, "host_call {s}(", .{hc.name});
            for (hc.args, 0..) |a, i| {
                if (i > 0) try app(gpa, out, ", ", .{});
                try hirExpr(gpa, out, a);
            }
            try app(gpa, out, ")\n", .{});
        },
        .global_set => |gs| {
            try app(gpa, out, "global_set #{d} = ", .{gs.idx});
            try hirExpr(gpa, out, gs.value);
            try app(gpa, out, "\n", .{});
        },
        .expr => |e| {
            try app(gpa, out, "expr ", .{});
            try hirExpr(gpa, out, e);
            try app(gpa, out, "\n", .{});
        },
        .ret => |e| {
            try app(gpa, out, "ret", .{});
            if (e) |val| {
                try app(gpa, out, " ", .{});
                try hirExpr(gpa, out, val);
            }
            try app(gpa, out, "\n", .{});
        },
        .let => |l| {
            try app(gpa, out, "let local#{d} = ", .{l.idx});
            try hirExpr(gpa, out, l.value);
            try app(gpa, out, "\n", .{});
        },
        .assign => |as| {
            try app(gpa, out, "assign local#{d} = ", .{as.idx});
            try hirExpr(gpa, out, as.value);
            try app(gpa, out, "\n", .{});
        },
        .str_let => |sl| {
            try app(gpa, out, "str_let [{d},{d}] = ", .{ sl.ptr_idx, sl.len_idx });
            try hirExpr(gpa, out, sl.value);
            try app(gpa, out, "\n", .{});
        },
        .field_set => |fs| {
            try app(gpa, out, "field_set ", .{});
            try hirExpr(gpa, out, fs.base);
            try app(gpa, out, "+{d} : {s} = ", .{ fs.offset, @tagName(fs.ty) });
            try hirExpr(gpa, out, fs.value);
            try app(gpa, out, "\n", .{});
        },
        .if_ => |iff| {
            try app(gpa, out, "if ", .{});
            try hirExpr(gpa, out, iff.cond);
            try app(gpa, out, "\n", .{});
            try hirStmt(gpa, out, iff.then_, depth + 1);
            if (iff.else_) |e| try hirStmt(gpa, out, e, depth + 1);
        },
        .while_ => |w| {
            try app(gpa, out, "while ", .{});
            try hirExpr(gpa, out, w.cond);
            try app(gpa, out, "\n", .{});
            try hirStmt(gpa, out, w.body, depth + 1);
        },
        .loop_ => |body| {
            try app(gpa, out, "loop\n", .{});
            try hirStmt(gpa, out, body, depth + 1);
        },
        .brk => try app(gpa, out, "break\n", .{}),
        .vec_push => |vp| {
            try app(gpa, out, "vec_push ", .{});
            try hirExpr(gpa, out, vp.vec);
            try app(gpa, out, " <- ", .{});
            try hirExpr(gpa, out, vp.value);
            try app(gpa, out, "\n", .{});
        },
        .cont => try app(gpa, out, "continue\n", .{}),
    }
}

fn hirExpr(gpa: std.mem.Allocator, out: *Buf, e: *const hir.Expr) Error!void {
    switch (e.*) {
        .fs_read => |fr| {
            try app(gpa, out, "fs_read(", .{});
            try hirExpr(gpa, out, fr.path);
            try app(gpa, out, ")", .{});
        },
        .kv_increment => |kv| {
            try app(gpa, out, "kv_increment(", .{});
            if (kv.key) |k| {
                try hirExpr(gpa, out, k);
                try app(gpa, out, ", ", .{});
            }
            try hirExpr(gpa, out, kv.delta);
            try app(gpa, out, ")", .{});
        },
        .chan_recv => |h| {
            try app(gpa, out, "chan_recv(", .{});
            try hirExpr(gpa, out, h);
            try app(gpa, out, ")", .{});
        },
        .chan_take => |h| {
            try app(gpa, out, "chan_take(", .{});
            try hirExpr(gpa, out, h);
            try app(gpa, out, ")", .{});
        },
        .chan_open => |name| try app(gpa, out, "chan_open({s})", .{name}),
        .vec_new => try app(gpa, out, "vec_new", .{}),
        .vec_len => |vl| {
            try app(gpa, out, "vec_len(", .{});
            try hirExpr(gpa, out, vl.vec);
            try app(gpa, out, ")", .{});
        },
        .vec_get => |vg| {
            try app(gpa, out, "vec_get(", .{});
            try hirExpr(gpa, out, vg.vec);
            try app(gpa, out, ", ", .{});
            try hirExpr(gpa, out, vg.idx);
            try app(gpa, out, ")", .{});
        },
        .str_const => |b| try app(gpa, out, "\"{s}\"", .{b}),
        .int_const => |v| try app(gpa, out, "{d}", .{v}),
        .float_const => |v| try app(gpa, out, "{d}f", .{v}),
        .num_cast => |nc| {
            try app(gpa, out, "{s}(", .{@tagName(nc.to)});
            try hirExpr(gpa, out, nc.value);
            try app(gpa, out, ")", .{});
        },
        .bitcast => |bc| {
            try app(gpa, out, "bitcast<{s}>(", .{@tagName(bc.to)});
            try hirExpr(gpa, out, bc.value);
            try app(gpa, out, ")", .{});
        },
        .bool_const => |v| try app(gpa, out, "{s}", .{if (v) "true" else "false"}),
        .local => |l| try app(gpa, out, "local#{d}", .{l.idx}),
        .global_get => |i| try app(gpa, out, "global#{d}", .{i}),
        .un => |u| {
            try app(gpa, out, "({s} ", .{@tagName(u.kind)});
            try hirExpr(gpa, out, u.operand);
            try app(gpa, out, ")", .{});
        },
        .bin => |b| {
            try app(gpa, out, "(", .{});
            try hirExpr(gpa, out, b.lhs);
            try app(gpa, out, " {s} ", .{@tagName(b.kind)});
            try hirExpr(gpa, out, b.rhs);
            try app(gpa, out, ")", .{});
        },
        .logical => |lg| {
            try app(gpa, out, "(", .{});
            try hirExpr(gpa, out, lg.lhs);
            try app(gpa, out, " {s} ", .{@tagName(lg.op)});
            try hirExpr(gpa, out, lg.rhs);
            try app(gpa, out, ")", .{});
        },
        .call => |cl| {
            try app(gpa, out, "call#{d}(", .{cl.func});
            for (cl.args, 0..) |arg, i| {
                if (i != 0) try app(gpa, out, ", ", .{});
                try hirExpr(gpa, out, arg);
            }
            try app(gpa, out, ")", .{});
        },
        .foreign_call => |fc| {
            try app(gpa, out, "foreign_call \"{s}\".\"{s}\"(", .{ fc.module, fc.field });
            for (fc.args, 0..) |arg, i| {
                if (i != 0) try app(gpa, out, ", ", .{});
                try hirExpr(gpa, out, arg);
            }
            try app(gpa, out, ")", .{});
        },
        .concat => |pieces| {
            try app(gpa, out, "concat[", .{});
            for (pieces, 0..) |p, i| {
                if (i != 0) try app(gpa, out, ", ", .{});
                try hirExpr(gpa, out, p);
            }
            try app(gpa, out, "]", .{});
        },
        .str_binding => |sb| try app(gpa, out, "str_binding[{d},{d}]", .{ sb.ptr_idx, sb.len_idx }),
        .fmt_int => |inner| {
            try app(gpa, out, "fmt_int(", .{});
            try hirExpr(gpa, out, inner);
            try app(gpa, out, ")", .{});
        },
        .fmt_float => |inner| {
            try app(gpa, out, "fmt_float(", .{});
            try hirExpr(gpa, out, inner);
            try app(gpa, out, ")", .{});
        },
        .str_len => |s| {
            try app(gpa, out, "str_len(", .{});
            try hirExpr(gpa, out, s);
            try app(gpa, out, ")", .{});
        },
        .str_index => |si| {
            try hirExpr(gpa, out, si.str);
            try app(gpa, out, "[", .{});
            try hirExpr(gpa, out, si.idx);
            try app(gpa, out, "]", .{});
        },
        .str_eq => |se| {
            try app(gpa, out, "str_eq(", .{});
            try hirExpr(gpa, out, se.lhs);
            try app(gpa, out, ", ", .{});
            try hirExpr(gpa, out, se.rhs);
            try app(gpa, out, ")", .{});
        },
        .str_slice => |sl| {
            try hirExpr(gpa, out, sl.str);
            try app(gpa, out, ".slice(", .{});
            try hirExpr(gpa, out, sl.start);
            try app(gpa, out, ", ", .{});
            try hirExpr(gpa, out, sl.end);
            try app(gpa, out, ")", .{});
        },
        .str_index_of => |m| {
            try hirExpr(gpa, out, m.str);
            try app(gpa, out, ".index_of(", .{});
            try hirExpr(gpa, out, m.byte);
            try app(gpa, out, ")", .{});
        },
        .str_starts_with => |m| {
            try hirExpr(gpa, out, m.str);
            try app(gpa, out, ".starts_with(", .{});
            try hirExpr(gpa, out, m.prefix);
            try app(gpa, out, ")", .{});
        },
        .str_contains => |m| {
            try hirExpr(gpa, out, m.str);
            try app(gpa, out, ".contains(", .{});
            try hirExpr(gpa, out, m.sub);
            try app(gpa, out, ")", .{});
        },
        .record_alloc => |ra| {
            try app(gpa, out, "record_alloc size={d} align={d} [", .{ ra.size, ra.alignment });
            for (ra.inits, 0..) |fi, i| {
                if (i != 0) try app(gpa, out, ", ", .{});
                try app(gpa, out, "+{d}: ", .{fi.offset});
                try hirExpr(gpa, out, fi.value);
            }
            try app(gpa, out, "]", .{});
        },
        .field_get => |fg| {
            try app(gpa, out, "field_get(", .{});
            try hirExpr(gpa, out, fg.base);
            try app(gpa, out, "+{d} : {s})", .{ fg.offset, @tagName(fg.ty) });
        },
        .array_lit => |al| {
            try app(gpa, out, "array_lit stride={d} align={d} n={d}[", .{ al.stride, al.alignment, al.inits.len });
            for (al.inits, 0..) |iv, i| {
                if (i != 0) try app(gpa, out, ", ", .{});
                try hirExpr(gpa, out, iv);
            }
            try app(gpa, out, "]", .{});
        },
        .elem_ptr => |ep| {
            try app(gpa, out, "elem_ptr(", .{});
            try hirExpr(gpa, out, ep.base);
            try app(gpa, out, "[", .{});
            try hirExpr(gpa, out, ep.index);
            try app(gpa, out, "]*{d})", .{ep.stride});
        },
        .bounds_check => |bc| {
            try app(gpa, out, "bounds(", .{});
            try hirExpr(gpa, out, bc.index);
            try app(gpa, out, " < ", .{});
            try hirExpr(gpa, out, bc.count);
            try app(gpa, out, ")", .{});
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
        switch (f.body) {
            .structured => |inst| try mirInst(gpa, &out, inst, 1),
            .cfg => |cfg| try mirCfg(gpa, &out, cfg, 1),
        }
    }
    return out.toOwnedSlice(gpa);
}

fn mirCfg(gpa: std.mem.Allocator, out: *Buf, cfg: *const mir.Cfg, depth: usize) Error!void {
    try indent(gpa, out, depth);
    try app(gpa, out, "cfg entry=bb{d}\n", .{cfg.entry});
    for (cfg.blocks, 0..) |bb, id| {
        try indent(gpa, out, depth);
        try app(gpa, out, "bb{d}:\n", .{id});
        for (bb.insts) |inst| try mirInst(gpa, out, inst, depth + 1);
        try indent(gpa, out, depth + 1);
        switch (bb.term) {
            .ret => |v| try app(gpa, out, "ret{s}\n", .{if (v == null) "" else " <val>"}),
            .br => |t| try app(gpa, out, "br bb{d}\n", .{t}),
            .cond_br => |cb| try app(gpa, out, "cond_br bb{d} bb{d}\n", .{ cb.then_blk, cb.else_blk }),
            .@"unreachable" => try app(gpa, out, "unreachable\n", .{}),
        }
    }
}

fn mirInst(gpa: std.mem.Allocator, out: *Buf, inst: *const mir.Inst, depth: usize) Error!void {
    try indent(gpa, out, depth);
    switch (inst.op) {
        .fs_read => |fr| {
            try app(gpa, out, "fs_read\n", .{});
            try mirInst(gpa, out, fr.path, depth + 1);
        },
        .kv_increment => |kv| {
            try app(gpa, out, "kv_increment\n", .{});
            if (kv.key) |k| try mirInst(gpa, out, k, depth + 1);
            try mirInst(gpa, out, kv.delta, depth + 1);
        },
        .chan_recv => |h| {
            try app(gpa, out, "chan_recv\n", .{});
            try mirInst(gpa, out, h, depth + 1);
        },
        .chan_take => |h| {
            try app(gpa, out, "chan_take\n", .{});
            try mirInst(gpa, out, h, depth + 1);
        },
        .chan_open => |name| try app(gpa, out, "chan_open {s}\n", .{name}),
        .vec_new => try app(gpa, out, "vec_new\n", .{}),
        .vec_push => |vp| {
            try app(gpa, out, "vec_push\n", .{});
            try mirInst(gpa, out, vp.vec, depth + 1);
            try mirInst(gpa, out, vp.value, depth + 1);
        },
        .vec_len => |vl| {
            try app(gpa, out, "vec_len\n", .{});
            try mirInst(gpa, out, vl.vec, depth + 1);
        },
        .vec_get => |vg| {
            try app(gpa, out, "vec_get\n", .{});
            try mirInst(gpa, out, vg.vec, depth + 1);
            try mirInst(gpa, out, vg.idx, depth + 1);
        },
        .block => |items| {
            try app(gpa, out, "block : {s}\n", .{@tagName(inst.ty)});
            for (items) |child| try mirInst(gpa, out, child, depth + 1);
        },
        .host_out_const => |hc| try app(gpa, out, "host_out_const off={d} len={d}\n", .{ hc.off, hc.len }),
        .host_call => |hc| {
            try app(gpa, out, "host_call {s} ({d} args)\n", .{ hc.name, hc.args.len });
            for (hc.args) |a| try mirInst(gpa, out, a, depth + 1);
        },
        .foreign_call => |fc| {
            try app(gpa, out, "foreign_call {s}.{s} : {s} ({d} args)\n", .{ fc.module, fc.field, @tagName(inst.ty), fc.args.len });
            for (fc.args) |a| try mirInst(gpa, out, a, depth + 1);
        },
        .const_i64 => |v| try app(gpa, out, "const_i64 {d}\n", .{v}),
        .const_f64 => |v| try app(gpa, out, "const_f64 {d}\n", .{v}),
        .num_cast => |src| {
            try app(gpa, out, "num_cast -> {s}\n", .{@tagName(inst.ty)});
            try mirInst(gpa, out, src, depth + 1);
        },
        .bitcast => |src| {
            try app(gpa, out, "bitcast -> {s}\n", .{@tagName(inst.ty)});
            try mirInst(gpa, out, src, depth + 1);
        },
        .const_i32 => |v| try app(gpa, out, "const_i32 {d}\n", .{v}),
        .local_get => |i| try app(gpa, out, "local_get {d}\n", .{i}),
        .global_get => |i| try app(gpa, out, "global_get {d}\n", .{i}),
        .global_set => |gs| { try app(gpa, out, "global_set {d}\n", .{gs.idx}); try mirInst(gpa, out, gs.value, depth + 1); },
        .local_set => |ls| {
            try app(gpa, out, "local_set {d}\n", .{ls.idx});
            try mirInst(gpa, out, ls.value, depth + 1);
        },
        .bin => |b| {
            try app(gpa, out, "bin {s}\n", .{@tagName(b.kind)});
            try mirInst(gpa, out, b.lhs, depth + 1);
            try mirInst(gpa, out, b.rhs, depth + 1);
        },
        .un => |u| {
            try app(gpa, out, "un {s}\n", .{@tagName(u.kind)});
            try mirInst(gpa, out, u.operand, depth + 1);
        },
        .call => |cl| {
            try app(gpa, out, "call #{d}\n", .{cl.func});
            for (cl.args) |arg| try mirInst(gpa, out, arg, depth + 1);
        },
        .ret => |v| {
            try app(gpa, out, "ret\n", .{});
            if (v) |val| try mirInst(gpa, out, val, depth + 1);
        },
        .host_out_int => |hi| {
            try app(gpa, out, "host_out_int nl_off={d}\n", .{hi.nl_off});
            try mirInst(gpa, out, hi.value, depth + 1);
        },
        .host_out_float => |hf| {
            try app(gpa, out, "host_out_float nl_off={d}\n", .{hf.nl_off});
            try mirInst(gpa, out, hf.value, depth + 1);
        },
        .str_const_val => |sc| try app(gpa, out, "str_const_val off={d} len={d}\n", .{ sc.off, sc.len }),
        .str_param => |idx| try app(gpa, out, "str_param {d}\n", .{idx}),
        .str_concat => |pieces| {
            try app(gpa, out, "str_concat\n", .{});
            for (pieces) |p| try mirInst(gpa, out, p, depth + 1);
        },
        .str_binding => |sb| try app(gpa, out, "str_binding [{d},{d}]\n", .{ sb.ptr_idx, sb.len_idx }),
        .str_bind => |sb| {
            try app(gpa, out, "str_bind [{d},{d}]\n", .{ sb.ptr_idx, sb.len_idx });
            try mirInst(gpa, out, sb.value, depth + 1);
        },
        .host_out_str => |hs| {
            try app(gpa, out, "host_out_str nl_off={d}\n", .{hs.nl_off});
            try mirInst(gpa, out, hs.value, depth + 1);
        },
        .fmt_int_to_str => |inner| {
            try app(gpa, out, "fmt_int_to_str\n", .{});
            try mirInst(gpa, out, inner, depth + 1);
        },
        .fmt_float_to_str => |inner| {
            try app(gpa, out, "fmt_float_to_str\n", .{});
            try mirInst(gpa, out, inner, depth + 1);
        },
        .str_len => |s| {
            try app(gpa, out, "str_len\n", .{});
            try mirInst(gpa, out, s, depth + 1);
        },
        .str_index => |si| {
            try app(gpa, out, "str_index\n", .{});
            try mirInst(gpa, out, si.str, depth + 1);
            try mirInst(gpa, out, si.idx, depth + 1);
        },
        .str_eq => |se| {
            try app(gpa, out, "str_eq\n", .{});
            try mirInst(gpa, out, se.lhs, depth + 1);
            try mirInst(gpa, out, se.rhs, depth + 1);
        },
        .str_slice => |sl| {
            try app(gpa, out, "str_slice\n", .{});
            try mirInst(gpa, out, sl.str, depth + 1);
            try mirInst(gpa, out, sl.start, depth + 1);
            try mirInst(gpa, out, sl.end, depth + 1);
        },
        .str_index_of => |m| {
            try app(gpa, out, "str_index_of\n", .{});
            try mirInst(gpa, out, m.str, depth + 1);
            try mirInst(gpa, out, m.byte, depth + 1);
        },
        .str_starts_with => |m| {
            try app(gpa, out, "str_starts_with\n", .{});
            try mirInst(gpa, out, m.str, depth + 1);
            try mirInst(gpa, out, m.prefix, depth + 1);
        },
        .str_contains => |m| {
            try app(gpa, out, "str_contains\n", .{});
            try mirInst(gpa, out, m.str, depth + 1);
            try mirInst(gpa, out, m.sub, depth + 1);
        },
        .record_make => |rm| {
            try app(gpa, out, "record_make size={d} align={d}\n", .{ rm.size, rm.alignment });
            for (rm.inits) |fi| {
                try indent(gpa, out, depth + 1);
                try app(gpa, out, "+{d}:\n", .{fi.offset});
                try mirInst(gpa, out, fi.value, depth + 2);
            }
        },
        .field_get => |fg| {
            try app(gpa, out, "field_get +{d} : {s}\n", .{ fg.offset, @tagName(inst.ty) });
            try mirInst(gpa, out, fg.base, depth + 1);
        },
        .field_set => |fs| {
            try app(gpa, out, "field_set +{d}\n", .{fs.offset});
            try mirInst(gpa, out, fs.base, depth + 1);
            try mirInst(gpa, out, fs.value, depth + 1);
        },
        .array_make => |am| {
            try app(gpa, out, "array_make stride={d} n={d}\n", .{ am.stride, am.inits.len });
            for (am.inits) |iv| try mirInst(gpa, out, iv, depth + 1);
        },
        .elem_ptr => |ep| {
            try app(gpa, out, "elem_ptr *{d}\n", .{ep.stride});
            try mirInst(gpa, out, ep.base, depth + 1);
            try mirInst(gpa, out, ep.index, depth + 1);
        },
        .bounds_check => |bc| {
            try app(gpa, out, "bounds_check\n", .{});
            try mirInst(gpa, out, bc.index, depth + 1);
            try mirInst(gpa, out, bc.count, depth + 1);
        },
        .if_ => |iff| {
            try app(gpa, out, "if : {s}\n", .{@tagName(inst.ty)});
            try mirInst(gpa, out, iff.cond, depth + 1);
            try mirInst(gpa, out, iff.then_, depth + 1);
            if (iff.else_) |e| try mirInst(gpa, out, e, depth + 1);
        },
        .while_ => |w| {
            try app(gpa, out, "while\n", .{});
            try mirInst(gpa, out, w.cond, depth + 1);
            try mirInst(gpa, out, w.body, depth + 1);
        },
        .loop => |body| {
            try app(gpa, out, "loop\n", .{});
            try mirInst(gpa, out, body, depth + 1);
        },
        .br => try app(gpa, out, "br\n", .{}),
        .br_cont => try app(gpa, out, "br_cont\n", .{}),
        .@"unreachable" => try app(gpa, out, "unreachable\n", .{}),
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

const testing = std.testing;

test "mir CFG escape hatch: a hand-built basic-block body prints" {
    // No pass produces CFG bodies yet; this exercises the reserved seam so
    // the types stay live and the dumper handles both forms.
    var inst: mir.Inst = .{ .ty = .void, .op = .{ .host_out_const = .{ .off = 0, .len = 4 } } };
    const bb: mir.BasicBlock = .{ .insts = &.{&inst}, .term = .{ .ret = null } };
    var cfg: mir.Cfg = .{ .blocks = &.{bb}, .entry = 0 };
    const func: mir.Func = .{ .name = "start", .body = .{ .cfg = &cfg }, .linkage = .entry };
    var funcs = [_]mir.Func{func};

    var m = mir.Module.init(testing.allocator);
    defer m.deinit();
    m.funcs = &funcs;
    m.entry = 0;
    m.data = "test";

    const dump = try mirToString(testing.allocator, &m);
    defer testing.allocator.free(dump);
    try testing.expect(std.mem.indexOf(u8, dump, "cfg entry=bb0") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "bb0:") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "host_out_const off=0 len=4") != null);
    try testing.expect(std.mem.indexOf(u8, dump, "ret\n") != null);
}
