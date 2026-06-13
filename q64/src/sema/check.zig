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
    /// True when the function being walked provably does NOT return
    /// `Result`, so a `try` inside it is TYP300.
    try_forbidden: bool = false,

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
            .@"try" => |te| {
                // TYP300: `try` requires the enclosing function to
                // return `Result` (spec/errors.md §type-system rules).
                // Fires only when the return type provably isn't —
                // an unknown named type (an alias) stays silent.
                _ = try c.typeOfOpt(te.operand());
                if (c.try_forbidden) {
                    try c.diags.append(c.gpa, .{ .code = "TYP300", .offset = firstTokenOffset(te.cst) });
                }
                return .unknown;
            },
            .question => |qe| {
                // TYP305: postfix `?` is not q64's error operator — the
                // language uses the `try` keyword instead (spec/errors.md
                // §"why a keyword not a sigil"). Always an error wherever it
                // appears in expression position.
                _ = try c.typeOfOpt(qe.operand());
                try c.diags.append(c.gpa, .{ .code = "TYP305", .offset = lastTokenOffset(qe.cst) });
                return .unknown;
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

    /// The known enum a `let` annotation's type names, if any —
    /// a path type (`Shape`, `Option<i64>`) or the `T?` sugar.
    fn enumAnnotation(c: *Checker, te: ast.TypeExpr) ?[]const u8 {
        const pt = switch (te) {
            .path => |x| x,
            .optional => return c.enums.getKey("Option"), // `T?` ≡ `Option<T>`
            else => return null,
        };
        const name = pt.name(c.gpa) catch return null;
        defer c.gpa.free(name);
        if (!c.enums.contains(name)) return null;
        return c.enums.getKey(name);
    }

    /// The known enum a lowered type (a signature return) points at,
    /// if any — a named type or the `T?` optional sugar.
    fn enumOfNamed(c: *Checker, id: types.TypeId) ?[]const u8 {
        const n = switch (c.store.get(id)) {
            .named => |nm| nm,
            .optional => return c.enums.getKey("Option"), // `T?` ≡ `Option<T>`
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
/// Does this function's declared return type provably NOT name
/// `Result` — i.e. is a `try` inside it TYP300 (spec/errors.md)?
/// Honesty rules: no return type (void), a builtin/prelude type, the
/// `T?` sugar, a structural type, or a locally-declared struct/enum
/// all forbid `try`; an *unknown* named type (it could be an alias of
/// `Result`) stays silent.
fn fnRetForbidsTry(gpa: std.mem.Allocator, store: *types.TypeStore, table: *const symbols.SymbolTable, fd: ast.FnDecl) bool {
    const rt = fd.returnType() orelse return true; // void
    const te = rt.type_() orelse return false; // unstructured: silent
    switch (te) {
        .path => |pt| {
            const name = pt.name(gpa) catch return false;
            defer gpa.free(name);
            if (std.mem.eql(u8, name, "Result")) return false;
            const id = types.lower(store, null, te) catch return false;
            switch (store.get(id)) {
                // A builtin scalar or a (non-Result) prelude type.
                .builtin, .named => return true,
                else => {},
            }
            if (table.lookup(name)) |sym| {
                return switch (sym.kind) {
                    .struct_, .enum_ => true,
                    else => false,
                };
            }
            return false;
        },
        // `T?` is Option, not Result; structural types aren't Result.
        .optional, .tuple, .slice, .array, .ref => return true,
        .raw => return false,
    }
}

/// `main` must match one of four shapes (env.md §"main signature"):
/// `fn main`, `fn main -> Result<…>`, `fn main(env: Env)`, or
/// `fn main(env: Env) -> Result<…>`. Anything else is **ENV052**. A Form-2
/// `main` (a `Result` return) whose body falls off the end through a void
/// operation — no explicit `return` and no `Result` tail expression — is
/// **ENV050**. Honesty: a non-`main` function, or an unstructured/raw return
/// (it might alias `Result`), is left alone.
fn checkMainSignature(gpa: std.mem.Allocator, fd: ast.FnDecl, diags: *std.ArrayList(Diag)) !void {
    const name_tok = fd.name() orelse return;
    if (!std.mem.eql(u8, name_tok.text, "main")) return;

    // Parameters: none, or exactly one of type `Env`.
    var nparams: usize = 0;
    var params_ok = true;
    if (fd.params()) |ps| {
        var pit = ps.iter();
        while (pit.next()) |p| : (nparams += 1) {
            if (nparams == 0) params_ok = typeIsNamed(gpa, p.type_(), "Env");
        }
    }
    if (nparams > 1) params_ok = false;

    // Return: absent, or `Result<…>`. A structured non-`Result` return (a
    // scalar, `T?`, a tuple, a ref, …) is a mismatch; a raw/unparsed return
    // stays lenient.
    var ret_ok = true;
    var ret_is_result = false;
    if (fd.returnType()) |rt| {
        if (rt.type_()) |te| switch (te) {
            .path => |pt| {
                const nm = pt.name(gpa) catch return;
                defer gpa.free(nm);
                ret_is_result = std.mem.eql(u8, nm, "Result");
                ret_ok = ret_is_result;
            },
            .raw => {}, // uncertain — lenient
            else => ret_ok = false,
        };
    }

    if (!params_ok or !ret_ok) {
        try diags.append(gpa, .{ .code = "ENV052", .offset = name_tok.offset });
        return;
    }

    // ENV050: a Form-2 `main` must end with an explicit `return`/diverge or a
    // `Result` tail expression — a fall-off through `env.out(…)` is flagged.
    if (ret_is_result) {
        if (fd.body()) |body| {
            if (!form2Yields(gpa, body)) {
                try diags.append(gpa, .{ .code = "ENV050", .offset = name_tok.offset });
            }
        }
    }
}

/// The blessed core effect markers (effects.md §"The core effect set").
/// A `pub effect @<name>` colliding with one of these is EFF140.
const core_effects = [_][]const u8{
    // asserts
    "pure",         "realtime",  "no_alloc", "no_suspend", "no_panic",
    "no_trap",      "uncancellable",
    // capabilities
    "io",           "network",   "fs",       "kv",         "stdout",
    "stderr",       "audio",     "midi",     "ui",         "inference",
    "time",         "random",    "exit",     "envvars",    "wire",
    // observation + type marker
    "cancel",       "send",
};

/// A user effect name (the IDENT after `@`, without the `@`) must match
/// `^[a-z][a-z_]*$` — lowercase letters and underscores, leading letter.
fn isValidEffectName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name[0] < 'a' or name[0] > 'z') return false;
    for (name[1..]) |ch| {
        if (!((ch >= 'a' and ch <= 'z') or ch == '_')) return false;
    }
    return true;
}

/// Check a `pub effect @<name>` declaration:
/// - **EFF141** if the name doesn't match `^@[a-z][a-z_]*$`;
/// - **EFF140** if a (valid) name collides with a core marker.
fn checkEffectDecl(gpa: std.mem.Allocator, ed: ast.EffectDecl, diags: *std.ArrayList(Diag)) !void {
    const name_tok = ed.name() orelse return;
    if (!isValidEffectName(name_tok.text)) {
        try diags.append(gpa, .{ .code = "EFF141", .offset = name_tok.offset });
        return;
    }
    for (core_effects) |core| {
        if (std.mem.eql(u8, core, name_tok.text)) {
            try diags.append(gpa, .{ .code = "EFF140", .offset = name_tok.offset });
            return;
        }
    }
}

/// Capability markers (effects.md §"The core effect set" — the
/// capabilities). A capability declares a power the function exercises.
const capability_effects = [_][]const u8{
    "io",   "network", "fs",   "kv",       "stdout",
    "stderr", "audio", "midi", "ui",       "inference",
    "time", "random",  "exit", "envvars",  "wire",
};

/// Capabilities a `@realtime` function may still declare — the
/// realtime-safe surfaces (effects.md §"`@realtime` and capabilities":
/// the `@time`/`@random`/`@audio` carve-outs). Every other capability is
/// forbidden under `@realtime`.
const realtime_safe_caps = [_][]const u8{ "time", "random", "audio" };

fn inEffectSet(set: []const []const u8, name: []const u8) bool {
    for (set) |s| {
        if (std.mem.eql(u8, s, name)) return true;
    }
    return false;
}

/// **EFF120** — a function's declared effect set is internally
/// contradictory: an assert that forbids a capability appears alongside
/// that capability (effects.md §"Effect annotations on functions": "A `+`
/// between an assert and a capability is EFF120"). v0 covers the two
/// asserts the spec defines as forbidding capabilities — `@pure` (forbids
/// every capability) and `@realtime` (forbids all but the realtime-safe
/// `@time`/`@random`/`@audio`). The `@no_*` asserts bound *operations*,
/// checked at the body level (EFF110/EFF103), not the declaration. Two
/// asserts compose (`@realtime + @pure` is fine); unknown user markers
/// are neither assert nor capability, so they never contradict.
fn checkEffectContradiction(gpa: std.mem.Allocator, es: ast.EffectSpec, diags: *std.ArrayList(Diag)) !void {
    var has_pure = false;
    var has_realtime = false;
    var it = es.markers();
    while (it.next()) |m| {
        const nt = m.name() orelse continue;
        if (std.mem.eql(u8, nt.text, "pure")) has_pure = true;
        if (std.mem.eql(u8, nt.text, "realtime")) has_realtime = true;
    }
    if (!has_pure and !has_realtime) return;

    var it2 = es.markers();
    while (it2.next()) |m| {
        const nt = m.name() orelse continue;
        if (!inEffectSet(&capability_effects, nt.text)) continue;
        const forbidden = has_pure or
            (has_realtime and !inEffectSet(&realtime_safe_caps, nt.text));
        if (forbidden) {
            try diags.append(gpa, .{ .code = "EFF120", .offset = nt.offset });
            return; // one EFF120 per function
        }
    }
}

/// **EFF160** — a `@cancel` function must carry a `ctx: Cancel`
/// parameter (effects.md §"`@cancel` and `@uncancellable`": `@cancel`
/// observes cancellation through the token, so the signature must accept
/// one). Declaring `@cancel` without a `Cancel`-typed parameter is the
/// error. The type is the load-bearing part — we match on a parameter
/// whose declared type is `Cancel`, not on the conventional name `ctx`.
fn checkCancelCtx(gpa: std.mem.Allocator, fd: ast.FnDecl, es: ast.EffectSpec, diags: *std.ArrayList(Diag)) !void {
    var cancel_off: ?u32 = null;
    var it = es.markers();
    while (it.next()) |m| {
        const nt = m.name() orelse continue;
        if (std.mem.eql(u8, nt.text, "cancel")) {
            cancel_off = nt.offset;
            break;
        }
    }
    const off = cancel_off orelse return;

    if (fd.params()) |ps| {
        var pit = ps.iter();
        while (pit.next()) |p| {
            const tt = (try p.typeText(gpa)) orelse continue;
            defer gpa.free(tt);
            if (std.mem.eql(u8, std.mem.trim(u8, tt, " \t"), "Cancel")) return; // satisfied
        }
    }
    try diags.append(gpa, .{ .code = "EFF160", .offset = off });
}

/// True when the path node's head segment is the ambient `env` (the
/// first non-trivia token is `IDENT "env"`), as in `env.out` / `env.fs`.
fn pathHeadIsEnv(node: *const cst.Node) bool {
    for (node.children) |c| switch (c) {
        .token => |t| {
            if (t.kind.isTrivia()) continue;
            return t.kind == .IDENT and std.mem.eql(u8, t.text, "env");
        },
        .node => return false,
    };
    return false;
}

/// Recursively: does `node` contain a `PATH_EXPR` headed by ambient `env`?
fn referencesAmbientEnv(node: *const cst.Node) bool {
    if (node.kind == .PATH_EXPR and pathHeadIsEnv(node)) return true;
    for (node.children) |c| switch (c) {
        .node => |n| if (referencesAmbientEnv(n)) return true,
        .token => {},
    };
    return false;
}

/// **ENV056** — a `@pure` function may not touch the ambient `env`
/// (env.md §"Diagnostic codes": ambient capability use is incompatible
/// with purity — the reference would synthesize a capability parameter).
/// Fires when a `@pure` function's body references `env.X` and `env`
/// isn't shadowed by a parameter of that name.
fn checkPureEnv(gpa: std.mem.Allocator, fd: ast.FnDecl, es: ast.EffectSpec, diags: *std.ArrayList(Diag)) !void {
    var pure_off: ?u32 = null;
    var it = es.markers();
    while (it.next()) |m| {
        const nt = m.name() orelse continue;
        if (std.mem.eql(u8, nt.text, "pure")) {
            pure_off = nt.offset;
            break;
        }
    }
    const off = pure_off orelse return;

    // A parameter named `env` shadows the ambient binding; its uses
    // aren't ambient, so ENV056 doesn't apply.
    if (fd.params()) |ps| {
        var pit = ps.iter();
        while (pit.next()) |p| {
            const pn = p.name() orelse continue;
            if (std.mem.eql(u8, pn.text, "env")) return;
        }
    }

    const body = fd.body() orelse return;
    if (referencesAmbientEnv(body.cst)) {
        try diags.append(gpa, .{ .code = "ENV056", .offset = off });
    }
}

/// Reserved non-verbs the language deliberately omits: the only
/// cross-region move is `transfer(to: …)`. `copy_to` / `pin_to` /
/// `intern` are absent (memory.md §"Cross-region transfers"), so a
/// method call by any of these names is REG050.
const reserved_nonverbs = [_][]const u8{ "copy_to", "pin_to", "intern" };

fn flagIfReservedVerb(gpa: std.mem.Allocator, tok: cst.Token, diags: *std.ArrayList(Diag)) !void {
    for (reserved_nonverbs) |v| {
        if (std.mem.eql(u8, v, tok.text)) {
            try diags.append(gpa, .{ .code = "REG050", .offset = tok.offset });
            return;
        }
    }
}

/// The last dotted segment of a `PATH_EXPR` (`a.copy_to` → `copy_to`),
/// but only when the path actually has a `.` — a bare name is not a verb
/// call. Used to read the verb out of `recv.verb(...)`.
fn dottedLastSegment(path: *const cst.Node) ?cst.Token {
    var last: ?cst.Token = null;
    var seen_dot = false;
    for (path.children) |c| switch (c) {
        .token => |t| {
            if (t.kind == .DOT) seen_dot = true else if (t.kind == .IDENT) last = t;
        },
        .node => {},
    };
    return if (seen_dot) last else null;
}

/// **REG050** — a call using an unknown transfer verb. The receiver form
/// `recv.verb(args)` parses two ways: as a `METHOD_EXPR` (receiver is a
/// non-path expression, `make().copy_to(r)`) or — the common case — as a
/// `CALL_EXPR` over a greedy dotted `PATH_EXPR` (`a.copy_to` + args). Both
/// are scanned; the verb is flagged at its token.
fn checkTransferVerbs(
    gpa: std.mem.Allocator,
    node: *const cst.Node,
    diags: *std.ArrayList(Diag),
) std.mem.Allocator.Error!void {
    switch (node.kind) {
        .METHOD_EXPR => {
            const me = ast.MethodExpr{ .cst = node };
            if (me.method()) |m| try flagIfReservedVerb(gpa, m, diags);
        },
        .CALL_EXPR => for (node.children) |c| switch (c) {
            .node => |n| {
                if (n.kind == .PATH_EXPR) {
                    if (dottedLastSegment(n)) |seg| try flagIfReservedVerb(gpa, seg, diags);
                }
                break; // the callee is the first child node
            },
            .token => {},
        },
        else => {},
    }
    for (node.children) |c| switch (c) {
        .node => |n| try checkTransferVerbs(gpa, n, diags),
        .token => {},
    };
}

/// True when a parameter's declared type is a `PathType` headed by
/// `Event` (`Event<Point>`, `Event<T>`), i.e. a pointwise event stream.
fn paramTypeIsEvent(gpa: std.mem.Allocator, p: ast.Param) bool {
    const ty = p.type_() orelse return false;
    switch (ty) {
        .path => |pt| {
            const nm = pt.name(gpa) catch return false;
            defer gpa.free(nm);
            return std.mem.eql(u8, nm, "Event");
        },
        else => return false,
    }
}

/// The head identifier of a `PATH_EXPR` (`clicks.pre` → `clicks`), or
/// null if the path doesn't start with an IDENT.
fn pathFirstIdent(node: *const cst.Node) ?cst.Token {
    for (node.children) |c| switch (c) {
        .token => |t| {
            if (t.kind.isTrivia()) continue;
            return if (t.kind == .IDENT) t else null;
        },
        .node => return null,
    };
    return null;
}

/// Recursively flag `<event>.pre` `PATH_EXPR`s — `.pre()` on an event
/// receiver (STR051). `events` holds the names known to be `Event<…>`.
fn scanEventPre(
    gpa: std.mem.Allocator,
    node: *const cst.Node,
    events: *const std.StringHashMap(void),
    diags: *std.ArrayList(Diag),
) std.mem.Allocator.Error!void {
    if (node.kind == .PATH_EXPR) {
        if (pathFirstIdent(node)) |head| {
            if (events.contains(head.text)) {
                if (dottedLastSegment(node)) |last| {
                    if (std.mem.eql(u8, last.text, "pre")) {
                        try diags.append(gpa, .{ .code = "STR051", .offset = last.offset });
                    }
                }
            }
        }
    }
    for (node.children) |c| switch (c) {
        .node => |n| try scanEventPre(gpa, n, events, diags),
        .token => {},
    };
}

/// **STR051** — `Event<T>` has no previous-tick notion, so `.pre()` (the
/// feedback one-tick delay, valid only on `Signal`) can't be called on an
/// event (streams.md §"`pre()` for feedback cycles"). v0 resolves the
/// receiver type from `Event<…>` *parameters*; `<event>.pre()` on any of
/// them is flagged. (Event-typed `let` bindings are a follow-on.)
fn checkEventPre(gpa: std.mem.Allocator, fd: ast.FnDecl, diags: *std.ArrayList(Diag)) !void {
    var events = std.StringHashMap(void).init(gpa);
    defer events.deinit();
    if (fd.params()) |ps| {
        var it = ps.iter();
        while (it.next()) |p| {
            if (paramTypeIsEvent(gpa, p)) {
                if (p.name()) |nm| try events.put(nm.text, {});
            }
        }
    }
    if (events.count() == 0) return;
    const body = fd.body() orelse return;
    try scanEventPre(gpa, body.cst, &events, diags);
}

/// **REG020** — a `@managed` (WasmGC) struct may only hold managed or
/// value-type fields; a `ref` into linear memory is rejected (memory.md
/// §"Marking a struct `@managed`"). Flags each `ref`-typed field.
fn flagLinearFields(gpa: std.mem.Allocator, sd: ast.StructDecl, diags: *std.ArrayList(Diag)) !void {
    var it = sd.fields();
    while (it.next()) |f| {
        const ty = f.type_() orelse continue;
        if (ty == .ref) {
            const off = if (f.name()) |nm| nm.offset else firstTokenOffset(f.cst);
            try diags.append(gpa, .{ .code = "REG020", .offset = off });
        }
    }
}

/// Scan top-level items for a `@managed` annotation immediately preceding
/// a `struct`, then check its fields for linear `ref`s (REG020). The
/// `@managed` annotation isn't attached to the struct node — it passes
/// through as sibling `@`/IDENT tokens — so we track it across the
/// SOURCE_FILE child stream up to the next item node.
fn checkManagedStructs(gpa: std.mem.Allocator, root: *const cst.Node, diags: *std.ArrayList(Diag)) !void {
    var seen_managed = false;
    var after_at = false;
    for (root.children) |c| switch (c) {
        .token => |t| {
            if (t.kind.isTrivia()) continue;
            if (t.kind == .AT) {
                after_at = true;
                continue;
            }
            if (after_at and t.kind == .IDENT) {
                if (std.mem.eql(u8, t.text, "managed")) seen_managed = true;
                after_at = false;
                continue;
            }
            after_at = false;
            if (t.kind == .KW_PUB) continue; // `@managed pub struct …`
            seen_managed = false; // a stray token breaks the annotation run
        },
        .node => |n| {
            if (n.kind == .STRUCT_DECL and seen_managed) {
                try flagLinearFields(gpa, ast.StructDecl{ .cst = n }, diags);
            }
            seen_managed = false;
            after_at = false;
        },
    };
}

/// The auto-prelude typed-string prefixes (modules.md §"Typed-prefix
/// string literals", types.md §"Typed-prefix form"). v0 ships the one
/// the prelude blesses: `url"…"`, reachable because `Url` appears in
/// `Net.get`'s signature. User-imported `StringLit` fits aren't resolved
/// yet, so any prefix outside this set is LEX020.
const prelude_str_prefixes = [_][]const u8{"url"};

fn isKnownStrPrefix(name: []const u8) bool {
    for (prelude_str_prefixes) |p| {
        if (std.mem.eql(u8, p, name)) return true;
    }
    return false;
}

/// **LEX020** — an `<ident>"…"` typed-string prefix whose identifier
/// doesn't name a reachable `StringLit` fit. A STR_PREFIX token can sit
/// in any expression position, so the scan recurses over the whole CST
/// and flags each unknown prefix at the identifier's offset.
fn checkTypedPrefixes(
    gpa: std.mem.Allocator,
    node: *const cst.Node,
    diags: *std.ArrayList(Diag),
) std.mem.Allocator.Error!void {
    for (node.children) |ch| switch (ch) {
        .token => |t| if (t.kind == .STR_PREFIX and !isKnownStrPrefix(t.text)) {
            try diags.append(gpa, .{ .code = "LEX020", .offset = t.offset });
        },
        .node => |n| try checkTypedPrefixes(gpa, n, diags),
    };
}

/// **TYP108**: in a generic parameter list, no parameter without a default
/// may follow one that has a default (spec/generics.md). Scans the raw
/// `GENERIC_PARAMS` token span, splitting on top-level commas and detecting a
/// top-level `=` per parameter (nested `<>`/`[]`/`()` in a default value are
/// skipped via depth tracking). `const N: i64` after `T = i64` trips it.
fn checkGenericDefaults(gpa: std.mem.Allocator, gp: *const cst.Node, diags: *std.ArrayList(Diag)) !void {
    var depth: i32 = 0;
    var seen_default = false; // a previous parameter carried a default
    var cur_default = false; // the current parameter carries a default
    var in_param = false;
    var cur_off: u32 = 0; // first-token offset of the current parameter
    var first_angle = true; // skip the opening `<`
    for (gp.children) |ch| {
        const t = switch (ch) {
            .token => |x| x,
            .node => continue,
        };
        if (t.kind.isTrivia()) continue;
        if (first_angle) { // the outer `<`
            first_angle = false;
            continue;
        }
        switch (t.kind) {
            .L_ANGLE, .L_PAREN, .L_BRACK => depth += 1,
            .R_ANGLE, .R_PAREN, .R_BRACK => {
                if (depth == 0) continue; // the outer `>` — list complete
                depth -= 1;
            },
            .SHR => depth -= 2,
            .EQ => if (depth == 0) {
                cur_default = true;
            },
            .COMMA => if (depth == 0) {
                if (seen_default and !cur_default) {
                    try diags.append(gpa, .{ .code = "TYP108", .offset = cur_off });
                }
                if (cur_default) seen_default = true;
                in_param = false;
                cur_default = false;
                continue;
            },
            else => {},
        }
        if (!in_param) {
            in_param = true;
            cur_off = t.offset;
        }
    }
    // The final parameter (after the last comma).
    if (in_param and seen_default and !cur_default) {
        try diags.append(gpa, .{ .code = "TYP108", .offset = cur_off });
    }
}

/// Does the optional type expression name `want` (a plain path type)?
fn typeIsNamed(gpa: std.mem.Allocator, te_opt: ?ast.TypeExpr, want: []const u8) bool {
    const te = te_opt orelse return false;
    switch (te) {
        .path => |pt| {
            const nm = pt.name(gpa) catch return false;
            defer gpa.free(nm);
            return std.mem.eql(u8, nm, want);
        },
        else => return false,
    }
}

/// Conservative tail check for a Form-2 `main`: does the body provide a value
/// or diverge on its last statement? An explicit `return`, a `panic`, or a
/// trailing `if`/`match` (whose arms may each yield) counts; a bare `env.*`
/// void call or a non-tail statement (`let`/`assign`/`while`/…) does not.
fn form2Yields(gpa: std.mem.Allocator, body: ast.Block) bool {
    var last: ?ast.Stmt = null;
    var it = body.statements();
    while (it.next()) |s| last = s;
    const ls = last orelse return false; // empty body: no tail
    switch (ls) {
        .return_stmt, .panic_stmt, .if_stmt, .match_stmt => return true,
        .expr_stmt => |es| {
            const e = es.expression() orelse return false;
            return !isVoidEnvCall(gpa, e);
        },
        else => return false, // let/assign/while/for/loop/break/continue
    }
}

/// Is `e` a call into the ambient `env` capability (`env.out(…)`,
/// `env.exit(…)`, …)? Such calls are void, so they are not a `Result` tail.
fn isVoidEnvCall(gpa: std.mem.Allocator, e: ast.Expr) bool {
    const cc = switch (e) {
        .call => |c| c,
        else => return false,
    };
    const callee = cc.callee() orelse return false;
    const pe = switch (callee) {
        .path => |p| p,
        else => return false,
    };
    const txt = pe.text(gpa) catch return false;
    defer gpa.free(txt);
    return std.mem.startsWith(u8, txt, "env.");
}

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

/// Offset of the node's last non-trivia token (e.g. the `?` of a
/// QUESTION_EXPR, so the diagnostic points at the offending sigil).
fn lastTokenOffset(node: *const cst.Node) u32 {
    var off: u32 = firstTokenOffset(node);
    for (node.children) |c| switch (c) {
        .token => |t| if (!t.kind.isTrivia()) {
            off = t.offset;
        },
        .node => |n| off = lastTokenOffset(n),
    };
    return off;
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

    // Item-level checks: TYP108 generic default-ordering (fn / struct / enum)
    // and EFF140/EFF141 on `pub effect @<name>` declarations.
    var git = sf.items();
    while (git.next()) |item| {
        const gp: ?*const cst.Node = switch (item) {
            .fn_decl => |fd| fd.genericParams(),
            .struct_decl => |sd| sd.genericParams(),
            .enum_decl => |ed| ed.genericParams(),
            else => null,
        };
        if (gp) |g| try checkGenericDefaults(gpa, g, &diags);
        if (item == .effect_decl) try checkEffectDecl(gpa, item.effect_decl, &diags);
        if (item == .fn_decl) {
            if (item.fn_decl.effectSpec()) |es| {
                try checkEffectContradiction(gpa, es, &diags);
                try checkCancelCtx(gpa, item.fn_decl, es, &diags);
                try checkPureEnv(gpa, item.fn_decl, es, &diags);
            }
            try checkEventPre(gpa, item.fn_decl, &diags);
        }
    }

    // LEX020: unknown typed-string prefixes (`xyz"…"`) anywhere in the file.
    try checkTypedPrefixes(gpa, sf.cst, &diags);
    // REG050: unknown transfer verbs (`a.copy_to(r)`, …) anywhere in the file.
    try checkTransferVerbs(gpa, sf.cst, &diags);
    // REG020: linear `ref` fields in a `@managed` struct.
    try checkManagedStructs(gpa, sf.cst, &diags);

    var it = sf.items();
    while (it.next()) |item| switch (item) {
        .fn_decl => |fd| {
            const name_tok = fd.name() orelse continue;
            try checkMainSignature(gpa, fd, &diags);
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
                .try_forbidden = fnRetForbidsTry(gpa, store, table, fd),
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
    // The `T?` sugar: `-> i64?` and `let o: i64?` are Option values.
    try expectCodes(
        \\fn find(n: i64) -> i64? {
        \\    if n > 0 { Some(n) } else { None }
        \\}
        \\fn main {
        \\    match find(5) {
        \\        Some(v) -> env.out(v),
        \\    }
        \\    let o: i64? = mystery()
        \\    match o {
        \\        None -> env.out("none"),
        \\    }
        \\}
        \\
    , &.{ "TYP062", "TYP062" });
}

test "check: TYP300 — `try` outside a Result-returning function" {
    // Provably-not-Result returns fire: a builtin, void, the T? sugar.
    try expectCodes(
        \\fn read_size(path: str) -> i64 {
        \\    let n = try parse(path)
        \\    n
        \\}
        \\fn main {
        \\    env.out(read_size("f"))
        \\}
        \\
    , &.{"TYP300"});
    try expectCodes(
        \\fn lookup(n: i64) -> i64? {
        \\    let v = try fetch(n)
        \\    Some(v)
        \\}
        \\fn main {
        \\    let o = lookup(1)
        \\}
        \\
    , &.{"TYP300"});
    // A Result return — and an unknown named return (it could alias
    // Result) — stay silent.
    try expectCodes(
        \\fn read_size(path: str) -> Result<i64, IoError> {
        \\    let n = try parse(path)
        \\    Ok(n)
        \\}
        \\fn weird(path: str) -> SomeAlias {
        \\    let n = try parse(path)
        \\    n
        \\}
        \\fn main {
        \\    let r = read_size("f")
        \\}
        \\
    , &.{});
}

test "check: EFF140 / EFF141 — user effect name collisions and shape" {
    // Shadows a core marker.
    try expectCodes("pub effect @realtime\nfn main { env.out(\"hi\") }\n", &.{"EFF140"});
    try expectCodes("effect @io\nfn main { env.out(\"hi\") }\n", &.{"EFF140"});
    // Invalid name (uppercase / not `^[a-z][a-z_]*$`).
    try expectCodes("pub effect @Logging\nfn main { env.out(\"hi\") }\n", &.{"EFF141"});
    // A well-formed, non-colliding user effect is silent.
    try expectCodes("pub effect @logging\nfn main { env.out(\"hi\") }\n", &.{});
    try expectCodes("pub effect @audit_trail\nfn main { env.out(\"hi\") }\n", &.{});
}

test "check: EFF120 — contradictory effect sets" {
    // An assert + a forbidden capability.
    try expectCodes("pub fn render @realtime + @io { env.out(\"x\") }\n", &.{"EFF120"});
    try expectCodes("fn f() -> i64 @pure + @network { 0 }\n", &.{"EFF120"});
    // `@wire` ⇒ `@io`, so `@realtime + @wire` is EFF120 (the capability is
    // forbidden directly here — `@wire` is itself a capability marker).
    try expectCodes("fn g() @realtime + @wire { env.out(\"x\") }\n", &.{"EFF120"});
    // Realtime-safe carve-outs stay silent.
    try expectCodes("fn h() @realtime + @audio { env.out(\"x\") }\n", &.{});
    try expectCodes("fn k() @realtime + @time { env.out(\"x\") }\n", &.{});
    // Two asserts compose; a lone assert or lone capability is fine.
    // (`@pure` bodies stay env-free so ENV056 doesn't also fire.)
    try expectCodes("fn a() -> i64 @realtime + @pure { 0 }\n", &.{});
    try expectCodes("fn b() @realtime { env.out(\"x\") }\n", &.{});
    try expectCodes("fn c() @io { env.out(\"x\") }\n", &.{});
    // A user marker is neither assert nor capability — no contradiction.
    try expectCodes("fn d() @realtime + @logging { env.out(\"x\") }\n", &.{});
    // `@pure` forbids every capability.
    try expectCodes("fn e() -> i64 @pure + @audio { 0 }\n", &.{"EFF120"});
}

test "check: EFF160 — `@cancel` requires a `ctx: Cancel` parameter" {
    // No params at all → EFF160.
    try expectCodes("pub fn watcher @cancel { env.out(\"x\") }\n", &.{"EFF160"});
    // A param, but not `Cancel`-typed → still EFF160.
    try expectCodes("fn w(n: i64) @cancel { env.out(\"x\") }\n", &.{"EFF160"});
    // A `Cancel`-typed parameter satisfies the requirement.
    try expectCodes("fn fetch(ctx: Cancel, n: i64) @cancel { env.out(\"x\") }\n", &.{});
    // `@cancel` not declared → no requirement.
    try expectCodes("fn plain(n: i64) { env.out(\"x\") }\n", &.{});
}

test "check: ENV056 — ambient `env` from a `@pure` function" {
    // A `@pure` body touching `env.X`.
    try expectCodes("pub fn p(x: i64) -> i64 @pure { env.out(\"c\")\n x }\n", &.{"ENV056"});
    // `@pure` without any `env` reference is clean.
    try expectCodes("fn q(x: i64) -> i64 @pure { x * 2 }\n", &.{});
    // A non-`@pure` function may use `env` freely.
    try expectCodes("fn r(x: i64) { env.out(\"ok\") }\n", &.{});
    // A parameter named `env` shadows the ambient binding — not ambient.
    try expectCodes("fn s(env: Env) -> i64 @pure { env.out(\"x\")\n 0 }\n", &.{});
}

test "check: STR051 — `pre()` on an Event parameter" {
    // `.pre()` on an `Event<…>` parameter.
    try expectCodes("fn echo(clicks: Event<Point>) -> Event<Point> { clicks.pre() }\n", &.{"STR051"});
    // `.pre()` on a `Signal<…>` parameter is valid (feedback).
    try expectCodes("fn fb(s: Signal<f32, 48.kHz>) -> Signal<f32, 48.kHz> { s.pre() }\n", &.{});
    // A non-`pre` method on an event is fine.
    try expectCodes("fn m(clicks: Event<Point>) { let _ = clicks.map(f) }\n", &.{});
}

test "check: REG020 — linear ref in a @managed struct" {
    // A `ref` field in a `@managed` struct.
    try expectCodes(
        \\@managed
        \\struct GameState { label: ref [u8], counter: i64 }
        \\fn main { env.out("hi") }
        \\
    , &.{"REG020"});
    // No `@managed` annotation → a `ref` field is fine here.
    try expectCodes("struct S { p: ref [u8] }\nfn main { env.out(\"hi\") }\n", &.{});
    // `@managed` with only value fields is clean.
    try expectCodes(
        \\@managed
        \\struct Ok { a: i64, b: bool }
        \\fn main { env.out("hi") }
        \\
    , &.{});
}

test "check: REG050 — unknown transfer verbs" {
    try expectCodes("fn main { let b = a.copy_to(arena2) }\n", &.{"REG050"});
    try expectCodes("fn main { let b = a.pin_to(p) }\n", &.{"REG050"});
    try expectCodes("fn main { let b = a.intern(pool) }\n", &.{"REG050"});
    // The real verb is silent.
    try expectCodes("fn main { let b = a.transfer(to: arena2) }\n", &.{});
    // An ordinary method call is untouched.
    try expectCodes("fn main { let n = xs.len() }\n", &.{});
}

test "check: LEX020 — unknown typed-string prefix" {
    // An unknown prefix is flagged.
    try expectCodes("fn main { let b = xyz\"hello\" }\n", &.{"LEX020"});
    // The auto-prelude `url` prefix is silent.
    try expectCodes("fn main { let u = url\"https://q64.dev\" }\n", &.{});
    // A plain string (no prefix) is untouched; a space before the quote
    // means it's an ordinary identifier, not a prefix.
    try expectCodes("fn main { env.out(\"hi\") }\n", &.{});
    // Each unknown prefix in the file is flagged independently.
    try expectCodes(
        \\fn main {
        \\    let a = foo"x"
        \\    let b = url"https://q64.dev"
        \\    let c = bar"y"
        \\}
        \\
    , &.{ "LEX020", "LEX020" });
}

test "check: TYP108 — a non-default generic parameter after a default" {
    // A `const` param with no default follows a defaulted type param.
    try expectCodes(
        \\pub struct Buffer<T = i64, const N: i64> {
        \\    data: [T; N],
        \\}
        \\fn main { env.out("hi") }
        \\
    , &.{"TYP108"});
    // Valid orderings stay silent: no defaults, all defaults, default last.
    try expectCodes("fn pair<T, U>() { }\nfn main { env.out(\"hi\") }\n", &.{});
    try expectCodes(
        \\fn buffer<T, const N: i64 = 16>() { }
        \\fn main { env.out("hi") }
        \\
    , &.{});
}

test "check: ENV052 — `main` signature mismatch (wrong param / return)" {
    // A wrong-typed parameter.
    try expectCodes(
        \\fn main(args: [str]) {
        \\    let _ = args
        \\}
        \\
    , &.{"ENV052"});
    // A non-Result return type.
    try expectCodes(
        \\fn main -> i64 {
        \\    0
        \\}
        \\
    , &.{"ENV052"});
    // The four valid shapes stay silent.
    try expectCodes("fn main { env.out(\"hi\") }\n", &.{});
    try expectCodes("fn main(env: Env) { env.out(\"hi\") }\n", &.{});
    try expectCodes(
        \\fn main -> Result<(), Error> {
        \\    Ok(())
        \\}
        \\
    , &.{});
}

test "check: ENV050 — Form-2 `main` falls off the end without a Result tail" {
    try expectCodes(
        \\fn main -> Result<(), Error> {
        \\    env.out("hello")
        \\}
        \\
    , &.{"ENV050"});
    // An explicit `Ok(())` tail or a trailing `match` is silent.
    try expectCodes(
        \\fn main -> Result<(), Error> {
        \\    env.out("hello")
        \\    Ok(())
        \\}
        \\
    , &.{});
}

test "check: TYP305 — postfix `?` is rejected (q64 uses `try`)" {
    // `expr?` in a let initializer fires regardless of the return type —
    // even in a Result-returning function, where `try` would be valid.
    try expectCodes(
        \\fn read_size(path: str) -> Result<i64, IoError> {
        \\    let bytes = env.fs.read(path)?
        \\    Ok(bytes)
        \\}
        \\fn main {
        \\    let r = read_size("f")
        \\}
        \\
    , &.{"TYP305"});
    // `T?` in type position is the Option sugar, not the `?` operator — silent.
    try expectCodes(
        \\fn find(n: i64) -> i64? {
        \\    Some(n)
        \\}
        \\fn main {
        \\    let o = find(1)
        \\}
        \\
    , &.{});
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
