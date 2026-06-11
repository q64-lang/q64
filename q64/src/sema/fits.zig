//! Fit registry (A1's deferred rung, unblocked by B3's structured
//! face/fit grammar) + the fit-form check (the first B4 slice).
//!
//! Classifies each face declaration as single- or multi-parameter by
//! the mechanical rule of spec/faces.md §"Fit declaration" / §Self: a
//! face whose method signatures take a `self` receiver has one
//! conceptual receiver — single-param, aux generic params
//! notwithstanding (`Filter<T, @e>`); a face whose methods name every
//! type (`Convert<From, To>`) has no `Self` and is multi-param. The
//! auto-prelude faces are all single-param (spec/faces.md §"Auto-
//! prelude faces" — `From`/`Into` are the "single-param" conversions).
//!
//! Registers each fit declaration keyed on (target, face) — the
//! registry B4's static dispatch will read — and emits the form checks:
//!
//! - **TYP201** — a single-param face written `fit Face<Type>`; must be
//!   `fit Type : Face` (implementer first).
//! - **TYP202** — a multi-param face written `fit Type : Face`; must be
//!   `fit Face<T1, T2>` (no implementer prefix).
//!
//! Honesty rules: a face that is neither declared in this file nor in
//! the auto-prelude stays silent (cross-module faces are the NAM
//! story), and a face with no method signatures is unclassified — no
//! form check fires.

const std = @import("std");
const parser = @import("parser");
const ast = parser.ast;
const cst = parser.cst;
const prelude = @import("prelude.zig");

pub const Diag = struct {
    code: []const u8,
    offset: u32,
};

pub const FaceKind = enum { single_param, multi_param };

/// One registered fit. `target` is the implementer's head name in the
/// colon form (`fit Color : Display` → "Color"), null in the bare
/// multi-param form. `face` is the face path's head name. Slices are
/// owned by the registry.
pub const FitEntry = struct {
    target: ?[]const u8,
    face: []const u8,
    decl: ast.FitDecl,
};

pub const Registry = struct {
    gpa: std.mem.Allocator,
    /// This file's face declarations that could be classified.
    faces: std.StringHashMapUnmanaged(FaceKind) = .empty,
    fits: std.ArrayList(FitEntry) = .empty,
    diags: std.ArrayList(Diag) = .empty,

    pub fn deinit(self: *Registry) void {
        var it = self.faces.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.faces.deinit(self.gpa);
        for (self.fits.items) |f| {
            if (f.target) |t| self.gpa.free(t);
            self.gpa.free(f.face);
        }
        self.fits.deinit(self.gpa);
        self.diags.deinit(self.gpa);
    }

    /// The registered fit for (target, face), for B4's static dispatch.
    pub fn find(self: *const Registry, target: []const u8, face: []const u8) ?FitEntry {
        for (self.fits.items) |f| {
            const t = f.target orelse continue;
            if (std.mem.eql(u8, t, target) and std.mem.eql(u8, f.face, face)) return f;
        }
        return null;
    }

    /// Is `name` a face this file can judge — declared (and classified)
    /// locally, or an auto-prelude face? Anything else is the NAM story
    /// (cross-module faces), and bound checks stay silent on it.
    pub fn knowsFace(self: *const Registry, name: []const u8) bool {
        if (self.faces.contains(name)) return true;
        const pk = prelude.kindOf(name) orelse return false;
        return pk == .face;
    }
};

// ---------------------------------------------------------------------
// Generic signatures (the B5 v0 floor) — shared between the TYP200
// bound check (sema/check.zig) and the emit path's monomorphization
// (ir/build_hir.zig).
// ---------------------------------------------------------------------

pub const GenericSig = struct { tname: []const u8, bound: ?[]const u8 };

/// Parse the raw `<T: Display>` span: one type parameter with an
/// optional face bound. More parameters are a later slice.
pub fn parseGenericSig(gp: *const cst.Node) ?GenericSig {
    var toks: [8]cst.Token = undefined;
    var n: usize = 0;
    for (gp.children) |ch| switch (ch) {
        .token => |t| {
            if (t.kind.isTrivia()) continue;
            if (n == toks.len) return null;
            toks[n] = t;
            n += 1;
        },
        .node => return null,
    };
    // < IDENT >  |  < IDENT : IDENT >
    if (n == 3 and toks[0].kind == .L_ANGLE and toks[1].kind == .IDENT and toks[2].kind == .R_ANGLE)
        return .{ .tname = toks[1].text, .bound = null };
    if (n == 5 and toks[0].kind == .L_ANGLE and toks[1].kind == .IDENT and toks[2].kind == .COLON and toks[3].kind == .IDENT and toks[4].kind == .R_ANGLE)
        return .{ .tname = toks[1].text, .bound = toks[3].text };
    return null;
}

/// Is this param type `[T]` for the generic's T?
pub fn isSliceOfT(p: ast.Param, tname: []const u8, a: std.mem.Allocator) bool {
    const te = p.type_() orelse return false;
    const sl = switch (te) {
        .slice => |x| x,
        else => return false,
    };
    const inner = sl.element() orelse return false;
    const pt = switch (inner) {
        .path => |x| x,
        else => return false,
    };
    const nm = pt.name(a) catch return false;
    defer a.free(nm);
    return std.mem.eql(u8, nm, tname);
}

/// Build the registry for `sf` and run the fit-form checks. The caller
/// owns the result (`deinit`).
pub fn build(gpa: std.mem.Allocator, sf: ast.SourceFile) std.mem.Allocator.Error!Registry {
    var reg = Registry{ .gpa = gpa };
    errdefer reg.deinit();

    // Pass 1: classify this file's faces.
    var it = sf.items();
    while (it.next()) |item| switch (item) {
        .face_decl => |fd| {
            const nm = fd.name() orelse continue;
            const kind = classifyFace(fd) orelse continue; // no methods — unclassified
            const gop = try reg.faces.getOrPut(gpa, nm.text);
            if (!gop.found_existing) {
                gop.key_ptr.* = try gpa.dupe(u8, nm.text);
            }
            gop.value_ptr.* = kind;
        },
        else => {},
    };

    // Pass 2: register fits and check the written form against the
    // face's arity kind.
    it = sf.items();
    while (it.next()) |item| switch (item) {
        .fit_decl => |fd| {
            const spec = fd.spec() orelse continue;
            const face_te = spec.face() orelse continue;
            const face_path = switch (face_te) {
                .path => |pt| pt,
                else => continue,
            };
            const face_name = try face_path.name(gpa);
            errdefer gpa.free(face_name);

            var target: ?[]const u8 = null;
            errdefer if (target) |t| gpa.free(t);
            if (spec.target()) |tgt| {
                if (tgt == .path) target = try tgt.path.name(gpa);
            }
            try reg.fits.append(gpa, .{ .target = target, .face = face_name, .decl = fd });
            target = null; // ownership moved into the registry

            // Form check. Prelude faces are all single-param; unknown
            // faces stay silent.
            const kind: FaceKind = reg.faces.get(face_name) orelse blk: {
                const pk = prelude.kindOf(face_name) orelse continue;
                if (pk != .face) continue;
                break :blk .single_param;
            };
            const wrong = switch (kind) {
                .single_param => !spec.isColonForm(), // wants `fit Type : Face`
                .multi_param => spec.isColonForm(), // wants `fit Face<T1, T2>`
            };
            if (wrong) {
                try reg.diags.append(gpa, .{
                    .code = if (kind == .single_param) "TYP201" else "TYP202",
                    .offset = firstTokenOffset(spec.cst),
                });
            }
        },
        else => {},
    };

    return reg;
}

/// spec/faces.md §Self: a method with a `self` receiver means the face
/// has one conceptual receiver (single-param); methods present but none
/// taking `self` means every type is a named parameter (multi-param).
/// No method signatures → null (unclassified; laws and associated
/// types don't decide arity).
fn classifyFace(fd: ast.FaceDecl) ?FaceKind {
    var any = false;
    var ms = fd.methods();
    while (ms.next()) |m| {
        any = true;
        const ps = m.params() orelse continue;
        var pit = ps.iter();
        while (pit.next()) |p| {
            if (p.isSelf()) return .single_param;
        }
    }
    return if (any) .multi_param else null;
}

fn firstTokenOffset(node: *const cst.Node) u32 {
    for (node.children) |c| switch (c) {
        .token => |t| return t.offset,
        .node => |n| {
            const o = firstTokenOffset(n);
            if (o != 0) return o;
        },
    };
    return 0;
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------
const testing = std.testing;

fn buildFrom(src: []const u8) !struct { r: parser.parse.Result, reg: Registry } {
    const r = try parser.parse.parse(testing.allocator, src, "<t>");
    errdefer r.deinit(testing.allocator);
    const sf = ast.SourceFile.cast(r.root).?;
    return .{ .r = r, .reg = try build(testing.allocator, sf) };
}

test "fits: correct forms register without diagnostics" {
    var b = try buildFrom(
        \\face Display { fn fmt(self) -> str }
        \\face Convert<From, To> { fn convert(x: From) -> To }
        \\struct Color { r: i64 }
        \\fit Color : Display { fn fmt(self) -> str { "x" } }
        \\fit Convert<Color, Color> { fn convert(x: Color) -> Color { x } }
        \\
    );
    defer b.r.deinit(testing.allocator);
    defer b.reg.deinit();
    try testing.expectEqual(@as(usize, 0), b.reg.diags.items.len);
    try testing.expectEqual(@as(usize, 2), b.reg.fits.items.len);
    const e = b.reg.find("Color", "Display").?;
    try testing.expectEqualStrings("Display", e.face);
}

test "fits: TYP201 — single-param face in the bare form" {
    // `Eq` resolves through the auto-prelude (all prelude faces are
    // single-param), mirroring spec/tests/faces/wrong-fit-form-single.q.
    var b = try buildFrom(
        \\struct Point { x: i64 }
        \\fit Eq<Point> { fn eq(self, other: Self) -> bool { true } }
        \\
    );
    defer b.r.deinit(testing.allocator);
    defer b.reg.deinit();
    try testing.expectEqual(@as(usize, 1), b.reg.diags.items.len);
    try testing.expectEqualStrings("TYP201", b.reg.diags.items[0].code);
}

test "fits: TYP202 — multi-param face in the colon form" {
    var b = try buildFrom(
        \\face Convert<From, To> { fn convert(x: From) -> To }
        \\struct Celsius { v: i64 }
        \\fit Celsius : Convert<Celsius> { fn convert(x: Celsius) -> Celsius { x } }
        \\
    );
    defer b.r.deinit(testing.allocator);
    defer b.reg.deinit();
    try testing.expectEqual(@as(usize, 1), b.reg.diags.items.len);
    try testing.expectEqualStrings("TYP202", b.reg.diags.items[0].code);
}

test "fits: an unknown face stays silent; an aux-param fit is fine" {
    var b = try buildFrom(
        \\struct E1 { v: i64 }
        \\fit E1 : SomeoneElsesFace { fn f(self) -> i64 { 1 } }
        \\fit E1 : From<i64> { fn from(e: i64) -> Self { E1 { v: e } } }
        \\
    );
    defer b.r.deinit(testing.allocator);
    defer b.reg.deinit();
    // SomeoneElsesFace: not local, not prelude — silent. From<i64>: a
    // prelude single-param face in the colon form — correct.
    try testing.expectEqual(@as(usize, 0), b.reg.diags.items.len);
}
