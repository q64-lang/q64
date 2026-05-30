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

    // Test seam: when Q64_FORCE_ICE is set, route through the internal-error
    // (ICE) path so the exit-70 + Q9xxx `severity:internal` envelope contract
    // (spec/q64-cli.md §"Exit codes", spec/diagnostics.md §"ICE convention")
    // is observable. Never triggered in normal use.
    if (init.environ_map.get("Q64_FORCE_ICE") != null) {
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stderr().writer(io, &buf);
        try w.interface.writeAll(
            \\{"ok":false,"diagnostics":[{"code":"Q9001","severity":"internal","kind":"ice","message":"forced internal error (Q64_FORCE_ICE)","repair":{"id":"report-upstream","safety":"n/a","report_url":"https://q64.dev/ice?code=Q9001"}}]}
        );
        try w.interface.writeAll("\n");
        try w.interface.flush();
        std.process.exit(70);
    }

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

    if (std.mem.eql(u8, sub, "show")) {
        try cmdShow(gpa, io, &args_it);
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
        \\  emit <file.q> <out.wasm> [--addr wasm32|wasm64] [--module name=dir ...]
        \\                                     Compile a q64 source file to wasm via codegen.
        \\                                     --addr selects the linear-memory address space
        \\                                     (default wasm64; wasm32 = 32-bit, WebKit/iPad).
        \\  emit-hello <out.wasm>              Emit the hello-world wasm module (hardcoded fixture).
        \\  show <hir|mir> <file.q> [--module name=dir ...]
        \\                                     Dump the Q64 IR (HIR or MIR) for a source file.
        \\  show effects <fn> --qube <file.q>  Print a function's inferred capability effect set.
        \\  show capabilities --qube <file.q>  Print the qube's compiler-derived capability set.
        \\  show world --qube <file.q>         Print the synthesized WIT world (exports + imports).
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
    // Address space (spec/memory.md §"The platform"). Explicit per build; we
    // default to wasm64 to preserve existing behavior for string programs until
    // the wasm32 string ABI lands (Path B). `--addr wasm32` opts in to a genuine
    // 32-bit module (the WebKit/iPad baseline) for the integer/import subset.
    var addr: emit.AddressSpace = .wasm64;
    var module_args: std.ArrayList(ModuleArg) = .empty;
    defer module_args.deinit(gpa);

    while (args_it.next()) |a| {
        if (std.mem.eql(u8, a, "--addr")) {
            const v = args_it.next() orelse {
                try usage(io);
                std.process.exit(2);
            };
            if (std.mem.eql(u8, v, "wasm32")) {
                addr = .wasm32;
            } else if (std.mem.eql(u8, v, "wasm64")) {
                addr = .wasm64;
            } else {
                var buf: [4096]u8 = undefined;
                var w = std.Io.File.stderr().writer(io, &buf);
                try w.interface.print("q64: --addr expects wasm32 or wasm64, got '{s}'\n", .{v});
                try w.interface.flush();
                std.process.exit(2);
            }
        } else if (std.mem.eql(u8, a, "--module")) {
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

    // Read each dependency module's entry file (`<dir>/lib.q`); freed below.
    var module_sources = try readModuleSources(gpa, io, module_args.items);
    defer {
        for (module_sources.items) |m| gpa.free(m.source);
        module_sources.deinit(gpa);
    }

    const bytes = emit.emitFromSource(gpa, source, src, module_sources.items, addr) catch |err| {
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

/// Read each dependency module's entry file (`<dir>/lib.q`) into a list of
/// `ModuleSource`s for the compiler. The caller frees each `.source` and
/// deinits the list. A read failure is a usage-level error (exit 2). Shared by
/// `emit` and `show`.
fn readModuleSources(gpa: std.mem.Allocator, io: std.Io, module_args: []const ModuleArg) !std.ArrayList(emit.ModuleSource) {
    var out: std.ArrayList(emit.ModuleSource) = .empty;
    errdefer {
        for (out.items) |m| gpa.free(m.source);
        out.deinit(gpa);
    }
    for (module_args) |ma| {
        const lib_path = try std.fs.path.join(gpa, &.{ ma.dir, "lib.q" });
        defer gpa.free(lib_path);
        const lib_src = std.Io.Dir.cwd().readFileAlloc(io, lib_path, gpa, .limited(16 * 1024 * 1024)) catch |err| {
            var buf: [4096]u8 = undefined;
            var w = std.Io.File.stderr().writer(io, &buf);
            try w.interface.print("q64: cannot read module {s} entry {s}: {s}\n", .{ ma.name, lib_path, @errorName(err) });
            try w.interface.flush();
            std.process.exit(2);
        };
        try out.append(gpa, .{ .name = ma.name, .source = lib_src });
    }
    return out;
}

/// `q64 show <hir|mir> <file.q> [--module name=dir ...]` — dump the Q64 IR
/// (HIR or MIR) for a source file to stdout (spec/q64-cli.md §"show"). The
/// front matter (parse + import resolution) is shared with `emit`, so `show`
/// surfaces the same honest diagnostics on a malformed program.
fn cmdShow(gpa: std.mem.Allocator, io: std.Io, args_it: *std.process.Args.Iterator) !void {
    var kind: ?[]const u8 = null;
    // The second positional: a source file for `hir`/`mir`, or a subject (a
    // function name) for `effects`. The qube-level kinds take `--qube` instead.
    var arg2: ?[]const u8 = null;
    var qube_file: ?[]const u8 = null;
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
        } else if (std.mem.eql(u8, a, "--qube")) {
            qube_file = args_it.next() orelse {
                try usage(io);
                std.process.exit(2);
            };
        } else if (std.mem.startsWith(u8, a, "--")) {
            // Tolerate (and ignore) flags this subcommand doesn't consume.
        } else if (kind == null) {
            kind = a;
        } else if (arg2 == null) {
            arg2 = a;
        } else {
            try usage(io);
            std.process.exit(2);
        }
    }

    const k = kind orelse {
        try usage(io);
        std.process.exit(2);
    };

    // Classify the kind and resolve which positional is the source file.
    const Kind = enum { hir, mir, effects, capabilities, world };
    const which: Kind = if (std.mem.eql(u8, k, "hir"))
        .hir
    else if (std.mem.eql(u8, k, "mir"))
        .mir
    else if (std.mem.eql(u8, k, "effects"))
        .effects
    else if (std.mem.eql(u8, k, "capabilities"))
        .capabilities
    else if (std.mem.eql(u8, k, "world"))
        .world
    else {
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stderr().writer(io, &buf);
        try w.interface.print("q64: show: unknown kind '{s}'\n", .{k});
        try w.interface.flush();
        std.process.exit(2);
    };

    // `hir`/`mir` take the source file as the second positional; the effect /
    // component kinds take `--qube <file>` (and `effects` a `<fn>` positional).
    const ir_kind = which == .hir or which == .mir;
    const src = (if (ir_kind) (arg2 orelse qube_file) else qube_file) orelse {
        try usage(io);
        std.process.exit(2);
    };
    if (which == .effects and arg2 == null) {
        try usage(io);
        std.process.exit(2);
    }

    const source = std.Io.Dir.cwd().readFileAlloc(io, src, gpa, .limited(16 * 1024 * 1024)) catch |err| {
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stderr().writer(io, &buf);
        try w.interface.print("q64: cannot read {s}: {s}\n", .{ src, @errorName(err) });
        try w.interface.flush();
        std.process.exit(2);
    };
    defer gpa.free(source);

    var module_sources = try readModuleSources(gpa, io, module_args.items);
    defer {
        for (module_sources.items) |m| gpa.free(m.source);
        module_sources.deinit(gpa);
    }

    const dump = (switch (which) {
        .hir => emit.showHir(gpa, source, src, module_sources.items),
        .mir => emit.showMir(gpa, source, src, module_sources.items),
        .effects => emit.showEffects(gpa, source, src, module_sources.items, arg2.?),
        .capabilities => emit.showCapabilities(gpa, source, src, module_sources.items),
        .world => emit.showWorld(gpa, source, src, module_sources.items),
    }) catch |err| {
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stderr().writer(io, &buf);
        try w.interface.print("q64: show {s} failed: {s}\n", .{ k, @errorName(err) });
        try w.interface.flush();
        std.process.exit(1);
    };
    defer gpa.free(dump);

    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.writeAll(dump);
    try w.interface.flush();
}
