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
const sema = @import("sema");
const doc = @import("doc.zig");
const wit = @import("wit");
const fmt = @import("fmt/fmt.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // Test seam: when Q64_FORCE_ICE is set, route through the internal-error
    // (ICE) path so the exit-70 + Q9xxx `severity:internal` envelope contract
    // (spec/q64-cli.md §"Exit codes", spec/diagnostics.md §"ICE convention")
    // is observable. Never triggered in normal use.
    if (init.environ_map.get("Q64_FORCE_ICE") != null) {
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stderr().writerStreaming(io, &buf);
        try w.interface.writeAll(
            \\{"ok":false,"diagnostics":[{"code":"Q9001","severity":"internal","kind":"ice","message":"forced internal error (Q64_FORCE_ICE)","repair":{"id":"report-upstream","safety":"n/a","report_url":"https://docs.q64.dev/diagnostics/Q9001"}}]}
        );
        try w.interface.writeAll("\n");
        try w.interface.flush();
        std.process.exit(70);
    }

    // iterateAllocator (not iterate) so this compiles on Windows, where
    // decoding the UTF-16 command line into argv needs an allocator. POSIX
    // ignores the allocator; the process exits right after, so we don't deinit.
    var args_it = try init.minimal.args.iterateAllocator(gpa);
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

    if (std.mem.eql(u8, sub, "fmt")) {
        try cmdFmt(gpa, io, &args_it);
        return;
    }

    if (std.mem.eql(u8, sub, "emit-hello")) {
        try cmdEmitHello(gpa, io, &args_it);
        return;
    }

    if (std.mem.eql(u8, sub, "emit")) {
        try cmdEmit(gpa, io, init.environ_map, &args_it);
        return;
    }

    if (std.mem.eql(u8, sub, "run")) {
        const file = args_it.next() orelse {
            try usage(io);
            std.process.exit(2);
        };
        try cmdRun(gpa, io, init.environ_map, file, &args_it);
        return;
    }

    // Implicit run: `q64 <file.q>` dispatches to `run` (spec/q64-cli.md
    // §Synopsis). A bare `.q` path that isn't a known subcommand is a program
    // to compile and execute.
    if (std.mem.endsWith(u8, sub, ".q")) {
        try cmdRun(gpa, io, init.environ_map, sub, &args_it);
        return;
    }

    if (std.mem.eql(u8, sub, "show")) {
        try cmdShow(gpa, io, &args_it);
        return;
    }

    if (std.mem.eql(u8, sub, "wit")) {
        try cmdWit(gpa, io, &args_it);
        return;
    }

    if (std.mem.eql(u8, sub, "doc")) {
        try cmdDoc(gpa, io, &args_it);
        return;
    }

    if (std.mem.eql(u8, sub, "explain")) {
        try cmdExplain(gpa, io, &args_it);
        return;
    }

    if (std.mem.eql(u8, sub, "--version")) {
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stdout().writerStreaming(io, &buf);
        try w.interface.writeAll("q64 0.0.10 (pre-alpha)\n");
        try w.interface.flush();
        return;
    }

    try usage(io);
    std.process.exit(2);
}

fn usage(io: std.Io) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(io, &buf);
    try w.interface.writeAll(
        \\usage: q64 <command> [args]
        \\
        \\Commands:
        \\  check <file> [--diagnostics json]  Parse a single file and emit diagnostics.
        \\  fmt [path] [--stdout] [--check] [--lint]
        \\                                     Format source in place (file or directory, recursive).
        \\                                     --stdout: read stdin (or path) and print to stdout.
        \\                                     --check: exit 64 if any file would change. --lint: report.
        \\  emit <file.q> <out.wasm> [--addr wasm32|wasm64] [--component] [--module name=file ...]
        \\                                     Compile a q64 source file to wasm via codegen.
        \\                                     --addr selects the linear-memory address space
        \\                                     (default wasm64; wasm32 = 32-bit, WebKit/iPad).
        \\                                     --component also writes <out>.component.wasm + <out>.wit.
        \\                                     --world <name> / --wit-package <id> name the synthesized world.
        \\                                     --wit-import <file.wit> declares a foreign import (repeatable).
        \\                                     --export-interface <pkg>/<iface> exports the surface as a named interface.
        \\  emit-hello <out.wasm>              Emit the hello-world wasm module (hardcoded fixture).
        \\  show <hir|mir|symbols> <file.q> [--module name=file ...]
        \\                                     Dump the Q64 IR (HIR or MIR) for a source file.
        \\  show effects <fn> --qube <file.q>  Print a function's inferred capability effect set.
        \\  show capabilities --qube <file.q>  Print the qube's compiler-derived capability set.
        \\  show world --qube <file.q> [--out <file.wit>] [--world <name>] [--wit-package <id>]
        \\                                     Print (or write) the synthesized WIT world.
        \\  wit import <file.wit> [--out <f>]  Parse a foreign WIT package and print its q64 bindings.
        \\  doc --json [--qube <file.q>]       Emit the language documentation index as JSON.
        \\  explain <code> [--diagnostics json]  Print documentation for a diagnostic code.
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
        var w = std.Io.File.stderr().writerStreaming(io, &buf);
        try w.interface.print("q64: cannot read {s}: {s}\n", .{ path, @errorName(err) });
        try w.interface.flush();
        std.process.exit(2);
    };
    defer gpa.free(source);

    const result = try parse.parse(gpa, source, path);
    defer result.deinit(gpa);

    // Parse diagnostics + the sema passes: NAM005 import-scope collisions
    // (spec/modules.md) and the A4 check pass (TYP042 / TYP051,
    // spec/types.md). Sema only runs when the file parsed into a
    // source-file root.
    var all_diags: std.ArrayList(diag.Diagnostic) = .empty;
    defer all_diags.deinit(gpa);
    try all_diags.appendSlice(gpa, result.diagnostics);
    if (parser.ast.SourceFile.cast(result.root)) |sf| {
        var table = try sema.build(gpa, sf);
        defer table.deinit();
        const sema_diags = try sema.fileDiagnostics(gpa, &table, path);
        defer gpa.free(sema_diags);
        try all_diags.appendSlice(gpa, sema_diags);

        // NAM002 — a quoted-relative import that escapes the qube. Needs the
        // filesystem (the qube root, walked up to the nearest `qube.json5`), so
        // it lives here rather than in the pure sema pass.
        const qube_root = findQubeRoot(gpa, io, path) catch null;
        defer if (qube_root) |r| gpa.free(r);
        var iit = sf.imports();
        while (iit.next()) |imp| {
            if (!imp.isRelative()) continue;
            const ipath = (try imp.path(gpa)) orelse continue;
            defer gpa.free(ipath);
            if (importEscapesQube(gpa, io, path, ipath, qube_root) catch false) {
                try all_diags.append(gpa, .{
                    .code = "NAM002",
                    .severity = .err,
                    .message = diag.messageFor("NAM002"),
                    .file = path,
                    .offset = imp.offset(),
                });
            }
        }

        // The fit registry: powers the fit-form checks (TYP201 / TYP202,
        // spec/faces.md §"Fit declaration") and the check pass's generic
        // bound check (TYP200).
        var fitreg = try sema.fits.build(gpa, sf);
        defer fitreg.deinit();

        var store = try sema.types.TypeStore.init(gpa);
        defer store.deinit();
        var sigs = try sema.types.collectSignatures(&store, &table, sf);
        defer sigs.deinit();
        const check_diags = try sema.check.checkFile(gpa, sf, &table, &store, &sigs, &fitreg);
        defer gpa.free(check_diags);
        for (check_diags) |cd| {
            try all_diags.append(gpa, .{
                .code = cd.code,
                .severity = .err,
                .message = diag.messageFor(cd.code),
                .file = path,
                .offset = cd.offset,
            });
        }

        for (fitreg.diags.items) |fd| {
            try all_diags.append(gpa, .{
                .code = fd.code,
                .severity = .err,
                .message = diag.messageFor(fd.code),
                .file = path,
                .offset = fd.offset,
            });
        }
    }

    var has_error = false;
    for (all_diags.items) |d| if (d.severity == .err) {
        has_error = true;
        break;
    };

    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(io, &buf);

    if (json) {
        try diag.emitJson(&w.interface, source, all_diags.items, gpa);
    } else {
        // Human-readable form. Mirrors the human format described
        // in spec/diagnostics.md §"Rendering".
        for (all_diags.items) |d| {
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

/// `q64 fmt` — the formatter (spec/q64-cli.md §"q64 fmt"). Default mode
/// rewrites files in place (atomically); `--stdout` prints to stdout and
/// reads stdin when no path is given; `--check` exits 64 if anything would
/// change; `--lint` reports without modifying. A file with syntax errors is
/// left untouched and reported as FMT001.
const FmtMode = enum { write, stdout, check, lint };

fn cmdFmt(gpa: std.mem.Allocator, io: std.Io, args_it: *std.process.Args.Iterator) !void {
    var path: ?[]const u8 = null;
    var mode: FmtMode = .write;
    var json = false;
    while (args_it.next()) |a| {
        if (std.mem.eql(u8, a, "--stdout")) {
            mode = .stdout;
        } else if (std.mem.eql(u8, a, "--check")) {
            mode = .check;
        } else if (std.mem.eql(u8, a, "--lint")) {
            mode = .lint;
        } else if (std.mem.eql(u8, a, "--diagnostics")) {
            // Next arg is "json"; flag-style, mirroring `check`.
        } else if (std.mem.eql(u8, a, "json")) {
            json = true;
        } else if (std.mem.startsWith(u8, a, "--")) {
            // Tolerate (and ignore) flags this subcommand doesn't consume.
        } else if (path == null) {
            path = a;
        }
    }

    // No path: format stdin → stdout. Only meaningful in `--stdout` mode
    // (spec: "read from stdin when path is omitted"); the file-mutating
    // modes need a path to act on.
    if (path == null) {
        if (mode != .stdout) {
            var ebuf: [256]u8 = undefined;
            var ew = std.Io.File.stderr().writerStreaming(io, &ebuf);
            try ew.interface.writeAll("q64: fmt: no path given (use --stdout to format stdin)\n");
            try ew.interface.flush();
            std.process.exit(2);
        }
        var rbuf: [4096]u8 = undefined;
        var sr = std.Io.File.stdin().reader(io, &rbuf);
        const source = sr.interface.allocRemaining(gpa, .limited(16 * 1024 * 1024)) catch |err| {
            var ebuf: [256]u8 = undefined;
            var ew = std.Io.File.stderr().writerStreaming(io, &ebuf);
            try ew.interface.print("q64: fmt: cannot read stdin: {s}\n", .{@errorName(err)});
            try ew.interface.flush();
            std.process.exit(2);
        };
        defer gpa.free(source);

        const outcome = try fmt.format(gpa, source);
        defer outcome.deinit(gpa);
        switch (outcome) {
            .formatted => |text| {
                var obuf: [4096]u8 = undefined;
                var ow = std.Io.File.stdout().writerStreaming(io, &obuf);
                try ow.interface.writeAll(text);
                try ow.interface.flush();
            },
            .unparseable => {
                try emitFmtUnparseable(gpa, io, "<stdin>", source, json);
                std.process.exit(1);
            },
        }
        return;
    }

    const p = path.?;
    const st = std.Io.Dir.cwd().statFile(io, p, .{}) catch |err| {
        var ebuf: [512]u8 = undefined;
        var ew = std.Io.File.stderr().writerStreaming(io, &ebuf);
        try ew.interface.print("q64: fmt: cannot read {s}: {s}\n", .{ p, @errorName(err) });
        try ew.interface.flush();
        std.process.exit(2);
    };

    if (st.kind == .directory) {
        if (mode == .stdout) {
            var ebuf: [256]u8 = undefined;
            var ew = std.Io.File.stderr().writerStreaming(io, &ebuf);
            try ew.interface.writeAll("q64: fmt: --stdout takes a single file or stdin, not a directory\n");
            try ew.interface.flush();
            std.process.exit(2);
        }
        var acc: FmtAcc = .{};
        try fmtDir(gpa, io, p, mode, json, &acc);
        fmtFinish(mode, acc);
        return;
    }

    var acc: FmtAcc = .{};
    try fmtOneFile(gpa, io, p, mode, json, &acc);
    fmtFinish(mode, acc);
}

/// Running tally across one `fmt` invocation.
const FmtAcc = struct {
    /// Files that would change (or did, in write mode).
    changed: usize = 0,
    /// Files that could not be parsed (reported as FMT001).
    unparseable: usize = 0,
};

/// Exit-code policy, applied once after all files are processed.
fn fmtFinish(mode: FmtMode, acc: FmtAcc) void {
    if (acc.unparseable > 0) std.process.exit(1);
    // `--check` signals "would reformat" with the conventional 64.
    if (mode == .check and acc.changed > 0) std.process.exit(64);
}

/// Recursively format every `.q` file under `dir`.
fn fmtDir(gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8, mode: FmtMode, json: bool, acc: *FmtAcc) !void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        var ebuf: [512]u8 = undefined;
        var ew = std.Io.File.stderr().writerStreaming(io, &ebuf);
        try ew.interface.print("q64: fmt: cannot open {s}: {s}\n", .{ dir_path, @errorName(err) });
        try ew.interface.flush();
        std.process.exit(2);
    };
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".q")) continue;
        const full = try std.fs.path.join(gpa, &.{ dir_path, entry.path });
        defer gpa.free(full);
        try fmtOneFile(gpa, io, full, mode, json, acc);
    }
}

/// Format a single file according to `mode`, updating `acc`.
fn fmtOneFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8, mode: FmtMode, json: bool, acc: *FmtAcc) !void {
    const source = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 * 1024 * 1024)) catch |err| {
        var ebuf: [512]u8 = undefined;
        var ew = std.Io.File.stderr().writerStreaming(io, &ebuf);
        try ew.interface.print("q64: fmt: cannot read {s}: {s}\n", .{ path, @errorName(err) });
        try ew.interface.flush();
        std.process.exit(2);
    };
    defer gpa.free(source);

    const outcome = try fmt.format(gpa, source);
    defer outcome.deinit(gpa);

    const text = switch (outcome) {
        .formatted => |t| t,
        .unparseable => {
            try emitFmtUnparseable(gpa, io, path, source, json);
            acc.unparseable += 1;
            return;
        },
    };

    const changed = !std.mem.eql(u8, text, source);
    if (changed) acc.changed += 1;

    switch (mode) {
        .stdout => {
            var obuf: [4096]u8 = undefined;
            var ow = std.Io.File.stdout().writerStreaming(io, &obuf);
            try ow.interface.writeAll(text);
            try ow.interface.flush();
        },
        .write => if (changed) {
            try atomicWrite(gpa, io, path, text);
            var obuf: [512]u8 = undefined;
            var ow = std.Io.File.stdout().writerStreaming(io, &obuf);
            try ow.interface.print("{s}\n", .{path});
            try ow.interface.flush();
        },
        .check => if (changed) {
            var ebuf: [512]u8 = undefined;
            var ew = std.Io.File.stderr().writerStreaming(io, &ebuf);
            try ew.interface.print("{s}: would reformat\n", .{path});
            try ew.interface.flush();
        },
        .lint => if (changed) {
            var ebuf: [512]u8 = undefined;
            var ew = std.Io.File.stderr().writerStreaming(io, &ebuf);
            try ew.interface.print("{s}:1:1: note: file is not formatted (run q64 fmt) [FMT002]\n", .{path});
            try ew.interface.flush();
        },
    }
}

/// Write `bytes` to `path` atomically: to a sibling temp file, then rename
/// over the target. A crash mid-write can't leave a truncated `.q` on disk
/// (fmt/README.md §"atomic write-on-success").
fn atomicWrite(gpa: std.mem.Allocator, io: std.Io, path: []const u8, bytes: []const u8) !void {
    const tmp = try std.fmt.allocPrint(gpa, "{s}.q64fmt.tmp", .{path});
    defer gpa.free(tmp);
    const cwd = std.Io.Dir.cwd();
    cwd.writeFile(io, .{ .sub_path = tmp, .data = bytes, .flags = .{ .truncate = true } }) catch |err| {
        var ebuf: [512]u8 = undefined;
        var ew = std.Io.File.stderr().writerStreaming(io, &ebuf);
        try ew.interface.print("q64: fmt: cannot write {s}: {s}\n", .{ path, @errorName(err) });
        try ew.interface.flush();
        std.process.exit(2);
    };
    cwd.rename(tmp, cwd, path, io) catch |err| {
        cwd.deleteFile(io, tmp) catch {};
        var ebuf: [512]u8 = undefined;
        var ew = std.Io.File.stderr().writerStreaming(io, &ebuf);
        try ew.interface.print("q64: fmt: cannot replace {s}: {s}\n", .{ path, @errorName(err) });
        try ew.interface.flush();
        std.process.exit(2);
    };
}

/// Emit the FMT001 "cannot format: source has syntax errors" diagnostic,
/// in text or JSON per `--diagnostics`. The file is left untouched.
fn emitFmtUnparseable(gpa: std.mem.Allocator, io: std.Io, path: []const u8, source: []const u8, json: bool) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(io, &buf);
    const d: diag.Diagnostic = .{
        .code = "FMT001",
        .severity = .err,
        .message = diag.messageFor("FMT001"),
        .file = path,
        .offset = 0,
    };
    if (json) {
        try diag.emitJson(&w.interface, source, &.{d}, gpa);
    } else {
        try w.interface.print("{s}:1:1: error: {s} [FMT001]\n", .{ path, d.message });
    }
    try w.interface.flush();
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

/// A `--module name=file` mapping from a dependency's module path to its entry
/// **source file**. `qube` resolves the file from the dependency's manifest
/// `entry` (default `src/lib.q`) before invoking the compiler — so the manifest
/// is authoritative and the compiler never guesses a filename or reads
/// `qube.json5` (spec/q64-cli.md §"--module").
const ModuleArg = struct { name: []const u8, path: []const u8 };

fn cmdEmit(gpa: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, args_it: *std.process.Args.Iterator) !void {
    var src_path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    // Address space (spec/memory.md §"The platform"). Explicit per build; we
    // default to wasm64 to preserve existing behavior for string programs until
    // the wasm32 string ABI lands (Path B). `--addr wasm32` opts in to a genuine
    // 32-bit module (the WebKit/iPad baseline) for the integer/import subset.
    var addr: emit.AddressSpace = .wasm64;
    var want_component = false;
    // `--asyncify`: run Binaryen's asyncify pass over the emitted core so a host
    // can suspend/resume the wasm at a blocking host read (the live
    // `@channel_handler` loop parks at `env.channel_recv` between messages).
    var want_asyncify = false;
    // WIT rung 2: the world name + WIT package id for the synthesized `.wit`,
    // set by `qube build` from the manifest (`wit.world` / `wit.package`).
    // Null = derive from the source filename / `q64:<world>`.
    var world_name: ?[]const u8 = null;
    var wit_package: ?[]const u8 = null;
    var module_args: std.ArrayList(ModuleArg) = .empty;
    defer module_args.deinit(gpa);
    // WIT rung 5: foreign `.wit` packages this qube imports — declared in the
    // emitted component's world (what `wac` links at build). Repeatable.
    var wit_import_paths: std.ArrayList([]const u8) = .empty;
    defer wit_import_paths.deinit(gpa);
    // Export this library's surface as a named WIT interface `<pkg>/<iface>`
    // (so a q64 consumer that imports it can be `wac`-linked); null = bare funcs.
    var export_interface: ?[]const u8 = null;

    while (args_it.next()) |a| {
        if (std.mem.eql(u8, a, "--component")) {
            // Also wrap the core module in a component (spec/q64-cli.md). The
            // core module is still written to `out`.
            want_component = true;
        } else if (std.mem.eql(u8, a, "--asyncify")) {
            want_asyncify = true;
        } else if (std.mem.eql(u8, a, "--export-interface")) {
            export_interface = args_it.next() orelse {
                try usage(io);
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, a, "--wit-import")) {
            try wit_import_paths.append(gpa, args_it.next() orelse {
                try usage(io);
                std.process.exit(2);
            });
        } else if (std.mem.eql(u8, a, "--world")) {
            world_name = args_it.next() orelse {
                try usage(io);
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, a, "--wit-package")) {
            wit_package = args_it.next() orelse {
                try usage(io);
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, a, "--addr")) {
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
                var w = std.Io.File.stderr().writerStreaming(io, &buf);
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
                var w = std.Io.File.stderr().writerStreaming(io, &buf);
                try w.interface.print("q64: --module expects name=file, got '{s}'\n", .{spec});
                try w.interface.flush();
                std.process.exit(2);
            };
            try module_args.append(gpa, .{ .name = spec[0..eq], .path = spec[eq + 1 ..] });
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
        var w = std.Io.File.stderr().writerStreaming(io, &buf);
        try w.interface.print("q64: cannot read {s}: {s}\n", .{ src, @errorName(err) });
        try w.interface.flush();
        std.process.exit(2);
    };
    defer gpa.free(source);

    // Gate codegen on parse-time errors. Codegen builds the HIR from the CST
    // and silently ignores anything the parser flagged — so a malformed
    // statement (e.g. two statements on one line with no `;`, PAR050) would be
    // dropped and an *incorrect* wasm emitted. Refuse to emit when the parser
    // reported an error, rendering each one with its location (same format as
    // `q64 check`), so the failure is legible instead of a silent miscompile.
    {
        const pre = try parse.parse(gpa, source, src);
        defer pre.deinit(gpa);
        var had_error = false;
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stderr().writerStreaming(io, &buf);
        for (pre.diagnostics) |d| if (d.severity == .err) {
            had_error = true;
            const idx = try diag.LineIndex.build(gpa, source);
            defer idx.deinit();
            const loc = idx.locate(d.offset);
            try w.interface.print("{s}:{d}:{d}: {s}: {s} [{s}]\n", .{
                d.file, loc.line, loc.col, d.severity.toString(), d.message, d.code,
            });
        };
        if (had_error) {
            try w.interface.flush();
            std.process.exit(1);
        }
    }

    // Read each dependency module's entry file (`<dir>/lib.q`); freed below.
    var module_sources = try readModuleSources(gpa, io, module_args.items);
    defer {
        for (module_sources.items) |m| gpa.free(m.source);
        module_sources.deinit(gpa);
    }

    // Foreign WIT imports (`--wit-import <file.wit>`, WIT rung 5). Parsed once
    // here and shared by the core emit (so a `<iface>.<fn>(…)` call lowers to a
    // real core import) and the `--component` wrap below. The arena holds the
    // parsed WIT + import model for the whole emit.
    var wit_arena = std.heap.ArenaAllocator.init(gpa);
    defer wit_arena.deinit();
    const foreign = buildForeignImports(wit_arena.allocator(), io, wit_import_paths.items) catch |err| {
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stderr().writerStreaming(io, &buf);
        try w.interface.print("q64: --wit-import failed: {s}\n", .{@errorName(err)});
        try w.interface.flush();
        std.process.exit(1);
    };

    const bytes = emit.emitFromSourceWithImports(gpa, source, src, module_sources.items, addr, foreign) catch |err| {
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stderr().writerStreaming(io, &buf);
        try w.interface.print("q64: emit failed: {s}\n", .{@errorName(err)});
        try w.interface.flush();
        std.process.exit(1);
    };
    defer gpa.free(bytes);

    // --asyncify: post-process the core so a host can park/resume it at the
    // blocking remote-channel reads (the `@channel_handler` live loop). Only
    // `env.channel_recv` / `env.presses` (the awaiting host reads) may unwind.
    const out_bytes = if (want_asyncify) blk: {
        const a = emit.asyncifyWasm(gpa, bytes, "env.channel_recv,env.presses", addr) catch |err| {
            var buf: [4096]u8 = undefined;
            var w = std.Io.File.stderr().writerStreaming(io, &buf);
            try w.interface.print("q64: asyncify failed: {s}\n", .{@errorName(err)});
            try w.interface.flush();
            std.process.exit(1);
        };
        break :blk a;
    } else bytes;
    defer if (want_asyncify) gpa.free(out_bytes);

    try writeFile(io, out, out_bytes);

    // --component: additionally wrap the core module in a WebAssembly component,
    // written to `<out without .wasm>.component.wasm` (spec/q64-cli.md). A
    // library lift is a finished component; an app is a WASI preview1 core that
    // we run through `wasm-tools component new --adapt` (vendor/wasi/) to get a
    // real `wasi:cli/run` command importing `wasi:cli/stdout`.
    if (want_component) {
        const artifact = emit.emitComponent(gpa, source, src, module_sources.items, addr, foreign, export_interface) catch |err| {
            var buf: [4096]u8 = undefined;
            var w = std.Io.File.stderr().writerStreaming(io, &buf);
            try w.interface.print("q64: component emit failed: {s}\n", .{@errorName(err)});
            try w.interface.flush();
            std.process.exit(1);
        };

        const base = if (std.mem.endsWith(u8, out, ".wasm")) out[0 .. out.len - ".wasm".len] else out;
        const comp_path = try std.fmt.allocPrint(gpa, "{s}.component.wasm", .{base});
        defer gpa.free(comp_path);

        switch (artifact) {
            .component => |comp_bytes| {
                defer gpa.free(comp_bytes);
                try writeFile(io, comp_path, comp_bytes);
            },
            .preview1_app => |core| {
                defer gpa.free(core);
                try adaptPreview1Component(gpa, io, env, core, comp_path);
            },
            .interface_lib => |lib| {
                defer gpa.free(lib.core);
                defer gpa.free(lib.world);
                try embedAndNewComponent(gpa, io, env, lib.core, lib.world, export_interface.?, comp_path);
            },
            .store_component => |kvc| {
                defer gpa.free(kvc.core);
                defer gpa.free(kvc.world);
                try embedStoreComponent(gpa, io, env, kvc.core, kvc.world, comp_path);
            },
        }

        // WIT rung 1: also write the synthesized world to `<base>.wit` next to
        // the component — the on-disk contract artifact the Continuum stores
        // and `wac`/`wasm-tools` consume. The component embeds its own type
        // (round-trips via `wasm-tools component wit`); this is its source-level
        // companion. Same synthesis as `q64 show world`.
        const wit_text = emit.showWorld(gpa, source, src, module_sources.items, world_name, wit_package, foreign) catch |err| {
            var buf: [4096]u8 = undefined;
            var w = std.Io.File.stderr().writerStreaming(io, &buf);
            try w.interface.print("q64: WIT emit failed: {s}\n", .{@errorName(err)});
            try w.interface.flush();
            std.process.exit(1);
        };
        defer gpa.free(wit_text);
        const wit_path = try std.fmt.allocPrint(gpa, "{s}.wit", .{base});
        defer gpa.free(wit_path);
        try writeFile(io, wit_path, wit_text);
    }
}

/// `q64 run <file.q> [-- args…]` (spec/q64-cli.md §"run"): compile the file to
/// a raw wasm core (the `env.*` host faces) and execute it on the q64 runtime
/// host, propagating its exit code. The raw path is used (not the WASI
/// component) because it preserves the full `env.exit(N)` code and the host
/// satisfies every `env.*` face. The host binary is located via
/// `Q64_WASMTIME_HOST`, then the repo's `runtime/wasmtime/zig-out/bin/`, then
/// `PATH`. Anything after `--` becomes the program's `env.args`.
fn cmdRun(gpa: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, src: []const u8, args_it: *std.process.Args.Iterator) !void {
    // Collect the program's own args. q64 flags (`--quiet`, …) before a `--`
    // separator are tolerated and ignored in v0; everything after `--` (and any
    // bare token before it) is the program's `env.args`.
    var qube_args: std.ArrayList([]const u8) = .empty;
    defer qube_args.deinit(gpa);
    var saw_sep = false;
    while (args_it.next()) |a| {
        if (saw_sep) {
            try qube_args.append(gpa, a);
        } else if (std.mem.eql(u8, a, "--")) {
            saw_sep = true;
        } else if (std.mem.startsWith(u8, a, "--")) {
            // A q64-level flag — ignored in v0 (the flag surface lands later).
        } else {
            try qube_args.append(gpa, a);
        }
    }

    const source = std.Io.Dir.cwd().readFileAlloc(io, src, gpa, .limited(16 * 1024 * 1024)) catch |err| {
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stderr().writerStreaming(io, &buf);
        try w.interface.print("q64: cannot read {s}: {s}\n", .{ src, @errorName(err) });
        try w.interface.flush();
        // Input error (spec/q64-cli.md §"Exit codes": 65 = input).
        std.process.exit(65);
    };
    defer gpa.free(source);

    // Compile to a raw wasm32 core (the `env.*` host faces). wasm32 is the
    // broad-compatibility target; the host introspects the address width.
    const bytes = emit.emitFromSourceWithImports(gpa, source, src, &.{}, .wasm32, &.{}) catch |err| {
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stderr().writerStreaming(io, &buf);
        try w.interface.print("q64: compile failed: {s}\n", .{@errorName(err)});
        try w.interface.flush();
        std.process.exit(1);
    };
    defer gpa.free(bytes);

    // Write the core to a temp file the host can load, then clean it up.
    const tmp_dir = if (env.get("TMPDIR")) |t| t else "/tmp";
    const base = std.fs.path.basename(src);
    const tmp_wasm = try std.fmt.allocPrint(gpa, "{s}/q64-run-{s}.wasm", .{ tmp_dir, base });
    defer gpa.free(tmp_wasm);
    try writeFile(io, tmp_wasm, bytes);
    defer std.Io.Dir.cwd().deleteFile(io, tmp_wasm) catch {};

    const repo_root = findRepoRoot(gpa, io, ".") catch null;
    defer if (repo_root) |r| gpa.free(r);
    const host = try resolveBinary(gpa, io, env, "Q64_WASMTIME_HOST", repo_root, "runtime/wasmtime/zig-out/bin/q64-wasmtime-host", "q64-wasmtime-host");
    defer gpa.free(host);

    // Spawn the host by its absolute path: a relative `argv[0]` defeats the
    // host's `$ORIGIN` rpath for `libwasmtime.so` (it would fail to load). A
    // bare PATH name (no separator) is left for the OS to resolve via PATH.
    const host_abs = if (std.fs.path.isAbsolute(host) or std.mem.indexOfScalar(u8, host, std.fs.path.sep) == null)
        try gpa.dupe(u8, host)
    else blk: {
        const cwd = try std.process.currentPathAlloc(io, gpa);
        defer gpa.free(cwd);
        break :blk try std.fs.path.join(gpa, &.{ cwd, host });
    };
    defer gpa.free(host_abs);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, host_abs);
    try argv.append(gpa, tmp_wasm);
    if (qube_args.items.len > 0) {
        try argv.append(gpa, "--");
        for (qube_args.items) |a| try argv.append(gpa, a);
    }

    const term = spawnInherit(io, argv.items) catch |err| {
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stderr().writerStreaming(io, &buf);
        try w.interface.print("q64: could not run the host ({s}): {s}\n", .{ host_abs, @errorName(err) });
        try w.interface.print("q64: set Q64_WASMTIME_HOST, or build runtime/wasmtime (zig build)\n", .{});
        try w.interface.flush();
        std.process.exit(1);
    };
    // Propagate the qube's exit code (env.exit(N) → N; a trap/panic → 1).
    std.process.exit(termCode(term) orelse 1);
}

/// Lift a WASI **preview1 core module** into a real component by shelling out to
/// `wasm-tools component new --adapt` with the vendored WASI adapter
/// (`vendor/wasi/`). The result — a `wasi:cli/run` command importing
/// `wasi:cli/stdout` — is written to `comp_path`. `wasm-tools` and the adapter
/// are located via env override (`Q64_WASM_TOOLS` / `Q64_WASI_ADAPTER`), then
/// the repo's `vendor/`, then `PATH`.
fn adaptPreview1Component(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    core: []const u8,
    comp_path: []const u8,
) !void {
    const repo_root = findRepoRoot(gpa, io, ".") catch null;
    defer if (repo_root) |r| gpa.free(r);

    const wasm_tools = try resolveBinary(gpa, io, env, "Q64_WASM_TOOLS", repo_root, "vendor/wasm-tools/wasm-tools", "wasm-tools");
    defer gpa.free(wasm_tools);
    const adapter = try resolveBinary(gpa, io, env, "Q64_WASI_ADAPTER", repo_root, "vendor/wasi/wasi_snapshot_preview1.command.wasm", "wasi_snapshot_preview1.command.wasm");
    defer gpa.free(adapter);

    // Write the preview1 core next to the component output, run the adapter,
    // then remove the scratch core (best-effort).
    const tmp_core = try std.fmt.allocPrint(gpa, "{s}.p1core.wasm", .{comp_path});
    defer gpa.free(tmp_core);
    try writeFile(io, tmp_core, core);
    defer std.Io.Dir.cwd().deleteFile(io, tmp_core) catch {};

    const adapt_arg = try std.fmt.allocPrint(gpa, "wasi_snapshot_preview1={s}", .{adapter});
    defer gpa.free(adapt_arg);

    const argv = [_][]const u8{ wasm_tools, "component", "new", tmp_core, "--adapt", adapt_arg, "-o", comp_path };
    const term = spawnInherit(io, &argv) catch |err| {
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stderr().writerStreaming(io, &buf);
        try w.interface.print("q64: could not run wasm-tools ({s}): {s}\n", .{ wasm_tools, @errorName(err) });
        try w.interface.print("q64: set Q64_WASM_TOOLS / Q64_WASI_ADAPTER, or run ./init.sh to vendor the WASI toolchain\n", .{});
        try w.interface.flush();
        std.process.exit(1);
    };
    if (termCode(term) != @as(u8, 0)) {
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stderr().writerStreaming(io, &buf);
        try w.interface.print("q64: wasm-tools component new failed (the WASI adapter could not lift the preview1 core)\n", .{});
        try w.interface.flush();
        std.process.exit(1);
    }
}

/// Lift an **interface-export** library core into a component that exports the
/// named WIT interface: write the core + the synthesized `world.wit` to temp
/// files, run `wasm-tools component embed <world.wit> <core> --world <iface>`
/// then `wasm-tools component new` → the component at `comp_path`. `iface_id` is
/// `<pkg>/<iface>`; the embed world is named after the interface. So a q64
/// consumer that imports `<pkg>/<iface>` can be `wac`-linked against this.
fn embedAndNewComponent(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    core: []const u8,
    world_wit: []const u8,
    iface_id: []const u8,
    comp_path: []const u8,
) !void {
    const repo_root = findRepoRoot(gpa, io, ".") catch null;
    defer if (repo_root) |r| gpa.free(r);
    const wasm_tools = try resolveBinary(gpa, io, env, "Q64_WASM_TOOLS", repo_root, "vendor/wasm-tools/wasm-tools", "wasm-tools");
    defer gpa.free(wasm_tools);

    const slash = std.mem.indexOfScalar(u8, iface_id, '/') orelse iface_id.len;
    const iface_name = if (slash < iface_id.len) iface_id[slash + 1 ..] else iface_id;
    // Matches `synthInterfaceWorld`: the world is named `<iface>-world` (it
    // can't share the interface's name within the package).
    const world_name = try std.fmt.allocPrint(gpa, "{s}-world", .{iface_name});
    defer gpa.free(world_name);

    const tmp_core = try std.fmt.allocPrint(gpa, "{s}.ifcore.wasm", .{comp_path});
    defer gpa.free(tmp_core);
    const tmp_wit = try std.fmt.allocPrint(gpa, "{s}.iface.wit", .{comp_path});
    defer gpa.free(tmp_wit);
    const tmp_embed = try std.fmt.allocPrint(gpa, "{s}.embed.wasm", .{comp_path});
    defer gpa.free(tmp_embed);
    try writeFile(io, tmp_core, core);
    try writeFile(io, tmp_wit, world_wit);
    defer std.Io.Dir.cwd().deleteFile(io, tmp_core) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, tmp_wit) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, tmp_embed) catch {};

    const fail = struct {
        fn f(io2: std.Io, comptime msg: []const u8) noreturn {
            var buf: [4096]u8 = undefined;
            var w = std.Io.File.stderr().writerStreaming(io2, &buf);
            w.interface.print("q64: {s}\n", .{msg}) catch {};
            w.interface.print("q64: set Q64_WASM_TOOLS or run ./init.sh to vendor wasm-tools\n", .{}) catch {};
            w.interface.flush() catch {};
            std.process.exit(1);
        }
    }.f;

    // 1. embed the component type into the core.
    {
        const argv = [_][]const u8{ wasm_tools, "component", "embed", tmp_wit, tmp_core, "--world", world_name, "-o", tmp_embed };
        const term = spawnInherit(io, &argv) catch fail(io, "could not run wasm-tools component embed");
        if (termCode(term) != @as(u8, 0)) fail(io, "wasm-tools component embed failed (interface export)");
    }
    // 2. lift the embedded core into a component exporting the interface.
    {
        const argv = [_][]const u8{ wasm_tools, "component", "new", tmp_embed, "-o", comp_path };
        const term = spawnInherit(io, &argv) catch fail(io, "could not run wasm-tools component new");
        if (termCode(term) != @as(u8, 0)) fail(io, "wasm-tools component new failed (interface export)");
    }
}

/// Lift a **kv** core (one that reaches `env.kv`, with canonical
/// `cm32p2|wasi:keyvalue/…` imports) into a component. Lay out a WIT dir with the
/// synthesized world + the vendored `wasi:keyvalue` dep package, then
/// `wasm-tools component embed <dir> --world qube <core>` + `component new`. The
/// result imports `wasi:keyvalue/{store,atomics}` for the host to supply.
fn embedStoreComponent(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    core: []const u8,
    world_wit: []const u8,
    comp_path: []const u8,
) !void {
    const repo_root = findRepoRoot(gpa, io, ".") catch null;
    defer if (repo_root) |r| gpa.free(r);
    const wasm_tools = try resolveBinary(gpa, io, env, "Q64_WASM_TOOLS", repo_root, "vendor/wasm-tools/wasm-tools", "wasm-tools");
    defer gpa.free(wasm_tools);

    const fail = struct {
        fn f(io2: std.Io, comptime msg: []const u8) noreturn {
            var buf: [4096]u8 = undefined;
            var w = std.Io.File.stderr().writerStreaming(io2, &buf);
            w.interface.print("q64: {s}\n", .{msg}) catch {};
            w.interface.print("q64: set Q64_WASM_TOOLS or run ./init.sh to vendor wasm-tools\n", .{}) catch {};
            w.interface.flush() catch {};
            std.process.exit(1);
        }
    }.f;

    // WIT dir: <comp>.kvwit/world.wit + a deps/ package per storage capability.
    // Both store deps (wasi-keyvalue + q64-blob) are written unconditionally;
    // wasm-tools resolves only the packages the synthesized world imports, so an
    // unused dep is harmless. This one path serves kv-only, blob-only, and mixed
    // qubes.
    const wit_dir = try std.fmt.allocPrint(gpa, "{s}.kvwit", .{comp_path});
    defer gpa.free(wit_dir);
    const kv_deps_dir = try std.fmt.allocPrint(gpa, "{s}/deps/wasi-keyvalue", .{wit_dir});
    defer gpa.free(kv_deps_dir);
    const blob_deps_dir = try std.fmt.allocPrint(gpa, "{s}/deps/q64-blob", .{wit_dir});
    defer gpa.free(blob_deps_dir);
    const db_deps_dir = try std.fmt.allocPrint(gpa, "{s}/deps/q64-db", .{wit_dir});
    defer gpa.free(db_deps_dir);
    const config_deps_dir = try std.fmt.allocPrint(gpa, "{s}/deps/wasi-config", .{wit_dir});
    defer gpa.free(config_deps_dir);
    const clocks_deps_dir = try std.fmt.allocPrint(gpa, "{s}/deps/wasi-clocks", .{wit_dir});
    defer gpa.free(clocks_deps_dir);
    const io_deps_dir = try std.fmt.allocPrint(gpa, "{s}/deps/wasi-io", .{wit_dir});
    defer gpa.free(io_deps_dir);
    const clocks_p3_deps_dir = try std.fmt.allocPrint(gpa, "{s}/deps/wasi-clocks-p3", .{wit_dir});
    defer gpa.free(clocks_p3_deps_dir);
    std.Io.Dir.cwd().createDirPath(io, kv_deps_dir) catch fail(io, "could not create temp WIT dir for the store lift");
    std.Io.Dir.cwd().createDirPath(io, blob_deps_dir) catch fail(io, "could not create temp WIT dir for the store lift");
    std.Io.Dir.cwd().createDirPath(io, db_deps_dir) catch fail(io, "could not create temp WIT dir for the store lift");
    std.Io.Dir.cwd().createDirPath(io, config_deps_dir) catch fail(io, "could not create temp WIT dir for the store lift");
    std.Io.Dir.cwd().createDirPath(io, clocks_deps_dir) catch fail(io, "could not create temp WIT dir for the store lift");
    std.Io.Dir.cwd().createDirPath(io, io_deps_dir) catch fail(io, "could not create temp WIT dir for the store lift");
    std.Io.Dir.cwd().createDirPath(io, clocks_p3_deps_dir) catch fail(io, "could not create temp WIT dir for the store lift");
    defer std.Io.Dir.cwd().deleteTree(io, wit_dir) catch {};
    const world_path = try std.fmt.allocPrint(gpa, "{s}/world.wit", .{wit_dir});
    defer gpa.free(world_path);
    const kv_dep_path = try std.fmt.allocPrint(gpa, "{s}/keyvalue.wit", .{kv_deps_dir});
    defer gpa.free(kv_dep_path);
    const blob_dep_path = try std.fmt.allocPrint(gpa, "{s}/blob.wit", .{blob_deps_dir});
    defer gpa.free(blob_dep_path);
    const db_dep_path = try std.fmt.allocPrint(gpa, "{s}/db.wit", .{db_deps_dir});
    defer gpa.free(db_dep_path);
    const config_dep_path = try std.fmt.allocPrint(gpa, "{s}/config.wit", .{config_deps_dir});
    defer gpa.free(config_dep_path);
    const clocks_dep_path = try std.fmt.allocPrint(gpa, "{s}/clocks.wit", .{clocks_deps_dir});
    defer gpa.free(clocks_dep_path);
    const io_dep_path = try std.fmt.allocPrint(gpa, "{s}/poll.wit", .{io_deps_dir});
    defer gpa.free(io_dep_path);
    const clocks_p3_dep_path = try std.fmt.allocPrint(gpa, "{s}/clocks.wit", .{clocks_p3_deps_dir});
    defer gpa.free(clocks_p3_dep_path);
    try writeFile(io, world_path, world_wit);
    try writeFile(io, kv_dep_path, emit.wasi_keyvalue_wit);
    try writeFile(io, blob_dep_path, emit.q64_blob_wit);
    try writeFile(io, db_dep_path, emit.q64_db_wit);
    try writeFile(io, config_dep_path, emit.wasi_config_wit);
    try writeFile(io, clocks_dep_path, emit.wasi_clocks_wit);
    try writeFile(io, io_dep_path, emit.wasi_io_wit);
    try writeFile(io, clocks_p3_dep_path, emit.wasi_clocks_p3_wit);

    const tmp_core = try std.fmt.allocPrint(gpa, "{s}.kvcore.wasm", .{comp_path});
    defer gpa.free(tmp_core);
    const tmp_embed = try std.fmt.allocPrint(gpa, "{s}.kvembed.wasm", .{comp_path});
    defer gpa.free(tmp_embed);
    try writeFile(io, tmp_core, core);
    defer std.Io.Dir.cwd().deleteFile(io, tmp_core) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, tmp_embed) catch {};

    // 1. embed the component type (world + wasi:keyvalue dep) into the core.
    {
        const argv = [_][]const u8{ wasm_tools, "component", "embed", wit_dir, "--world", "qube", tmp_core, "-o", tmp_embed };
        const term = spawnInherit(io, &argv) catch fail(io, "could not run wasm-tools component embed");
        if (termCode(term) != @as(u8, 0)) fail(io, "wasm-tools component embed failed (env.kv lift)");
    }
    // 2. lift the embedded core into a component importing wasi:keyvalue.
    {
        const argv = [_][]const u8{ wasm_tools, "component", "new", tmp_embed, "-o", comp_path };
        const term = spawnInherit(io, &argv) catch fail(io, "could not run wasm-tools component new");
        if (termCode(term) != @as(u8, 0)) fail(io, "wasm-tools component new failed (env.kv lift)");
    }
}

fn spawnInherit(io: std.Io, argv: []const []const u8) !std.process.Child.Term {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    return child.wait(io);
}

fn termCode(term: std.process.Child.Term) ?u8 {
    return switch (term) {
        .exited => |code| code,
        else => null,
    };
}

/// Walk up from `file_path`'s directory looking for `qube.json5`; return the
/// owned absolute directory of the nearest one (the qube root), or null when no
/// manifest is found (a loose file checked outside any qube).
fn findQubeRoot(gpa: std.mem.Allocator, io: std.Io, file_path: []const u8) !?[]u8 {
    const dir = std.fs.path.dirname(file_path) orelse ".";
    const abs = if (std.fs.path.isAbsolute(dir))
        try gpa.dupe(u8, dir)
    else blk: {
        const cwd = try std.process.currentPathAlloc(io, gpa);
        defer gpa.free(cwd);
        break :blk try std.fs.path.join(gpa, &.{ cwd, dir });
    };
    defer gpa.free(abs);

    var cur: []const u8 = abs;
    while (true) {
        const candidate = try std.fs.path.join(gpa, &.{ cur, "qube.json5" });
        defer gpa.free(candidate);
        const ok = blk: {
            std.Io.Dir.cwd().access(io, candidate, .{}) catch break :blk false;
            break :blk true;
        };
        if (ok) return try gpa.dupe(u8, cur);
        const parent = std.fs.path.dirname(cur) orelse return null;
        if (std.mem.eql(u8, parent, cur)) return null;
        cur = parent;
    }
}

/// True when `child` is `parent` or lies beneath it (path-prefix with a `/`
/// boundary), both assumed normalized + absolute.
fn isPathUnder(child: []const u8, parent: []const u8) bool {
    if (!std.mem.startsWith(u8, child, parent)) return false;
    return child.len == parent.len or child[parent.len] == std.fs.path.sep;
}

/// NAM002 test: does a quoted-relative `import_str` (resolved against the
/// importing file's directory) escape the qube? The boundary is the qube root
/// when a `qube.json5` was found; otherwise the file's own directory (a loose
/// file is treated as its own root, so any `../` that climbs out is flagged).
fn importEscapesQube(
    gpa: std.mem.Allocator,
    io: std.Io,
    file_path: []const u8,
    import_str: []const u8,
    qube_root: ?[]const u8,
) !bool {
    const dir = std.fs.path.dirname(file_path) orelse ".";
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const file_abs = if (std.fs.path.isAbsolute(dir))
        try gpa.dupe(u8, dir)
    else
        try std.fs.path.join(gpa, &.{ cwd, dir });
    defer gpa.free(file_abs);

    const resolved = try std.fs.path.resolve(gpa, &.{ file_abs, import_str });
    defer gpa.free(resolved);

    const root_norm = try std.fs.path.resolve(gpa, &.{qube_root orelse file_abs});
    defer gpa.free(root_norm);

    return !isPathUnder(resolved, root_norm);
}

/// Walk up from `start` to the repo root — the directory holding `vendor/zig`.
/// Used to locate the vendored `wasm-tools` + WASI adapter when no env override
/// is set. Returns null if no such ancestor exists.
fn findRepoRoot(gpa: std.mem.Allocator, io: std.Io, start: []const u8) !?[]u8 {
    const abs = if (std.fs.path.isAbsolute(start))
        try gpa.dupe(u8, start)
    else blk: {
        const cwd = try std.process.currentPathAlloc(io, gpa);
        defer gpa.free(cwd);
        break :blk try std.fs.path.join(gpa, &.{ cwd, start });
    };
    defer gpa.free(abs);

    var cur: []const u8 = abs;
    while (true) {
        const candidate = try std.fs.path.join(gpa, &.{ cur, "vendor", "zig" });
        defer gpa.free(candidate);
        const ok = blk: {
            std.Io.Dir.cwd().access(io, candidate, .{}) catch break :blk false;
            break :blk true;
        };
        if (ok) return try gpa.dupe(u8, cur);

        const parent = std.fs.path.dirname(cur) orelse return null;
        if (std.mem.eql(u8, parent, cur)) return null;
        cur = parent;
    }
}

/// Resolve a vendored tool: an explicit `env_key` override wins; otherwise try
/// `<repo_root>/<repo_rel>`; otherwise fall back to `path_name` for the OS to
/// resolve via `PATH` at spawn time.
fn resolveBinary(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    env_key: []const u8,
    repo_root: ?[]const u8,
    repo_rel: []const u8,
    path_name: []const u8,
) ![]u8 {
    if (env.get(env_key)) |v| {
        if (v.len > 0) return try gpa.dupe(u8, v);
    }
    if (repo_root) |root| {
        const candidate = try std.fs.path.join(gpa, &.{ root, repo_rel });
        const ok = blk: {
            std.Io.Dir.cwd().access(io, candidate, .{}) catch break :blk false;
            break :blk true;
        };
        if (ok) return candidate;
        gpa.free(candidate);
    }
    return try gpa.dupe(u8, path_name);
}

fn writeFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = bytes,
        .flags = .{ .truncate = true },
    }) catch |err| {
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stderr().writerStreaming(io, &buf);
        try w.interface.print("q64: cannot write {s}: {s}\n", .{ path, @errorName(err) });
        try w.interface.flush();
        std.process.exit(2);
    };
}

/// Read each dependency module's entry **file** (`ma.path`, resolved by `qube`
/// from the dependency's manifest `entry`) into a list of `ModuleSource`s for
/// the compiler. The compiler does not guess the filename or read `qube.json5` —
/// `qube` already resolved it. A read failure is a usage-level error (exit 2).
/// Shared by `emit` and `show`.
fn readModuleSources(gpa: std.mem.Allocator, io: std.Io, module_args: []const ModuleArg) !std.ArrayList(emit.ModuleSource) {
    var out: std.ArrayList(emit.ModuleSource) = .empty;
    errdefer {
        for (out.items) |m| gpa.free(m.source);
        out.deinit(gpa);
    }
    for (module_args) |ma| {
        const lib_src = std.Io.Dir.cwd().readFileAlloc(io, ma.path, gpa, .limited(16 * 1024 * 1024)) catch |err| {
            var buf: [4096]u8 = undefined;
            var w = std.Io.File.stderr().writerStreaming(io, &buf);
            try w.interface.print("q64: cannot read module {s} entry {s}: {s}\n", .{ ma.name, ma.path, @errorName(err) });
            try w.interface.flush();
            std.process.exit(2);
        };
        try out.append(gpa, .{ .name = ma.name, .source = lib_src });
    }
    return out;
}

/// `q64 show <hir|mir> <file.q> [--module name=file ...]` — dump the Q64 IR
/// (HIR or MIR) for a source file to stdout (spec/q64-cli.md §"show"). The
/// front matter (parse + import resolution) is shared with `emit`, so `show`
/// surfaces the same honest diagnostics on a malformed program.
fn cmdShow(gpa: std.mem.Allocator, io: std.Io, args_it: *std.process.Args.Iterator) !void {
    var kind: ?[]const u8 = null;
    // The second positional: a source file for `hir`/`mir`, or a subject (a
    // function name) for `effects`. The qube-level kinds take `--qube` instead.
    var arg2: ?[]const u8 = null;
    var qube_file: ?[]const u8 = null;
    // `--out <file>` redirects the dump to a file instead of stdout (spec
    // §"show"); the on-disk WIT companion to `q64 show world` (WIT rung 1).
    var out_path: ?[]const u8 = null;
    // `--world` / `--wit-package` (WIT rung 2) name the world / WIT package for
    // `show world`; null = derive from the filename / `q64:<world>`.
    var world_name: ?[]const u8 = null;
    var wit_package: ?[]const u8 = null;
    var module_args: std.ArrayList(ModuleArg) = .empty;
    defer module_args.deinit(gpa);
    // `--wit-import <file.wit>` (WIT rung 5): foreign interfaces the qube links
    // against. `show world` lists them as `import`s; `show hir|mir` resolve
    // `<iface>.<fn>(…)` calls against them.
    var wit_import_paths: std.ArrayList([]const u8) = .empty;
    defer wit_import_paths.deinit(gpa);

    while (args_it.next()) |a| {
        if (std.mem.eql(u8, a, "--module")) {
            const spec = args_it.next() orelse {
                try usage(io);
                std.process.exit(2);
            };
            const eq = std.mem.indexOfScalar(u8, spec, '=') orelse {
                var buf: [4096]u8 = undefined;
                var w = std.Io.File.stderr().writerStreaming(io, &buf);
                try w.interface.print("q64: --module expects name=file, got '{s}'\n", .{spec});
                try w.interface.flush();
                std.process.exit(2);
            };
            try module_args.append(gpa, .{ .name = spec[0..eq], .path = spec[eq + 1 ..] });
        } else if (std.mem.eql(u8, a, "--wit-import")) {
            try wit_import_paths.append(gpa, args_it.next() orelse {
                try usage(io);
                std.process.exit(2);
            });
        } else if (std.mem.eql(u8, a, "--qube")) {
            qube_file = args_it.next() orelse {
                try usage(io);
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, a, "--out")) {
            out_path = args_it.next() orelse {
                try usage(io);
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, a, "--world")) {
            world_name = args_it.next() orelse {
                try usage(io);
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, a, "--wit-package")) {
            wit_package = args_it.next() orelse {
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
    const Kind = enum { hir, mir, symbols, effects, capabilities, world };
    const which: Kind = if (std.mem.eql(u8, k, "hir"))
        .hir
    else if (std.mem.eql(u8, k, "mir"))
        .mir
    else if (std.mem.eql(u8, k, "symbols"))
        .symbols
    else if (std.mem.eql(u8, k, "effects"))
        .effects
    else if (std.mem.eql(u8, k, "capabilities"))
        .capabilities
    else if (std.mem.eql(u8, k, "world"))
        .world
    else {
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stderr().writerStreaming(io, &buf);
        try w.interface.print("q64: show: unknown kind '{s}'\n", .{k});
        try w.interface.flush();
        std.process.exit(2);
    };

    // `hir`/`mir`/`symbols` take the source file as the second positional; the
    // effect / component kinds take `--qube <file>` (and `effects` a `<fn>`
    // positional).
    const ir_kind = which == .hir or which == .mir or which == .symbols;
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
        var w = std.Io.File.stderr().writerStreaming(io, &buf);
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

    var wit_arena = std.heap.ArenaAllocator.init(gpa);
    defer wit_arena.deinit();
    const foreign = buildForeignImports(wit_arena.allocator(), io, wit_import_paths.items) catch |err| {
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stderr().writerStreaming(io, &buf);
        try w.interface.print("q64: --wit-import failed: {s}\n", .{@errorName(err)});
        try w.interface.flush();
        std.process.exit(1);
    };

    const dump = (switch (which) {
        .hir => emit.showHir(gpa, source, src, module_sources.items, foreign),
        .mir => emit.showMir(gpa, source, src, module_sources.items, foreign),
        .symbols => sema.showSymbols(gpa, source, src),
        .effects => emit.showEffects(gpa, source, src, module_sources.items, arg2.?),
        .capabilities => emit.showCapabilities(gpa, source, src, module_sources.items),
        .world => emit.showWorld(gpa, source, src, module_sources.items, world_name, wit_package, foreign),
    }) catch |err| {
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stderr().writerStreaming(io, &buf);
        try w.interface.print("q64: show {s} failed: {s}\n", .{ k, @errorName(err) });
        try w.interface.flush();
        std.process.exit(1);
    };
    defer gpa.free(dump);

    // `--out <file>` writes the dump to disk (e.g. `show world --out app.wit`);
    // otherwise it goes to stdout.
    if (out_path) |op| {
        try writeFile(io, op, dump);
        return;
    }

    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(io, &buf);
    try w.interface.writeAll(dump);
    try w.interface.flush();
}

/// Map a WIT primitive to the canonical-ABI scalar the component encoder
/// handles (`s64`/`bool`/`f64`), or null for a type that needs memory glue —
/// mirrors the export slice's scalar-only scope.
fn witPrimToScalar(p: wit.Prim) ?emit.Scalar {
    return switch (p) {
        .s64 => .s64,
        .bool_ => .bool_,
        .f64 => .f64,
        else => null,
    };
}

/// Build the component-import model from each `--wit-import <file.wit>` (WIT
/// rung 5). Each foreign interface becomes an `ImportIface`; only its
/// **scalar-signature** functions are declared (a non-scalar param/result is
/// skipped — the same boundary as scalar exports). Everything is arena-owned.
fn buildForeignImports(arena: std.mem.Allocator, io: std.Io, paths: []const []const u8) ![]const emit.ImportIface {
    var ifaces: std.ArrayList(emit.ImportIface) = .empty;
    for (paths) |path| {
        const src = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 * 1024 * 1024));
        var p: wit.Parser = undefined;
        const document = wit.parse(arena, src, &p) catch |err| switch (err) {
            wit.Error.ParseError => {
                var buf: [4096]u8 = undefined;
                var w = std.Io.File.stderr().writerStreaming(io, &buf);
                try w.interface.print("q64: WIT001: {s}: {s} (byte {d})\n", .{ path, p.err_msg, p.err_pos });
                try w.interface.flush();
                return error.ParseError;
            },
            else => return err,
        };

        // The component-model interface id: `<package-base>/<iface>[@version]`.
        var base: []const u8 = "root:imports";
        var version: ?[]const u8 = null;
        if (document.package_id) |pid| {
            if (std.mem.indexOfScalar(u8, pid, '@')) |at| {
                base = pid[0..at];
                version = pid[at + 1 ..];
            } else base = pid;
        }

        for (document.interfaces) |iface| {
            var funcs: std.ArrayList(emit.ImportFunc) = .empty;
            for (iface.funcs) |f| {
                var ok = true;
                const params = try arena.alloc(emit.Scalar, f.params.len);
                const names = try arena.alloc([]const u8, f.params.len);
                for (f.params, 0..) |param, i| {
                    const sc = if (param.ty.* == .prim) witPrimToScalar(param.ty.*.prim) else null;
                    params[i] = sc orelse {
                        ok = false;
                        break;
                    };
                    names[i] = param.name;
                }
                if (!ok) continue; // non-scalar param — skip this func
                const ret: ?emit.Scalar = if (f.result) |r|
                    (if (r.* == .prim) (witPrimToScalar(r.*.prim) orelse {
                        continue; // non-scalar result — skip
                    }) else continue)
                else
                    null;
                try funcs.append(arena, .{ .name = f.name, .params = params, .param_names = names, .ret = ret });
            }
            if (funcs.items.len == 0) continue; // no liftable scalar funcs
            const wit_name = if (version) |v|
                try std.fmt.allocPrint(arena, "{s}/{s}@{s}", .{ base, iface.name, v })
            else
                try std.fmt.allocPrint(arena, "{s}/{s}", .{ base, iface.name });
            try ifaces.append(arena, .{ .wit_name = wit_name, .funcs = try funcs.toOwnedSlice(arena) });
        }
    }
    return ifaces.toOwnedSlice(arena);
}

/// `q64 wit import <file.wit> [--out <f>]` — parse a foreign/authored WIT
/// package and print its q64 **binding preview** (WIT rung 5, the consume
/// direction): each interface's type defs + functions rendered as q64
/// declarations, with honest gaps for the WIT primitives q64 can't represent
/// (`flags`/`char`/anonymous `tuple`) and opaque handles for `resource`s. A
/// parse error is reported on stderr (WIT001) with a non-zero exit; a document
/// that maps with gaps still prints (the gaps are notes), exiting 0.
fn cmdWit(gpa: std.mem.Allocator, io: std.Io, args_it: *std.process.Args.Iterator) !void {
    const verb = args_it.next() orelse {
        try usage(io);
        std.process.exit(2);
    };
    if (!std.mem.eql(u8, verb, "import")) {
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stderr().writerStreaming(io, &buf);
        try w.interface.print("q64: wit: unknown verb '{s}' (expected 'import')\n", .{verb});
        try w.interface.flush();
        std.process.exit(2);
    }

    var src_path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    while (args_it.next()) |a| {
        if (std.mem.eql(u8, a, "--out")) {
            out_path = args_it.next() orelse {
                try usage(io);
                std.process.exit(2);
            };
        } else if (std.mem.startsWith(u8, a, "--")) {
            // Tolerate unknown flags.
        } else if (src_path == null) {
            src_path = a;
        } else {
            try usage(io);
            std.process.exit(2);
        }
    }
    const src = src_path orelse {
        try usage(io);
        std.process.exit(2);
    };

    const source = std.Io.Dir.cwd().readFileAlloc(io, src, gpa, .limited(16 * 1024 * 1024)) catch |err| {
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stderr().writerStreaming(io, &buf);
        try w.interface.print("q64: cannot read {s}: {s}\n", .{ src, @errorName(err) });
        try w.interface.flush();
        std.process.exit(2);
    };
    defer gpa.free(source);

    // The parser arena owns the model + rendered output for this invocation.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var p: wit.Parser = undefined;
    const document = wit.parse(a, source, &p) catch |err| switch (err) {
        wit.Error.ParseError => {
            var buf: [4096]u8 = undefined;
            var w = std.Io.File.stderr().writerStreaming(io, &buf);
            try w.interface.print("q64: WIT001: {s}: {s} (byte {d})\n", .{ src, p.err_msg, p.err_pos });
            try w.interface.flush();
            std.process.exit(1);
        },
        else => return err,
    };

    var gaps = wit.Gaps{};
    const rendered = try wit.renderBindings(a, &document, &gaps);

    if (out_path) |op| {
        try writeFile(io, op, rendered);
    } else {
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stdout().writerStreaming(io, &buf);
        try w.interface.writeAll(rendered);
        try w.interface.flush();
    }
}

/// `q64 doc --json [--qube <file.q>] [--module name=file ...]` — emit the
/// documentation index as JSON on stdout (spec/q64-cli.md §"doc"). With no
/// `--qube`, emits the language-level index (keywords, builtin types,
/// diagnostics). With `--qube`, additionally emits that qube's public surface.
/// Parse diagnostics on a `--qube` source go to stderr as the standard
/// envelope, mirroring `check`.
fn cmdDoc(gpa: std.mem.Allocator, io: std.Io, args_it: *std.process.Args.Iterator) !void {
    var json = false;
    var qube_file: ?[]const u8 = null;
    while (args_it.next()) |a| {
        if (std.mem.eql(u8, a, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, a, "--qube")) {
            qube_file = args_it.next() orelse {
                try usage(io);
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, a, "--module")) {
            // The public surface is extracted from the qube's own source;
            // dependency modules are not needed. Tolerate + skip the value.
            _ = args_it.next();
        } else if (std.mem.startsWith(u8, a, "--")) {
            // Ignore flags this subcommand doesn't consume.
        } else if (qube_file == null) {
            qube_file = a;
        }
    }

    if (!json) {
        // v0 has only the JSON form; there is no human renderer for `doc` yet.
        var ebuf: [256]u8 = undefined;
        var ew = std.Io.File.stderr().writerStreaming(io, &ebuf);
        try ew.interface.writeAll("q64: doc requires --json\n");
        try ew.interface.flush();
        std.process.exit(2);
    }

    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(io, &buf);

    if (qube_file) |path| {
        const source = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 * 1024 * 1024)) catch |err| {
            var ebuf: [4096]u8 = undefined;
            var ew = std.Io.File.stderr().writerStreaming(io, &ebuf);
            try ew.interface.print("q64: cannot read {s}: {s}\n", .{ path, @errorName(err) });
            try ew.interface.flush();
            std.process.exit(2);
        };
        defer gpa.free(source);
        try doc.emitQubeJson(&w.interface, gpa, source, path);
    } else {
        try doc.emitLanguageJson(&w.interface, gpa);
    }
    try w.interface.flush();
}

/// `q64 explain <code> [--diagnostics json]` — print documentation for a
/// diagnostic code (spec/q64-cli.md §"explain"). Reads the same `diag.codes`
/// registry `doc --json` iterates, so the terminal and the web pages never
/// disagree. Unknown codes exit 1.
fn cmdExplain(gpa: std.mem.Allocator, io: std.Io, args_it: *std.process.Args.Iterator) !void {
    _ = gpa;
    var code: ?[]const u8 = null;
    var json = false;
    while (args_it.next()) |a| {
        if (std.mem.eql(u8, a, "--diagnostics")) {
            // Next arg is "json"; flag-style, mirroring `check`.
        } else if (std.mem.eql(u8, a, "json")) {
            json = true;
        } else if (std.mem.startsWith(u8, a, "--")) {
            // Ignore unknown flags.
        } else if (code == null) {
            code = a;
        }
    }

    const c = code orelse {
        try usage(io);
        std.process.exit(2);
    };

    const info = diag.lookup(c) orelse {
        var ebuf: [256]u8 = undefined;
        var ew = std.Io.File.stderr().writerStreaming(io, &ebuf);
        try ew.interface.print("q64: explain: unknown diagnostic code '{s}'\n", .{c});
        try ew.interface.flush();
        std.process.exit(1);
    };

    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(io, &buf);
    if (json) {
        try w.interface.writeAll("{\"code\":");
        try diag.writeJsonString(&w.interface, info.code);
        try w.interface.writeAll(",\"subsystem\":");
        try diag.writeJsonString(&w.interface, info.subsystem);
        try w.interface.writeAll(",\"severity\":");
        try diag.writeJsonString(&w.interface, info.severity.toString());
        try w.interface.writeAll(",\"message\":");
        try diag.writeJsonString(&w.interface, info.message);
        try w.interface.writeAll(",\"summary\":");
        try diag.writeJsonString(&w.interface, info.summary);
        try w.interface.writeAll(",\"url\":");
        try w.interface.print("\"{s}/{s}\"", .{ diag.diagnostics_base, info.code });
        try w.interface.writeAll("}\n");
    } else {
        try w.interface.print("{s} [{s}, {s}]\n  {s}\n", .{
            info.code, info.subsystem, info.severity.toString(), info.message,
        });
        if (info.summary.len > 0) {
            try w.interface.print("\n  {s}\n", .{info.summary});
        }
        try w.interface.print("\n  {s}/{s}\n", .{ diag.diagnostics_base, info.code });
    }
    try w.interface.flush();
}
