//! qube — the package and build tool. CLI surface specified in
//! spec/qube-cli.md, manifest schema in spec/qube.json5.md.
//!
//! v0 scope: `qube run`, `qube web`, and `qube --version`. Everything
//! else prints "not implemented yet" and exits 2. `qube run`
//! discovers the nearest `qube.json5`, parses it as JSON5 (comments +
//! trailing commas), resolves local-path dependencies into
//! `q64 emit --module` flags, then shells out to `q64 emit` and
//! `q64-wasmtime-host`.
//! `qube web` shells out to `q64 emit`, copies the browser adapter
//! into `target/web/`, serves it via `python3 -m http.server`, and
//! opens the default browser.

const std = @import("std");
const builtin = @import("builtin");

const version_string = "qube 0.0.1 (pre-alpha)";

// Emitted by the QUBE_FORCE_ICE test seam (see main). A single-line diagnostic
// envelope matching spec/diagnostics.md §"ICE convention".
const ice_envelope =
    \\{"ok":false,"diagnostics":[{"code":"Q9001","severity":"internal","kind":"ice","message":"forced internal error (QUBE_FORCE_ICE)","repair":{"id":"report-upstream","safety":"n/a","report_url":"https://q64.dev/ice?code=Q9001"}}]}
;

// Kept in sync with q64/src/main.zig's `--version` output. The `qube web`
// debug page surfaces it; a future revision will capture it dynamically
// via `q64 --version`.
const q64_version_string = "q64 0.0.1 (pre-alpha)";

const Sub = struct { needle: []const u8, value: []const u8 };

const ExitCode = enum(u8) {
    success = 0,
    runtime_failure = 1,
    usage = 2,
    compile = 64,
    input = 65,
    dependency = 66,
    registry = 67,
    internal = 70,
};

const default_registry = "https://qubes.q64.dev";

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const env = init.environ_map;

    // Test seam: when QUBE_FORCE_ICE is set, route through the internal-error
    // path so the exit-70 + Q9xxx `severity:internal` envelope contract
    // (spec/qube-cli.md §"Exit codes", spec/diagnostics.md §"ICE convention")
    // is observable. Never triggered in normal use.
    if (env.get("QUBE_FORCE_ICE") != null) {
        try printStderr(io, "{s}\n", .{ice_envelope});
        std.process.exit(@intFromEnum(ExitCode.internal));
    }

    var args_it = init.minimal.args.iterate();
    _ = args_it.next(); // argv[0]

    const sub = args_it.next() orelse {
        try usage(io);
        std.process.exit(@intFromEnum(ExitCode.usage));
    };

    if (std.mem.eql(u8, sub, "--version") or std.mem.eql(u8, sub, "-v")) {
        try writeStdout(io, version_string ++ "\n");
        return;
    }
    if (std.mem.eql(u8, sub, "--help") or std.mem.eql(u8, sub, "-h")) {
        try usage(io);
        return;
    }

    if (std.mem.eql(u8, sub, "run")) {
        cmdRun(gpa, io, env, &args_it) catch |err| {
            try printStderr(io, "qube: run failed: {s}\n", .{@errorName(err)});
            std.process.exit(@intFromEnum(ExitCode.internal));
        };
        return;
    }

    if (std.mem.eql(u8, sub, "web")) {
        cmdWeb(gpa, io, env, &args_it) catch |err| {
            try printStderr(io, "qube: web failed: {s}\n", .{@errorName(err)});
            std.process.exit(@intFromEnum(ExitCode.internal));
        };
        return;
    }

    if (std.mem.eql(u8, sub, "login")) {
        cmdLogin(gpa, io, env, &args_it) catch |err| {
            try printStderr(io, "qube: login failed: {s}\n", .{@errorName(err)});
            std.process.exit(@intFromEnum(ExitCode.internal));
        };
        return;
    }

    if (std.mem.eql(u8, sub, "add")) {
        cmdAdd(gpa, io, env, &args_it) catch |err| {
            try printStderr(io, "qube: add failed: {s}\n", .{@errorName(err)});
            std.process.exit(@intFromEnum(ExitCode.internal));
        };
        return;
    }

    if (std.mem.eql(u8, sub, "publish")) {
        cmdPublish(gpa, io, env, &args_it) catch |err| {
            try printStderr(io, "qube: publish failed: {s}\n", .{@errorName(err)});
            std.process.exit(@intFromEnum(ExitCode.internal));
        };
        return;
    }

    // Documented subcommands that are not implemented yet. Listed
    // explicitly so unknown names still hit the usage fallback.
    const stub_subs = [_][]const u8{
        "new",     "init",    "remove",  "build",
        "test",    "install", "lock",    "outdated",
        "audit",   "clean",   "explain", "fix",     "fmt",
        "workspace",
    };
    for (stub_subs) |s| {
        if (std.mem.eql(u8, sub, s)) {
            try printStderr(io, "qube: {s}: not implemented yet\n", .{s});
            std.process.exit(@intFromEnum(ExitCode.usage));
        }
    }

    try printStderr(io, "qube: unknown subcommand: {s}\n", .{sub});
    try usage(io);
    std.process.exit(@intFromEnum(ExitCode.usage));
}

fn usage(io: std.Io) !void {
    try writeStderr(io,
        \\usage: qube <subcommand> [args]
        \\
        \\Subcommands (v0):
        \\  run                     Build and run the qube in the current directory.
        \\  web                     Build the qube to wasm and serve it in a browser.
        \\  add <name>[@version]    Resolve a dependency from the Continuum and add it.
        \\  publish                 Pack this qube and publish it to the Continuum.
        \\  login                   Authenticate against the Continuum registry.
        \\  --version, -v           Print the version and exit.
        \\  --help, -h              Print this help and exit.
        \\
        \\Other subcommands from the spec (new, init, build, test,
        \\fix, explain, fmt, workspace, ...) are not implemented yet.
        \\
    );
}

fn writeStdout(io: std.Io, text: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.writeAll(text);
    try w.interface.flush();
}

fn writeStderr(io: std.Io, text: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    try w.interface.writeAll(text);
    try w.interface.flush();
}

fn printStderr(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    try w.interface.print(fmt, args);
    try w.interface.flush();
}

// ---------------------------------------------------------------------------
// qube run
// ---------------------------------------------------------------------------

/// Convert a JSON5 manifest to strict JSON that `std.json` accepts.
/// v0 handles the features every real `qube.json5` uses: `//` and
/// `/* */` comments and trailing commas. Single-quoted strings and
/// unquoted keys (also valid JSON5) are not yet handled — all manifests
/// in the corpus quote their keys. String contents are preserved
/// verbatim so a `//` or `,` inside a value is never touched. Caller
/// owns the returned buffer.
fn json5ToJson(gpa: std.mem.Allocator, src: []const u8) ![]u8 {
    // Pass 1: drop comments, copying string literals through untouched.
    var nocomments: std.ArrayList(u8) = .empty;
    defer nocomments.deinit(gpa);
    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        if (c == '"') {
            try nocomments.append(gpa, c);
            i += 1;
            while (i < src.len) {
                const d = src[i];
                try nocomments.append(gpa, d);
                i += 1;
                if (d == '\\' and i < src.len) {
                    try nocomments.append(gpa, src[i]);
                    i += 1;
                    continue;
                }
                if (d == '"') break;
            }
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

    // Pass 2: drop a comma when the next significant byte is `}` or `]`.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const buf = nocomments.items;
    var j: usize = 0;
    while (j < buf.len) {
        const c = buf[j];
        if (c == '"') {
            try out.append(gpa, c);
            j += 1;
            while (j < buf.len) {
                const d = buf[j];
                try out.append(gpa, d);
                j += 1;
                if (d == '\\' and j < buf.len) {
                    try out.append(gpa, buf[j]);
                    j += 1;
                    continue;
                }
                if (d == '"') break;
            }
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

/// Read a top-level string field from a parsed manifest object.
fn manifestString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// Resolve the manifest's `dependencies` map into `name=dir` strings for
/// `q64 emit --module`. v0 resolves local-path dependencies only: the
/// module's source directory is `<dep-path>/src`, made absolute. A
/// registry or git dependency (which would need cache/lock resolution)
/// is reported and rejected rather than silently dropped. Caller owns
/// each returned string and the list.
fn resolveModuleSpecs(
    gpa: std.mem.Allocator,
    io: std.Io,
    project_dir: []const u8,
    root: std.json.ObjectMap,
) !std.ArrayList([]u8) {
    var specs: std.ArrayList([]u8) = .empty;
    errdefer {
        for (specs.items) |s| gpa.free(s);
        specs.deinit(gpa);
    }

    const deps_v = root.get("dependencies") orelse return specs;
    const deps = switch (deps_v) {
        .object => |o| o,
        else => return specs,
    };

    var it = deps.iterator();
    while (it.next()) |entry| {
        const dep_name = entry.key_ptr.*;
        const path_val: ?[]const u8 = switch (entry.value_ptr.*) {
            .object => |o| manifestString(o, "path"),
            else => null,
        };
        const p = path_val orelse {
            try printStderr(io, "qube: dependency '{s}' is not a local-path dependency; v0 resolves only `path` deps\n", .{dep_name});
            return error.UnsupportedDependency;
        };
        // Module source dir = <dep>/src, absolute and normalized.
        const dir = try std.fs.path.resolve(gpa, &.{ project_dir, p, "src" });
        defer gpa.free(dir);
        const spec = try std.fmt.allocPrint(gpa, "{s}={s}", .{ dep_name, dir });
        try specs.append(gpa, spec);
    }
    return specs;
}

fn cmdRun(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    args_it: *std.process.Args.Iterator,
) !void {
    // No flags supported in v0; warn on anything passed.
    while (args_it.next()) |a| {
        try printStderr(io, "qube run: ignoring unrecognised arg in v0: {s}\n", .{a});
    }

    // Discover qube.json5 by walking up from cwd.
    const cwd_path = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd_path);

    const manifest_path = try findManifestUpward(gpa, io, cwd_path) orelse {
        try writeStderr(io, "qube: no qube.json5 found in this directory or any parent\n");
        std.process.exit(@intFromEnum(ExitCode.input));
    };
    defer gpa.free(manifest_path);

    const project_dir = std.fs.path.dirname(manifest_path) orelse ".";

    const manifest_src = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, gpa, .limited(1 * 1024 * 1024)) catch |err| {
        try printStderr(io, "qube: cannot read {s}: {s}\n", .{ manifest_path, @errorName(err) });
        std.process.exit(@intFromEnum(ExitCode.input));
    };
    defer gpa.free(manifest_src);

    const json = json5ToJson(gpa, manifest_src) catch |err| {
        try printStderr(io, "qube: cannot read {s}: {s}\n", .{ manifest_path, @errorName(err) });
        std.process.exit(@intFromEnum(ExitCode.input));
    };
    defer gpa.free(json);

    const parsed = std.json.parseFromSlice(std.json.Value, gpa, json, .{}) catch |err| {
        try printStderr(io, "qube: cannot parse {s}: {s}\n", .{ manifest_path, @errorName(err) });
        std.process.exit(@intFromEnum(ExitCode.input));
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => {
            try writeStderr(io, "qube: manifest is not a JSON object\n");
            std.process.exit(@intFromEnum(ExitCode.input));
        },
    };

    const name = manifestString(root, "name") orelse {
        try writeStderr(io, "qube: manifest has no \"name\"\n");
        std.process.exit(@intFromEnum(ExitCode.input));
    };
    const type_str = manifestString(root, "type");
    const is_app = if (type_str) |t| std.mem.eql(u8, t, "application") else true;
    if (!is_app) {
        try printStderr(io, "qube: cannot run a {s} qube\n", .{type_str.?});
        std.process.exit(@intFromEnum(ExitCode.usage));
    }

    // Resolve entry; default per spec is src/main.q for applications.
    const entry_rel = manifestString(root, "entry") orelse "src/main.q";
    const entry_path = try std.fs.path.join(gpa, &.{ project_dir, entry_rel });
    defer gpa.free(entry_path);

    // Resolve dependencies → `--module name=dir` specs (ladder step 4).
    var module_specs = resolveModuleSpecs(gpa, io, project_dir, root) catch |err| {
        try printStderr(io, "qube: dependency resolution failed: {s}\n", .{@errorName(err)});
        std.process.exit(@intFromEnum(ExitCode.dependency));
    };
    defer {
        for (module_specs.items) |s| gpa.free(s);
        module_specs.deinit(gpa);
    }

    // Heuristic repo root: walk up from project_dir until we find a
    // sibling `vendor/zig/` directory. Used to locate the in-tree
    // q64 and host binaries when env vars are not set.
    const repo_root_opt = findRepoRoot(gpa, io, project_dir) catch null;
    defer if (repo_root_opt) |r| gpa.free(r);

    const q64_bin = try resolveBinary(gpa, io, env, "Q64_BIN", repo_root_opt, "q64/zig-out/bin/q64", "q64");
    defer gpa.free(q64_bin);

    const host_bin = try resolveBinary(gpa, io, env, "Q64_HOST", repo_root_opt, "runtime/wasmtime/zig-out/bin/q64-wasmtime-host", "q64-wasmtime-host");
    defer gpa.free(host_bin);

    // Build output: target/debug/<name>.wasm next to the manifest.
    const out_dir = try std.fs.path.join(gpa, &.{ project_dir, "target", "debug" });
    defer gpa.free(out_dir);
    try std.Io.Dir.cwd().createDirPath(io, out_dir);

    const wasm_name = try std.fmt.allocPrint(gpa, "{s}.wasm", .{name});
    defer gpa.free(wasm_name);
    const wasm_path = try std.fs.path.join(gpa, &.{ out_dir, wasm_name });
    defer gpa.free(wasm_path);

    // 1. q64 emit <entry> <wasm> [--module name=dir ...]
    {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ q64_bin, "emit", entry_path, wasm_path });
        for (module_specs.items) |spec| {
            try argv.appendSlice(gpa, &.{ "--module", spec });
        }
        const term = try spawnInherit(io, argv.items);
        if (termCode(term)) |code| {
            if (code != 0) {
                // Compile error from q64 is exit 64; pass through any
                // non-zero code as compile error for v0.
                std.process.exit(if (code == 1) @intFromEnum(ExitCode.compile) else code);
            }
        } else {
            std.process.exit(@intFromEnum(ExitCode.compile));
        }
    }

    // 2. q64-wasmtime-host <wasm>
    {
        const argv = [_][]const u8{ host_bin, wasm_path };
        const term = try spawnInherit(io, &argv);
        if (termCode(term)) |code| {
            if (code != 0) std.process.exit(@intFromEnum(ExitCode.runtime_failure));
        } else {
            std.process.exit(@intFromEnum(ExitCode.runtime_failure));
        }
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
        .exited => |c| c,
        else => null,
    };
}

fn findManifestUpward(gpa: std.mem.Allocator, io: std.Io, start_abs: []const u8) !?[]u8 {
    const dir_buf = try gpa.dupe(u8, start_abs);
    defer gpa.free(dir_buf);
    var cur: []const u8 = dir_buf;

    while (true) {
        const candidate = try std.fs.path.join(gpa, &.{ cur, "qube.json5" });
        const exists = blk: {
            std.Io.Dir.cwd().access(io, candidate, .{}) catch break :blk false;
            break :blk true;
        };
        if (exists) return candidate;
        gpa.free(candidate);

        const parent = std.fs.path.dirname(cur) orelse return null;
        if (std.mem.eql(u8, parent, cur)) return null;
        cur = parent;
    }
}

fn findRepoRoot(gpa: std.mem.Allocator, io: std.Io, start: []const u8) !?[]u8 {
    // Resolve start to absolute. If it's already absolute, dupe;
    // otherwise join with cwd.
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
    // Fall back to argv[0] name; the OS resolves via PATH at spawn time.
    return try gpa.dupe(u8, path_name);
}

// ---------------------------------------------------------------------------
// qube web
// ---------------------------------------------------------------------------

const port_first: u16 = 4711;
const port_last: u16 = 4720;

fn cmdWeb(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    args_it: *std.process.Args.Iterator,
) !void {
    while (args_it.next()) |a| {
        try printStderr(io, "qube web: ignoring unrecognised arg in v0: {s}\n", .{a});
    }

    const cwd_path = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd_path);

    const manifest_path = try findManifestUpward(gpa, io, cwd_path) orelse {
        try writeStderr(io, "qube: no qube.json5 found in this directory or any parent\n");
        std.process.exit(@intFromEnum(ExitCode.input));
    };
    defer gpa.free(manifest_path);

    const project_dir = std.fs.path.dirname(manifest_path) orelse ".";

    const manifest_src = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, gpa, .limited(1 * 1024 * 1024)) catch |err| {
        try printStderr(io, "qube: cannot read {s}: {s}\n", .{ manifest_path, @errorName(err) });
        std.process.exit(@intFromEnum(ExitCode.input));
    };
    defer gpa.free(manifest_src);

    const json = json5ToJson(gpa, manifest_src) catch |err| {
        try printStderr(io, "qube: cannot read {s}: {s}\n", .{ manifest_path, @errorName(err) });
        std.process.exit(@intFromEnum(ExitCode.input));
    };
    defer gpa.free(json);

    const parsed = std.json.parseFromSlice(std.json.Value, gpa, json, .{}) catch |err| {
        try printStderr(io, "qube: cannot parse {s}: {s}\n", .{ manifest_path, @errorName(err) });
        std.process.exit(@intFromEnum(ExitCode.input));
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => {
            try writeStderr(io, "qube: manifest is not a JSON object\n");
            std.process.exit(@intFromEnum(ExitCode.input));
        },
    };

    const name = manifestString(root, "name") orelse {
        try writeStderr(io, "qube: manifest has no \"name\"\n");
        std.process.exit(@intFromEnum(ExitCode.input));
    };
    const user_version_field = manifestString(root, "version");
    const type_str = manifestString(root, "type");
    const is_app = if (type_str) |t| std.mem.eql(u8, t, "application") else true;
    if (!is_app) {
        try printStderr(io, "qube: cannot serve a {s} qube\n", .{type_str.?});
        std.process.exit(@intFromEnum(ExitCode.usage));
    }

    const entry_rel = manifestString(root, "entry") orelse "src/main.q";
    const entry_path = try std.fs.path.join(gpa, &.{ project_dir, entry_rel });
    defer gpa.free(entry_path);

    var module_specs = resolveModuleSpecs(gpa, io, project_dir, root) catch |err| {
        try printStderr(io, "qube: dependency resolution failed: {s}\n", .{@errorName(err)});
        std.process.exit(@intFromEnum(ExitCode.dependency));
    };
    defer {
        for (module_specs.items) |s| gpa.free(s);
        module_specs.deinit(gpa);
    }

    const repo_root_opt = findRepoRoot(gpa, io, project_dir) catch null;
    defer if (repo_root_opt) |r| gpa.free(r);

    const q64_bin = try resolveBinary(gpa, io, env, "Q64_BIN", repo_root_opt, "q64/zig-out/bin/q64", "q64");
    defer gpa.free(q64_bin);

    const adapter_dir = try resolveAdapterDir(gpa, io, env, repo_root_opt);
    defer gpa.free(adapter_dir);

    const web_dir = try std.fs.path.join(gpa, &.{ project_dir, "target", "web" });
    defer gpa.free(web_dir);
    try std.Io.Dir.cwd().createDirPath(io, web_dir);

    const wasm_name = try std.fmt.allocPrint(gpa, "{s}.wasm", .{name});
    defer gpa.free(wasm_name);
    const wasm_path = try std.fs.path.join(gpa, &.{ web_dir, wasm_name });
    defer gpa.free(wasm_path);

    // 1. q64 emit <entry> <wasm> [--module name=dir ...]
    {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ q64_bin, "emit", entry_path, wasm_path });
        for (module_specs.items) |spec| {
            try argv.appendSlice(gpa, &.{ "--module", spec });
        }
        const term = try spawnInherit(io, argv.items);
        if (termCode(term)) |code| {
            if (code != 0) {
                std.process.exit(if (code == 1) @intFromEnum(ExitCode.compile) else code);
            }
        } else {
            std.process.exit(@intFromEnum(ExitCode.compile));
        }
    }

    // 2. Copy host.js verbatim; template index.html.
    try copyAdapterFile(gpa, io, adapter_dir, web_dir, "host.js", &.{});
    const user_version = user_version_field orelse "0.0.0";
    const html_subs = [_]Sub{
        .{ .needle = "{{WASM}}", .value = wasm_name },
        .{ .needle = "{{NAME}}", .value = name },
        .{ .needle = "{{USER_VERSION}}", .value = user_version },
        .{ .needle = "{{Q64_VERSION}}", .value = q64_version_string },
        .{ .needle = "{{QUBE_VERSION}}", .value = version_string },
    };
    try copyAdapterFile(gpa, io, adapter_dir, web_dir, "index.html", &html_subs);

    // 3. Pick a free port.
    const port = pickFreePort(io) orelse {
        try printStderr(io, "qube web: no free port in [{d}, {d}]\n", .{ port_first, port_last });
        std.process.exit(@intFromEnum(ExitCode.runtime_failure));
    };

    // 4. Spawn `python3 -m http.server <port> --directory <web_dir>`.
    // TODO: replace with a built-in server later.
    const port_str = try std.fmt.allocPrint(gpa, "{d}", .{port});
    defer gpa.free(port_str);
    const url = try std.fmt.allocPrint(gpa, "http://localhost:{d}/", .{port});
    defer gpa.free(url);

    const server_argv = [_][]const u8{
        "python3", "-m", "http.server", port_str, "--directory", web_dir,
    };
    var server = std.process.spawn(io, .{
        .argv = &server_argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        try printStderr(io, "qube web: cannot spawn python3 http.server: {s}\n", .{@errorName(err)});
        std.process.exit(@intFromEnum(ExitCode.internal));
    };

    // 5. Wait briefly for the server to start accepting connections.
    waitForPort(io, port);

    // 6. Open the default browser. Best-effort; log on failure.
    openBrowser(io, url) catch |err| {
        try printStderr(io, "qube web: could not open browser: {s}\n", .{@errorName(err)});
    };

    try printStdout(io, "qube web: serving at {s}  (Ctrl-C to stop)\n", .{url});

    const term = server.wait(io) catch |err| {
        try printStderr(io, "qube web: wait on http.server failed: {s}\n", .{@errorName(err)});
        std.process.exit(@intFromEnum(ExitCode.internal));
    };
    if (termCode(term)) |code| {
        if (code != 0) std.process.exit(code);
    }
}

fn resolveAdapterDir(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    repo_root: ?[]const u8,
) ![]u8 {
    if (env.get("Q64_BROWSER_ADAPTER")) |v| {
        if (v.len > 0) return try gpa.dupe(u8, v);
    }
    if (repo_root) |root| {
        const candidate = try std.fs.path.join(gpa, &.{ root, "runtime", "browser" });
        const ok = blk: {
            std.Io.Dir.cwd().access(io, candidate, .{}) catch break :blk false;
            break :blk true;
        };
        if (ok) return candidate;
        gpa.free(candidate);
    }
    return try gpa.dupe(u8, "runtime/browser");
}

fn copyAdapterFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    src_dir: []const u8,
    dst_dir: []const u8,
    name: []const u8,
    subs: []const Sub,
) !void {
    const src_path = try std.fs.path.join(gpa, &.{ src_dir, name });
    defer gpa.free(src_path);
    const dst_path = try std.fs.path.join(gpa, &.{ dst_dir, name });
    defer gpa.free(dst_path);

    const src_bytes = std.Io.Dir.cwd().readFileAlloc(io, src_path, gpa, .limited(1 * 1024 * 1024)) catch |err| {
        try printStderr(io, "qube web: cannot read {s}: {s}\n", .{ src_path, @errorName(err) });
        return err;
    };
    defer gpa.free(src_bytes);

    var current: []u8 = try gpa.dupe(u8, src_bytes);
    for (subs) |sub| {
        const size = std.mem.replacementSize(u8, current, sub.needle, sub.value);
        const next = try gpa.alloc(u8, size);
        _ = std.mem.replace(u8, current, sub.needle, sub.value, next);
        gpa.free(current);
        current = next;
    }
    defer gpa.free(current);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dst_path, .data = current });
}

fn pickFreePort(io: std.Io) ?u16 {
    var port: u16 = port_first;
    while (port <= port_last) : (port += 1) {
        const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
        var server = std.Io.net.IpAddress.listen(&addr, io, .{ .reuse_address = false }) catch continue;
        server.deinit(io);
        return port;
    }
    return null;
}

fn waitForPort(io: std.Io, port: u16) void {
    // Zig 0.16's std.Io.net doesn't yet implement connect-with-timeout
    // on POSIX (it panics). Probe with a plain blocking connect; the OS
    // will reject fast while the server isn't listening yet, and we
    // sleep between tries.
    const addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    var attempts: u8 = 0;
    while (attempts < 40) : (attempts += 1) {
        const stream = std.Io.net.IpAddress.connect(&addr, io, .{
            .mode = .stream,
        }) catch {
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake) catch {};
            continue;
        };
        stream.close(io);
        return;
    }
}

fn openBrowser(io: std.Io, url: []const u8) !void {
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{ "open", url },
        .linux => &.{ "xdg-open", url },
        else => return,
    };
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    _ = child.wait(io) catch {};
}

fn printStdout(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.print(fmt, args);
    try w.interface.flush();
}

// ---------------------------------------------------------------------------
// qube login
// ---------------------------------------------------------------------------
//
// v0 design: shell to curl for HTTPS (the same posture as `qube run`'s
// shell-out to q64). Credentials are taken from flags or env vars; no stdin
// masking yet. When OAuth lands, this becomes a browser device-flow.

fn cmdLogin(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    args_it: *std.process.Args.Iterator,
) !void {
    // qube login [<email>] [--registry <url>]
    //   Reads password from stdin (no echo). Email may be positional, an env
    //   var (QUBE_EMAIL), or — if neither — prompted. Password may also come
    //   from QUBE_PASSWORD for non-interactive / CI use.
    var registry: []const u8 = "https://qubes.q64.dev";
    var email_opt: ?[]const u8 = null;
    while (args_it.next()) |a| {
        if (std.mem.eql(u8, a, "--registry")) {
            registry = args_it.next() orelse {
                try writeStderr(io, "qube login: --registry needs a value\n");
                std.process.exit(@intFromEnum(ExitCode.usage));
            };
        } else if (std.mem.startsWith(u8, a, "-")) {
            try printStderr(io, "qube login: unknown flag: {s}\n", .{a});
            std.process.exit(@intFromEnum(ExitCode.usage));
        } else if (email_opt == null) {
            email_opt = a;
        } else {
            try printStderr(io, "qube login: unexpected extra arg: {s}\n", .{a});
            std.process.exit(@intFromEnum(ExitCode.usage));
        }
    }
    if (email_opt == null) email_opt = env.get("QUBE_EMAIL");

    var email_owned: ?[]u8 = null;
    defer if (email_owned) |e| gpa.free(e);
    const email: []const u8 = if (email_opt) |e| e else blk: {
        try writeStdout(io, "email: ");
        const line = try readStdinLineAlloc(gpa, io);
        email_owned = line;
        break :blk line;
    };

    var password_owned: ?[]u8 = null;
    defer if (password_owned) |p| gpa.free(p);
    const password: []const u8 = if (env.get("QUBE_PASSWORD")) |p| p else blk: {
        try writeStdout(io, "password: ");
        const line = try readPasswordSilent(gpa, io);
        password_owned = line;
        try writeStdout(io, "\n");
        break :blk line;
    };

    const host = stripScheme(registry);
    const url = try std.fmt.allocPrint(gpa, "{s}/v1/auth/token", .{registry});
    defer gpa.free(url);

    // v0: passwords are bypass-only ("***"); no need to JSON-escape yet.
    const body = try std.fmt.allocPrint(
        gpa,
        \\{{"email":"{s}","password":"{s}","description":"qube login"}}
    ,
        .{ email, password },
    );
    defer gpa.free(body);

    const argv = [_][]const u8{
        "curl", "-sS",                       "-X",
        "POST", url,                         "-H",
        "content-type: application/json",    "-d",
        body,
    };

    var child = std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .inherit,
    }) catch |err| {
        try printStderr(io, "qube login: cannot spawn curl: {s}\n", .{@errorName(err)});
        return err;
    };

    var stdout_buf: [16 * 1024]u8 = undefined;
    var stdout_reader = child.stdout.?.reader(io, &stdout_buf);
    const response = stdout_reader.interface.allocRemaining(gpa, .limited(64 * 1024)) catch |err| {
        try printStderr(io, "qube login: cannot read response: {s}\n", .{@errorName(err)});
        _ = child.wait(io) catch {};
        return err;
    };
    defer gpa.free(response);

    const term = try child.wait(io);
    if (termCode(term)) |c| {
        if (c != 0) {
            try printStderr(io, "qube login: curl exited {d}\n", .{c});
            std.process.exit(@intFromEnum(ExitCode.runtime_failure));
        }
    }

    const TokenResponse = struct {
        token: []const u8,
        expires_at: []const u8,
        user: struct {
            email: []const u8,
            username: []const u8,
        },
    };
    const parsed = std.json.parseFromSlice(TokenResponse, gpa, response, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        try printStderr(io, "qube login: server returned unexpected response:\n{s}\n", .{response});
        return err;
    };
    defer parsed.deinit();
    const t = parsed.value;

    const home = env.get("HOME") orelse {
        try writeStderr(io, "qube login: HOME not set\n");
        std.process.exit(@intFromEnum(ExitCode.internal));
    };
    const qube_dir = try std.fs.path.join(gpa, &.{ home, ".qube" });
    defer gpa.free(qube_dir);
    try std.Io.Dir.cwd().createDirPath(io, qube_dir);

    const cred_path = try std.fs.path.join(gpa, &.{ qube_dir, "credentials.toml" });
    defer gpa.free(cred_path);

    const toml = try std.fmt.allocPrint(gpa,
        \\# Continuum registry credentials. Written by `qube login`.
        \\# Do not check in. The token grants publish access to your qubes.
        \\
        \\[registries."{s}"]
        \\token = "{s}"
        \\user = "{s}"
        \\expires_at = "{s}"
        \\
    , .{ host, t.token, t.user.email, t.expires_at });
    defer gpa.free(toml);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cred_path, .data = toml });
    try printStdout(io, "Logged in as {s}. Token stored in {s}.\n", .{ t.user.email, cred_path });
}

// ---------------------------------------------------------------------------
// Shared helpers for add / publish
// ---------------------------------------------------------------------------

const Captured = struct { stdout: []u8, code: ?u8 };

/// Spawn `argv`, capture its stdout, inherit stderr, return both. Caller owns
/// `stdout`. The v0 posture (per spec/qube-cli.md) is to shell out to `curl`,
/// `zip`, and `unzip` rather than vendor those libraries.
fn runCapture(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !Captured {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .inherit,
    });
    var buf: [16 * 1024]u8 = undefined;
    var r = child.stdout.?.reader(io, &buf);
    const out = try r.interface.allocRemaining(gpa, .limited(8 * 1024 * 1024));
    const term = try child.wait(io);
    return .{ .stdout = out, .code = termCode(term) };
}

const HttpResp = struct {
    raw: []u8, // owned; free this
    body: []const u8, // slice into raw
    status: u16,
};

/// GET `url`, returning the body and HTTP status. `-w "\n%{http_code}"` appends
/// the status as a trailing line we split off.
fn httpGet(gpa: std.mem.Allocator, io: std.Io, url: []const u8) !HttpResp {
    const argv = [_][]const u8{ "curl", "-sS", "-w", "\n%{http_code}", url };
    const cap = try runCapture(gpa, io, &argv);
    const nl = std.mem.lastIndexOfScalar(u8, cap.stdout, '\n') orelse {
        gpa.free(cap.stdout);
        return error.BadResponse;
    };
    const status = std.fmt.parseInt(u16, std.mem.trim(u8, cap.stdout[nl + 1 ..], " \r\n"), 10) catch 0;
    return .{ .raw = cap.stdout, .body = cap.stdout[0..nl], .status = status };
}

/// GET `url` writing the body to `path`; returns the HTTP status.
fn httpGetToFile(gpa: std.mem.Allocator, io: std.Io, url: []const u8, path: []const u8) !u16 {
    const argv = [_][]const u8{ "curl", "-sS", "-o", path, "-w", "%{http_code}", url };
    const cap = try runCapture(gpa, io, &argv);
    defer gpa.free(cap.stdout);
    return std.fmt.parseInt(u16, std.mem.trim(u8, cap.stdout, " \r\n"), 10) catch 0;
}

fn qubeHome(gpa: std.mem.Allocator, env: *std.process.Environ.Map) ![]u8 {
    if (env.get("QUBE_HOME")) |h| {
        if (h.len > 0) return gpa.dupe(u8, h);
    }
    const home = env.get("HOME") orelse return error.NoHome;
    return std.fs.path.join(gpa, &.{ home, ".qube" });
}

/// Read the bearer token for `host` out of `<qube_home>/credentials.toml`.
/// v0 keeps a single registry, so we take the first `token = "…"` line.
fn readRegistryToken(gpa: std.mem.Allocator, io: std.Io, qube_home: []const u8) ![]u8 {
    const path = try std.fs.path.join(gpa, &.{ qube_home, "credentials.toml" });
    defer gpa.free(path);
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024)) catch
        return error.NotLoggedIn;
    defer gpa.free(text);
    const key = "token = \"";
    const i = std.mem.indexOf(u8, text, key) orelse return error.NoToken;
    const start = i + key.len;
    const end = std.mem.indexOfScalarPos(u8, text, start, '"') orelse return error.NoToken;
    return gpa.dupe(u8, text[start..end]);
}

/// Find a `"key": "value"` string field in raw manifest text. Tolerates the
/// JSON5 our manifests use because it scans rather than fully parses; it only
/// recognises double-quoted keys (enough for `name`/`version`).
fn extractStringField(src: []const u8, quoted_key: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, src, pos, quoted_key)) |k| {
        pos = k + quoted_key.len;
        var j = pos;
        while (j < src.len and (src[j] == ' ' or src[j] == '\t')) j += 1;
        if (j >= src.len or src[j] != ':') continue;
        j += 1;
        while (j < src.len and (src[j] == ' ' or src[j] == '\t')) j += 1;
        if (j >= src.len or src[j] != '"') continue;
        j += 1;
        const value_start = j;
        while (j < src.len and src[j] != '"') j += 1;
        if (j >= src.len) return null;
        return src[value_start..j];
    }
    return null;
}

fn isLowerAlnumU(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_';
}

/// Publishable name: reverse-DNS dotted, ≥2 lowercase identifier segments
/// (snake_case, no dashes). Mirrors spec/qube.json5.schema.json.
fn isPublishableName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    var segs: usize = 0;
    var i: usize = 0;
    while (i < name.len) {
        if (!(name[i] >= 'a' and name[i] <= 'z')) return false;
        i += 1;
        while (i < name.len and isLowerAlnumU(name[i])) i += 1;
        segs += 1;
        if (i < name.len) {
            if (name[i] != '.') return false;
            i += 1;
            if (i >= name.len) return false; // trailing dot
        }
    }
    return segs >= 2;
}

fn isReservedNamespace(name: []const u8) bool {
    return std.mem.eql(u8, name, "q64") or std.mem.startsWith(u8, name, "q64.");
}

fn sha256HexOfFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024 * 1024));
    defer gpa.free(bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hexchars = "0123456789abcdef";
    const hex = try gpa.alloc(u8, 64);
    for (digest, 0..) |b, idx| {
        hex[idx * 2] = hexchars[b >> 4];
        hex[idx * 2 + 1] = hexchars[b & 0x0f];
    }
    return hex;
}

// ---------------------------------------------------------------------------
// qube publish
// ---------------------------------------------------------------------------

const pack_script =
    \\set -e
    \\PROJECT="$1"; ROOT="$2"; OUT="$3"
    \\STAGE="$(mktemp -d)"
    \\mkdir -p "$STAGE/$ROOT" "$(dirname "$OUT")"
    \\cd "$PROJECT"
    \\for item in qube.json5 README.md src tests examples example; do
    \\  [ -e "$item" ] && cp -R "$item" "$STAGE/$ROOT/" || true
    \\done
    \\for lic in LICENSE LICENSE-MIT LICENSE-APACHE; do
    \\  [ -e "$lic" ] && cp "$lic" "$STAGE/$ROOT/" || true
    \\done
    \\cd "$STAGE"
    \\find . -name .DS_Store -delete 2>/dev/null || true
    \\rm -f "$OUT"
    \\zip -rqX "$OUT" "$ROOT"
    \\rm -rf "$STAGE"
;

fn cmdPublish(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    args_it: *std.process.Args.Iterator,
) !void {
    var registry: []const u8 = default_registry;
    while (args_it.next()) |a| {
        if (std.mem.eql(u8, a, "--registry")) {
            registry = args_it.next() orelse {
                try writeStderr(io, "qube publish: --registry needs a value\n");
                std.process.exit(@intFromEnum(ExitCode.usage));
            };
        } else {
            try printStderr(io, "qube publish: ignoring unrecognised arg in v0: {s}\n", .{a});
        }
    }

    const cwd_path = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd_path);
    const manifest_path = try findManifestUpward(gpa, io, cwd_path) orelse {
        try writeStderr(io, "qube: no qube.json5 found in this directory or any parent\n");
        std.process.exit(@intFromEnum(ExitCode.input));
    };
    defer gpa.free(manifest_path);
    const project_dir = std.fs.path.dirname(manifest_path) orelse ".";

    const raw = try std.Io.Dir.cwd().readFileAlloc(io, manifest_path, gpa, .limited(1024 * 1024));
    defer gpa.free(raw);

    const name = extractStringField(raw, "\"name\"") orelse {
        try writeStderr(io, "qube publish: manifest has no \"name\" field\n");
        std.process.exit(@intFromEnum(ExitCode.input));
    };
    const version = extractStringField(raw, "\"version\"") orelse {
        try writeStderr(io, "qube publish: manifest has no \"version\" field\n");
        std.process.exit(@intFromEnum(ExitCode.input));
    };

    if (!isPublishableName(name)) {
        try printStderr(io, "qube publish: invalid name '{s}': use a reverse-DNS dotted name with >=2 lowercase identifier segments, e.g. dev.q64.webmcp_client\n", .{name});
        std.process.exit(@intFromEnum(ExitCode.input));
    }
    if (isReservedNamespace(name)) {
        try writeStderr(io, "qube publish: the 'q64.*' namespace is reserved for the built-in standard library\n");
        std.process.exit(@intFromEnum(ExitCode.input));
    }
    if (std.mem.indexOf(u8, raw, "\"publish\"") != null and std.mem.indexOf(u8, raw, "false") != null) {
        // Coarse v0 guard: a manifest that sets publish:false is opted out.
        try writeStderr(io, "qube publish: manifest sets publish: false; refusing\n");
        std.process.exit(@intFromEnum(ExitCode.input));
    }

    // Pack the default file set into target/publish/<name>-<version>.zip.
    const root = try std.fmt.allocPrint(gpa, "{s}-{s}", .{ name, version });
    defer gpa.free(root);
    const out_zip = try std.fs.path.join(gpa, &.{ project_dir, "target", "publish", root });
    defer gpa.free(out_zip);
    const out_zip_full = try std.fmt.allocPrint(gpa, "{s}.zip", .{out_zip});
    defer gpa.free(out_zip_full);

    {
        const argv = [_][]const u8{ "sh", "-c", pack_script, "sh", project_dir, root, out_zip_full };
        const term = try spawnInherit(io, &argv);
        if (termCode(term) != 0) {
            try writeStderr(io, "qube publish: packing the archive failed\n");
            std.process.exit(@intFromEnum(ExitCode.internal));
        }
    }
    try printStdout(io, "qube publish: packed {s}\n", .{out_zip_full});

    // Token.
    const home = try qubeHome(gpa, env);
    defer gpa.free(home);
    const token = readRegistryToken(gpa, io, home) catch {
        try writeStderr(io, "qube publish: no credentials; run `qube login` first\n");
        std.process.exit(@intFromEnum(ExitCode.registry));
    };
    defer gpa.free(token);

    // Upload.
    const url = try std.fmt.allocPrint(gpa, "{s}/v1/qubes/{s}", .{ registry, name });
    defer gpa.free(url);
    const auth = try std.fmt.allocPrint(gpa, "authorization: Bearer {s}", .{token});
    defer gpa.free(auth);
    const manifest_field = try std.fmt.allocPrint(gpa, "manifest=<{s}", .{manifest_path});
    defer gpa.free(manifest_field);
    const archive_field = try std.fmt.allocPrint(gpa, "archive=@{s};type=application/zip", .{out_zip_full});
    defer gpa.free(archive_field);

    const argv = [_][]const u8{
        "curl",          "-sS",  "-w", "\n%{http_code}",
        "-X",            "POST", url,  "-H",
        auth,            "-F",   manifest_field,
        "-F",            archive_field,
    };
    const cap = try runCapture(gpa, io, &argv);
    defer gpa.free(cap.stdout);
    const nl = std.mem.lastIndexOfScalar(u8, cap.stdout, '\n') orelse cap.stdout.len;
    const body = cap.stdout[0..nl];
    const status = if (nl < cap.stdout.len)
        std.fmt.parseInt(u16, std.mem.trim(u8, cap.stdout[nl + 1 ..], " \r\n"), 10) catch 0
    else
        0;

    if (status == 201) {
        try printStdout(io, "Published {s}@{s}.\n{s}\n", .{ name, version, body });
        return;
    }
    try printStderr(io, "qube publish: registry returned {d}:\n{s}\n", .{ status, body });
    std.process.exit(@intFromEnum(ExitCode.registry));
}

// ---------------------------------------------------------------------------
// qube add
// ---------------------------------------------------------------------------

const VersionMeta = struct {
    version: []const u8,
    archive_sha: []const u8,
    yanked: bool = false,
};
const QubeMeta = struct {
    name: []const u8,
    latest: ?[]const u8 = null,
    versions: []VersionMeta = &.{},
};

const extract_script =
    \\set -e
    \\ZIP="$1"; DEST="$2"
    \\TMP="$(mktemp -d)"
    \\unzip -oq "$ZIP" -d "$TMP"
    \\rm -rf "$DEST"; mkdir -p "$DEST"
    \\inner="$(ls -d "$TMP"/*/ 2>/dev/null | head -1)"
    \\if [ -n "$inner" ]; then cp -R "$inner". "$DEST"/; else cp -R "$TMP"/. "$DEST"/; fi
    \\rm -rf "$TMP"
;

fn cmdAdd(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    args_it: *std.process.Args.Iterator,
) !void {
    var registry: []const u8 = default_registry;
    var dep_arg: ?[]const u8 = null;
    while (args_it.next()) |a| {
        if (std.mem.eql(u8, a, "--registry")) {
            registry = args_it.next() orelse {
                try writeStderr(io, "qube add: --registry needs a value\n");
                std.process.exit(@intFromEnum(ExitCode.usage));
            };
        } else if (std.mem.startsWith(u8, a, "-")) {
            try printStderr(io, "qube add: unknown flag: {s}\n", .{a});
            std.process.exit(@intFromEnum(ExitCode.usage));
        } else if (dep_arg == null) {
            dep_arg = a;
        } else {
            try printStderr(io, "qube add: unexpected extra arg: {s}\n", .{a});
            std.process.exit(@intFromEnum(ExitCode.usage));
        }
    }
    const dep = dep_arg orelse {
        try writeStderr(io, "usage: qube add <name>[@version]\n");
        std.process.exit(@intFromEnum(ExitCode.usage));
    };

    var name = dep;
    var req_version: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, dep, '@')) |at| {
        name = dep[0..at];
        req_version = dep[at + 1 ..];
    }
    if (!isPublishableName(name)) {
        try printStderr(io, "qube add: invalid name '{s}'\n", .{name});
        std.process.exit(@intFromEnum(ExitCode.dependency));
    }

    const cwd_path = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd_path);
    const manifest_path = try findManifestUpward(gpa, io, cwd_path) orelse {
        try writeStderr(io, "qube: no qube.json5 found in this directory or any parent\n");
        std.process.exit(@intFromEnum(ExitCode.input));
    };
    defer gpa.free(manifest_path);

    // Resolve metadata.
    const meta_url = try std.fmt.allocPrint(gpa, "{s}/v1/qubes/{s}", .{ registry, name });
    defer gpa.free(meta_url);
    const resp = try httpGet(gpa, io, meta_url);
    defer gpa.free(resp.raw);
    if (resp.status == 404) {
        try printStderr(io, "qube add: '{s}' not found on {s}\n", .{ name, registry });
        std.process.exit(@intFromEnum(ExitCode.dependency));
    }
    if (resp.status != 200) {
        try printStderr(io, "qube add: registry returned {d}:\n{s}\n", .{ resp.status, resp.body });
        std.process.exit(@intFromEnum(ExitCode.registry));
    }

    const parsed = std.json.parseFromSlice(QubeMeta, gpa, resp.body, .{ .ignore_unknown_fields = true }) catch {
        try writeStderr(io, "qube add: could not parse registry metadata\n");
        std.process.exit(@intFromEnum(ExitCode.registry));
    };
    defer parsed.deinit();
    const meta = parsed.value;

    const want = req_version orelse meta.latest orelse {
        try writeStderr(io, "qube add: registry returned no versions\n");
        std.process.exit(@intFromEnum(ExitCode.dependency));
    };
    var chosen: ?VersionMeta = null;
    for (meta.versions) |v| {
        if (std.mem.eql(u8, v.version, want)) {
            chosen = v;
            break;
        }
    }
    const cv = chosen orelse {
        try printStderr(io, "qube add: version '{s}' of '{s}' not found\n", .{ want, name });
        std.process.exit(@intFromEnum(ExitCode.dependency));
    };

    // Download the archive into the cache, verifying the SHA-256.
    const home = try qubeHome(gpa, env);
    defer gpa.free(home);
    const cache_root = try std.fs.path.join(gpa, &.{ home, "cache" });
    defer gpa.free(cache_root);
    try std.Io.Dir.cwd().createDirPath(io, cache_root);
    const tmp_zip = try std.fmt.allocPrint(gpa, "{s}/{s}.part", .{ cache_root, cv.archive_sha });
    defer gpa.free(tmp_zip);

    const archive_url = try std.fmt.allocPrint(gpa, "{s}/v1/qubes/{s}/{s}/archive", .{ registry, name, cv.version });
    defer gpa.free(archive_url);
    const dl_status = try httpGetToFile(gpa, io, archive_url, tmp_zip);
    if (dl_status != 200) {
        try printStderr(io, "qube add: archive download returned {d}\n", .{dl_status});
        std.process.exit(@intFromEnum(ExitCode.registry));
    }

    const got_sha = try sha256HexOfFile(gpa, io, tmp_zip);
    defer gpa.free(got_sha);
    if (!std.mem.eql(u8, got_sha, cv.archive_sha)) {
        try printStderr(io, "qube add: archive SHA-256 mismatch\n  expected {s}\n  got      {s}\n", .{ cv.archive_sha, got_sha });
        std.process.exit(@intFromEnum(ExitCode.dependency));
    }

    // Extract to cache/sha256/<ab>/<cd>/<digest>/ (spec/qube-cli.md).
    const cache_dir = try std.fmt.allocPrint(gpa, "{s}/sha256/{s}/{s}/{s}", .{ cache_root, cv.archive_sha[0..2], cv.archive_sha[2..4], cv.archive_sha });
    defer gpa.free(cache_dir);
    {
        const argv = [_][]const u8{ "sh", "-c", extract_script, "sh", tmp_zip, cache_dir };
        const term = try spawnInherit(io, &argv);
        if (termCode(term) != 0) {
            try writeStderr(io, "qube add: extracting the archive failed\n");
            std.process.exit(@intFromEnum(ExitCode.internal));
        }
    }
    std.Io.Dir.cwd().deleteFile(io, tmp_zip) catch {};

    // Insert the dependency into the manifest.
    try insertDependency(gpa, io, manifest_path, name, cv.version);

    try printStdout(io, "Added {s}@{s}\n  cached at {s}\n", .{ name, cv.version, cache_dir });
}

/// Add `"<name>": "^<major>.<minor>"` to the manifest's `dependencies` map,
/// preserving the surrounding JSON5. v0 text-edits rather than reformatting.
fn insertDependency(
    gpa: std.mem.Allocator,
    io: std.Io,
    manifest_path: []const u8,
    name: []const u8,
    version: []const u8,
) !void {
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, manifest_path, gpa, .limited(1024 * 1024));
    defer gpa.free(raw);

    const quoted = try std.fmt.allocPrint(gpa, "\"{s}\"", .{name});
    defer gpa.free(quoted);
    if (std.mem.indexOf(u8, raw, quoted) != null) {
        try printStdout(io, "qube add: '{s}' is already referenced in the manifest; cache updated, manifest left as-is\n", .{name});
        return;
    }

    // Caret spec from major.minor.
    var spec_buf: [80]u8 = undefined;
    const ver_spec = blk: {
        const d1 = std.mem.indexOfScalar(u8, version, '.') orelse break :blk version;
        const d2 = std.mem.indexOfScalarPos(u8, version, d1 + 1, '.') orelse version.len;
        break :blk std.fmt.bufPrint(&spec_buf, "{s}", .{version[0..d2]}) catch version;
    };

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    if (std.mem.indexOf(u8, raw, "\"dependencies\"")) |dep_key| {
        // Insert right after the block's opening brace.
        const brace = std.mem.indexOfScalarPos(u8, raw, dep_key, '{') orelse return error.MalformedManifest;
        try out.appendSlice(gpa, raw[0 .. brace + 1]);
        try out.print(gpa, "\n    \"{s}\": \"^{s}\",", .{ name, ver_spec });
        try out.appendSlice(gpa, raw[brace + 1 ..]);
    } else {
        // No dependencies block: add one before the manifest's closing brace.
        const close = std.mem.lastIndexOfScalar(u8, raw, '}') orelse return error.MalformedManifest;
        try out.appendSlice(gpa, raw[0..close]);
        try out.print(gpa, "  \"dependencies\": {{\n    \"{s}\": \"^{s}\",\n  }},\n", .{ name, ver_spec });
        try out.appendSlice(gpa, raw[close..]);
    }

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = manifest_path, .data = out.items });
}

fn stripScheme(url: []const u8) []const u8 {
    if (std.mem.startsWith(u8, url, "https://")) return url[8..];
    if (std.mem.startsWith(u8, url, "http://")) return url[7..];
    return url;
}

fn readStdinLineAlloc(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    var buf: [4096]u8 = undefined;
    var r = std.Io.File.stdin().reader(io, &buf);
    // The pinned zig returns a slice into the reader's buffer; copy it out so
    // the caller owns it. Strip a trailing \r for CRLF terminals.
    const line = try r.interface.takeDelimiterExclusive('\n');
    const trimmed = if (line.len > 0 and line[line.len - 1] == '\r')
        line[0 .. line.len - 1]
    else
        line;
    return gpa.dupe(u8, trimmed);
}

// POSIX-only: disable terminal echo while reading the password.
fn readPasswordSilent(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    const fd = std.posix.STDIN_FILENO;
    const old = std.posix.tcgetattr(fd) catch {
        // Not a TTY (piped input, CI without QUBE_PASSWORD). Read plainly.
        return try readStdinLineAlloc(gpa, io);
    };
    var new = old;
    new.lflag.ECHO = false;
    new.lflag.ECHONL = true;
    std.posix.tcsetattr(fd, .FLUSH, new) catch {};
    defer std.posix.tcsetattr(fd, .FLUSH, old) catch {};
    return try readStdinLineAlloc(gpa, io);
}
