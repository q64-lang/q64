//! The sema check pass (ladder rung A4) — the first sema layer that
//! *emits* rather than records. Walks every function body with sema's
//! own typed scopes (params from the lowered signatures, `let` bindings
//! from their annotations or inferred initializers) and reports the
//! first two TYP diagnostics:
//!
//! - **TYP051** — an `if`/`while` condition whose type is provably an
//!   integer (`if 1`, `if n` with `n: i64`). Conditions require `bool`
//!   (spec/types.md §bool).
//! - **TYP042** — an arithmetic site mixing two *different* known
//!   numeric types (`i32 + i64`). No implicit conversion
//!   (spec/types.md §arithmetic).
//!
//! Honesty rules, in keeping with the floor: a check fires only on
//! *provable* types. Unknown stays silent — bare integer literals are
//! flexible (they adapt to context, so `a + 1` never mismatches),
//! unannotated bindings inherit their initializer's type or unknown,
//! calls resolve through this file's signatures only, and anything the
//! parser leaves unstructured types as unknown. NAM010 (unknown name)
//! stays *recorded-only* in resolve.zig: the corpus survey shows
//! systematic false positives until lambdas, `graph`/`channel` exprs,
//! named arguments, record-pattern fields, and the auto-prelude table
//! land.

const std = @import("std");
const parser = @import("parser");
const ast = parser.ast;
const cst = parser.cst;
const symbols = @import("symbols.zig");
const types = @import("types.zig");
const exprtype = @import("exprtype.zig");
const fits = @import("fits.zig");
const prelude = @import("prelude.zig");

pub const Diag = struct {
    code: []const u8,
    offset: u32,
};

/// What the body typer knows about a value.
const Info = union(enum) {
    /// A known type in the store.
    id: types.TypeId,
    /// A bare integer literal — flexible, adapts to context: counts as
    /// an integer for TYP051, never mismatches for TYP042.
    int_literal,
    /// A record value of a locally-declared struct (`Color { … }`);
    /// the name borrows the symbol table's token text.
    record: []const u8,
    /// An array whose elements are all records of one local struct
    /// (`[Color { … }, …]`) — what a `[T]` argument infers T from.
    rec_array: []const u8,
    /// A value of a locally-declared enum (`Light.Yellow`,
    /// `Shape.Circle(7)`, or a binding holding one) — the enum's name.
    enum_value: []const u8,
    unknown,
};

const Scope = struct {
    gpa: std.mem.Allocator,
    levels: std.ArrayList(std.StringHashMapUnmanaged(Info)) = .empty,

    fn push(self: *Scope) !void {
        try self.levels.append(self.gpa, .empty);
    }
    fn pop(self: *Scope) void {
        var lvl = &self.levels.items[self.levels.items.len - 1];
        var it = lvl.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        lvl.deinit(self.gpa);
        self.levels.items.len -= 1;
    }
    fn bind(self: *Scope, name: []const u8, info: Info) !void {
        var lvl = &self.levels.items[self.levels.items.len - 1];
        const gop = try lvl.getOrPut(self.gpa, name);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.gpa.dupe(u8, name);
        }
        gop.value_ptr.* = info; // rebind within a level: latest wins
    }
    fn find(self: *const Scope, name: []const u8) ?Info {
        var i = self.levels.items.len;
        while (i > 0) {
            i -= 1;
            if (self.levels.items[i].get(name)) |info| return info;
        }
        return null;
    }
    fn deinit(self: *Scope) void {
        while (self.levels.items.len > 0) self.pop();
        self.levels.deinit(self.gpa);
    }
};

/// A face-bounded generic declaration in this file (the B5 v0 floor:
/// one `<T>` / `<T: Face>` parameter), for the TYP200 bound check.
const GenericDecl = struct { sig: fits.GenericSig, fd: ast.FnDecl };
const Generics = std.StringHashMapUnmanaged(GenericDecl);

/// This file's enums: name → variant names (declaration order), for
/// the TYP062 exhaustiveness check.
const Enums = std.StringHashMapUnmanaged([]const []const u8);

fn collectEnums(gpa: std.mem.Allocator, sf: ast.SourceFile) !Enums {
    var out: Enums = .empty;
    errdefer deinitEnums(gpa, &out);
    var it = sf.items();
    while (it.next()) |item| switch (item) {
        .enum_decl => |ed| {
            const name = ed.name() orelse continue;
            var names: std.ArrayList([]const u8) = .empty;
            var vit = ed.variants();
            while (vit.next()) |v| {
                const vn = v.name() orelse {
                    names.deinit(gpa);
                    continue;
                };
                try names.append(gpa, vn.text);
            }
            if (names.items.len == 0) {
                names.deinit(gpa);
                continue;
            }
            try out.put(gpa, name.text, try names.toOwnedSlice(gpa));
        },
        else => {},
    };
    // The auto-prelude pair (spec/errors.md §"Result and Option") — a
    // file declaration of the same name shadows it.
    const prelude_enums = [_]struct { name: []const u8, variants: []const []const u8 }{
        .{ .name = "Option", .variants = &.{ "Some", "None" } },
        .{ .name = "Result", .variants = &.{ "Ok", "Err" } },
    };
    for (prelude_enums) |pe| {
        if (out.contains(pe.name)) continue;
        try out.put(gpa, pe.name, try gpa.dupe([]const u8, pe.variants));
    }
    return out;
}

fn deinitEnums(gpa: std.mem.Allocator, e: *Enums) void {
    var it = e.valueIterator();
    while (it.next()) |v| gpa.free(v.*);
    e.deinit(gpa);
}

fn collectGenerics(gpa: std.mem.Allocator, sf: ast.SourceFile) !Generics {
    var out: Generics = .empty;
    errdefer out.deinit(gpa);
    var it = sf.items();
    while (it.next()) |item| switch (item) {
        .fn_decl => |fd| {
            const gp = fd.genericParams() orelse continue;
            const sig = fits.parseGenericSig(gp) orelse continue;
            const name = fd.name() orelse continue;
            try out.put(gpa, name.text, .{ .sig = sig, .fd = fd });
        },
        else => {},
    };
    return out;
}

const Checker = struct {
    gpa: std.mem.Allocator,
    store: *types.TypeStore,
    sigs: *const types.Signatures,
    table: *const symbols.SymbolTable,
    fitreg: ?*const fits.Registry,
    generics: *const Generics,
    enums: *const Enums,
    scope: Scope,
    diags: *std.ArrayList(Diag),

    // -- typing ------------------------------------------------------

    fn builtinOf(c: *Checker, info: Info) ?types.Builtin {
        return switch (info) {
            .id => |id| switch (c.store.get(id)) {
                .builtin => |b| b,
                else => null,
            },
            else => null,
        };
    }

    fn isNumeric(b: types.Builtin) bool {
        return switch (b) {
            .bool, .str, .void => false,
            else => true,
        };
    }

    fn isInteger(b: types.Builtin) bool {
        return switch (b) {
            .f16, .f32, .f64, .bool, .str, .void => false,
            else => true,
        };
    }

    fn boolInfo(c: *Checker) !Info {
        return .{ .id = try c.store.intern(.{ .builtin = .bool }) };
    }

    /// Type `expr`, emitting TYP042 for mixed-numeric arithmetic found
    /// anywhere inside it.
    fn typeOf(c: *Checker, expr: ast.Expr) std.mem.Allocator.Error!Info {
        switch (expr) {
            .num_lit => return .int_literal,
            .string_lit => return .{ .id = try c.store.intern(.{ .builtin = .str }) },
            .literal => |lit| {
                const t = lit.token() orelse return .unknown;
                switch (t.kind) {
                    .KW_TRUE, .KW_FALSE => return try c.boolInfo(),
                    .KW_NONE => {
                        // The prelude `None` — an Option value (unless a
                        // file declaration shadows Option without it).
                        if (c.enumOfCtor("None")) |ename| return .{ .enum_value = ename };
                        return .unknown;
                    },
                    else => return .unknown,
                }
            },
            .paren => |p| return c.typeOf(p.inner() orelse return .unknown),
            .unary => |u| {
                const inner = try c.typeOf(u.operand() orelse return .unknown);
                const op = u.op() orelse return .unknown;
                return switch (op.kind) {
                    .BANG => try c.boolInfo(),
                    .MINUS, .TILDE => inner,
                    else => .unknown,
                };
            },
            .bin => |bx| {
                const lhs = try c.typeOf(bx.lhs() orelse return .unknown);
                const rhs = try c.typeOf(bx.rhs() orelse return .unknown);
                const op = bx.op() orelse return .unknown;
                if (exprtype.boolOp(op.kind)) return try c.boolInfo();
                if (exprtype.intOp(op.kind)) {
                    // TYP042: both sides provably numeric and different.
                    if (c.builtinOf(lhs)) |lb| if (c.builtinOf(rhs)) |rb| {
                        if (isNumeric(lb) and isNumeric(rb) and lb != rb) {
                            try c.diags.append(c.gpa, .{ .code = "TYP042", .offset = op.offset });
                        }
                    };
                    // Result: a known side wins; two literals stay flexible.
                    if (c.builtinOf(lhs) != null) return lhs;
                    if (c.builtinOf(rhs) != null) return rhs;
                    if (lhs == .int_literal and rhs == .int_literal) return .int_literal;
                    return .unknown;
                }
                return .unknown;
            },
            .call => |cc| {
                // `Shape.Circle(7)` — a payload-variant construction —
                // or a bare auto-prelude constructor (`Some(5)`).
                if (cc.callee()) |callee| {
                    if (callee == .path) {
                        if (callee.path.text(c.gpa)) |cn| {
                            defer c.gpa.free(cn);
                            if (c.enumOfDotted(cn) orelse c.enumOfCtor(cn)) |ename| {
                                var args = cc.args();
                                while (args.next()) |a| _ = try c.typeOf(a);
                                return .{ .enum_value = ename };
                            }
                        } else |_| {}
                    }
                }
                // TYP060: a parameter-mode keyword used argument-style
                // (`process(ref: s)`). Syntactic; checked on every call.
                try c.checkCallArgModes(cc);

                const Callee = struct { sig: ?types.FnSig, gen: ?GenericDecl };
                const target: Callee = blk: {
                    const callee = cc.callee() orelse break :blk .{ .sig = null, .gen = null };
                    const cpath = switch (callee) {
                        .path => |p| p,
                        else => break :blk .{ .sig = null, .gen = null },
                    };
                    const name = cpath.text(c.gpa) catch break :blk .{ .sig = null, .gen = null };
                    defer c.gpa.free(name);
                    break :blk .{ .sig = c.sigs.find(name), .gen = c.generics.get(name) };
                };
                const sig = target.sig;

                // Positional claims (per-arg type checks, the TYP061
                // count) are only honest on a *well-formed* argument
                // list. Parse recovery degrades unsupported forms —
                // record literals, `ref:` — into extra CALL_ARGs, which
                // would misalign indices and inflate the count.
                const wf = argsWellFormed(cc);

                // Type the arguments (a mismatch can hide inside) and,
                // when this file's signature is known, check each one
                // against its parameter.
                var args = cc.args();
                var i: usize = 0;
                while (args.next()) |a| : (i += 1) {
                    const info = try c.typeOf(a);
                    if (!wf) continue;
                    try c.checkGenericBound(target.gen, i, a, info);
                    const s = sig orelse continue;
                    if (i >= s.params.len) continue; // counted below (TYP061)
                    try c.checkAgainstExpected(s.params[i], info, firstTokenOffset(exprNode(a)));
                }
                // TYP061: argument count vs the declaration.
                if (wf) if (sig) |s| {
                    if (i != s.params.len) {
                        try c.diags.append(c.gpa, .{
                            .code = "TYP061",
                            .offset = firstTokenOffset(cc.cst),
                        });
                    }
                };

                const s = sig orelse return .unknown;
                // An enum-returning call (`-> Option<i64>` / `-> Shape`)
                // is an enum value for the match checks.
                if (c.enumOfNamed(s.ret)) |ename| return .{ .enum_value = ename };
                return switch (c.store.get(s.ret)) {
                    .unparsed, .unresolved => .unknown,
                    else => .{ .id = s.ret },
                };
            },
            .path => |p| {
                const name = p.text(c.gpa) catch return .unknown;
                defer c.gpa.free(name);
                if (c.enumOfDotted(name)) |ename| return .{ .enum_value = ename };
                if (c.scope.find(name)) |info| return info;
                // A bare auto-prelude constructor (`None`) — after the
                // scope so a local binding of the name wins.
                if (c.enumOfCtor(name)) |ename| return .{ .enum_value = ename };
                return .unknown;
            },
            .match => |me| {
                // A value match: judge exhaustiveness like the
                // statement form; its own type stays unknown here.
                try c.checkMatch(me.scrutinee(), me.arms(), firstTokenOffset(me.cst));
                return .unknown;
            },
            .record => |re| {
                // A record literal of a locally-declared struct. Field
                // values are typed too (a mismatch can hide inside);
                // field-shape checks join when struct shapes land.
                var iit = re.inits();
                while (iit.next()) |fi| {
                    if (fi.value()) |v| _ = try c.typeOf(v);
                }
                const p = re.path() orelse return .unknown;
                const name = p.text(c.gpa) catch return .unknown;
                defer c.gpa.free(name);
                const sym = c.table.lookup(name) orelse return .unknown;
                if (sym.kind != .struct_) return .unknown;
                return .{ .record = sym.name };
            },
            .array => |ae| {
                // An array of record literals of one struct is what a
                // generic's `[T]` argument infers T from
                // (`print_all([Color { … }])`); anything mixed or
                // non-record stays unknown.
                var it = ae.elements();
                var elem: ?[]const u8 = null;
                var any = false;
                var all_match = true;
                while (it.next()) |e| {
                    const ei = try c.typeOf(e);
                    const nm: ?[]const u8 = switch (ei) {
                        .record => |r| r,
                        else => null,
                    };
                    if (!any) {
                        elem = nm;
                        any = true;
                    } else if (elem == null or nm == null or !std.mem.eql(u8, elem.?, nm.?)) {
                        all_match = false;
                    }
                }
                const n = elem orelse return .unknown;
                if (!all_match) return .unknown;
                return .{ .rec_array = n };
            },
            else => return .unknown,
        }
    }

    // -- checks ------------------------------------------------------

    /// A value of type `info` lands where `expected` is declared (call
    /// argument, annotated `let` initializer). Provable mismatches only:
    /// - **TYP041** two different known numeric types;
    /// - **TYP050** a bool where an integer is expected;
    /// - **TYP051** an integer where a bool is expected.
    /// Flexible literals never trip TYP041 (they adapt), but they are
    /// definitely integers, so they do trip TYP051.
    fn checkAgainstExpected(c: *Checker, expected: types.TypeId, info: Info, offset: u32) !void {
        const eb = switch (c.store.get(expected)) {
            .builtin => |b| b,
            else => return,
        };
        const is_int_value = switch (info) {
            .int_literal => true,
            .id => if (c.builtinOf(info)) |b| isInteger(b) else false,
            .record, .rec_array, .enum_value, .unknown => false,
        };
        if (eb == .bool) {
            if (is_int_value) try c.diags.append(c.gpa, .{ .code = "TYP051", .offset = offset });
            return;
        }
        const vb = c.builtinOf(info) orelse return; // flexible/unknown: silent
        if (isInteger(eb) and vb == .bool) {
            try c.diags.append(c.gpa, .{ .code = "TYP050", .offset = offset });
            return;
        }
        if (isNumeric(eb) and isNumeric(vb) and eb != vb) {
            try c.diags.append(c.gpa, .{ .code = "TYP041", .offset = offset });
        }
    }

    /// TYP200: a call argument bound to a generic's `[T]` parameter
    /// whose inferred element type has no fit for the face bound
    /// (spec/faces.md §"Diagnostic codes"). Fires only on provable
    /// shapes — the face judgeable in this file (declared locally or in
    /// the auto-prelude), the element type a local struct's record
    /// array. Everything else stays silent; the emit path still rejects
    /// honestly.
    fn checkGenericBound(c: *Checker, gen_opt: ?GenericDecl, i: usize, arg: ast.Expr, info: Info) !void {
        const gen = gen_opt orelse return;
        const reg = c.fitreg orelse return;
        const p = paramAt(gen.fd, i) orelse return;
        // The param decides the judgeable shape: `[T]` takes a record
        // array, a bare `T` takes a record value.
        const elem: []const u8, const which: usize = if (fits.sliceOfWhich(p, gen.sig, c.gpa)) |w| switch (info) {
            .rec_array => |n| .{ n, w },
            else => return,
        } else if (fits.bareWhich(p, gen.sig, c.gpa)) |w| switch (info) {
            .record => |n| .{ n, w },
            else => return,
        } else return;
        const face = gen.sig.params[which].bound orelse return;
        if (!reg.knowsFace(face)) return;
        if (reg.find(elem, face) == null) {
            try c.diags.append(c.gpa, .{
                .code = "TYP200",
                .offset = firstTokenOffset(exprNode(arg)),
            });
        }
    }

    /// TYP060: `f(ref: x)` / `f(in: x)` — a parameter-mode keyword in
    /// argument position (v0 calls use bare arguments).
    fn checkCallArgModes(c: *Checker, cc: ast.CallExpr) !void {
        for (cc.cst.children) |ch| switch (ch) {
            .node => |n| if (n.kind == .CALL_ARGS) {
                for (n.children) |argc| switch (argc) {
                    .node => |arg| if (arg.kind == .CALL_ARG) {
                        try c.checkOneArgMode(arg);
                    },
                    .token => {},
                };
            },
            .token => {},
        };
    }

    fn checkOneArgMode(c: *Checker, arg: *const cst.Node) !void {
        // Fire on a leading mode keyword followed by `:`. The recovery
        // shape varies (`ref:` degrades into a UNARY_EXPR holding a
        // stray-colon literal), so judge the *flattened* first two
        // tokens of the argument, not the node structure.
        var first: ?cst.Token = null;
        var second: ?cst.Token = null;
        firstTwoTokens(arg, &first, &second);
        const kw = first orelse return;
        switch (kw.kind) {
            .KW_IN, .KW_OUT, .KW_REF, .KW_MOVE => {},
            else => return,
        }
        const next = second orelse return;
        if (next.kind == .COLON) {
            try c.diags.append(c.gpa, .{ .code = "TYP060", .offset = kw.offset });
        }
    }

    /// TYP040: an integer-literal initializer that doesn't fit its
    /// annotated standard-width integer type. `neg` marks a `-literal`.
    fn checkLiteralRange(c: *Checker, b: types.Builtin, text: []const u8, neg: bool, offset: u32) !void {
        const mag = parseIntMagnitude(c.gpa, text) orelse return; // suffixed/float/odd: skip
        const in_range = literalFits(b, mag, neg);
        if (!in_range) try c.diags.append(c.gpa, .{ .code = "TYP040", .offset = offset });
    }

    /// An annotated `let`'s initializer against its annotation: the
    /// expected-type checks plus the literal range check (TYP040).
    fn checkAnnotatedInit(c: *Checker, ann: types.TypeId, init_expr: ast.Expr, init_info: Info) !void {
        const offset = firstTokenOffset(exprNode(init_expr));
        // Literal range first: a bare (possibly negated) integer literal
        // against an integer annotation.
        if (c.builtinOf(.{ .id = ann })) |ab| {
            if (isInteger(ab)) {
                if (literalParts(init_expr)) |lit| {
                    try c.checkLiteralRange(ab, lit.text, lit.neg, offset);
                    return; // an in-range literal adapts; nothing else to check
                }
            }
        }
        try c.checkAgainstExpected(ann, init_info, offset);
    }

    /// TYP051: a condition whose type is provably an integer.
    fn checkCondition(c: *Checker, cond: ast.Expr) !void {
        const info = try c.typeOf(cond);
        const is_int = switch (info) {
            .int_literal => true,
            .id => if (c.builtinOf(info)) |b| isInteger(b) else false,
            .record, .rec_array, .enum_value, .unknown => false,
        };
        if (is_int) {
            try c.diags.append(c.gpa, .{
                .code = "TYP051",
                .offset = firstTokenOffset(exprNode(cond)),
            });
        }
    }

    /// The enum a dotted `Enum.Variant` path names, if both halves
    /// resolve against this file's enums.
    fn enumOfDotted(c: *Checker, name: []const u8) ?[]const u8 {
        const dot = std.mem.indexOfScalar(u8, name, '.') orelse return null;
        const vname = name[dot + 1 ..];
        if (std.mem.indexOfScalar(u8, vname, '.') != null) return null;
        const variants = c.enums.get(name[0..dot]) orelse return null;
        for (variants) |v| {
            if (std.mem.eql(u8, v, vname)) {
                // Borrow the enum's key text via the variants slice owner:
                // look the key up again for a stable slice.
                return c.enums.getKey(name[0..dot]);
            }
        }
        return null;
    }

    /// The known enum a `let` annotation's path type names, if any.
    fn enumAnnotation(c: *Checker, te: ast.TypeExpr) ?[]const u8 {
        const pt = switch (te) {
            .path => |x| x,
            else => return null,
        };
        const name = pt.name(c.gpa) catch return null;
        defer c.gpa.free(name);
        if (!c.enums.contains(name)) return null;
        return c.enums.getKey(name);
    }

    /// The known enum a named type (a signature return, an annotation)
    /// points at, if any.
    fn enumOfNamed(c: *Checker, id: types.TypeId) ?[]const u8 {
        const n = switch (c.store.get(id)) {
            .named => |nm| nm,
            else => return null,
        };
        if (!c.enums.contains(n.name)) return null;
        return c.enums.getKey(n.name);
    }

    /// The enum a bare auto-prelude constructor names (`Some`/`None` →
    /// `Option`, `Ok`/`Err` → `Result`). Resolved through the enums
    /// table, so a file declaration shadowing the enum wins — and
    /// drops the bare form when it lacks the variant.
    fn enumOfCtor(c: *Checker, name: []const u8) ?[]const u8 {
        const ename = prelude.ctorEnum(name) orelse return null;
        const variants = c.enums.get(ename) orelse return null;
        for (variants) |v| {
            if (std.mem.eql(u8, v, name)) return c.enums.getKey(ename);
        }
        return null;
    }

    /// TYP062: a `match` over a known enum value covers neither every
    /// variant nor a `_` arm (spec/types.md). Judged only when the
    /// scrutinee provably carries a local enum and every arm pattern
    /// is a judgeable shape; anything else stays silent.
    fn checkMatch(c: *Checker, scrut_opt: ?ast.Expr, arms_in: ast.MatchArmIter, offset: u32) std.mem.Allocator.Error!void {
        const scrut = scrut_opt orelse return;
        const info = try c.typeOf(scrut);
        const ename = switch (info) {
            .enum_value => |n| n,
            else => return,
        };
        const variants = c.enums.get(ename) orelse return;
        var covered: usize = 0;
        var seen: u64 = 0;
        var arms = arms_in;
        while (arms.next()) |arm| {
            const pat = arm.pattern() orelse return; // unjudgeable: silent
            switch (pat.kind()) {
                .WILD_PATTERN => return, // a default arm: exhaustive
                .IDENT_PATTERN, .TUPLE_STRUCT_PATTERN, .ENUM_VARIANT_PATTERN => {
                    const head = patternHead(pat.cst) orelse return;
                    const idx = for (variants, 0..) |v, i| {
                        if (std.mem.eql(u8, v, head)) break i;
                    } else return; // not a variant: another check's story
                    if (idx < 64 and (seen & (@as(u64, 1) << @intCast(idx))) == 0) {
                        seen |= @as(u64, 1) << @intCast(idx);
                        covered += 1;
                    }
                },
                else => return, // literal/nested patterns: silent
            }
        }
        if (covered < variants.len) {
            try c.diags.append(c.gpa, .{ .code = "TYP062", .offset = offset });
        }
    }

    // -- walking -----------------------------------------------------

    fn walkBlock(c: *Checker, block: ast.Block) std.mem.Allocator.Error!void {
        try c.scope.push();
        defer c.scope.pop();
        var it = block.statements();
        while (it.next()) |s| try c.walkStmt(s);
    }

    fn walkStmt(c: *Checker, s: ast.Stmt) std.mem.Allocator.Error!void {
        switch (s) {
            .expr_stmt => |es| _ = try c.typeOfOpt(es.expression()),
            .let_stmt => |ls| {
                const init_info = try c.typeOfOpt(ls.initializer());
                // Annotation wins; a missing/unlowerable one infers.
                var info = init_info;
                if (ls.type_()) |te| {
                    // An enum annotation (`let o: Option<i64>`, `let s:
                    // Shape`) binds an enum value for the match checks.
                    // Judged against the enums table directly — the
                    // null-table lowering below leaves local names
                    // unresolved.
                    if (c.enumAnnotation(te)) |ename| {
                        info = .{ .enum_value = ename };
                    } else {
                        const id = try types.lower(c.store, null, te);
                        switch (c.store.get(id)) {
                            .unparsed, .unresolved => {},
                            else => {
                                info = .{ .id = id };
                                if (ls.initializer()) |init_expr| {
                                    try c.checkAnnotatedInit(id, init_expr, init_info);
                                }
                            },
                        }
                    }
                }
                if (ls.pattern()) |p| {
                    if (p.bindingName()) |tok| try c.scope.bind(tok.text, info);
                }
            },
            .return_stmt => |rs| _ = try c.typeOfOpt(rs.value()),
            .panic_stmt => |ps| _ = try c.typeOfOpt(ps.value()),
            .break_stmt => |bs| _ = try c.typeOfOpt(bs.value()),
            .continue_stmt => {},
            .assign_stmt => |as_| {
                _ = try c.typeOfOpt(as_.target());
                _ = try c.typeOfOpt(as_.value());
            },
            .if_stmt => |is| try c.walkIf(is),
            .while_stmt => |ws| {
                if (ws.condition()) |cond| try c.checkCondition(cond);
                if (ws.body()) |b| try c.walkBlock(b);
            },
            .loop_stmt => |ls| if (ls.body()) |b| try c.walkBlock(b),
            .for_stmt => |fs| {
                _ = try c.typeOfOpt(fs.iterable());
                try c.scope.push();
                defer c.scope.pop();
                if (fs.pattern()) |p| {
                    if (p.bindingName()) |tok| try c.scope.bind(tok.text, .unknown);
                }
                if (fs.body()) |b| try c.walkBlock(b);
            },
            .match_stmt => |ms| {
                try c.checkMatch(ms.scrutinee(), ms.arms(), firstTokenOffset(ms.cst));
                var arms = ms.arms();
                while (arms.next()) |arm| {
                    try c.scope.push();
                    defer c.scope.pop();
                    if (arm.pattern()) |p| {
                        if (p.bindingName()) |tok| try c.scope.bind(tok.text, .unknown);
                    }
                    if (arm.block()) |b| {
                        try c.walkBlock(b);
                    } else {
                        _ = try c.typeOfOpt(arm.expression());
                    }
                }
            },
        }
    }

    fn walkIf(c: *Checker, is: ast.IfStmt) std.mem.Allocator.Error!void {
        if (is.condition()) |cond| try c.checkCondition(cond);
        // `if let` patterns bind in the then-branch; their type is the
        // scrutinee's payload — unknown at this floor.
        try c.scope.push();
        defer c.scope.pop();
        if (is.condition() == null) {
            if (firstChildPattern(is.cst)) |p| {
                if (p.bindingName()) |tok| try c.scope.bind(tok.text, .unknown);
            }
        }
        if (is.thenBody()) |b| try c.walkBlock(b);
        if (is.elseBody()) |b| try c.walkBlock(b);
        if (is.elseIf()) |ei| try c.walkIf(ei);
    }

    fn typeOfOpt(c: *Checker, e: ?ast.Expr) std.mem.Allocator.Error!Info {
        const expr = e orelse return .unknown;
        return c.typeOf(expr);
    }
};

fn exprNode(e: ast.Expr) *const cst.Node {
    return switch (e) {
        inline else => |v| v.cst,
    };
}

/// The declaration's i-th parameter, if it has one.
fn paramAt(fd: ast.FnDecl, i: usize) ?ast.Param {
    const ps = fd.params() orelse return null;
    var it = ps.iter();
    var k: usize = 0;
    while (it.next()) |p| : (k += 1) {
        if (k == i) return p;
    }
    return null;
}

/// A bare integer literal initializer — `42` or `-42` (one negation,
/// possibly parenthesized). `null` for anything else.
fn literalParts(e: ast.Expr) ?struct { text: []const u8, neg: bool } {
    switch (e) {
        .num_lit => |nl| {
            const t = nl.rawText() orelse return null;
            return .{ .text = t, .neg = false };
        },
        .paren => |p| return literalParts(p.inner() orelse return null),
        .unary => |u| {
            const op = u.op() orelse return null;
            if (op.kind != .MINUS) return null;
            const inner = literalParts(u.operand() orelse return null) orelse return null;
            if (inner.neg) return null; // `--x`: not a literal shape
            return .{ .text = inner.text, .neg = true };
        },
        else => return null,
    }
}

/// Parse a decimal/hex/octal/binary integer literal's magnitude.
/// `null` for float literals, type-suffixed forms, or anything that
/// doesn't parse cleanly (conservative: no diagnostic on a shape we
/// don't understand). A magnitude that overflows u128 saturates to
/// `maxInt(u128)` — genuinely out of range for every builtin width,
/// so the fit check still reports it correctly.
fn parseIntMagnitude(gpa: std.mem.Allocator, raw: []const u8) ?u128 {
    // Strip `_` separators.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    for (raw) |ch| {
        if (ch == '_') continue;
        buf.append(gpa, ch) catch return null;
    }
    const s = buf.items;
    if (s.len == 0) return null;
    if (std.mem.indexOfScalar(u8, s, '.') != null) return null; // float
    var base: u8 = 10;
    var digits: []const u8 = s;
    if (s.len > 2 and s[0] == '0') {
        switch (s[1]) {
            'x', 'X' => {
                base = 16;
                digits = s[2..];
            },
            'o', 'O' => {
                base = 8;
                digits = s[2..];
            },
            'b', 'B' => {
                base = 2;
                digits = s[2..];
            },
            else => {},
        }
    }
    return std.fmt.parseUnsigned(u128, digits, base) catch |e| switch (e) {
        error.Overflow => std.math.maxInt(u128), // definitely out of range for any width
        error.InvalidCharacter => null, // suffix or unexpected shape: skip
    };
}

/// Does a literal of magnitude `mag` (negated when `neg`) fit builtin
/// integer type `b`?
fn literalFits(b: @import("types.zig").Builtin, mag: u128, neg: bool) bool {
    const info: struct { bits: u8, signed: bool } = switch (b) {
        .i8 => .{ .bits = 8, .signed = true },
        .i16 => .{ .bits = 16, .signed = true },
        .i32 => .{ .bits = 32, .signed = true },
        .i64 => .{ .bits = 64, .signed = true },
        .i128 => .{ .bits = 128, .signed = true },
        .u8 => .{ .bits = 8, .signed = false },
        .u16 => .{ .bits = 16, .signed = false },
        .u32 => .{ .bits = 32, .signed = false },
        .u64 => .{ .bits = 64, .signed = false },
        .u128 => .{ .bits = 128, .signed = false },
        else => return true, // not an integer: not this check's job
    };
    if (neg) {
        if (!info.signed) return mag == 0; // `-0` is fine, any other negative isn't
        // |min| = 2^(bits-1)
        const min_mag: u128 = @as(u128, 1) << @intCast(info.bits - 1);
        return mag <= min_mag;
    }
    const max: u128 = if (info.bits == 128)
        (if (info.signed) std.math.maxInt(i128) else std.math.maxInt(u128))
    else if (info.signed)
        (@as(u128, 1) << @intCast(info.bits - 1)) - 1
    else
        (@as(u128, 1) << @intCast(info.bits)) - 1;
    return mag <= max;
}

fn firstChildPattern(node: *const cst.Node) ?ast.Pattern {
    for (node.children) |c| switch (c) {
        .node => |n| if (ast.Pattern.cast(n)) |p| return p,
        .token => {},
    };
    return null;
}

/// Did this call's argument list parse cleanly? Well-formed means the
/// CALL_ARGS children read `( ARG (, ARG)* ,? )` with nothing stray.
/// Recovery from unsupported forms (record literals, `ref:`) leaves
/// back-to-back CALL_ARGs or loose tokens, which this rejects.
fn argsWellFormed(cc: ast.CallExpr) bool {
    for (cc.cst.children) |ch| switch (ch) {
        .node => |n| if (n.kind == .CALL_ARGS) {
            var expect_arg = true; // after `(` or `,`
            var closed = false;
            for (n.children) |e| switch (e) {
                .token => |t| {
                    if (t.kind.isTrivia()) continue;
                    switch (t.kind) {
                        .L_PAREN => {},
                        .COMMA => {
                            if (expect_arg) return false; // `(,` / `,,`
                            expect_arg = true;
                        },
                        .R_PAREN => closed = true,
                        else => return false, // stray token
                    }
                },
                .node => |a| {
                    if (a.kind != .CALL_ARG) return false;
                    if (!expect_arg) return false; // two args, no comma
                    expect_arg = false;
                },
            };
            return closed;
        },
        .token => {},
    };
    return false; // no argument list at all
}

/// The first two non-trivia tokens under `node`, in source order.
fn firstTwoTokens(node: *const cst.Node, first: *?cst.Token, second: *?cst.Token) void {
    for (node.children) |c| {
        if (second.* != null) return;
        switch (c) {
            .token => |t| {
                if (t.kind.isTrivia()) continue;
                if (first.* == null) {
                    first.* = t;
                } else {
                    second.* = t;
                }
            },
            .node => |n| firstTwoTokens(n, first, second),
        }
    }
}

/// The variant name an arm pattern opens with: a bare ident, or the
/// last IDENT before a payload `(`.
fn patternHead(node: *const cst.Node) ?[]const u8 {
    var head: ?[]const u8 = null;
    for (node.children) |c| switch (c) {
        .token => |t| {
            if (t.kind == .L_PAREN) return head;
            if (t.kind == .IDENT or t.kind == .KW_NONE) head = t.text;
        },
        .node => |n| if (patternHead(n)) |h| {
            head = h;
        },
    };
    return head;
}

fn firstTokenOffset(node: *const cst.Node) u32 {
    for (node.children) |c| switch (c) {
        .token => |t| if (!t.kind.isTrivia()) return t.offset,
        .node => |n| {
            const o = firstTokenOffset(n);
            if (o != 0) return o;
        },
    };
    return 0;
}

/// Check every function body in `sf`. `fitreg` (when supplied) powers
/// the TYP200 generic-bound check. Caller frees the returned slice.
pub fn checkFile(
    gpa: std.mem.Allocator,
    sf: ast.SourceFile,
    table: *const symbols.SymbolTable,
    store: *types.TypeStore,
    sigs: *const types.Signatures,
    fitreg: ?*const fits.Registry,
) ![]Diag {
    var diags: std.ArrayList(Diag) = .empty;
    errdefer diags.deinit(gpa);

    var generics = try collectGenerics(gpa, sf);
    defer generics.deinit(gpa);
    var enums = try collectEnums(gpa, sf);
    defer deinitEnums(gpa, &enums);

    var it = sf.items();
    while (it.next()) |item| switch (item) {
        .fn_decl => |fd| {
            const name_tok = fd.name() orelse continue;
            const body = fd.body() orelse continue;

            var c = Checker{
                .gpa = gpa,
                .store = store,
                .sigs = sigs,
                .table = table,
                .fitreg = fitreg,
                .generics = &generics,
                .enums = &enums,
                .scope = .{ .gpa = gpa },
                .diags = &diags,
            };
            defer c.scope.deinit();

            // Param scope, typed from the lowered signature.
            try c.scope.push();
            if (sigs.find(name_tok.text)) |sig| {
                if (fd.params()) |ps| {
                    var pit = ps.iter();
                    var i: usize = 0;
                    while (pit.next()) |p| : (i += 1) {
                        const pn = p.name() orelse continue;
                        if (i < sig.params.len) {
                            const info: Info = switch (store.get(sig.params[i])) {
                                .unparsed, .unresolved => .unknown,
                                else => .{ .id = sig.params[i] },
                            };
                            try c.scope.bind(pn.text, info);
                        }
                    }
                }
            }
            try c.walkBlock(body);
            c.scope.pop();
        },
        else => {},
    };

    return diags.toOwnedSlice(gpa);
}

// =====================================================================
// Tests
// =====================================================================

const t_alloc = std.testing.allocator;
const parse = parser.parse;

fn checkSource(src: []const u8) ![]Diag {
    const pr = try parse.parse(t_alloc, src, "t.q");
    defer pr.deinit(t_alloc);
    const sf = ast.SourceFile.cast(pr.root).?;
    var table = try symbols.build(t_alloc, sf);
    defer table.deinit();
    var store = try types.TypeStore.init(t_alloc);
    defer store.deinit();
    var sigs = try types.collectSignatures(&store, &table, sf);
    defer sigs.deinit();
    var fitreg = try fits.build(t_alloc, sf);
    defer fitreg.deinit();
    return checkFile(t_alloc, sf, &table, &store, &sigs, &fitreg);
}

fn expectCodes(src: []const u8, expected: []const []const u8) !void {
    const ds = try checkSource(src);
    defer t_alloc.free(ds);
    try std.testing.expectEqual(expected.len, ds.len);
    for (expected, 0..) |code, i| {
        try std.testing.expectEqualStrings(code, ds[i].code);
    }
}

test "check: TYP051 — integer conditions in if and while" {
    try expectCodes("fn main { if 1 { env.out(\"y\") } }\n", &.{"TYP051"});
    try expectCodes("fn f(n: i64) { while n { env.out(\"t\") } }\n", &.{"TYP051"});
    try expectCodes("fn f(n: i64) { if n + 1 { env.out(\"t\") } }\n", &.{"TYP051"});
}

test "check: bool and unknown conditions stay silent" {
    try expectCodes("fn f(n: i64) { if n > 0 { env.out(\"y\") } }\n", &.{});
    try expectCodes("fn f(b: bool) { while b { env.out(\"y\") } }\n", &.{});
    try expectCodes("fn main { if mystery() { env.out(\"y\") } }\n", &.{});
    try expectCodes("fn main { if let Some(x) = opt() { env.out(x) } }\n", &.{});
}

test "check: TYP042 — mixed numeric arithmetic on annotated bindings" {
    try expectCodes(
        \\fn main {
        \\    let a: i32 = 1
        \\    let b: i64 = 2
        \\    let c = a + b
        \\    env.out("{c}")
        \\}
        \\
    , &.{"TYP042"});
    try expectCodes(
        \\fn f(x: i32, y: f64) -> f64 { x + y }
        \\
    , &.{"TYP042"});
}

test "check: literals are flexible; same types and unknowns are clean" {
    try expectCodes("fn main { let a: i32 = 1\n let c = a + 1 }\n", &.{});
    try expectCodes("fn f(a: i64, b: i64) -> i64 { a + b }\n", &.{});
    try expectCodes("fn main { let c = ghost() + 1 }\n", &.{});
}

test "check: call returns type through this file's signature" {
    // narrow() -> i32 mixed with an i64 param: provable through the sig.
    try expectCodes(
        \\fn narrow() -> i32 { 0 }
        \\fn f(b: i64) -> i64 { narrow() + b }
        \\
    , &.{"TYP042"});
}

test "check: TYP040 — annotated literal out of range (incl. negative + hex)" {
    try expectCodes("fn main { let e: u8 = 256 }\n", &.{"TYP040"});
    try expectCodes("fn main { let e: u8 = 255 }\n", &.{});
    try expectCodes("fn main { let e: u8 = 0xFF }\n", &.{});
    try expectCodes("fn main { let e: u8 = 0x100 }\n", &.{"TYP040"});
    try expectCodes("fn main { let e: i8 = -128 }\n", &.{});
    try expectCodes("fn main { let e: i8 = -129 }\n", &.{"TYP040"});
    try expectCodes("fn main { let e: u8 = -1 }\n", &.{"TYP040"});
    try expectCodes("fn main { let big: i64 = 1_000_000 }\n", &.{});
}

test "check: TYP041/TYP050/TYP051 at annotated lets" {
    // Different known numerics.
    try expectCodes(
        \\fn main {
        \\    let a: i32 = 1
        \\    let b: i64 = a
        \\}
        \\
    , &.{"TYP041"});
    // bool where an integer is expected / integer where bool expected.
    try expectCodes("fn main { let x: i32 = true }\n", &.{"TYP050"});
    try expectCodes("fn f(n: i64) { let b: bool = n }\n", &.{"TYP051"});
}

test "check: call arguments check against this file's signatures" {
    try expectCodes(
        \\fn takes64(n: i64) { env.out(n) }
        \\fn main {
        \\    let a: i32 = 1
        \\    takes64(a)
        \\}
        \\
    , &.{"TYP041"});
    try expectCodes(
        \\fn pick(b: bool) { }
        \\fn main { pick(1) }
        \\
    , &.{"TYP051"});
    // Flexible literal to a numeric param: clean.
    try expectCodes(
        \\fn takes64(n: i64) { env.out(n) }
        \\fn main { takes64(7) }
        \\
    , &.{});
    // Unknown callee: silent.
    try expectCodes("fn main { ghost(true) }\n", &.{});
}

test "check: TYP061 — wrong number of call arguments" {
    try expectCodes(
        \\fn add(a: i64, b: i64) -> i64 { a + b }
        \\fn main { env.out(add(1)) }
        \\
    , &.{"TYP061"});
    try expectCodes(
        \\fn add(a: i64, b: i64) -> i64 { a + b }
        \\fn main { env.out(add(1, 2, 3)) }
        \\
    , &.{"TYP061"});
    try expectCodes(
        \\fn add(a: i64, b: i64) -> i64 { a + b }
        \\fn main { env.out(add(1, 2)) }
        \\
    , &.{});
    // Unknown callee: no signature, no arity claim.
    try expectCodes("fn main { ghost(1, 2, 3) }\n", &.{});
}

test "check: TYP060 — mode keyword in call argument" {
    try expectCodes(
        \\fn process(ref state: i64) { state = state + 1 }
        \\fn main {
        \\    var s: i64 = 0
        \\    process(ref: s)
        \\}
        \\
    , &.{"TYP060"});
}

test "check: TYP200 — bounded generic call, element type has no fit" {
    // `Plain` has no `fit Plain : Display`; the bound fails. Both the
    // literal-argument and via-binding forms fire.
    try expectCodes(
        \\face Display { fn fmt(self) -> str }
        \\struct Plain { v: i64 }
        \\fn print_all<T: Display>(items: [T]) { }
        \\fn main { print_all([Plain { v: 1 }, Plain { v: 2 }]) }
        \\
    , &.{"TYP200"});
    try expectCodes(
        \\face Display { fn fmt(self) -> str }
        \\struct Plain { v: i64 }
        \\fn print_all<T: Display>(items: [T]) { }
        \\fn main {
        \\    let ps = [Plain { v: 1 }]
        \\    print_all(ps)
        \\}
        \\
    , &.{"TYP200"});
    // A prelude face (no local declaration) is judgeable too.
    try expectCodes(
        \\struct Plain { v: i64 }
        \\fn show_all<T: Display>(items: [T]) { }
        \\fn main { show_all([Plain { v: 1 }]) }
        \\
    , &.{"TYP200"});
}

test "check: TYP200 — a bare `T` argument is judged like a `[T]` one" {
    // A record value to a bounded bare `T` with no fit fires; a record
    // array to the same param shape does not match (and vice versa).
    try expectCodes(
        \\face D { fn fmt(self) -> str }
        \\struct Plain { v: i64 }
        \\fn show<T: D>(x: T) { }
        \\fn main { show(Plain { v: 1 }) }
        \\
    , &.{"TYP200"});
    try expectCodes(
        \\face D { fn fmt(self) -> str }
        \\struct Color { r: i64 }
        \\fit Color : D { fn fmt(self) -> str { "c" } }
        \\fn show<T: D>(x: T) { }
        \\fn main { show(Color { r: 1 }) }
        \\
    , &.{});
}

test "check: TYP200 — multi-param bounds judge each slot independently" {
    // Only the second slot's element type lacks a fit: one TYP200.
    try expectCodes(
        \\face D { fn fmt(self) -> str }
        \\struct A { x: i64 }
        \\struct NoFit { y: i64 }
        \\fit A : D { fn fmt(self) -> str { "a" } }
        \\fn both<T: D, U: D>(xs: [T], ys: [U]) { }
        \\fn main { both([A { x: 1 }], [NoFit { y: 2 }]) }
        \\
    , &.{"TYP200"});
    // Both slots fit: clean.
    try expectCodes(
        \\face D { fn fmt(self) -> str }
        \\struct A { x: i64 }
        \\struct B { y: i64 }
        \\fit A : D { fn fmt(self) -> str { "a" } }
        \\fit B : D { fn fmt(self) -> str { "b" } }
        \\fn both<T: D, U: D>(xs: [T], ys: [U]) { }
        \\fn main { both([B { y: 2 }], [A { x: 1 }]) }
        \\
    , &.{});
}

test "check: TYP200 stays silent on fitting / unprovable shapes" {
    // The fit exists: clean (the golden triangle's shape).
    try expectCodes(
        \\face Display { fn fmt(self) -> str }
        \\struct Color { r: i64 }
        \\fit Color : Display { fn fmt(self) -> str { "c" } }
        \\fn print_all<T: Display>(items: [T]) { }
        \\fn main { print_all([Color { r: 1 }]) }
        \\
    , &.{});
    // Unbounded generic: nothing to check.
    try expectCodes(
        \\struct Plain { v: i64 }
        \\fn each<T>(items: [T]) { }
        \\fn main { each([Plain { v: 1 }]) }
        \\
    , &.{});
    // A cross-module face is not judgeable here: silent.
    try expectCodes(
        \\struct Plain { v: i64 }
        \\fn render<T: SomeoneElsesFace>(items: [T]) { }
        \\fn main { render([Plain { v: 1 }]) }
        \\
    , &.{});
    // Unknown element type (a binding the typer can't see through):
    // silent.
    try expectCodes(
        \\face Display { fn fmt(self) -> str }
        \\fn print_all<T: Display>(items: [T]) { }
        \\fn main { print_all(mystery()) }
        \\
    , &.{});
    // A mixed-element array doesn't infer one T: silent.
    try expectCodes(
        \\face Display { fn fmt(self) -> str }
        \\struct A { v: i64 }
        \\struct B { v: i64 }
        \\fn print_all<T: Display>(items: [T]) { }
        \\fn main { print_all([A { v: 1 }, B { v: 2 }]) }
        \\
    , &.{});
}

test "check: TYP062 — non-exhaustive match on a local enum" {
    try expectCodes(
        \\enum Light { Red, Yellow, Green }
        \\fn main {
        \\    var l = Light.Yellow
        \\    match l {
        \\        Red -> env.out("stop"),
        \\        Yellow -> env.out("slow"),
        \\    }
        \\}
        \\
    , &.{"TYP062"});
    // A value match misses a payload variant.
    try expectCodes(
        \\enum Shape { Empty, Circle(i64) }
        \\fn main {
        \\    let s = Shape.Circle(7)
        \\    let x = match s {
        \\        Circle(r) -> r,
        \\    }
        \\    env.out(x)
        \\}
        \\
    , &.{"TYP062"});
}

test "check: TYP062 — non-exhaustive match on prelude Option/Result" {
    // Bare constructors type as enum values; a missing `None` fires.
    try expectCodes(
        \\fn main {
        \\    let o = Some(5)
        \\    match o {
        \\        Some(v) -> env.out(v),
        \\    }
        \\}
        \\
    , &.{"TYP062"});
    // The `None` literal types as Option; a missing `Some` fires.
    try expectCodes(
        \\fn main {
        \\    let e = None
        \\    match e {
        \\        None -> env.out("none"),
        \\    }
        \\}
        \\
    , &.{"TYP062"});
    // Exhaustive Option / Result matches stay silent; a file enum
    // shadowing Option drops the prelude variants.
    try expectCodes(
        \\enum Option { Just(i64) }
        \\fn main {
        \\    let o = Err(3)
        \\    match o {
        \\        Ok(v) -> env.out(v),
        \\        Err(c) -> env.out(c),
        \\    }
        \\    let e = None
        \\    match e {
        \\        None -> env.out("none"),
        \\    }
        \\}
        \\
    , &.{});
}

test "check: TYP062 across calls and annotations — enum-typed returns/lets" {
    // A `-> Option<i64>` call types as an Option value: matching the
    // call directly and matching a binding of it are both judgeable.
    try expectCodes(
        \\fn find(n: i64) -> Option<i64> {
        \\    if n > 0 { Some(n) } else { None }
        \\}
        \\fn main {
        \\    match find(5) {
        \\        Some(v) -> env.out(v),
        \\    }
        \\}
        \\
    , &.{"TYP062"});
    // An enum-annotated let binds an enum value.
    try expectCodes(
        \\enum Shape { Empty, Circle(i64) }
        \\fn main {
        \\    let s: Shape = mystery()
        \\    match s {
        \\        Circle(r) -> env.out(r),
        \\    }
        \\}
        \\
    , &.{"TYP062"});
}

test "check: TYP062 stays silent on exhaustive / unjudgeable matches" {
    // Full coverage; a `_` arm; an unknown scrutinee.
    try expectCodes(
        \\enum L { A, B }
        \\fn main {
        \\    var l = L.A
        \\    match l {
        \\        A -> env.out("a"),
        \\        B -> env.out("b"),
        \\    }
        \\    match l {
        \\        A -> env.out("a"),
        \\        _ -> env.out("rest"),
        \\    }
        \\    match mystery() {
        \\        A -> env.out("a"),
        \\    }
        \\}
        \\
    , &.{});
}
