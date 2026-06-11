//! Sema type representation (ladder rung A2). An interned, structural
//! type store covering the spec surface the parser already structures:
//! the builtin tower (spec/types.md), named types resolved against the
//! file's symbol table, optionals, refs, slices, arrays, and tuples.
//!
//! Like resolve.zig, this pass *records* problems rather than emitting
//! them: a type name that resolves to nothing (or to a non-type symbol)
//! becomes an `.unresolved` type, surfaced by `q64 show symbols` and
//! ready for the A4 TYP-code wiring. `fn`/`dyn`/union types are still
//! raw parser spans (`.unparsed`) until their grammar lands.
//!
//! Generic arguments are carried as raw source text (`Vec<f32>` keeps
//! `"<f32>"`): structured generic args are a deferred parser item, and
//! pretending otherwise here would just invent a second parser.

const std = @import("std");
const parser = @import("parser");
const ast = parser.ast;
const symbols = @import("symbols.zig");

pub const TypeId = u32;

/// The builtin tower the type checker recognizes by name
/// (spec/types.md §"Numeric tower" + bool/str/void).
pub const Builtin = enum {
    i8,
    i16,
    i32,
    i64,
    i128,
    u8,
    u16,
    u32,
    u64,
    u128,
    f16,
    f32,
    f64,
    bool,
    str,
    void,

    pub fn fromName(name: []const u8) ?Builtin {
        inline for (@typeInfo(Builtin).@"enum".fields) |f| {
            if (std.mem.eql(u8, name, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }
};

/// What kind of declaration a `.named` type points at.
pub const NamedKind = enum {
    struct_,
    enum_,
    type_alias,
    face,
    /// Bound by an import; its declaring module isn't loaded in this
    /// pass, so the shape is unknown until cross-module resolution (A3).
    imported,
};

pub const Type = union(enum) {
    builtin: Builtin,
    named: Named,
    optional: TypeId,
    ref_: TypeId,
    slice: TypeId,
    /// Element type only; the count is a raw span in the v0 grammar.
    array: TypeId,
    tuple: []const TypeId,
    /// A path type whose name resolves to nothing (or to a value, not a
    /// type). Recorded, not yet emitted.
    unresolved: []const u8,
    /// A form the v0 parser leaves unstructured (fn / dyn / union), or a
    /// missing annotation.
    unparsed,

    pub const Named = struct {
        kind: NamedKind,
        /// Interned in the store.
        name: []const u8,
        /// Raw generic-argument text (`"<f32>"`), interned; null when none.
        args: ?[]const u8,
    };
};

/// Interned type store. Structural: equal types share a TypeId.
pub const TypeStore = struct {
    gpa: std.mem.Allocator,
    types: std.ArrayList(Type) = .empty,
    /// canonical key → TypeId. Keys are owned by the store.
    keys: std.StringHashMapUnmanaged(TypeId) = .empty,
    /// Pre-interned id for `.unparsed` (the most common fallback).
    unparsed_id: TypeId = 0,
    void_id: TypeId = 0,

    pub fn init(gpa: std.mem.Allocator) !TypeStore {
        var s = TypeStore{ .gpa = gpa };
        errdefer s.deinit();
        s.unparsed_id = try s.intern(.unparsed);
        s.void_id = try s.intern(.{ .builtin = .void });
        return s;
    }

    pub fn deinit(self: *TypeStore) void {
        for (self.types.items) |t| switch (t) {
            .tuple => |elems| self.gpa.free(elems),
            .named => |n| {
                self.gpa.free(n.name);
                if (n.args) |a| self.gpa.free(a);
            },
            .unresolved => |n| self.gpa.free(n),
            else => {},
        };
        self.types.deinit(self.gpa);
        var it = self.keys.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.keys.deinit(self.gpa);
    }

    pub fn get(self: *const TypeStore, id: TypeId) Type {
        return self.types.items[id];
    }

    /// Intern `t`. Slice/string payloads in `t` are borrowed; the store
    /// copies them when the type is new.
    pub fn intern(self: *TypeStore, t: Type) !TypeId {
        const key = try canonicalKey(self.gpa, t);
        if (self.keys.get(key)) |id| {
            self.gpa.free(key);
            return id;
        }
        const id: TypeId = @intCast(self.types.items.len);
        const owned: Type = switch (t) {
            .tuple => |elems| .{ .tuple = try self.gpa.dupe(TypeId, elems) },
            .named => |n| .{ .named = .{
                .kind = n.kind,
                .name = try self.gpa.dupe(u8, n.name),
                .args = if (n.args) |a| try self.gpa.dupe(u8, a) else null,
            } },
            .unresolved => |n| .{ .unresolved = try self.gpa.dupe(u8, n) },
            else => t,
        };
        try self.types.append(self.gpa, owned);
        try self.keys.put(self.gpa, key, id);
        return id;
    }

    fn canonicalKey(gpa: std.mem.Allocator, t: Type) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(gpa);
        switch (t) {
            .builtin => |b| try appendFmt(gpa, &buf, "b:{s}", .{@tagName(b)}),
            .named => |n| try appendFmt(gpa, &buf, "n:{s}:{s}:{s}", .{
                @tagName(n.kind), n.name, n.args orelse "",
            }),
            .optional => |id| try appendFmt(gpa, &buf, "o:{d}", .{id}),
            .ref_ => |id| try appendFmt(gpa, &buf, "r:{d}", .{id}),
            .slice => |id| try appendFmt(gpa, &buf, "s:{d}", .{id}),
            .array => |id| try appendFmt(gpa, &buf, "a:{d}", .{id}),
            .tuple => |elems| {
                try appendFmt(gpa, &buf, "t:", .{});
                for (elems) |id| try appendFmt(gpa, &buf, "{d},", .{id});
            },
            .unresolved => |n| try appendFmt(gpa, &buf, "u:{s}", .{n}),
            .unparsed => try appendFmt(gpa, &buf, "?", .{}),
        }
        return buf.toOwnedSlice(gpa);
    }

    /// Render in q64 surface syntax (`i64?`, `[f32]`, `(i64, str)`,
    /// `Vec<f32>`). Unresolved renders as `<unresolved Name>`, unparsed
    /// as `<unparsed>`. Appends to `out`.
    pub fn render(self: *const TypeStore, gpa: std.mem.Allocator, out: *std.ArrayList(u8), id: TypeId) !void {
        switch (self.get(id)) {
            .builtin => |b| try appendFmt(gpa, out, "{s}", .{@tagName(b)}),
            .named => |n| {
                try appendFmt(gpa, out, "{s}", .{n.name});
                if (n.args) |a| try appendFmt(gpa, out, "{s}", .{a});
            },
            .optional => |inner| {
                try self.render(gpa, out, inner);
                try appendFmt(gpa, out, "?", .{});
            },
            .ref_ => |inner| {
                try appendFmt(gpa, out, "ref ", .{});
                try self.render(gpa, out, inner);
            },
            .slice => |inner| {
                try appendFmt(gpa, out, "[", .{});
                try self.render(gpa, out, inner);
                try appendFmt(gpa, out, "]", .{});
            },
            .array => |inner| {
                try appendFmt(gpa, out, "[", .{});
                try self.render(gpa, out, inner);
                try appendFmt(gpa, out, "; _]", .{});
            },
            .tuple => |elems| {
                try appendFmt(gpa, out, "(", .{});
                for (elems, 0..) |e, i| {
                    if (i > 0) try appendFmt(gpa, out, ", ", .{});
                    try self.render(gpa, out, e);
                }
                try appendFmt(gpa, out, ")", .{});
            },
            .unresolved => |n| try appendFmt(gpa, out, "<unresolved {s}>", .{n}),
            .unparsed => try appendFmt(gpa, out, "<unparsed>", .{}),
        }
    }
};

fn appendFmt(gpa: std.mem.Allocator, out: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(gpa, fmt, args);
    defer gpa.free(s);
    try out.appendSlice(gpa, s);
}

/// Lower a parsed type expression against the file's symbol table.
/// `null` (no annotation) lowers to `.unparsed` — the *caller* decides
/// whether absence means `void` (return position) or inference (binding).
pub fn lower(store: *TypeStore, table: *const symbols.SymbolTable, te_opt: ?ast.TypeExpr) std.mem.Allocator.Error!TypeId {
    const te = te_opt orelse return store.unparsed_id;
    switch (te) {
        .path => |p| {
            const name = p.name(store.gpa) catch return store.unparsed_id;
            defer store.gpa.free(name);
            if (Builtin.fromName(name)) |b| return store.intern(.{ .builtin = b });

            const args = p.genericArgsText(store.gpa) catch null;
            defer if (args) |a| store.gpa.free(a);

            if (table.lookup(name)) |sym| {
                const kind: NamedKind = switch (sym.kind) {
                    .struct_ => .struct_,
                    .enum_ => .enum_,
                    .type_alias => .type_alias,
                    .face => .face,
                    .import_binding => .imported,
                    // A value symbol (fn/const/state/screen) in type
                    // position is not a type.
                    else => return store.intern(.{ .unresolved = name }),
                };
                return store.intern(.{ .named = .{ .kind = kind, .name = name, .args = args } });
            }
            return store.intern(.{ .unresolved = name });
        },
        .optional => |o| {
            const inner = try lower(store, table, o.inner());
            return store.intern(.{ .optional = inner });
        },
        .ref => |r| {
            const inner = try lower(store, table, r.inner());
            return store.intern(.{ .ref_ = inner });
        },
        .slice => |s| {
            const inner = try lower(store, table, s.element());
            return store.intern(.{ .slice = inner });
        },
        .array => |a| {
            const inner = try lower(store, table, a.element());
            return store.intern(.{ .array = inner });
        },
        .tuple => |t| {
            var elems: std.ArrayList(TypeId) = .empty;
            defer elems.deinit(store.gpa);
            var it = t.elements();
            while (it.next()) |e| try elems.append(store.gpa, try lower(store, table, e));
            // `()` is the unit/void type.
            if (elems.items.len == 0) return store.void_id;
            return store.intern(.{ .tuple = elems.items });
        },
        .raw => return store.unparsed_id,
    }
}

// =====================================================================
// Signatures
// =====================================================================

pub const FnSig = struct {
    /// Borrowed from the parsed source (caller keeps the parse alive).
    name: []const u8,
    params: []TypeId,
    /// `void` when no return annotation is written.
    ret: TypeId,
};

pub const Signatures = struct {
    gpa: std.mem.Allocator,
    sigs: std.ArrayList(FnSig) = .empty,

    pub fn deinit(self: *Signatures) void {
        for (self.sigs.items) |s| self.gpa.free(s.params);
        self.sigs.deinit(self.gpa);
    }

    pub fn find(self: *const Signatures, name: []const u8) ?FnSig {
        for (self.sigs.items) |s| {
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        return null;
    }
};

/// Lower every top-level function signature in `sf`.
pub fn collectSignatures(
    store: *TypeStore,
    table: *const symbols.SymbolTable,
    sf: ast.SourceFile,
) !Signatures {
    var out = Signatures{ .gpa = store.gpa };
    errdefer out.deinit();

    var it = sf.items();
    while (it.next()) |item| switch (item) {
        .fn_decl => |fd| {
            const name_tok = fd.name() orelse continue;

            var params: std.ArrayList(TypeId) = .empty;
            defer params.deinit(store.gpa);
            if (fd.params()) |ps| {
                var pit = ps.iter();
                while (pit.next()) |p| {
                    try params.append(store.gpa, try lower(store, table, p.type_()));
                }
            }

            // No `-> T` written means the function returns void.
            const ret = if (fd.returnType()) |rt|
                try lower(store, table, rt.type_())
            else
                store.void_id;

            try out.sigs.append(store.gpa, .{
                .name = name_tok.text,
                .params = try params.toOwnedSlice(store.gpa),
                .ret = ret,
            });
        },
        else => {},
    };
    return out;
}

// =====================================================================
// Tests
// =====================================================================

const t_alloc = std.testing.allocator;
const parse = parser.parse;

fn renderId(store: *const TypeStore, id: TypeId) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(t_alloc);
    try store.render(t_alloc, &buf, id);
    return buf.toOwnedSlice(t_alloc);
}

test "types: interner dedups structurally" {
    var store = try TypeStore.init(t_alloc);
    defer store.deinit();

    const a = try store.intern(.{ .builtin = .i64 });
    const b = try store.intern(.{ .builtin = .i64 });
    try std.testing.expectEqual(a, b);

    const o1 = try store.intern(.{ .optional = a });
    const o2 = try store.intern(.{ .optional = b });
    try std.testing.expectEqual(o1, o2);
    try std.testing.expect(o1 != a);
}

test "types: signatures lower builtins, optionals, slices, tuples, named, unresolved" {
    const src =
        \\struct Point { x: i64, y: i64 }
        \\
        \\fn f(a: i64, b: str?, c: [f32], d: (bool, u8), p: Point, m: Mystery) -> i64 { a }
        \\fn g { }
        \\
    ;
    const pr = try parse.parse(t_alloc, src, "t.q");
    defer pr.deinit(t_alloc);
    const sf = ast.SourceFile.cast(pr.root).?;
    var table = try symbols.build(t_alloc, sf);
    defer table.deinit();

    var store = try TypeStore.init(t_alloc);
    defer store.deinit();
    var sigs = try collectSignatures(&store, &table, sf);
    defer sigs.deinit();

    const f = sigs.find("f").?;
    try std.testing.expectEqual(@as(usize, 6), f.params.len);

    const cases = [_][]const u8{ "i64", "str?", "[f32]", "(bool, u8)", "Point", "<unresolved Mystery>" };
    for (cases, 0..) |want, i| {
        const got = try renderId(&store, f.params[i]);
        defer t_alloc.free(got);
        try std.testing.expectEqualStrings(want, got);
    }

    const ret = try renderId(&store, f.ret);
    defer t_alloc.free(ret);
    try std.testing.expectEqualStrings("i64", ret);

    // No annotation → void.
    const g = sigs.find("g").?;
    try std.testing.expectEqual(store.void_id, g.ret);

    // `Point` resolved through the symbol table as a struct.
    switch (store.get(f.params[4])) {
        .named => |n| try std.testing.expectEqual(NamedKind.struct_, n.kind),
        else => return error.TestUnexpectedResult,
    }
}

test "types: generic args ride along as text; imported names resolve as imported" {
    const src =
        \\import dev.q64.math.{Vec}
        \\
        \\fn h(v: Vec<f32>) -> Vec<f32> { v }
        \\
    ;
    const pr = try parse.parse(t_alloc, src, "t.q");
    defer pr.deinit(t_alloc);
    const sf = ast.SourceFile.cast(pr.root).?;
    var table = try symbols.build(t_alloc, sf);
    defer table.deinit();

    var store = try TypeStore.init(t_alloc);
    defer store.deinit();
    var sigs = try collectSignatures(&store, &table, sf);
    defer sigs.deinit();

    const h = sigs.find("h").?;
    const got = try renderId(&store, h.params[0]);
    defer t_alloc.free(got);
    try std.testing.expectEqualStrings("Vec<f32>", got);
    try std.testing.expectEqual(h.params[0], h.ret); // same interned id

    switch (store.get(h.params[0])) {
        .named => |n| try std.testing.expectEqual(NamedKind.imported, n.kind),
        else => return error.TestUnexpectedResult,
    }
}

test "types: a value symbol in type position is unresolved, not named" {
    const src =
        \\fn val { }
        \\fn k(x: val) { }
        \\
    ;
    const pr = try parse.parse(t_alloc, src, "t.q");
    defer pr.deinit(t_alloc);
    const sf = ast.SourceFile.cast(pr.root).?;
    var table = try symbols.build(t_alloc, sf);
    defer table.deinit();

    var store = try TypeStore.init(t_alloc);
    defer store.deinit();
    var sigs = try collectSignatures(&store, &table, sf);
    defer sigs.deinit();

    const k = sigs.find("k").?;
    switch (store.get(k.params[0])) {
        .unresolved => {},
        else => return error.TestUnexpectedResult,
    }
}
