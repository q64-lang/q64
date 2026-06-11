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
        try cmdEmit(gpa, io, init.environ_map, &args_it);
        return;
    }

    if (std.mem.eql(u8, sub, "show")) {
        try cmdShow(gpa, io, &args_it);
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
        try w.interface.writeAll("q64 0.0.1 (pre-alpha)\n");
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
        \\  emit <file.q> <out.wasm> [--addr wasm32|wasm64] [--module name=dir ...]
        \\                                     Compile a q64 source file to wasm via codegen.
        \\                                     --addr selects the linear-memory address space
        \\                                     (default wasm64; wasm32 = 32-bit, WebKit/iPad).
        \\  emit-hello <out.wasm>              Emit the hello-world wasm module (hardcoded fixture).
        \\  show <hir|mir|symbols> <file.q> [--module name=dir ...]
        \\                                     Dump the Q64 IR (HIR or MIR) for a source file.
        \\  show effects <fn> --qube <file.q>  Print a function's inferred capability effect set.
        \\  show capabilities --qube <file.q>  Print the qube's compiler-derived capability set.
        \\  show world --qube <file.q>         Print the synthesized WIT world (exports + imports).
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

        var store = try sema.types.TypeStore.init(gpa);
        defer store.deinit();
        var sigs = try sema.types.collectSignatures(&store, &table, sf);
        defer sigs.deinit();
        const check_diags = try sema.check.checkFile(gpa, sf, &table, &store, &sigs);
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

fn cmdEmit(gpa: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, args_it: *std.process.Args.Iterator) !void {
    var src_path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    // Address space (spec/memory.md §"The platform"). Explicit per build; we
    // default to wasm64 to preserve existing behavior for string programs until
    // the wasm32 string ABI lands (Path B). `--addr wasm32` opts in to a genuine
    // 32-bit module (the WebKit/iPad baseline) for the integer/import subset.
    var addr: emit.AddressSpace = .wasm64;
    var want_component = false;
    var module_args: std.ArrayList(ModuleArg) = .empty;
    defer module_args.deinit(gpa);

    while (args_it.next()) |a| {
        if (std.mem.eql(u8, a, "--component")) {
            // Also wrap the core module in a component (spec/q64-cli.md). The
            // core module is still written to `out`.
            want_component = true;
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
        var w = std.Io.File.stderr().writerStreaming(io, &buf);
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
        var w = std.Io.File.stderr().writerStreaming(io, &buf);
        try w.interface.print("q64: emit failed: {s}\n", .{@errorName(err)});
        try w.interface.flush();
        std.process.exit(1);
    };
    defer gpa.free(bytes);

    try writeFile(io, out, bytes);

    // --component: additionally wrap the core module in a WebAssembly component,
    // written to `<out without .wasm>.component.wasm` (spec/q64-cli.md). A
    // library lift is a finished component; an app is a WASI preview1 core that
    // we run through `wasm-tools component new --adapt` (vendor/wasi/) to get a
    // real `wasi:cli/run` command importing `wasi:cli/stdout`.
    if (want_component) {
        const artifact = emit.emitComponent(gpa, source, src, module_sources.items, addr) catch |err| {
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
        }
    }
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
            var w = std.Io.File.stderr().writerStreaming(io, &buf);
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
                var w = std.Io.File.stderr().writerStreaming(io, &buf);
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

    const dump = (switch (which) {
        .hir => emit.showHir(gpa, source, src, module_sources.items),
        .mir => emit.showMir(gpa, source, src, module_sources.items),
        .symbols => sema.showSymbols(gpa, source, src),
        .effects => emit.showEffects(gpa, source, src, module_sources.items, arg2.?),
        .capabilities => emit.showCapabilities(gpa, source, src, module_sources.items),
        .world => emit.showWorld(gpa, source, src, module_sources.items),
    }) catch |err| {
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stderr().writerStreaming(io, &buf);
        try w.interface.print("q64: show {s} failed: {s}\n", .{ k, @errorName(err) });
        try w.interface.flush();
        std.process.exit(1);
    };
    defer gpa.free(dump);

    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(io, &buf);
    try w.interface.writeAll(dump);
    try w.interface.flush();
}

/// `q64 doc --json [--qube <file.q>] [--module name=dir ...]` — emit the
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
