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

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args_it = init.minimal.args.iterate();
    // Skip argv[0].
    _ = args_it.next();

    const sub = args_it.next() orelse {
        try usage(io);
        std.process.exit(2);
    };

    if (std.mem.eql(u8, sub, "check")) {
        try cmdCheck(gpa, io, &args_it);
        return;
    }

    if (std.mem.eql(u8, sub, "emit-hello")) {
        try cmdEmitHello(gpa, io, &args_it);
        return;
    }

    if (std.mem.eql(u8, sub, "emit")) {
        try cmdEmit(gpa, io, &args_it);
        return;
    }

    if (std.mem.eql(u8, sub, "--version")) {
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stdout().writer(io, &buf);
        try w.interface.writeAll("q64 0.0.1 (pre-alpha)\n");
        try w.interface.flush();
        return;
    }

    try usage(io);
    std.process.exit(2);
}

fn usage(io: std.Io) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    try w.interface.writeAll(
        \\usage: q64 <command> [args]
        \\
        \\Commands:
        \\  check <file> [--diagnostics json]  Parse a single file and emit diagnostics.
        \\  emit <file.q> <out.wasm> [--module name=dir ...]
        \\                                     Compile a q64 source file to wasm via codegen.
        \\  emit-hello <out.wasm>              Emit the hello-world wasm module (hardcoded fixture).
        \\  --version                          Print the version and exit.
        \\
    );
    try w.interface.flush();
}

fn cmdCheck(gpa: std.mem.Allocator, io: std.Io, args_it: *std.process.Args.Iterator) !void {
    var file: ?[]const u8 = null;
    var json = false;
    while (args_it.next()) |a| {
        if (std.mem.eql(u8, a, "--diagnostics")) {
            // Next arg should be "json"; flag-style for now.
            continue;
        }
        if (std.mem.eql(u8, a, "json")) {
            json = true;
            continue;
        }
        if (file == null) file = a;
    }

    const path = file orelse {
        try usage(io);
        std.process.exit(2);
    };

    const source = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 * 1024 * 1024)) catch |err| {
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stderr().writer(io, &buf);
        try w.interface.print("q64: cannot read {s}: {s}\n", .{ path, @errorName(err) });
        try w.interface.flush();
        std.process.exit(2);
    };
    defer gpa.free(source);

    const result = try parse.parse(gpa, source, path);
    defer result.deinit(gpa);

    var has_error = false;
    for (result.diagnostics) |d| if (d.severity == .err) {
        has_error = true;
        break;
    };

    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);

    if (json) {
        try diag.emitJson(&w.interface, source, result.diagnostics, gpa);
    } else {
        // Human-readable form. Mirrors the human format described
        // in spec/diagnostics.md §"Rendering".
        for (result.diagnostics) |d| {
            const idx = try diag.LineIndex.build(gpa, source);
            defer idx.deinit();
            const loc = idx.locate(d.offset);
            try w.interface.print("{s}:{d}:{d}: {s}: {s} [{s}]\n", .{
                d.file, loc.line, loc.col, d.severity.toString(), d.message, d.code,
            });
        }
    }
    try w.interface.flush();

    if (has_error) std.process.exit(1);
}

fn cmdEmitHello(gpa: std.mem.Allocator, io: std.Io, args_it: *std.process.Args.Iterator) !void {
    const out_path = args_it.next() orelse {
        try usage(io);
        std.process.exit(2);
    };
    if (args_it.next() != null) {
        try usage(io);
        std.process.exit(2);
    }

    const bytes = try emit.emitHelloWasm(gpa);
    defer gpa.free(bytes);

    try writeFile(io, out_path, bytes);
}

/// A `--module name=dir` mapping from a dependency's module path to its
/// source directory. The compiler reads the module's entry (`lib.q`)
/// from `dir`; it never reads `qube.json5` (spec/q64-cli.md §"--module").
const ModuleArg = struct { name: []const u8, dir: []const u8 };

fn cmdEmit(gpa: std.mem.Allocator, io: std.Io, args_it: *std.process.Args.Iterator) !void {
    var src_path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var module_args: std.ArrayList(ModuleArg) = .empty;
    defer module_args.deinit(gpa);

    while (args_it.next()) |a| {
        if (std.mem.eql(u8, a, "--module")) {
            const spec = args_it.next() orelse {
                try usage(io);
                std.process.exit(2);
            };
            const eq = std.mem.indexOfScalar(u8, spec, '=') orelse {
                var buf: [4096]u8 = undefined;
                var w = std.Io.File.stderr().writer(io, &buf);
                try w.interface.print("q64: --module expects name=dir, got '{s}'\n", .{spec});
                try w.interface.flush();
                std.process.exit(2);
            };
            try module_args.append(gpa, .{ .name = spec[0..eq], .dir = spec[eq + 1 ..] });
        } else if (std.mem.startsWith(u8, a, "--")) {
            // Flags q64 emit does not consume in v0 (e.g. --diagnostics)
            // are tolerated and ignored so the qube subprocess contract
            // can evolve without breaking older binaries.
        } else if (src_path == null) {
            src_path = a;
        } else if (out_path == null) {
            out_path = a;
        } else {
            try usage(io);
            std.process.exit(2);
        }
    }

    const src = src_path orelse {
        try usage(io);
        std.process.exit(2);
    };
    const out = out_path orelse {
        try usage(io);
        std.process.exit(2);
    };

    const source = std.Io.Dir.cwd().readFileAlloc(io, src, gpa, .limited(16 * 1024 * 1024)) catch |err| {
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stderr().writer(io, &buf);
        try w.interface.print("q64: cannot read {s}: {s}\n", .{ src, @errorName(err) });
        try w.interface.flush();
        std.process.exit(2);
    };
    defer gpa.free(source);

    // Read each dependency module's entry file (`<dir>/lib.q`). Kept
    // alive until after codegen; freed below.
    var module_sources: std.ArrayList(emit.ModuleSource) = .empty;
    defer {
        for (module_sources.items) |m| gpa.free(m.source);
        module_sources.deinit(gpa);
    }
    for (module_args.items) |ma| {
        const lib_path = try std.fs.path.join(gpa, &.{ ma.dir, "lib.q" });
        defer gpa.free(lib_path);
        const lib_src = std.Io.Dir.cwd().readFileAlloc(io, lib_path, gpa, .limited(16 * 1024 * 1024)) catch |err| {
            var buf: [4096]u8 = undefined;
            var w = std.Io.File.stderr().writer(io, &buf);
            try w.interface.print("q64: cannot read module {s} entry {s}: {s}\n", .{ ma.name, lib_path, @errorName(err) });
            try w.interface.flush();
            std.process.exit(2);
        };
        try module_sources.append(gpa, .{ .name = ma.name, .source = lib_src });
    }

    const bytes = emit.emitFromSource(gpa, source, src, module_sources.items) catch |err| {
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stderr().writer(io, &buf);
        try w.interface.print("q64: emit failed: {s}\n", .{@errorName(err)});
        try w.interface.flush();
        std.process.exit(1);
    };
    defer gpa.free(bytes);

    try writeFile(io, out, bytes);
}

fn writeFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = bytes,
        .flags = .{ .truncate = true },
    }) catch |err| {
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stderr().writer(io, &buf);
        try w.interface.print("q64: cannot write {s}: {s}\n", .{ path, @errorName(err) });
        try w.interface.flush();
        std.process.exit(2);
    };
}
