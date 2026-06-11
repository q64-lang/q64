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

pub const Linker = struct {
    gpa: std.mem.Allocator,
    modules: []const ModuleSource,
    /// Parsed dependency modules, kept alive so the `FnDecl` views below
    /// stay valid for the lifetime of the linker.
    parsed: std.ArrayList(parse.Result) = .empty,
    /// name → defining function. Keys are slices into a CST that outlives
    /// the linker (the caller's parse result or a `parsed` entry).
    symbols: std.StringHashMapUnmanaged(ast.FnDecl) = .empty,

    pub fn init(gpa: std.mem.Allocator, modules: []const ModuleSource) Linker {
        return .{ .gpa = gpa, .modules = modules };
    }

    pub fn deinit(self: *Linker) void {
        for (self.parsed.items) |r| r.deinit(self.gpa);
        self.parsed.deinit(self.gpa);
        self.symbols.deinit(self.gpa);
    }

    /// Index every top-level function in `sf` under its own name, so a
    /// program that defines and calls a local function resolves without
    /// an import.
    pub fn indexLocalFunctions(self: *Linker, sf: ast.SourceFile) std.mem.Allocator.Error!void {
        var it = sf.items();
        while (it.next()) |item| switch (item) {
            .fn_decl => |fd| {
                const name = fd.name() orelse continue;
                try self.symbols.put(self.gpa, name.text, fd);
            },
            else => {},
        };
    }

    /// Resolve each import statement against the `--module` set. Binds
    /// every selectively-imported name to its defining `pub fn`.
    pub fn resolveImports(self: *Linker, sf: ast.SourceFile) LinkError!void {
        var imports = sf.imports();
        while (imports.next()) |im| {
            if (im.isRelative()) return LinkError.UnsupportedImport;

            const module_path = (try im.path(self.gpa)) orelse return LinkError.UnsupportedImport;
            defer self.gpa.free(module_path);

            const src = self.moduleSource(module_path) orelse return LinkError.UnknownModule;

            const r = try parse.parse(self.gpa, src, module_path);
            try self.parsed.append(self.gpa, r);
            const dep_sf = ast.SourceFile.cast(r.root) orelse return LinkError.UnknownModule;

            var names = im.names();
            while (names.next()) |name_tok| {
                const fd = findPublicFn(dep_sf, name_tok.text) orelse return LinkError.NameNotFound;
                try self.symbols.put(self.gpa, name_tok.text, fd);
            }
        }
    }

    fn moduleSource(self: *Linker, name: []const u8) ?[]const u8 {
        for (self.modules) |m| {
            if (std.mem.eql(u8, m.name, name)) return m.source;
        }
        return null;
    }

    pub fn lookup(self: *Linker, name: []const u8) ?ast.FnDecl {
        return self.symbols.get(name);
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
    try linker.indexLocalFunctions(sf);
    try linker.resolveImports(sf);
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

    try std.testing.expect(l.linker.lookup("version") != null);
    try std.testing.expect(l.linker.lookup("local_helper") != null);
    try std.testing.expect(l.linker.lookup("main") != null);
    try std.testing.expect(l.linker.lookup("private_helper") == null);
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
