//! q64 — the language binary. CLI surface specified in
//! spec/q64-cli.md.
//!
//! v0 scope: a single subcommand, `check`, that runs the parser
//! over a single file and emits the diagnostic envelope on stderr.
//! This is the minimum surface the conformance test runner needs.

const std = @import("std");
const parser = @import("parser");
const parse = parser.parse;
const diag = parser.diag;
const emit = @import("codegen/emit.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try usage();
        std.process.exit(2);
    }

    if (std.mem.eql(u8, args[1], "check")) {
        try cmdCheck(allocator, args[2..]);
        return;
    }

    if (std.mem.eql(u8, args[1], "emit-hello")) {
        try cmdEmitHello(allocator, args[2..]);
        return;
    }

    if (std.mem.eql(u8, args[1], "emit")) {
        try cmdEmit(allocator, args[2..]);
        return;
    }

    if (std.mem.eql(u8, args[1], "--version")) {
        try std.io.getStdOut().writer().writeAll("q64 0.0.1 (pre-alpha)\n");
        return;
    }

    try usage();
    std.process.exit(2);
}

fn usage() !void {
    const w = std.io.getStdErr().writer();
    try w.writeAll(
        \\usage: q64 <command> [args]
        \\
        \\Commands:
        \\  check <file> [--diagnostics json]  Parse a single file and emit diagnostics.
        \\  emit <file.q> <out.wasm>           Compile a q64 source file to wasm via codegen.
        \\  emit-hello <out.wasm>              Emit the hello-world wasm module (hardcoded fixture).
        \\  --version                          Print the version and exit.
        \\
    );
}

fn cmdCheck(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try usage();
        std.process.exit(2);
    }

    var file: ?[]const u8 = null;
    var json = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--diagnostics")) {
            // Next arg should be "json"; flag-style for now.
            // (No other diagnostics format implemented yet.)
            continue;
        }
        if (std.mem.eql(u8, a, "json")) {
            json = true;
            continue;
        }
        if (file == null) file = a;
    }

    const path = file orelse {
        try usage();
        std.process.exit(2);
    };

    const source = std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024) catch |err| {
        const w = std.io.getStdErr().writer();
        try w.print("q64: cannot read {s}: {s}\n", .{ path, @errorName(err) });
        std.process.exit(2);
    };
    defer allocator.free(source);

    const result = try parse.parse(allocator, source, path);
    defer result.deinit(allocator);

    var has_error = false;
    for (result.diagnostics) |d| if (d.severity == .err) {
        has_error = true;
        break;
    };

    if (json) {
        try diag.emitJson(std.io.getStdErr().writer(), source, result.diagnostics, allocator);
    } else {
        // Human-readable form. Mirrors the human format described
        // in spec/diagnostics.md §"Rendering".
        const w = std.io.getStdErr().writer();
        for (result.diagnostics) |d| {
            const idx = try diag.LineIndex.build(allocator, source);
            defer idx.deinit();
            const loc = idx.locate(d.offset);
            try w.print("{s}:{d}:{d}: {s}: {s} [{s}]\n", .{
                d.file, loc.line, loc.col, d.severity.toString(), d.message, d.code,
            });
        }
    }

    if (has_error) std.process.exit(1);
}

fn cmdEmitHello(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len != 1) {
        try usage();
        std.process.exit(2);
    }
    const out_path = args[0];

    const bytes = try emit.emitHelloWasm(allocator);
    defer allocator.free(bytes);

    try writeFile(out_path, bytes);
}

fn cmdEmit(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len != 2) {
        try usage();
        std.process.exit(2);
    }
    const src_path = args[0];
    const out_path = args[1];

    const source = std.fs.cwd().readFileAlloc(allocator, src_path, 16 * 1024 * 1024) catch |err| {
        const w = std.io.getStdErr().writer();
        try w.print("q64: cannot read {s}: {s}\n", .{ src_path, @errorName(err) });
        std.process.exit(2);
    };
    defer allocator.free(source);

    const bytes = emit.emitFromSource(allocator, source, src_path) catch |err| {
        const w = std.io.getStdErr().writer();
        try w.print("q64: emit failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer allocator.free(bytes);

    try writeFile(out_path, bytes);
}

fn writeFile(path: []const u8, bytes: []const u8) !void {
    const file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch |err| {
        const w = std.io.getStdErr().writer();
        try w.print("q64: cannot write {s}: {s}\n", .{ path, @errorName(err) });
        std.process.exit(2);
    };
    defer file.close();
    try file.writeAll(bytes);
}
