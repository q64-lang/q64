//! Cross-module name resolution (sema rung A3, final slice). Owns what
//! the codegen `Resolver` used to do: index the root file's functions,
//! resolve each `import` against the `--module` source map (parsing the
//! dependency modules), and answer name → defining `ast.FnDecl` lookups
//! for the HIR builder.
//!
//! Errors stay the honest baseline trio the CLI already maps:
//! `UnknownModule` (import names a module not supplied via `--module`),
//! `NameNotFound` (a selectively-imported name isn't a `pub fn` in the
//! module), `UnsupportedImport` (forms not resolvable yet: relative
//! paths, stdlib). Per spec/q64-cli.md §"--module" the resolver never
//! reads `qube.json5` or touches the filesystem — sources are handed in.
//!
//! v0 boundary (unchanged from the codegen Resolver): lookups return
//! function declarations only; bare-dotted *selective* imports are the
//! resolvable form. The name → kind/visibility view of the same file
//! lives in `symbols.zig`; the two converge when sema owns declaration
//! storage (ladder B).

const std = @import("std");
const parser = @import("parser");
const ast = parser.ast;
const parse = parser.parse;

pub const ModuleSource = struct {
    name: []const u8,
    source: []const u8,
};

pub const LinkError = error{
    UnknownModule,
    NameNotFound,
    UnsupportedImport,
} || std.mem.Allocator.Error;

/// A resolved function: its declaration + the scope its body resolves in.
pub const Resolved = struct { fd: ast.FnDecl, scope: u32 };

/// One module's resolution scope: its source file plus a name → `Resolved`
/// table (its own top-level functions, mapped to *this* scope, plus the `pub
/// fn`s it selectively imports, mapped to the providing module's scope).
const Scope = struct {
    sf: ast.SourceFile,
    table: std.StringHashMapUnmanaged(Resolved) = .empty,
};

/// Module-scoped cross-module resolution. Scope 0 is the root file; each
/// transitively-imported module gets its own scope. A name resolves in the
/// *caller's* scope, but the resolved callee carries the scope its **own** body
/// resolves in — so a library's functions can call the library's other
/// functions and the library's imports (transitively), while a module's private
/// functions stay invisible to other modules.
pub const Linker = struct {
    gpa: std.mem.Allocator,
    modules: []const ModuleSource,
    /// Parsed dependency modules, kept alive so the `FnDecl` views stay valid.
    parsed: std.ArrayList(parse.Result) = .empty,
    /// All scopes; index 0 is the root file's scope.
    scopes: std.ArrayList(Scope) = .empty,
    /// Module name → its scope index (also the cycle guard / parse-once cache).
    /// Keys are the stable `ModuleSource.name` slices (live for the linker).
    module_scope: std.StringHashMapUnmanaged(u32) = .empty,

    pub fn init(gpa: std.mem.Allocator, modules: []const ModuleSource) Linker {
        return .{ .gpa = gpa, .modules = modules };
    }

    pub fn deinit(self: *Linker) void {
        for (self.parsed.items) |r| r.deinit(self.gpa);
        self.parsed.deinit(self.gpa);
        for (self.scopes.items) |*s| s.table.deinit(self.gpa);
        self.scopes.deinit(self.gpa);
        self.module_scope.deinit(self.gpa);
    }

    /// Build the root scope (index 0) and, transitively, a scope for every
    /// imported module. Call once with the root source file.
    pub fn build(self: *Linker, sf: ast.SourceFile) LinkError!void {
        try self.scopes.append(self.gpa, .{ .sf = sf });
        try self.indexLocals(sf, 0);
        try self.resolveImportsInto(sf, 0);
    }

    /// The source file backing a scope (0 = the root file; imported modules
    /// get theirs when their scope is built). Null for an unknown index.
    pub fn sourceFile(self: *const Linker, scope: u32) ?ast.SourceFile {
        if (scope >= self.scopes.items.len) return null;
        return self.scopes.items[scope].sf;
    }

    /// Index every top-level function of `sf` into scope `scope_idx`, each
    /// mapped to that same scope (a module's own functions resolve in it).
    fn indexLocals(self: *Linker, sf: ast.SourceFile, scope_idx: u32) std.mem.Allocator.Error!void {
        var it = sf.items();
        while (it.next()) |item| switch (item) {
            .fn_decl => |fd| {
                const name = fd.name() orelse continue;
                try self.scopes.items[scope_idx].table.put(self.gpa, name.text, .{ .fd = fd, .scope = scope_idx });
            },
            else => {},
        };
    }

    /// Resolve `sf`'s imports into scope `scope_idx`: each selectively-imported
    /// `pub fn` is bound to the providing module's scope (built on demand).
    fn resolveImportsInto(self: *Linker, sf: ast.SourceFile, scope_idx: u32) LinkError!void {
        var imports = sf.imports();
        while (imports.next()) |im| {
            if (im.isRelative()) return LinkError.UnsupportedImport;
            const module_path = (try im.path(self.gpa)) orelse return LinkError.UnsupportedImport;
            defer self.gpa.free(module_path);

            const dep_scope = try self.ensureModuleScope(module_path);
            const dep_sf = self.scopes.items[dep_scope].sf;
            var names = im.names();
            while (names.next()) |name_tok| {
                const fd = findPublicFn(dep_sf, name_tok.text) orelse return LinkError.NameNotFound;
                try self.scopes.items[scope_idx].table.put(self.gpa, name_tok.text, .{ .fd = fd, .scope = dep_scope });
            }
        }
    }

    /// The scope for module `name`, building it (parse + index locals + resolve
    /// its own imports) on first request. Idempotent — the `module_scope` entry
    /// is recorded before recursing, so an import cycle terminates.
    fn ensureModuleScope(self: *Linker, name: []const u8) LinkError!u32 {
        if (self.module_scope.get(name)) |idx| return idx;
        const m = self.moduleByName(name) orelse return LinkError.UnknownModule;

        const r = try parse.parse(self.gpa, m.source, m.name);
        try self.parsed.append(self.gpa, r);
        const dep_sf = ast.SourceFile.cast(r.root) orelse return LinkError.UnknownModule;

        const idx: u32 = @intCast(self.scopes.items.len);
        try self.scopes.append(self.gpa, .{ .sf = dep_sf });
        try self.module_scope.put(self.gpa, m.name, idx); // record BEFORE recursing (cycle guard)
        try self.indexLocals(dep_sf, idx);
        try self.resolveImportsInto(dep_sf, idx);
        return idx;
    }

    fn moduleByName(self: *Linker, name: []const u8) ?ModuleSource {
        for (self.modules) |m| {
            if (std.mem.eql(u8, m.name, name)) return m;
        }
        return null;
    }

    /// Resolve `name` in scope `scope`. Returns the declaration + the scope its
    /// body resolves in, or null if the name isn't visible in that scope.
    pub fn lookup(self: *Linker, scope: u32, name: []const u8) ?Resolved {
        if (scope >= self.scopes.items.len) return null;
        return self.scopes.items[scope].table.get(name);
    }
};

/// The `pub fn` named `name` in `sf`, if any. Only public functions are
/// importable (spec/modules.md NAM006).
pub fn findPublicFn(sf: ast.SourceFile, name: []const u8) ?ast.FnDecl {
    var it = sf.items();
    while (it.next()) |item| switch (item) {
        .fn_decl => |fd| {
            if (!fd.isPublic()) continue;
            const fn_name = fd.name() orelse continue;
            if (std.mem.eql(u8, fn_name.text, name)) return fd;
        },
        else => {},
    };
    return null;
}

// =====================================================================
// Tests
// =====================================================================

const t_alloc = std.testing.allocator;

const Linked = struct {
    pr: parse.Result,
    linker: Linker,

    fn deinit(self: *Linked) void {
        self.linker.deinit();
        self.pr.deinit(t_alloc);
    }
};

fn linkSource(root: []const u8, modules: []const ModuleSource) LinkError!Linked {
    const pr = try parse.parse(t_alloc, root, "root.q");
    errdefer pr.deinit(t_alloc);
    const sf = ast.SourceFile.cast(pr.root) orelse return LinkError.UnknownModule;
    var linker = Linker.init(t_alloc, modules);
    errdefer linker.deinit();
    try linker.build(sf);
    return .{ .pr = pr, .linker = linker };
}

test "link: local functions and imported pub fns both resolve" {
    const dep = "pub fn version() -> str { \"0.1.0\" }\nfn private_helper { }\n";
    var l = try linkSource(
        \\import dev.q64.hello_world.{version}
        \\
        \\fn local_helper -> i64 { 1 }
        \\fn main { env.out(version()) }
        \\
    , &.{.{ .name = "dev.q64.hello_world", .source = dep }});
    defer l.deinit();

    // Root scope (0) sees its own functions + the imported `version`.
    try std.testing.expect(l.linker.lookup(0, "version") != null);
    try std.testing.expect(l.linker.lookup(0, "local_helper") != null);
    try std.testing.expect(l.linker.lookup(0, "main") != null);
    // `version` resolves into the dependency's OWN scope (not root).
    try std.testing.expect(l.linker.lookup(0, "version").?.scope != 0);
    // The dependency's private function is invisible from the root scope.
    try std.testing.expect(l.linker.lookup(0, "private_helper") == null);
}

test "link: a module sees its own private helper in its own scope" {
    // libA's `a` calls its private `helper` — `helper` lives in libA's scope,
    // not the root scope.
    const lib = "fn helper() -> i64 { 5 }\npub fn a() -> i64 { helper() + 1 }\n";
    var l = try linkSource(
        "import test.a.{a}\nfn main { env.out(a()) }\n",
        &.{.{ .name = "test.a", .source = lib }},
    );
    defer l.deinit();

    const a = l.linker.lookup(0, "a").?; // root imports `a`
    try std.testing.expect(a.scope != 0); // a's body resolves in libA's scope
    // `helper` is visible in libA's scope, invisible in root's.
    try std.testing.expect(l.linker.lookup(a.scope, "helper") != null);
    try std.testing.expect(l.linker.lookup(0, "helper") == null);
}

test "link: transitive — a library imports another library" {
    // app → libA → libB. libA's `a` calls libB's imported `b`.
    const libB = "pub fn b() -> i64 { 7 }\n";
    const libA = "import test.b.{b}\npub fn a() -> i64 { b() + 1 }\n";
    var l = try linkSource(
        "import test.a.{a}\nfn main { env.out(a()) }\n",
        &.{
            .{ .name = "test.a", .source = libA },
            .{ .name = "test.b", .source = libB },
        },
    );
    defer l.deinit();

    const a = l.linker.lookup(0, "a").?;
    // In libA's scope, the imported `b` resolves into libB's (distinct) scope.
    const b = l.linker.lookup(a.scope, "b").?;
    try std.testing.expect(b.scope != a.scope and b.scope != 0);
    // `b` is not visible from the root scope (only libA imports it).
    try std.testing.expect(l.linker.lookup(0, "b") == null);
}

test "link: sourceFile exposes each scope's file (for imported module consts)" {
    const lib = "let K = 3.5\npub fn a() -> f64 { K }\n";
    var l = try linkSource(
        "import test.a.{a}\nfn main { env.out(a()) }\n",
        &.{.{ .name = "test.a", .source = lib }},
    );
    defer l.deinit();

    const a = l.linker.lookup(0, "a").?;
    // The imported module's scope hands back ITS source file — the builder
    // collects `let K = …` module consts from it on first entry.
    const dep_sf = l.linker.sourceFile(a.scope) orelse return error.TestUnexpectedResult;
    var found_let = false;
    var it = dep_sf.items();
    while (it.next()) |item| switch (item) {
        .let_decl => found_let = true,
        else => {},
    };
    try std.testing.expect(found_let);
    // Root's file is scope 0; an unknown scope is null, never a panic.
    try std.testing.expect(l.linker.sourceFile(0) != null);
    try std.testing.expect(l.linker.sourceFile(99) == null);
}

test "link: unknown module / missing name / private name / relative import error honestly" {
    const dep = "pub fn version() -> str { \"0.1.0\" }\nfn secret { }\n";
    const mods: []const ModuleSource = &.{.{ .name = "dev.q64.hello_world", .source = dep }};

    try std.testing.expectError(LinkError.UnknownModule, linkSource(
        "import dev.q64.nope.{version}\nfn main { }\n",
        mods,
    ));
    try std.testing.expectError(LinkError.NameNotFound, linkSource(
        "import dev.q64.hello_world.{missing}\nfn main { }\n",
        mods,
    ));
    // A private fn is not importable (spec/modules.md NAM006's rule;
    // surfaced as NameNotFound at this layer today).
    try std.testing.expectError(LinkError.NameNotFound, linkSource(
        "import dev.q64.hello_world.{secret}\nfn main { }\n",
        mods,
    ));
    try std.testing.expectError(LinkError.UnsupportedImport, linkSource(
        "import \"./util.q\".{helper}\nfn main { }\n",
        mods,
    ));
}
