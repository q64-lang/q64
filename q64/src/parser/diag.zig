//! Diagnostic envelope construction. Matches the JSON shape in
//! spec/diagnostics.md.
//!
//! This module is the bridge between in-pass diagnostic emission
//! (lex.zig / parse.zig produce raw `{code, offset}` pairs) and the
//! envelope every q64 binary prints on stderr.
//!
//! v0 scope: writes the minimal envelope — `ok` + `diagnostics[]`
//! with `code`, `severity`, `message`, and `location`. Labels,
//! notes, and repair are left unfilled until the passes that
//! produce them land.

const std = @import("std");

pub const Severity = enum {
    err, // emitted as "error" — `error` is a Zig keyword
    warning,
    note,
    help,
    internal,

    pub fn toString(self: Severity) []const u8 {
        return switch (self) {
            .err => "error",
            .warning => "warning",
            .note => "note",
            .help => "help",
            .internal => "internal",
        };
    }
};

pub const Diagnostic = struct {
    code: []const u8,
    severity: Severity,
    message: []const u8,
    file: []const u8,
    offset: u32,
};

/// Line-break index built once per file; converts byte offsets to
/// `(line, col)` in O(log n).
pub const LineIndex = struct {
    breaks: []const u32,
    allocator: std.mem.Allocator,

    pub fn build(allocator: std.mem.Allocator, source: []const u8) !LineIndex {
        var list: std.ArrayList(u32) = .empty;
        defer list.deinit(allocator);
        try list.append(allocator, 0); // line 1 starts at offset 0
        var i: u32 = 0;
        while (i < source.len) : (i += 1) {
            if (source[i] == '\n') try list.append(allocator, i + 1);
        }
        return .{ .breaks = try list.toOwnedSlice(allocator), .allocator = allocator };
    }

    pub fn deinit(self: LineIndex) void {
        self.allocator.free(self.breaks);
    }

    /// 1-based line and column.
    pub fn locate(self: LineIndex, offset: u32) struct { line: u32, col: u32 } {
        // Find the largest break index whose value is <= offset.
        var lo: usize = 0;
        var hi: usize = self.breaks.len;
        while (lo + 1 < hi) {
            const mid = (lo + hi) / 2;
            if (self.breaks[mid] <= offset) lo = mid else hi = mid;
        }
        const line = @as(u32, @intCast(lo + 1));
        const col = offset - self.breaks[lo] + 1;
        return .{ .line = line, .col = col };
    }
};

/// Look up the canonical short-message for a diagnostic code.
/// Returns `""` for unknown codes — the caller is responsible for
/// supplying a message in that case.
pub fn messageFor(code: []const u8) []const u8 {
    inline for (message_table) |entry| {
        if (std.mem.eql(u8, entry.code, code)) return entry.message;
    }
    return "";
}

const MessageEntry = struct { code: []const u8, message: []const u8 };

/// Stable code → short-message table. Mirrors the rows in each
/// spec's "Diagnostic codes" section. New codes append; numbers
/// are never reused.
const message_table = [_]MessageEntry{
    // Lexical
    .{ .code = "LEX010", .message = "stray carriage return" },
    .{ .code = "LEX020", .message = "unknown string-literal prefix" },
    .{ .code = "LEX021", .message = "unexpected `&` in type position" },
    .{ .code = "LEX030", .message = "unterminated string literal" },
    .{ .code = "LEX031", .message = "char literals are not supported" },
    .{ .code = "LEX040", .message = "unexpected character" },
    // Parser
    .{ .code = "PAR040", .message = "generic vs less-than ambiguity" },
    // Names
    .{ .code = "NAM001", .message = "unknown module" },
    .{ .code = "NAM002", .message = "import path escapes qube" },
    .{ .code = "NAM003", .message = "wildcard import is forbidden" },
    .{ .code = "NAM004", .message = "selective import combined with alias" },
    .{ .code = "NAM005", .message = "name collision in import scope" },
    .{ .code = "NAM006", .message = "name is private to its qube" },
    .{ .code = "NAM007", .message = "sub-module not re-exported" },
    .{ .code = "NAM008", .message = "re-export cycle" },
    .{ .code = "NAM009", .message = "block `pub` form is forbidden" },
    .{ .code = "NAM010", .message = "unknown name in source module" },
    .{ .code = "NAM011", .message = "dash in bare module path" },
};

/// Emit a JSON envelope per spec/diagnostics.md §"Envelope shape"
/// to `writer`. `ok` is true iff `diagnostics` contains no
/// error-severity entries.
pub fn emitJson(
    writer: *std.Io.Writer,
    source: []const u8,
    diagnostics: []const Diagnostic,
    allocator: std.mem.Allocator,
) !void {
    const idx = try LineIndex.build(allocator, source);
    defer idx.deinit();

    var ok = true;
    for (diagnostics) |d| if (d.severity == .err) {
        ok = false;
        break;
    };

    try writer.print("{{\"ok\":{s},\"diagnostics\":[", .{if (ok) "true" else "false"});
    for (diagnostics, 0..) |d, i| {
        if (i > 0) try writer.writeByte(',');
        const loc = idx.locate(d.offset);
        try writer.writeAll("{\"code\":\"");
        try writer.writeAll(d.code);
        try writer.writeAll("\",\"severity\":\"");
        try writer.writeAll(d.severity.toString());
        try writer.writeAll("\",\"message\":");
        try writeJsonString(writer, d.message);
        try writer.writeAll(",\"location\":{\"file\":");
        try writeJsonString(writer, d.file);
        try writer.print(",\"line\":{d},\"col\":{d}}}}}", .{ loc.line, loc.col });
    }
    try writer.writeAll("]}");
    try writer.writeByte('\n');
}

fn writeJsonString(writer: *std.Io.Writer, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0...0x08, 0x0b, 0x0c, 0x0e...0x1f => try writer.print("\\u{x:0>4}", .{c}),
        else => try writer.writeByte(c),
    };
    try writer.writeByte('"');
}

// =====================================================================
// Tests
// =====================================================================

const testing = std.testing;

test "line index: basic two-line file" {
    const src = "abc\ndef\n";
    const idx = try LineIndex.build(testing.allocator, src);
    defer idx.deinit();

    try testing.expectEqual(@as(u32, 1), idx.locate(0).line);
    try testing.expectEqual(@as(u32, 1), idx.locate(0).col);
    try testing.expectEqual(@as(u32, 1), idx.locate(2).line);
    try testing.expectEqual(@as(u32, 3), idx.locate(2).col);
    try testing.expectEqual(@as(u32, 2), idx.locate(4).line);
    try testing.expectEqual(@as(u32, 1), idx.locate(4).col);
    try testing.expectEqual(@as(u32, 2), idx.locate(6).line);
    try testing.expectEqual(@as(u32, 3), idx.locate(6).col);
}

test "messageFor: known and unknown codes" {
    try testing.expectEqualStrings("stray carriage return", messageFor("LEX010"));
    try testing.expectEqualStrings("", messageFor("XYZ999"));
}

test "emitJson: ok envelope" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try emitJson(&aw.writer, "", &.{}, testing.allocator);
    try testing.expectEqualStrings("{\"ok\":true,\"diagnostics\":[]}\n", aw.writer.buffered());
}

test "emitJson: single LEX010 envelope" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const src = "fn main\r{}\n";
    const diags = [_]Diagnostic{.{
        .code = "LEX010",
        .severity = .err,
        .message = messageFor("LEX010"),
        .file = "stray.q",
        .offset = 7,
    }};
    try emitJson(&aw.writer, src, &diags, testing.allocator);
    const buf_items = aw.writer.buffered();
    // Spot-check the envelope rather than full byte match.
    try testing.expect(std.mem.indexOf(u8, buf_items, "\"ok\":false") != null);
    try testing.expect(std.mem.indexOf(u8, buf_items, "\"code\":\"LEX010\"") != null);
    try testing.expect(std.mem.indexOf(u8, buf_items, "\"severity\":\"error\"") != null);
    try testing.expect(std.mem.indexOf(u8, buf_items, "\"file\":\"stray.q\"") != null);
    try testing.expect(std.mem.indexOf(u8, buf_items, "\"line\":1") != null);
    try testing.expect(std.mem.indexOf(u8, buf_items, "\"col\":8") != null);
}
