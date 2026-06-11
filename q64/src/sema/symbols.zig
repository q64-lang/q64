//! File-level symbol table — the sema scaffold (ladder rung A0, see
//! README.md). One symbol per top-level item and per selective-import
//! binding; first-binding-wins lookup; same-name collisions recorded for
//! the A1 diagnostic wiring (NAM005 for the import-involving ones).
//!
//! Imports `parser` only — never `ir/`, never Binaryen. The table owns
//! every string it hands out, so it outlives the parse result.

const std = @import("std");
const parser = @import("parser");
const ast = parser.ast;
const parse = parser.parse;

pub const SymbolKind = enum {
    function,
    struct_,
    enum_,
    type_alias,
    constant,
    state,
    face,
    fit,
    screen,
    import_binding,

    pub fn label(self: SymbolKind) []const u8 {
        return switch (self) {
            .function => "fn",
            .struct_ => "struct",
            .enum_ => "enum",
            .type_alias => "type",
            .constant => "const",
            .state => "state",
            .face => "face",
            .fit => "fit",
            .screen => "screen",
            .import_binding => "import",
        };
    }
};

pub const Symbol = struct {
    /// Owned by the table.
    name: []const u8,
    kind: SymbolKind,
    public: bool,
    /// For an `import_binding`: the module path it came from (owned).
    origin: ?[]const u8 = null,
};

/// Two bindings of one name. Indices into `SymbolTable.syms`; the earlier
/// binding wins `lookup` until the A1 diagnostic wiring rejects the file.
pub const Collision = struct { name: []const u8, first: u32, second: u32 };

pub const SymbolTable = struct {
    gpa: std.mem.Allocator,
    /// Every symbol in declaration order — including `fit` entries, which
    /// are listed for introspection but are NOT name bindings (a fit is
    /// keyed by its (type, face) pair; binding its leading type name would
    /// false-collide with the type's own declaration).
    syms: std.ArrayList(Symbol) = .empty,
    /// name → index of the FIRST binding. `fit` entries are absent.
    by_name: std.StringHashMapUnmanaged(u32) = .empty,
    collisions: std.ArrayList(Collision) = .empty,

    pub fn deinit(self: *SymbolTable) void {
        for (self.syms.items) |s| {
            self.gpa.free(s.name);
            if (s.origin) |o| self.gpa.free(o);
        }
        self.syms.deinit(self.gpa);
        self.by_name.deinit(self.gpa);
        self.collisions.deinit(self.gpa);
    }

    pub fn lookup(self: *const SymbolTable, name: []const u8) ?Symbol {
        const idx = self.by_name.get(name) orelse return null;
        return self.syms.items[idx];
    }

    /// Append + register in `by_name`, recording a collision on a re-bind.
    fn bind(self: *SymbolTable, sym: Symbol) !void {
        const idx: u32 = @intCast(self.syms.items.len);
        try self.syms.append(self.gpa, sym);
        const gop = try self.by_name.getOrPut(self.gpa, sym.name);
        if (gop.found_existing) {
            try self.collisions.append(self.gpa, .{
                .name = sym.name,
                .first = gop.value_ptr.*,
                .second = idx,
            });
        } else {
            gop.value_ptr.* = idx;
        }
    }

    /// Append without a name binding (fit entries).
    fn list(self: *SymbolTable, sym: Symbol) !void {
        try self.syms.append(self.gpa, sym);
    }
};

/// Build the file-level table for `sf`. Imports bind before items (they
/// lexically lead a file per spec/modules.md, so a colliding declaration
/// reports the import as the earlier binding).
pub fn build(gpa: std.mem.Allocator, sf: ast.SourceFile) !SymbolTable {
    var t = SymbolTable{ .gpa = gpa };
    errdefer t.deinit();

    var imp = sf.imports();
    while (imp.next()) |im| {
        const mod_path = try im.path(gpa);
        defer if (mod_path) |p| gpa.free(p);

        var names = im.names();
        var selective = false;
        while (names.next()) |tok| {
            selective = true;
            try t.bind(.{
                .name = try gpa.dupe(u8, tok.text),
                .kind = .import_binding,
                .public = false,
                .origin = if (mod_path) |p| try gpa.dupe(u8, p) else null,
            });
        }
        // Namespace import: binds the last path segment. (Alias imports
        // need the `as` accessor on ast.ImportStmt — rung A1.)
        if (!selective) {
            if (mod_path) |p| {
                const last = if (std.mem.lastIndexOfScalar(u8, p, '.')) |i| p[i + 1 ..] else p;
                if (last.len > 0) try t.bind(.{
                    .name = try gpa.dupe(u8, last),
                    .kind = .import_binding,
                    .public = false,
                    .origin = try gpa.dupe(u8, p),
                });
            }
        }
    }

    var it = sf.items();
    while (it.next()) |item| switch (item) {
        .fn_decl => |d| try bindNamed(&t, d.name(), .function, d.isPublic()),
        .struct_decl => |d| try bindNamed(&t, d.name(), .struct_, d.isPublic()),
        .enum_decl => |d| try bindNamed(&t, d.name(), .enum_, d.isPublic()),
        .type_decl => |d| try bindNamed(&t, d.name(), .type_alias, d.isPublic()),
        .const_decl => |d| try bindNamed(&t, d.name(), .constant, d.isPublic()),
        .state_decl => |d| try bindNamed(&t, d.name(), .state, d.visibility() != null),
        .face_decl => |d| try bindNamed(&t, d.name(), .face, d.isPublic()),
        .screen_decl => |d| try bindNamed(&t, d.name(), .screen, d.visibility() != null),
        .fit_decl => |d| {
            // Listed, not bound — see SymbolTable.syms doc comment.
            const tok = d.name() orelse continue;
            try t.list(.{
                .name = try t.gpa.dupe(u8, tok.text),
                .kind = .fit,
                .public = d.isPublic(),
            });
        },
    };

    return t;
}

fn bindNamed(t: *SymbolTable, tok: ?@import("parser").cst.Token, kind: SymbolKind, public: bool) !void {
    const tk = tok orelse return; // nameless item: a parse error already diagnosed it
    try t.bind(.{ .name = try t.gpa.dupe(u8, tk.text), .kind = kind, .public = public });
}

/// `q64 show symbols` — parse `source` and render the table. Unstable
/// human/test-facing format, like `show hir`. Caller owns the slice.
pub fn showSymbols(gpa: std.mem.Allocator, source: []const u8, file: []const u8) ![]u8 {
    const pr = try parse.parse(gpa, source, file);
    defer pr.deinit(gpa);
    const sf = ast.SourceFile.cast(pr.root) orelse return error.NoSourceFile;

    var t = try build(gpa, sf);
    defer t.deinit();
    return render(gpa, &t, file);
}

fn render(gpa: std.mem.Allocator, t: *const SymbolTable, file: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try app(gpa, &out, "symbols {s}\n", .{file});
    for (t.syms.items) |s| {
        try app(gpa, &out, "  {s}{s} {s}", .{
            if (s.public) "pub " else "",
            s.kind.label(),
            s.name,
        });
        if (s.origin) |o| try app(gpa, &out, " <- {s}", .{o});
        if (s.kind == .fit) try out.appendSlice(gpa, " (impl entry; not a name binding)");
        try out.appendSlice(gpa, "\n");
    }
    if (t.collisions.items.len > 0) {
        try out.appendSlice(gpa, "collisions\n");
        for (t.collisions.items) |c| {
            const a = t.syms.items[c.first];
            const b = t.syms.items[c.second];
            try app(gpa, &out, "  {s}: {s} then {s}\n", .{ c.name, a.kind.label(), b.kind.label() });
        }
    }
    return out.toOwnedSlice(gpa);
}

fn app(gpa: std.mem.Allocator, out: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(gpa, fmt, args);
    defer gpa.free(s);
    try out.appendSlice(gpa, s);
}

// =====================================================================
// Tests
// =====================================================================

const t_alloc = std.testing.allocator;

fn buildFromSource(source: []const u8) !struct { pr: parse.Result, table: SymbolTable } {
    const pr = try parse.parse(t_alloc, source, "test.q");
    errdefer pr.deinit(t_alloc);
    const sf = ast.SourceFile.cast(pr.root) orelse return error.NoSourceFile;
    const table = try build(t_alloc, sf);
    return .{ .pr = pr, .table = table };
}

test "symbols: every top-level item kind binds with its visibility" {
    var r = try buildFromSource(
        \\import dev.q64.hello_world.{version}
        \\
        \\pub fn greet(name: str) -> str { "hi {name}" }
        \\fn main { env.out(greet("q64")) }
        \\struct Point { x: i64, y: i64 }
        \\pub face Display { }
        \\fit Point : Display { }
        \\state count = 0
        \\
    );
    defer r.pr.deinit(t_alloc);
    defer r.table.deinit();

    const greet = r.table.lookup("greet").?;
    try std.testing.expectEqual(SymbolKind.function, greet.kind);
    try std.testing.expect(greet.public);

    const main_sym = r.table.lookup("main").?;
    try std.testing.expect(!main_sym.public);

    try std.testing.expectEqual(SymbolKind.struct_, r.table.lookup("Point").?.kind);
    try std.testing.expectEqual(SymbolKind.face, r.table.lookup("Display").?.kind);
    try std.testing.expectEqual(SymbolKind.state, r.table.lookup("count").?.kind);

    const version = r.table.lookup("version").?;
    try std.testing.expectEqual(SymbolKind.import_binding, version.kind);
    try std.testing.expectEqualStrings("dev.q64.hello_world", version.origin.?);

    try std.testing.expectEqual(@as(usize, 0), r.table.collisions.items.len);
    try std.testing.expect(r.table.lookup("nope") == null);
}

test "symbols: a fit is listed but is not a name binding (no false collision)" {
    var r = try buildFromSource(
        \\struct Point { x: i64 }
        \\fit Point : Display { }
        \\
    );
    defer r.pr.deinit(t_alloc);
    defer r.table.deinit();

    // `fit Point` must not collide with `struct Point` …
    try std.testing.expectEqual(@as(usize, 0), r.table.collisions.items.len);
    // … and lookup resolves to the struct, not the fit.
    try std.testing.expectEqual(SymbolKind.struct_, r.table.lookup("Point").?.kind);
    // The fit still appears in the listing.
    var fits: usize = 0;
    for (r.table.syms.items) |s| {
        if (s.kind == .fit) fits += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), fits);
}

test "symbols: import-vs-declaration collision is recorded, first binding wins" {
    var r = try buildFromSource(
        \\import dev.q64.util.{helper}
        \\
        \\fn helper { env.out("local") }
        \\
    );
    defer r.pr.deinit(t_alloc);
    defer r.table.deinit();

    try std.testing.expectEqual(@as(usize, 1), r.table.collisions.items.len);
    const c = r.table.collisions.items[0];
    try std.testing.expectEqualStrings("helper", c.name);
    // The import lexically leads, so it is the surviving binding.
    try std.testing.expectEqual(SymbolKind.import_binding, r.table.lookup("helper").?.kind);
}

test "symbols: namespace import binds the last path segment" {
    var r = try buildFromSource(
        \\import dev.q64.hello_world
        \\
        \\fn main { env.out("hi") }
        \\
    );
    defer r.pr.deinit(t_alloc);
    defer r.table.deinit();

    const ns = r.table.lookup("hello_world").?;
    try std.testing.expectEqual(SymbolKind.import_binding, ns.kind);
    try std.testing.expectEqualStrings("dev.q64.hello_world", ns.origin.?);
}

test "showSymbols: renders kinds, origins, and collisions" {
    const dump = try showSymbols(t_alloc,
        \\import dev.q64.util.{helper}
        \\
        \\pub fn helper { env.out("x") }
        \\fit Point : Display { }
        \\
    , "t.q");
    defer t_alloc.free(dump);

    try std.testing.expect(std.mem.indexOf(u8, dump, "symbols t.q") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump, "import helper <- dev.q64.util") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump, "pub fn helper") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump, "fit Point (impl entry; not a name binding)") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump, "collisions") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump, "helper: import then fn") != null);
}
