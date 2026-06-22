//! WIT ingestion — parse a foreign/authored `.wit` package and map its types
//! into q64's type system (WIT rung 5, the **consume** direction). This is the
//! inverse of component emission (`codegen/component.zig`, which lowers q64 →
//! WIT): here a foreign component's WIT — written in any language — is parsed so
//! a q64 qube can `import` and call it.
//!
//! Scope of this slice: a self-contained WIT parser for the common surface
//! (package, interface, world, type/record/enum/variant/flags/resource/func,
//! and the type grammar) plus the WIT→q64 type mapping (the inverse of the
//! `spec/modules.md` lowering table). It produces the **binding preview** that
//! `q64 wit import` / `qube wit import` print — the q64-typed view of a foreign
//! interface. Actually *generating* the wasm imports + canonical-ABI call glue
//! (so q64 source can call across) is the next slice; this lands the parser +
//! mapping the rest of rung 5 builds on.
//!
//! Type-system honesty (per the rung-5 notes): WIT primitives q64 has no
//! representation for — `flags` (WIT020), `char` (WIT021), and an anonymous
//! `tuple<…>` in a foreign signature (WIT022) — are surfaced as gaps, never
//! silently coerced. Foreign `resource`s become an **opaque handle** type that
//! lives *outside* the face system (q64 can hold/pass a handle but not
//! introspect it), keeping the `faces.md` boundary intact.

const std = @import("std");

pub const Error = error{ ParseError, OutOfMemory };

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

pub const Prim = enum {
    bool_,
    s8,
    s16,
    s32,
    s64,
    u8_,
    u16,
    u32,
    u64,
    f32,
    f64,
    char,
    string,
};

pub const Type = union(enum) {
    prim: Prim,
    list: *const Type,
    option: *const Type,
    result: struct { ok: ?*const Type, err: ?*const Type },
    tuple: []const *const Type,
    /// A reference to a named type (record/enum/variant/flags/alias/resource).
    named: []const u8,
    /// `own<R>` — an owned handle to a foreign resource `R`.
    own: []const u8,
    /// `borrow<R>` — a borrowed handle to a foreign resource `R`.
    borrow: []const u8,
};

pub const Param = struct { name: []const u8, ty: *const Type };

pub const Func = struct {
    name: []const u8,
    params: []const Param,
    /// A single result type, or null for `func(...)` with no result. Named or
    /// multiple results (a result tuple) are flattened to the first for the v0
    /// preview; `multi_result` flags that the preview is lossy.
    result: ?*const Type,
    multi_result: bool = false,
};

pub const TypeDefKind = enum { record, enum_, variant, flags, resource, alias };

pub const TypeDef = struct {
    kind: TypeDefKind,
    name: []const u8,
    /// record fields / variant cases (name + optional payload); enum/flags
    /// cases carry a null type. An alias carries its single aliased type as a
    /// one-entry list named "".
    members: []const Param2 = &.{},
    alias: ?*const Type = null,
};

/// A field/case: name + optional payload type (enum/flags cases have none).
pub const Param2 = struct { name: []const u8, ty: ?*const Type };

pub const Interface = struct {
    name: []const u8,
    types: []const TypeDef,
    funcs: []const Func,
};

pub const Doc = struct {
    package_id: ?[]const u8,
    interfaces: []const Interface,
    /// World import/export interface references, recorded for the preview.
    world_names: []const []const u8,
};

// ---------------------------------------------------------------------------
// Lexer
// ---------------------------------------------------------------------------

const TokKind = enum {
    ident,
    lbrace,
    rbrace,
    lparen,
    rparen,
    lt,
    gt,
    colon,
    semicolon,
    comma,
    eq,
    arrow,
    slash,
    dot,
    at,
    star,
    underscore,
    eof,
};

const Tok = struct { kind: TokKind, text: []const u8, pos: usize };

const Lexer = struct {
    src: []const u8,
    i: usize = 0,

    fn isIdentStart(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '%';
    }
    fn isIdentCont(c: u8) bool {
        return isIdentStart(c) or (c >= '0' and c <= '9') or c == '-';
    }

    fn skipTrivia(self: *Lexer) void {
        while (self.i < self.src.len) {
            const c = self.src[self.i];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                self.i += 1;
            } else if (c == '/' and self.i + 1 < self.src.len and self.src[self.i + 1] == '/') {
                while (self.i < self.src.len and self.src[self.i] != '\n') self.i += 1;
            } else if (c == '/' and self.i + 1 < self.src.len and self.src[self.i + 1] == '*') {
                self.i += 2;
                while (self.i + 1 < self.src.len and !(self.src[self.i] == '*' and self.src[self.i + 1] == '/')) self.i += 1;
                self.i += 2; // consume the closing */ (clamped below)
                if (self.i > self.src.len) self.i = self.src.len;
            } else break;
        }
    }

    fn next(self: *Lexer) Tok {
        self.skipTrivia();
        const start = self.i;
        if (self.i >= self.src.len) return .{ .kind = .eof, .text = "", .pos = start };
        const c = self.src[self.i];
        // An identifier (incl. the `%`-escape form and the `_` placeholder).
        if (isIdentStart(c)) {
            // A bare `_` is the result-placeholder token, not an identifier.
            if (c == '_' and (self.i + 1 >= self.src.len or !isIdentCont(self.src[self.i + 1]))) {
                self.i += 1;
                return .{ .kind = .underscore, .text = "_", .pos = start };
            }
            var j = self.i + 1;
            while (j < self.src.len and isIdentCont(self.src[j])) j += 1;
            const text = self.src[self.i..j];
            self.i = j;
            // Strip a leading `%` escape so keyword labels read normally.
            return .{ .kind = .ident, .text = if (text.len > 0 and text[0] == '%') text[1..] else text, .pos = start };
        }
        // Punctuation.
        self.i += 1;
        return switch (c) {
            '{' => .{ .kind = .lbrace, .text = "{", .pos = start },
            '}' => .{ .kind = .rbrace, .text = "}", .pos = start },
            '(' => .{ .kind = .lparen, .text = "(", .pos = start },
            ')' => .{ .kind = .rparen, .text = ")", .pos = start },
            '<' => .{ .kind = .lt, .text = "<", .pos = start },
            '>' => .{ .kind = .gt, .text = ">", .pos = start },
            ':' => .{ .kind = .colon, .text = ":", .pos = start },
            ';' => .{ .kind = .semicolon, .text = ";", .pos = start },
            ',' => .{ .kind = .comma, .text = ",", .pos = start },
            '=' => .{ .kind = .eq, .text = "=", .pos = start },
            '/' => .{ .kind = .slash, .text = "/", .pos = start },
            '.' => .{ .kind = .dot, .text = ".", .pos = start },
            '@' => .{ .kind = .at, .text = "@", .pos = start },
            '*' => .{ .kind = .star, .text = "*", .pos = start },
            '-' => blk: {
                if (self.i < self.src.len and self.src[self.i] == '>') {
                    self.i += 1;
                    break :blk Tok{ .kind = .arrow, .text = "->", .pos = start };
                }
                break :blk Tok{ .kind = .ident, .text = "-", .pos = start }; // stray; parser will reject
            },
            else => .{ .kind = .ident, .text = self.src[start..self.i], .pos = start },
        };
    }
};

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

pub const Parser = struct {
    arena: std.mem.Allocator,
    lex: Lexer,
    cur: Tok,
    /// On ParseError, the human-facing reason (arena-owned).
    err_msg: []const u8 = "",
    err_pos: usize = 0,

    pub fn init(arena: std.mem.Allocator, src: []const u8) Parser {
        var lex = Lexer{ .src = src };
        const first = lex.next();
        return .{ .arena = arena, .lex = lex, .cur = first };
    }

    fn advance(self: *Parser) void {
        self.cur = self.lex.next();
    }

    fn fail(self: *Parser, comptime fmt: []const u8, args: anytype) Error {
        self.err_msg = std.fmt.allocPrint(self.arena, fmt, args) catch "out of memory";
        self.err_pos = self.cur.pos;
        return Error.ParseError;
    }

    fn expect(self: *Parser, kind: TokKind) Error!Tok {
        if (self.cur.kind != kind) return self.fail("expected {s}, found '{s}'", .{ @tagName(kind), self.cur.text });
        const t = self.cur;
        self.advance();
        return t;
    }

    fn isKw(self: *Parser, kw: []const u8) bool {
        return self.cur.kind == .ident and std.mem.eql(u8, self.cur.text, kw);
    }

    /// Parse a whole document. The arena owns every node.
    pub fn parseDoc(self: *Parser) Error!Doc {
        var package_id: ?[]const u8 = null;
        var ifaces: std.ArrayList(Interface) = .empty;
        var worlds: std.ArrayList([]const u8) = .empty;

        if (self.isKw("package")) {
            self.advance();
            package_id = try self.parsePackageId();
            // An optional `;` (some `.wit` omit it before a block form).
            if (self.cur.kind == .semicolon) self.advance();
        }

        while (self.cur.kind != .eof) {
            if (self.isKw("interface")) {
                self.advance();
                try ifaces.append(self.arena, try self.parseInterface());
            } else if (self.isKw("world")) {
                self.advance();
                const wname = (try self.expect(.ident)).text;
                try worlds.append(self.arena, wname);
                try self.parseWorldBody();
            } else if (self.isKw("use")) {
                try self.skipStatement();
            } else {
                return self.fail("unexpected top-level item '{s}'", .{self.cur.text});
            }
        }
        return .{
            .package_id = package_id,
            .interfaces = try ifaces.toOwnedSlice(self.arena),
            .world_names = try worlds.toOwnedSlice(self.arena),
        };
    }

    /// `ns:name/path@x.y.z` — read as text up to a `;`, `{`, or EOF.
    fn parsePackageId(self: *Parser) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        while (self.cur.kind != .semicolon and self.cur.kind != .lbrace and self.cur.kind != .eof) {
            if (self.cur.kind == .at) {
                try out.append(self.arena, '@');
                self.advance();
                // version: consume ident/dot/number runs verbatim
                while (self.cur.kind == .ident or self.cur.kind == .dot) {
                    try out.appendSlice(self.arena, self.cur.text);
                    self.advance();
                }
                break;
            }
            try out.appendSlice(self.arena, self.cur.text);
            self.advance();
        }
        return out.toOwnedSlice(self.arena);
    }

    fn parseInterface(self: *Parser) Error!Interface {
        const name = (try self.expect(.ident)).text;
        _ = try self.expect(.lbrace);
        var types: std.ArrayList(TypeDef) = .empty;
        var funcs: std.ArrayList(Func) = .empty;
        while (self.cur.kind != .rbrace and self.cur.kind != .eof) {
            if (self.isKw("use")) {
                try self.skipStatement();
            } else if (self.isKw("type")) {
                self.advance();
                try types.append(self.arena, try self.parseAlias());
            } else if (self.isKw("record")) {
                self.advance();
                try types.append(self.arena, try self.parseRecord());
            } else if (self.isKw("enum")) {
                self.advance();
                try types.append(self.arena, try self.parseEnumOrFlags(.enum_));
            } else if (self.isKw("flags")) {
                self.advance();
                try types.append(self.arena, try self.parseEnumOrFlags(.flags));
            } else if (self.isKw("variant")) {
                self.advance();
                try types.append(self.arena, try self.parseVariant());
            } else if (self.isKw("resource")) {
                self.advance();
                try types.append(self.arena, try self.parseResource());
            } else {
                // `name: func(...)…;`
                try funcs.append(self.arena, try self.parseFunc());
            }
        }
        _ = try self.expect(.rbrace);
        return .{ .name = name, .types = try types.toOwnedSlice(self.arena), .funcs = try funcs.toOwnedSlice(self.arena) };
    }

    /// World bodies are recorded by name only in this slice; skip the body,
    /// tracking brace depth so a nested inline `interface { … }` is consumed.
    fn parseWorldBody(self: *Parser) Error!void {
        _ = try self.expect(.lbrace);
        var depth: usize = 1;
        while (depth > 0 and self.cur.kind != .eof) {
            switch (self.cur.kind) {
                .lbrace => depth += 1,
                .rbrace => depth -= 1,
                else => {},
            }
            self.advance();
        }
    }

    fn parseAlias(self: *Parser) Error!TypeDef {
        const name = (try self.expect(.ident)).text;
        _ = try self.expect(.eq);
        const t = try self.parseType();
        if (self.cur.kind == .semicolon) self.advance();
        return .{ .kind = .alias, .name = name, .alias = t };
    }

    fn parseRecord(self: *Parser) Error!TypeDef {
        const name = (try self.expect(.ident)).text;
        _ = try self.expect(.lbrace);
        var fields: std.ArrayList(Param2) = .empty;
        while (self.cur.kind != .rbrace and self.cur.kind != .eof) {
            const fname = (try self.expect(.ident)).text;
            _ = try self.expect(.colon);
            const ft = try self.parseType();
            try fields.append(self.arena, .{ .name = fname, .ty = ft });
            if (self.cur.kind == .comma) self.advance();
        }
        _ = try self.expect(.rbrace);
        return .{ .kind = .record, .name = name, .members = try fields.toOwnedSlice(self.arena) };
    }

    fn parseEnumOrFlags(self: *Parser, kind: TypeDefKind) Error!TypeDef {
        const name = (try self.expect(.ident)).text;
        _ = try self.expect(.lbrace);
        var cases: std.ArrayList(Param2) = .empty;
        while (self.cur.kind != .rbrace and self.cur.kind != .eof) {
            const cname = (try self.expect(.ident)).text;
            try cases.append(self.arena, .{ .name = cname, .ty = null });
            if (self.cur.kind == .comma) self.advance();
        }
        _ = try self.expect(.rbrace);
        return .{ .kind = kind, .name = name, .members = try cases.toOwnedSlice(self.arena) };
    }

    fn parseVariant(self: *Parser) Error!TypeDef {
        const name = (try self.expect(.ident)).text;
        _ = try self.expect(.lbrace);
        var cases: std.ArrayList(Param2) = .empty;
        while (self.cur.kind != .rbrace and self.cur.kind != .eof) {
            const cname = (try self.expect(.ident)).text;
            var payload: ?*const Type = null;
            if (self.cur.kind == .lparen) {
                self.advance();
                payload = try self.parseType();
                _ = try self.expect(.rparen);
            }
            try cases.append(self.arena, .{ .name = cname, .ty = payload });
            if (self.cur.kind == .comma) self.advance();
        }
        _ = try self.expect(.rbrace);
        return .{ .kind = .variant, .name = name, .members = try cases.toOwnedSlice(self.arena) };
    }

    /// A resource: name + (skipped) method block. Methods are not part of the
    /// preview — a resource maps to an opaque handle; q64 holds it, never
    /// introspects it.
    fn parseResource(self: *Parser) Error!TypeDef {
        const name = (try self.expect(.ident)).text;
        if (self.cur.kind == .lbrace) {
            self.advance();
            var depth: usize = 1;
            while (depth > 0 and self.cur.kind != .eof) {
                switch (self.cur.kind) {
                    .lbrace => depth += 1,
                    .rbrace => depth -= 1,
                    else => {},
                }
                self.advance();
            }
        } else if (self.cur.kind == .semicolon) {
            self.advance();
        }
        return .{ .kind = .resource, .name = name };
    }

    fn parseFunc(self: *Parser) Error!Func {
        const name = (try self.expect(.ident)).text;
        _ = try self.expect(.colon);
        if (!self.isKw("func")) return self.fail("expected 'func' after '{s}:', found '{s}'", .{ name, self.cur.text });
        self.advance();
        _ = try self.expect(.lparen);
        var params: std.ArrayList(Param) = .empty;
        while (self.cur.kind != .rparen and self.cur.kind != .eof) {
            const pname = (try self.expect(.ident)).text;
            _ = try self.expect(.colon);
            const pt = try self.parseType();
            try params.append(self.arena, .{ .name = pname, .ty = pt });
            if (self.cur.kind == .comma) self.advance();
        }
        _ = try self.expect(.rparen);

        var result: ?*const Type = null;
        var multi = false;
        if (self.cur.kind == .arrow) {
            self.advance();
            if (self.cur.kind == .lparen) {
                // Named/multiple results: take the first, flag lossy.
                self.advance();
                var first: ?*const Type = null;
                var count: usize = 0;
                while (self.cur.kind != .rparen and self.cur.kind != .eof) {
                    _ = try self.expect(.ident); // result name
                    _ = try self.expect(.colon);
                    const rt = try self.parseType();
                    if (first == null) first = rt;
                    count += 1;
                    if (self.cur.kind == .comma) self.advance();
                }
                _ = try self.expect(.rparen);
                result = first;
                multi = count > 1;
            } else {
                result = try self.parseType();
            }
        }
        if (self.cur.kind == .semicolon) self.advance();
        return .{ .name = name, .params = try params.toOwnedSlice(self.arena), .result = result, .multi_result = multi };
    }

    fn box(self: *Parser, t: Type) Error!*const Type {
        const p = try self.arena.create(Type);
        p.* = t;
        return p;
    }

    fn parseType(self: *Parser) Error!*const Type {
        if (self.cur.kind == .underscore) {
            // `_` only appears as a result placeholder; treat as unit string.
            self.advance();
            return self.box(.{ .named = "_" });
        }
        if (self.cur.kind != .ident) return self.fail("expected a type, found '{s}'", .{self.cur.text});
        const word = self.cur.text;
        // Primitives.
        if (primFromName(word)) |p| {
            self.advance();
            return self.box(.{ .prim = p });
        }
        // Parameterized / handle forms.
        if (std.mem.eql(u8, word, "list")) {
            self.advance();
            const inner = try self.parseAngleOne();
            return self.box(.{ .list = inner });
        }
        if (std.mem.eql(u8, word, "option")) {
            self.advance();
            const inner = try self.parseAngleOne();
            return self.box(.{ .option = inner });
        }
        if (std.mem.eql(u8, word, "tuple")) {
            self.advance();
            const items = try self.parseAngleList();
            return self.box(.{ .tuple = items });
        }
        if (std.mem.eql(u8, word, "result")) {
            self.advance();
            return self.parseResultType();
        }
        if (std.mem.eql(u8, word, "own") or std.mem.eql(u8, word, "borrow")) {
            self.advance();
            _ = try self.expect(.lt);
            const id = (try self.expect(.ident)).text;
            _ = try self.expect(.gt);
            return self.box(if (std.mem.eql(u8, word, "own")) .{ .own = id } else .{ .borrow = id });
        }
        // A named-type reference (record/enum/variant/flags/alias/resource).
        self.advance();
        return self.box(.{ .named = word });
    }

    fn parseAngleOne(self: *Parser) Error!*const Type {
        _ = try self.expect(.lt);
        const t = try self.parseType();
        _ = try self.expect(.gt);
        return t;
    }

    fn parseAngleList(self: *Parser) Error![]const *const Type {
        _ = try self.expect(.lt);
        var items: std.ArrayList(*const Type) = .empty;
        while (self.cur.kind != .gt and self.cur.kind != .eof) {
            try items.append(self.arena, try self.parseType());
            if (self.cur.kind == .comma) self.advance();
        }
        _ = try self.expect(.gt);
        return items.toOwnedSlice(self.arena);
    }

    /// `result`, `result<T>`, `result<T, E>`, `result<_, E>`, `result<_>`.
    fn parseResultType(self: *Parser) Error!*const Type {
        if (self.cur.kind != .lt) return self.box(.{ .result = .{ .ok = null, .err = null } });
        self.advance();
        const ok = try self.parseOptionalSlot();
        var err: ?*const Type = null;
        if (self.cur.kind == .comma) {
            self.advance();
            err = try self.parseOptionalSlot();
        }
        _ = try self.expect(.gt);
        return self.box(.{ .result = .{ .ok = ok, .err = err } });
    }

    /// A `_` placeholder yields null; otherwise a real type.
    fn parseOptionalSlot(self: *Parser) Error!?*const Type {
        if (self.cur.kind == .underscore) {
            self.advance();
            return null;
        }
        return try self.parseType();
    }

    /// Skip a `use …;` (or any) statement up to and including the `;`.
    fn skipStatement(self: *Parser) Error!void {
        while (self.cur.kind != .semicolon and self.cur.kind != .eof) self.advance();
        if (self.cur.kind == .semicolon) self.advance();
    }
};

fn primFromName(s: []const u8) ?Prim {
    const map = .{
        .{ "bool", Prim.bool_ },   .{ "s8", Prim.s8 },   .{ "s16", Prim.s16 },
        .{ "s32", Prim.s32 },      .{ "s64", Prim.s64 }, .{ "u8", Prim.u8_ },
        .{ "u16", Prim.u16 },      .{ "u32", Prim.u32 }, .{ "u64", Prim.u64 },
        .{ "f32", Prim.f32 },      .{ "f64", Prim.f64 }, .{ "char", Prim.char },
        .{ "string", Prim.string },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, s, entry[0])) return entry[1];
    }
    return null;
}

// ---------------------------------------------------------------------------
// WIT → q64 type mapping (inverse of spec/modules.md lowering)
// ---------------------------------------------------------------------------

pub const Gap = struct { code: []const u8, message: []const u8 };

/// Collects type gaps surfaced while rendering (deduplicated by message).
pub const Gaps = struct {
    list: std.ArrayList(Gap) = .empty,

    pub fn add(self: *Gaps, arena: std.mem.Allocator, code: []const u8, comptime fmt: []const u8, args: anytype) !void {
        const msg = try std.fmt.allocPrint(arena, fmt, args);
        for (self.list.items) |g| if (std.mem.eql(u8, g.message, msg)) return;
        try self.list.append(arena, .{ .code = code, .message = msg });
    }
};

/// Render a WIT type as its q64 type name, recording any representation gaps.
/// The mapping inverts the `spec/modules.md` table; unrepresentable WIT
/// primitives render a placeholder *and* record a WIT0xx gap (never a silent
/// coercion).
pub fn renderQ64Type(arena: std.mem.Allocator, t: *const Type, gaps: *Gaps) Error![]const u8 {
    return switch (t.*) {
        .prim => |p| switch (p) {
            .bool_ => "bool",
            .s8 => "i8",
            .s16 => "i16",
            .s32 => "i32",
            .s64 => "i64",
            .u8_ => "u8",
            .u16 => "u16",
            .u32 => "u32",
            .u64 => "u64",
            .f32 => "f32",
            .f64 => "f64",
            .string => "str",
            .char => blk: {
                try gaps.add(arena, "WIT021", "WIT `char` has no q64 type (no Unicode-scalar type); surfaced as `char`", .{});
                break :blk "char";
            },
        },
        .list => |inner| blk: {
            // `list<u8>` is q64 `Bytes`; `list<T>` is `[T]`.
            if (inner.* == .prim and inner.*.prim == .u8_) break :blk "Bytes";
            const i = try renderQ64Type(arena, inner, gaps);
            break :blk try std.fmt.allocPrint(arena, "[{s}]", .{i});
        },
        .option => |inner| blk: {
            const i = try renderQ64Type(arena, inner, gaps);
            break :blk try std.fmt.allocPrint(arena, "Option<{s}>", .{i});
        },
        .result => |r| blk: {
            const ok = if (r.ok) |o| try renderQ64Type(arena, o, gaps) else "unit";
            const er = if (r.err) |e| try renderQ64Type(arena, e, gaps) else "unit";
            break :blk try std.fmt.allocPrint(arena, "Result<{s}, {s}>", .{ ok, er });
        },
        .tuple => |items| blk: {
            try gaps.add(arena, "WIT022", "anonymous `tuple<…>` has no q64 type (q64 tuples are nominal); declare a named struct", .{});
            var out: std.ArrayList(u8) = .empty;
            try out.append(arena, '(');
            for (items, 0..) |it, idx| {
                if (idx > 0) try out.appendSlice(arena, ", ");
                try out.appendSlice(arena, try renderQ64Type(arena, it, gaps));
            }
            try out.append(arena, ')');
            break :blk try out.toOwnedSlice(arena);
        },
        .named => |n| n,
        // A foreign resource handle is an opaque type *outside* the face system.
        .own => |r| try std.fmt.allocPrint(arena, "handle<{s}>", .{r}),
        .borrow => |r| try std.fmt.allocPrint(arena, "&handle<{s}>", .{r}),
    };
}

/// Render the whole document as a q64 binding preview (what `q64 wit import`
/// prints): each interface's type defs and functions as q64 declarations, plus
/// a trailing gap report. `gaps` is filled for the caller to also exit-code on.
pub fn renderBindings(arena: std.mem.Allocator, doc: *const Doc, gaps: *Gaps) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    if (doc.package_id) |pid| {
        try out.print(arena, "// q64 bindings for WIT package {s} (q64 wit import)\n", .{pid});
    } else {
        try out.appendSlice(arena, "// q64 bindings (q64 wit import)\n");
    }

    for (doc.interfaces) |iface| {
        try out.print(arena, "\nimport interface {s} {{\n", .{iface.name});
        for (iface.types) |td| try renderTypeDef(arena, &out, &td, gaps);
        for (iface.funcs) |f| {
            try out.print(arena, "  fn {s}(", .{f.name});
            for (f.params, 0..) |p, i| {
                if (i > 0) try out.appendSlice(arena, ", ");
                try out.print(arena, "{s}: {s}", .{ p.name, try renderQ64Type(arena, p.ty, gaps) });
            }
            try out.appendSlice(arena, ")");
            if (f.result) |r| try out.print(arena, " -> {s}", .{try renderQ64Type(arena, r, gaps)});
            if (f.multi_result) try out.appendSlice(arena, "  // WIT023: multiple results flattened to the first");
            try out.appendSlice(arena, "\n");
        }
        try out.appendSlice(arena, "}\n");
    }

    if (gaps.list.items.len > 0) {
        try out.appendSlice(arena, "\n// type gaps (surfaced, not coerced):\n");
        for (gaps.list.items) |g| try out.print(arena, "//   {s}: {s}\n", .{ g.code, g.message });
    }
    return out.toOwnedSlice(arena);
}

fn renderTypeDef(arena: std.mem.Allocator, out: *std.ArrayList(u8), td: *const TypeDef, gaps: *Gaps) Error!void {
    switch (td.kind) {
        .alias => {
            const t = if (td.alias) |a| try renderQ64Type(arena, a, gaps) else "unit";
            try out.print(arena, "  type {s} = {s}\n", .{ td.name, t });
        },
        .record => {
            try out.print(arena, "  struct {s} {{ ", .{td.name});
            for (td.members, 0..) |m, i| {
                if (i > 0) try out.appendSlice(arena, ", ");
                const t = if (m.ty) |mt| try renderQ64Type(arena, mt, gaps) else "unit";
                try out.print(arena, "{s}: {s}", .{ m.name, t });
            }
            try out.appendSlice(arena, " }\n");
        },
        .enum_ => {
            try out.print(arena, "  enum {s} {{ ", .{td.name});
            for (td.members, 0..) |m, i| {
                if (i > 0) try out.appendSlice(arena, ", ");
                try out.appendSlice(arena, m.name);
            }
            try out.appendSlice(arena, " }\n");
        },
        .variant => {
            try out.print(arena, "  enum {s} {{ ", .{td.name});
            for (td.members, 0..) |m, i| {
                if (i > 0) try out.appendSlice(arena, ", ");
                if (m.ty) |mt| {
                    try out.print(arena, "{s}({s})", .{ m.name, try renderQ64Type(arena, mt, gaps) });
                } else try out.appendSlice(arena, m.name);
            }
            try out.appendSlice(arena, " }\n");
        },
        .flags => {
            try gaps.add(arena, "WIT020", "WIT `flags` has no q64 type; declare a struct of bools or an enum set", .{});
            try out.print(arena, "  // WIT020: flags {s} (no q64 flags type)\n", .{td.name});
        },
        .resource => {
            try out.print(arena, "  // opaque handle: resource {s} (held, not introspected — outside faces)\n", .{td.name});
        },
    }
}

/// Parse `src` into a `Doc` (arena-owned). On a parse error, returns
/// `error.ParseError` with `p.err_msg`/`p.err_pos` set for the caller.
pub fn parse(arena: std.mem.Allocator, src: []const u8, p: *Parser) Error!Doc {
    p.* = Parser.init(arena, src);
    return p.parseDoc();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn renderSrc(arena: std.mem.Allocator, src: []const u8) ![]u8 {
    var p: Parser = undefined;
    const doc = try parse(arena, src, &p);
    var gaps = Gaps{};
    return renderBindings(arena, &doc, &gaps);
}

test "parse: a simple interface with scalar funcs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const out = try renderSrc(a,
        \\package acme:calc@1.0.0;
        \\interface calc {
        \\  add: func(a: s64, b: s64) -> s64;
        \\  ok: func(flag: bool) -> string;
        \\}
    );
    try testing.expect(std.mem.indexOf(u8, out, "package acme:calc@1.0.0") != null);
    try testing.expect(std.mem.indexOf(u8, out, "fn add(a: i64, b: i64) -> i64") != null);
    try testing.expect(std.mem.indexOf(u8, out, "fn ok(flag: bool) -> str") != null);
}

test "map: compound types — list, option, result, list<u8>=Bytes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const out = try renderSrc(a,
        \\interface i {
        \\  f: func(xs: list<s32>, maybe: option<string>, bytes: list<u8>) -> result<s64, string>;
        \\}
    );
    try testing.expect(std.mem.indexOf(u8, out, "xs: [i32]") != null);
    try testing.expect(std.mem.indexOf(u8, out, "maybe: Option<str>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "bytes: Bytes") != null);
    try testing.expect(std.mem.indexOf(u8, out, "-> Result<i64, str>") != null);
}

test "map: record→struct, enum, variant→enum-with-payload" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const out = try renderSrc(a,
        \\interface i {
        \\  record point { x: s32, y: s32 }
        \\  enum color { red, green, blue }
        \\  variant shape { circle(f64), square(s32), nothing }
        \\}
    );
    try testing.expect(std.mem.indexOf(u8, out, "struct point { x: i32, y: i32 }") != null);
    try testing.expect(std.mem.indexOf(u8, out, "enum color { red, green, blue }") != null);
    try testing.expect(std.mem.indexOf(u8, out, "circle(f64)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "nothing") != null);
}

test "gaps: char, flags, and anonymous tuple are surfaced, not coerced" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var p: Parser = undefined;
    const doc = try parse(a,
        \\interface i {
        \\  flags perms { read, write }
        \\  f: func(c: char, pair: tuple<s32, s32>) -> bool;
        \\}
    , &p);
    var gaps = Gaps{};
    _ = try renderBindings(a, &doc, &gaps);
    var saw_char = false;
    var saw_flags = false;
    var saw_tuple = false;
    for (gaps.list.items) |g| {
        if (std.mem.eql(u8, g.code, "WIT021")) saw_char = true;
        if (std.mem.eql(u8, g.code, "WIT020")) saw_flags = true;
        if (std.mem.eql(u8, g.code, "WIT022")) saw_tuple = true;
    }
    try testing.expect(saw_char and saw_flags and saw_tuple);
}

test "resource → opaque handle, own/borrow render as handles" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const out = try renderSrc(a,
        \\interface i {
        \\  resource file { read: func() -> list<u8>; }
        \\  open: func(path: string) -> own<file>;
        \\  size: func(f: borrow<file>) -> u64;
        \\}
    );
    try testing.expect(std.mem.indexOf(u8, out, "opaque handle: resource file") != null);
    try testing.expect(std.mem.indexOf(u8, out, "-> handle<file>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "f: &handle<file>") != null);
}

test "parse: a world is recorded by name; comments are skipped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var p: Parser = undefined;
    const doc = try parse(a,
        \\// a comment
        \\package w:demo;
        \\interface i { ping: func(); }
        \\world demo {
        \\  import i;
        \\  /* block */ export i;
        \\}
    , &p);
    try testing.expectEqual(@as(usize, 1), doc.interfaces.len);
    try testing.expectEqual(@as(usize, 1), doc.world_names.len);
    try testing.expectEqualStrings("demo", doc.world_names[0]);
}

test "parse error: a malformed type is reported, not panicked" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var p: Parser = undefined;
    const r = parse(a, "interface i { f: func(x: ) -> bool; }", &p);
    try testing.expectError(Error.ParseError, r);
    try testing.expect(p.err_msg.len > 0);
}
