//! JSON5 → strict JSON for qube.json5 manifests — the dialect
//! spec/qube.json5.md commits to. Pure (allocator + slices, no fs), so
//! it compiles to wasm: the shared parser for the native CLI and the
//! wasm `qube` resolver.

const std = @import("std");

/// Copy a quoted string literal (including its quotes) from `src[start..]`
/// into `out`, honoring backslash escapes. `src[start]` must be the opening
/// quote (`"` or `'`). Returns the index just past the closing quote.
fn copyStringLiteral(gpa: std.mem.Allocator, out: *std.ArrayList(u8), src: []const u8, start: usize) !usize {
    const q = src[start];
    try out.append(gpa, q);
    var i = start + 1;
    while (i < src.len) {
        const d = src[i];
        try out.append(gpa, d);
        i += 1;
        if (d == '\\' and i < src.len) {
            try out.append(gpa, src[i]);
            i += 1;
            continue;
        }
        if (d == q) break;
    }
    return i;
}

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$';
}

fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

/// Convert a JSON5 manifest to strict JSON that `std.json` accepts.
/// Handles exactly the dialect `spec/qube.json5.md` commits to: `//` and
/// `/* */` comments, trailing commas, single-quoted strings, and unquoted
/// (ASCII-identifier) object keys. String contents are preserved verbatim,
/// so a `//`, `,`, or quote inside a value is never touched. JSON5
/// features outside the manifest dialect (hex numbers, `Infinity`, …)
/// pass through and are rejected by `std.json`. Caller owns the returned
/// buffer.
pub fn toJson(gpa: std.mem.Allocator, src: []const u8) ![]u8 {
    // Pass 1: drop comments, copying string literals (either quote kind)
    // through untouched.
    var nocomments: std.ArrayList(u8) = .empty;
    defer nocomments.deinit(gpa);
    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        if (c == '"' or c == '\'') {
            i = try copyStringLiteral(gpa, &nocomments, src, i);
            continue;
        }
        if (c == '/' and i + 1 < src.len and src[i + 1] == '/') {
            i += 2;
            while (i < src.len and src[i] != '\n') i += 1;
            continue;
        }
        if (c == '/' and i + 1 < src.len and src[i + 1] == '*') {
            i += 2;
            while (i + 1 < src.len and !(src[i] == '*' and src[i + 1] == '/')) i += 1;
            i = @min(i + 2, src.len);
            continue;
        }
        try nocomments.append(gpa, c);
        i += 1;
    }

    // Pass 2: rewrite single-quoted strings as double-quoted — `\'`
    // unescapes to a bare `'`, an embedded `"` gains a backslash.
    var dquoted: std.ArrayList(u8) = .empty;
    defer dquoted.deinit(gpa);
    {
        const buf = nocomments.items;
        var j: usize = 0;
        while (j < buf.len) {
            const c = buf[j];
            if (c == '"') {
                j = try copyStringLiteral(gpa, &dquoted, buf, j);
                continue;
            }
            if (c == '\'') {
                try dquoted.append(gpa, '"');
                j += 1;
                while (j < buf.len) {
                    const d = buf[j];
                    if (d == '\\' and j + 1 < buf.len) {
                        if (buf[j + 1] == '\'') {
                            try dquoted.append(gpa, '\'');
                        } else {
                            try dquoted.append(gpa, d);
                            try dquoted.append(gpa, buf[j + 1]);
                        }
                        j += 2;
                        continue;
                    }
                    if (d == '\'') {
                        try dquoted.append(gpa, '"');
                        j += 1;
                        break;
                    }
                    if (d == '"') {
                        try dquoted.appendSlice(gpa, "\\\"");
                        j += 1;
                        continue;
                    }
                    try dquoted.append(gpa, d);
                    j += 1;
                }
                continue;
            }
            try dquoted.append(gpa, c);
            j += 1;
        }
    }

    // Pass 3: quote unquoted object keys. A container stack tells object
    // from array context; in an object, a key is expected after `{` and
    // after `,`. Value-position identifiers (`true`, `false`, `null`)
    // are never in key position, so they pass through.
    var keyed: std.ArrayList(u8) = .empty;
    defer keyed.deinit(gpa);
    {
        var stack: std.ArrayList(u8) = .empty;
        defer stack.deinit(gpa);
        var expect_key = false;
        const buf = dquoted.items;
        var j: usize = 0;
        while (j < buf.len) {
            const c = buf[j];
            if (c == '"') {
                j = try copyStringLiteral(gpa, &keyed, buf, j);
                expect_key = false;
                continue;
            }
            switch (c) {
                '{' => {
                    try stack.append(gpa, '{');
                    expect_key = true;
                },
                '[' => {
                    try stack.append(gpa, '[');
                    expect_key = false;
                },
                '}', ']' => {
                    _ = stack.pop();
                    expect_key = false;
                },
                ',' => {
                    expect_key = stack.items.len > 0 and stack.items[stack.items.len - 1] == '{';
                },
                else => {
                    if (expect_key and isIdentStart(c)) {
                        try keyed.append(gpa, '"');
                        while (j < buf.len and isIdentChar(buf[j])) {
                            try keyed.append(gpa, buf[j]);
                            j += 1;
                        }
                        try keyed.append(gpa, '"');
                        expect_key = false;
                        continue;
                    }
                },
            }
            try keyed.append(gpa, c);
            j += 1;
        }
    }

    // Pass 4: drop a comma when the next significant byte is `}` or `]`.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const buf = keyed.items;
    var j: usize = 0;
    while (j < buf.len) {
        const c = buf[j];
        if (c == '"') {
            j = try copyStringLiteral(gpa, &out, buf, j);
            continue;
        }
        if (c == ',') {
            var k = j + 1;
            while (k < buf.len and (buf[k] == ' ' or buf[k] == '\t' or buf[k] == '\n' or buf[k] == '\r')) k += 1;
            if (k < buf.len and (buf[k] == '}' or buf[k] == ']')) {
                j += 1; // drop the trailing comma
                continue;
            }
        }
        try out.append(gpa, c);
        j += 1;
    }
    return out.toOwnedSlice(gpa);
}

/// Test helper: drop whitespace outside string literals, so expectations
/// don't depend on the exact residue comment-stripping leaves behind.
fn stripWsOutsideStrings(gpa: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        if (c == '"') {
            i = try copyStringLiteral(gpa, &out, src, i);
            continue;
        }
        if (c != ' ' and c != '\t' and c != '\n' and c != '\r') try out.append(gpa, c);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

fn expectJson5(expected: []const u8, src: []const u8) !void {
    const gpa = std.testing.allocator;
    const got = try toJson(gpa, src);
    defer gpa.free(got);
    const got_stripped = try stripWsOutsideStrings(gpa, got);
    defer gpa.free(got_stripped);
    const expected_stripped = try stripWsOutsideStrings(gpa, expected);
    defer gpa.free(expected_stripped);
    try std.testing.expectEqualStrings(expected_stripped, got_stripped);
    // Whatever the transform produces must be valid strict JSON.
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, got, .{});
    defer parsed.deinit();
}

test "json5ToJson: comments and trailing commas (regression)" {
    try expectJson5(
        "{ \"name\": \"x\" }",
        "{ \"name\": \"x\", // c\n /* block */ }",
    );
}

test "json5ToJson: comment markers inside strings are preserved" {
    try expectJson5(
        "{ \"url\": \"https://q64.dev\", \"note\": \"a, b /* not a comment */\" }",
        "{ \"url\": \"https://q64.dev\", \"note\": \"a, b /* not a comment */\" }",
    );
}

test "json5ToJson: single-quoted strings convert, escapes rewrite" {
    try expectJson5(
        "{ \"a\": \"it's\", \"b\": \"say \\\"hi\\\"\" }",
        "{ \"a\": 'it\\'s', \"b\": 'say \"hi\"' }",
    );
}

test "json5ToJson: unquoted keys are quoted, value identifiers untouched" {
    try expectJson5(
        "{ \"$schema\": \"s\", \"name\": \"x\", \"flag\": true, \"deps\": { \"a_1\": null }, \"xs\": [false] }",
        "{ $schema: \"s\", name: \"x\", flag: true, deps: { a_1: null }, xs: [false] }",
    );
}

test "json5ToJson: full manifest dialect end to end" {
    try expectJson5(
        "{ \"name\": \"dev.q64.j5\", \"version\": \"0.1.0\", \"license\": \"MIT\", \"type\": \"application\", \"entry\": \"src/main.q\" }",
        "{ name: 'dev.q64.j5', version: '0.1.0', /* id */ license: 'MIT', type: 'application', entry: 'src/main.q', // tail\n }",
    );
}

test "json5ToJson: single-quoted string containing comment and brace bytes" {
    try expectJson5(
        "{ \"k\": \"// { , } [\" }",
        "{ k: '// { , } [' }",
    );
}
