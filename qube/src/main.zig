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
const resolve = @import("resolve.zig");
const json5 = @import("json5.zig");
const deploy_manifest = @import("deploy_manifest.zig");
const dispatch = @import("dispatch.zig");

test {
    // Pull the shared wasm-safe cores into `zig build test`.
    _ = resolve;
    _ = json5;
    _ = dispatch;
}

const version_string = "qube 0.0.8 (pre-alpha)";

// Emitted by the QUBE_FORCE_ICE test seam (see main). A single-line diagnostic
// envelope matching spec/diagnostics.md §"ICE convention".
const ice_envelope =
    \\{"ok":false,"diagnostics":[{"code":"Q9001","severity":"internal","kind":"ice","message":"forced internal error (QUBE_FORCE_ICE)","repair":{"id":"report-upstream","safety":"n/a","report_url":"https://docs.q64.dev/diagnostics/Q9001"}}]}
;

// Kept in sync with q64/src/main.zig's `--version` output. The `qube web`
// debug page surfaces it; a future revision will capture it dynamically
// via `q64 --version`.
const q64_version_string = "q64 0.0.8 (pre-alpha)";

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

    // iterateAllocator (not iterate) so this compiles on Windows, where
    // decoding the UTF-16 command line into argv needs an allocator. POSIX
    // ignores the allocator; the process exits right after, so we don't deinit.
    var args_it = try init.minimal.args.iterateAllocator(gpa);
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

    if (std.mem.eql(u8, sub, "lock")) {
        cmdLock(gpa, io, env, &args_it) catch |err| {
            try printStderr(io, "qube: lock failed: {s}\n", .{@errorName(err)});
            std.process.exit(@intFromEnum(ExitCode.internal));
        };
        return;
    }

    if (std.mem.eql(u8, sub, "install")) {
        cmdInstall(gpa, io, env, &args_it) catch |err| {
            try printStderr(io, "qube: install failed: {s}\n", .{@errorName(err)});
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

    if (std.mem.eql(u8, sub, "new")) {
        scaffoldQubeCmd(gpa, io, &args_it, false) catch |err| {
            try printStderr(io, "qube: new failed: {s}\n", .{@errorName(err)});
            std.process.exit(@intFromEnum(ExitCode.internal));
        };
        return;
    }

    if (std.mem.eql(u8, sub, "init")) {
        scaffoldQubeCmd(gpa, io, &args_it, true) catch |err| {
            try printStderr(io, "qube: init failed: {s}\n", .{@errorName(err)});
            std.process.exit(@intFromEnum(ExitCode.internal));
        };
        return;
    }

    if (std.mem.eql(u8, sub, "deploy")) {
        cmdDeploy(gpa, io, env, &args_it) catch |err| {
            try printStderr(io, "qube: deploy failed: {s}\n", .{@errorName(err)});
            std.process.exit(@intFromEnum(ExitCode.internal));
        };
        return;
    }

    if (std.mem.eql(u8, sub, "pod")) {
        cmdPod(gpa, io, env, &args_it) catch |err| {
            try printStderr(io, "qube: pod failed: {s}\n", .{@errorName(err)});
            std.process.exit(@intFromEnum(ExitCode.internal));
        };
        return;
    }

    if (std.mem.eql(u8, sub, "build")) {
        cmdBuild(gpa, io, env, &args_it) catch |err| {
            try printStderr(io, "qube: build failed: {s}\n", .{@errorName(err)});
            std.process.exit(@intFromEnum(ExitCode.internal));
        };
        return;
    }

    if (std.mem.eql(u8, sub, "wit")) {
        cmdWit(gpa, io, env, &args_it) catch |err| {
            try printStderr(io, "qube: wit failed: {s}\n", .{@errorName(err)});
            std.process.exit(@intFromEnum(ExitCode.internal));
        };
        return;
    }

    if (std.mem.eql(u8, sub, "wac")) {
        cmdWac(gpa, io, env, &args_it) catch |err| {
            try printStderr(io, "qube: wac failed: {s}\n", .{@errorName(err)});
            std.process.exit(@intFromEnum(ExitCode.internal));
        };
        return;
    }

    if (std.mem.eql(u8, sub, "webgpu") or std.mem.eql(u8, sub, "gpu")) {
        // WebGPU is a browser capability (navigator.gpu) — the native CLI has no
        // GPU surface, so the probe lives on-device. Same command name, so the
        // surface matches the shell (dispatch.zig owns the on-device routing).
        try writeStdout(io, "qube webgpu: WebGPU is a browser capability — run `qube webgpu` in the Qubonaut web shell.\n");
        return;
    }

    // Documented subcommands that are not implemented yet. Listed
    // explicitly so unknown names still hit the usage fallback.
    const stub_subs = [_][]const u8{
        "remove", "test",  "outdated",
        "audit",  "clean", "explain",
        "fix",    "fmt",   "workspace",
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
        \\  new [name] [flags]      Scaffold a new qube in a new directory (wizard if no flags).
        \\  init [flags]            Scaffold a qube in the current directory (wizard if no flags).
        \\  deploy [flags]          Deploy this qube to qubepods (reads qube.json5). Same command in the web shell and a terminal.
        \\  pod login [--token <t>] Save a qubepods token (minted in the console) for deploys.
        \\  pod info                Show the qubepods provider, API origin, and auth status.
        \\  pod logout              Remove the saved qubepods token.
        \\  build [--component] [--addr wasm32|wasm64] [--release]
        \\                          Compile the qube to wasm under target/<profile>/<addr>/.
        \\  run                     Build and run the qube in the current directory.
        \\  web                     Build the qube to wasm and serve it in a browser.
        \\  add <name>[@version]    Resolve a dependency from the Continuum and add it.
        \\  lock                    Resolve manifest dependencies and write qube.lock.
        \\  install [--offline]     Fetch locked dependencies into the cache (relocks if stale).
        \\  publish                 Pack this qube and publish it to the Continuum.
        \\  wit <show|extract|check|diff|import>
        \\                          Inspect WIT worlds: this qube's contract, a component's
        \\                          embedded world, surface↔manifest agreement, version diffs,
        \\                          and a foreign .wit's q64 bindings.
        \\  wac plug <socket> --plug <dep> -o <out>
        \\                          Link components — satisfy a socket's imports with a plug's
        \\                          exports (link at build). `wac compose <file.wac>` for graphs.
        \\  login                   Authenticate against the Continuum registry.
        \\  --version, -v           Print the version and exit.
        \\  --help, -h              Print this help and exit.
        \\
        \\Other subcommands from the spec (remove, test,
        \\fix, explain, fmt, workspace, ...) are not implemented yet.
        \\
    );
}

fn writeStdout(io: std.Io, text: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(io, &buf);
    try w.interface.writeAll(text);
    try w.interface.flush();
}

fn writeStderr(io: std.Io, text: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(io, &buf);
    try w.interface.writeAll(text);
    try w.interface.flush();
}

fn printStderr(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(io, &buf);
    try w.interface.print(fmt, args);
    try w.interface.flush();
}

// ---------------------------------------------------------------------------
// qube run
// ---------------------------------------------------------------------------


// ---------------------------------------------------------------------------
// qube.lock (spec/qube.lock.md)
// ---------------------------------------------------------------------------

const lock_file_name = "qube.lock";

const LockEntry = struct {
    name: []const u8,
    version: []const u8,
    source: []const u8,
    sha256: ?[]const u8 = null,
    effects: []const []const u8 = &.{},
    dependencies: []const []const u8 = &.{},
};

const LockFile = struct {
    version: i64 = 1,
    qubes: []LockEntry = &.{},
};

/// Serialize lock entries to the deterministic strict-JSON form the spec
/// pins: sorted by name, two-space indent, fixed field order, trailing
/// newline. Field values come from validated names / semvers / URLs /
/// manifest paths, so no JSON string escaping is applied. Caller owns
/// the returned buffer.
fn renderLockFile(gpa: std.mem.Allocator, entries: []const LockEntry) ![]u8 {
    const sorted = try gpa.dupe(LockEntry, entries);
    defer gpa.free(sorted);
    std.mem.sort(LockEntry, sorted, {}, struct {
        fn lt(_: void, a: LockEntry, b: LockEntry) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lt);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "{\n  \"version\": 1,\n  \"qubes\": [");
    for (sorted, 0..) |e, idx| {
        if (idx > 0) try out.append(gpa, ',');
        try out.appendSlice(gpa, "\n    {\n");
        try out.print(gpa, "      \"name\": \"{s}\",\n", .{e.name});
        try out.print(gpa, "      \"version\": \"{s}\",\n", .{e.version});
        try out.print(gpa, "      \"source\": \"{s}\"", .{e.source});
        if (e.sha256) |sha| try out.print(gpa, ",\n      \"sha256\": \"{s}\"", .{sha});
        if (e.effects.len > 0) {
            try out.appendSlice(gpa, ",\n      \"effects\": [");
            for (e.effects, 0..) |eff, i| {
                if (i > 0) try out.appendSlice(gpa, ", ");
                try out.print(gpa, "\"{s}\"", .{eff});
            }
            try out.append(gpa, ']');
        }
        if (e.dependencies.len > 0) {
            try out.appendSlice(gpa, ",\n      \"dependencies\": [");
            for (e.dependencies, 0..) |d, i| {
                if (i > 0) try out.appendSlice(gpa, ", ");
                try out.print(gpa, "\"{s}\"", .{d});
            }
            try out.append(gpa, ']');
        }
        try out.appendSlice(gpa, "\n    }");
    }
    if (sorted.len > 0) try out.appendSlice(gpa, "\n  ");
    try out.appendSlice(gpa, "]\n}\n");
    return out.toOwnedSlice(gpa);
}

/// Read and parse `<project_dir>/qube.lock`. Returns null when the file
/// does not exist; `error.MalformedLockfile` (PKG013) when it is not
/// valid JSON or its format version is unknown.
fn readLockFile(gpa: std.mem.Allocator, io: std.Io, project_dir: []const u8) !?std.json.Parsed(LockFile) {
    const path = try std.fs.path.join(gpa, &.{ project_dir, lock_file_name });
    defer gpa.free(path);
    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer gpa.free(raw);
    // `raw` dies with this frame, so the parse must copy every string.
    const parsed = std.json.parseFromSlice(LockFile, gpa, raw, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.MalformedLockfile;
    if (parsed.value.version != 1) {
        parsed.deinit();
        return error.MalformedLockfile;
    }
    return parsed;
}

fn writeLockFileEntries(gpa: std.mem.Allocator, io: std.Io, project_dir: []const u8, entries: []const LockEntry) !void {
    const rendered = try renderLockFile(gpa, entries);
    defer gpa.free(rendered);
    const path = try std.fs.path.join(gpa, &.{ project_dir, lock_file_name });
    defer gpa.free(path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = rendered });
}

/// Replace-or-append one entry in the project's lockfile (creating the
/// file if absent), preserving every other entry.
fn upsertLockEntry(gpa: std.mem.Allocator, io: std.Io, project_dir: []const u8, new_entry: LockEntry) !void {
    const maybe = try readLockFile(gpa, io, project_dir);
    defer if (maybe) |p| p.deinit();

    var entries: std.ArrayList(LockEntry) = .empty;
    defer entries.deinit(gpa);
    if (maybe) |p| {
        for (p.value.qubes) |e| {
            if (!std.mem.eql(u8, e.name, new_entry.name)) try entries.append(gpa, e);
        }
    }
    try entries.append(gpa, new_entry);
    try writeLockFileEntries(gpa, io, project_dir, entries.items);
}

/// Extracted-archive cache directory for a locked digest:
/// `<home>/cache/sha256/<ab>/<cd>/<digest>` (spec/qube-cli.md §cache).
fn cacheDirForSha(gpa: std.mem.Allocator, home: []const u8, sha: []const u8) ![]u8 {
    if (sha.len < 4) return error.MalformedLockfile;
    return std.fmt.allocPrint(gpa, "{s}/cache/sha256/{s}/{s}/{s}", .{ home, sha[0..2], sha[2..4], sha });
}

const Semver = struct { major: u64, minor: u64, patch: u64 };

/// Parse `maj[.min[.pat]]`, ignoring any prerelease / build suffix.
fn parseSemver(s: []const u8) ?Semver {
    var core = s;
    if (std.mem.indexOfAny(u8, s, "-+")) |i| core = s[0..i];
    var it = std.mem.splitScalar(u8, core, '.');
    const major = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
    const minor = std.fmt.parseInt(u64, it.next() orelse "0", 10) catch return null;
    const patch = std.fmt.parseInt(u64, it.next() orelse "0", 10) catch return null;
    if (it.next() != null) return null;
    return .{ .major = major, .minor = minor, .patch = patch };
}

fn semverGte(a: Semver, b: Semver) bool {
    if (a.major != b.major) return a.major > b.major;
    if (a.minor != b.minor) return a.minor > b.minor;
    return a.patch >= b.patch;
}

/// The v0 range forms (spec/qube.lock.md §"v0 resolver floor"): caret
/// (`^0.3`, `^1.2.3` — compatible-and-at-least) and exact (`0.3.2`).
fn versionSatisfies(spec: []const u8, version: []const u8) bool {
    const v = parseSemver(version) orelse return false;
    if (spec.len > 0 and spec[0] == '^') {
        const base = parseSemver(spec[1..]) orelse return false;
        if (v.major != base.major) return false;
        if (base.major == 0 and v.minor != base.minor) return false;
        return semverGte(v, base);
    }
    const base = parseSemver(spec) orelse return false;
    return v.major == base.major and v.minor == base.minor and v.patch == base.patch;
}

test "versionSatisfies: caret and exact forms" {
    try std.testing.expect(versionSatisfies("^0.3", "0.3.0"));
    try std.testing.expect(versionSatisfies("^0.3", "0.3.7"));
    try std.testing.expect(!versionSatisfies("^0.3", "0.4.0")); // 0.x: minor is breaking
    try std.testing.expect(versionSatisfies("^1.2", "1.9.0"));
    try std.testing.expect(!versionSatisfies("^1.2", "2.0.0"));
    try std.testing.expect(!versionSatisfies("^1.2", "1.1.9")); // below base
    try std.testing.expect(versionSatisfies("0.3.2", "0.3.2"));
    try std.testing.expect(!versionSatisfies("0.3.2", "0.3.3"));
    try std.testing.expect(versionSatisfies("^1.2.3", "1.2.3-rc.1")); // prerelease ignored
    try std.testing.expect(!versionSatisfies("^0.3", "junk"));
}

test "renderLockFile: deterministic, sorted, parseable" {
    const gpa = std.testing.allocator;
    const entries = [_]LockEntry{
        .{ .name = "dev.q64.zeta", .version = "0.1.0", .source = "path+../zeta" },
        .{
            .name = "dev.q64.audio",
            .version = "0.3.2",
            .source = "registry+https://qubes.q64.dev",
            .sha256 = "ab12cd34",
            .effects = &.{ "@audio", "@io" },
        },
    };
    const rendered = try renderLockFile(gpa, &entries);
    defer gpa.free(rendered);

    const expected =
        \\{
        \\  "version": 1,
        \\  "qubes": [
        \\    {
        \\      "name": "dev.q64.audio",
        \\      "version": "0.3.2",
        \\      "source": "registry+https://qubes.q64.dev",
        \\      "sha256": "ab12cd34",
        \\      "effects": ["@audio", "@io"]
        \\    },
        \\    {
        \\      "name": "dev.q64.zeta",
        \\      "version": "0.1.0",
        \\      "source": "path+../zeta"
        \\    }
        \\  ]
        \\}
        \\
    ;
    try std.testing.expectEqualStrings(expected, rendered);

    // Round-trip through the reader's parse.
    const parsed = try std.json.parseFromSlice(LockFile, gpa, rendered, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.qubes.len);
    try std.testing.expectEqualStrings("dev.q64.audio", parsed.value.qubes[0].name);
    try std.testing.expectEqualStrings("ab12cd34", parsed.value.qubes[0].sha256.?);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.qubes[0].effects.len);
    try std.testing.expect(parsed.value.qubes[1].sha256 == null);
}

test "renderLockFile: empty graph" {
    const gpa = std.testing.allocator;
    const rendered = try renderLockFile(gpa, &.{});
    defer gpa.free(rendered);
    try std.testing.expectEqualStrings("{\n  \"version\": 1,\n  \"qubes\": []\n}\n", rendered);
}

/// Read a top-level string field from a parsed manifest object.
fn manifestString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// Read a string field from a nested object field (`obj.outer.key`). Used for
/// the `wit` / `component` manifest blocks.
fn manifestNestedString(obj: std.json.ObjectMap, outer: []const u8, key: []const u8) ?[]const u8 {
    const o = obj.get(outer) orelse return null;
    return switch (o) {
        .object => |inner| manifestString(inner, key),
        else => null,
    };
}

/// The qube's WIT world name (WIT rung 2): `wit.world`, else `component.world`,
/// else the last dotted segment of the qube name (`dev.q64.math` → `math`).
fn resolveWorldName(root: std.json.ObjectMap, name: []const u8) []const u8 {
    if (manifestNestedString(root, "wit", "world")) |w| return w;
    if (manifestNestedString(root, "component", "world")) |w| return w;
    return lastDottedSegment(name);
}

/// The qube's WIT package id: `wit.package`, else derived from the qube name —
/// namespace = the dotted prefix with `.`→`-`, package = the last segment
/// (`dev.q64.math` → `dev-q64:math`). A single-segment name has no namespace,
/// so it falls back to `q64:<name>` (workspace roots aren't publishable). The
/// returned slice is allocated from `gpa` (caller frees) unless it aliases the
/// manifest (`wit.package`), so callers should treat it as borrowed-or-owned —
/// here we always allocate a copy for a uniform free.
fn resolveWitPackage(gpa: std.mem.Allocator, root: std.json.ObjectMap, name: []const u8) ![]u8 {
    if (manifestNestedString(root, "wit", "package")) |p| return gpa.dupe(u8, p);
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return std.fmt.allocPrint(gpa, "q64:{s}", .{name});
    const ns = try gpa.alloc(u8, dot);
    for (name[0..dot], 0..) |ch, i| ns[i] = if (ch == '.') '-' else ch;
    defer gpa.free(ns);
    return std.fmt.allocPrint(gpa, "{s}:{s}", .{ ns, name[dot + 1 ..] });
}

/// The qube's foreign WIT imports (WIT rung 5): the `wit.imports` array of
/// relative `.wit` paths, each resolved to an absolute path under the project
/// dir. Returns an owned list of owned strings.
fn resolveWitImports(gpa: std.mem.Allocator, root: std.json.ObjectMap, project_dir: []const u8) !std.ArrayList([]u8) {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |w| gpa.free(w);
        out.deinit(gpa);
    }
    const wit = root.get("wit") orelse return out;
    const wobj = switch (wit) {
        .object => |o| o,
        else => return out,
    };
    const imports = wobj.get("imports") orelse return out;
    const arr = switch (imports) {
        .array => |a| a,
        else => return out,
    };
    for (arr.items) |item| {
        const rel = switch (item) {
            .string => |s| s,
            else => continue,
        };
        try out.append(gpa, try std.fs.path.join(gpa, &.{ project_dir, rel }));
    }
    return out;
}

/// The last `.`-separated segment of a dotted qube name.
fn lastDottedSegment(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| return name[dot + 1 ..];
    return name;
}

/// Resolve a dependency's entry **source file** from ITS OWN manifest
/// (`<dep_root>/qube.json5`): the `entry` field, defaulting per type (library →
/// `src/lib.q`, application → `src/main.q`). The manifest is authoritative — the
/// consumer reads it, exactly as `package.json`'s `main` / Cargo's `[lib] path`
/// work — so a library that overrides its entry still links. Returns
/// `<dep_root>/<entry>` (caller owns). A dependency with no readable manifest
/// falls back to the library default `src/lib.q`.
fn depEntryFile(gpa: std.mem.Allocator, io: std.Io, dep_root: []const u8) ![]u8 {
    const manifest_path = try std.fs.path.join(gpa, &.{ dep_root, "qube.json5" });
    defer gpa.free(manifest_path);

    var owned_entry: ?[]u8 = null;
    defer if (owned_entry) |b| gpa.free(b);
    const entry_rel: []const u8 = blk: {
        const src = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, gpa, .limited(1 * 1024 * 1024)) catch break :blk resolve.DEFAULT_LIB_ENTRY;
        defer gpa.free(src);
        const json = json5.toJson(gpa, src) catch break :blk resolve.DEFAULT_LIB_ENTRY;
        defer gpa.free(json);
        const parsed = std.json.parseFromSlice(std.json.Value, gpa, json, .{}) catch break :blk resolve.DEFAULT_LIB_ENTRY;
        defer parsed.deinit();
        const root = switch (parsed.value) {
            .object => |o| o,
            else => break :blk resolve.DEFAULT_LIB_ENTRY,
        };
        const is_lib = !std.mem.eql(u8, manifestString(root, "type") orelse "library", "application");
        // `entryOf` may return a slice into `parsed`; dupe it so it outlives the deinit.
        owned_entry = try gpa.dupe(u8, resolve.entryOf(manifestString(root, "entry"), is_lib));
        break :blk owned_entry.?;
    };
    return std.fs.path.join(gpa, &.{ dep_root, entry_rel });
}

/// Resolve the manifest's `dependencies` map into `name=file` strings for
/// `q64 emit --module`. A local-path dependency resolves to its declared entry
/// file under `<dep-path>/` (via `depEntryFile`), made absolute. A registry
/// dependency (a version-range string) resolves only through `qube.lock`
/// (spec/qube.lock.md): the locked sha256 names the extracted cache directory —
/// the build path never touches the network — and its entry comes from the
/// cached manifest the same way. Caller owns each returned string and the list.
fn resolveModuleSpecs(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
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

    // The lockfile is read lazily: a path-only project never needs one.
    var lock: ?std.json.Parsed(LockFile) = null;
    defer if (lock) |p| p.deinit();
    var lock_loaded = false;

    var it = deps.iterator();
    while (it.next()) |entry| {
        const dep_name = entry.key_ptr.*;
        switch (entry.value_ptr.*) {
            .object => |o| {
                const p = manifestString(o, "path") orelse {
                    try printStderr(io, "qube: dependency '{s}' has no `path`; v0 resolves `path` and locked registry deps\n", .{dep_name});
                    return error.UnsupportedDependency;
                };
                // The dependency's entry file, from ITS manifest (default
                // src/lib.q), made absolute. The manifest is authoritative.
                const dep_root = try std.fs.path.resolve(gpa, &.{ project_dir, p });
                defer gpa.free(dep_root);
                const entry_file = try depEntryFile(gpa, io, dep_root);
                defer gpa.free(entry_file);
                const spec = try std.fmt.allocPrint(gpa, "{s}={s}", .{ dep_name, entry_file });
                try specs.append(gpa, spec);
            },
            .string => |range| {
                if (!lock_loaded) {
                    lock_loaded = true;
                    lock = readLockFile(gpa, io, project_dir) catch |err| switch (err) {
                        error.MalformedLockfile => {
                            try writeStderr(io, "qube: PKG013: qube.lock is malformed or has an unsupported version; run `qube lock`\n");
                            return error.MalformedLockfile;
                        },
                        else => return err,
                    };
                }
                const locked: ?LockEntry = blk: {
                    const l = lock orelse break :blk null;
                    for (l.value.qubes) |e| {
                        if (std.mem.eql(u8, e.name, dep_name)) break :blk e;
                    }
                    break :blk null;
                };
                const e = locked orelse {
                    try printStderr(io, "qube: PKG010: dependency '{s}' is not locked; run `qube lock` (or `qube add {s}`)\n", .{ dep_name, dep_name });
                    return error.DependencyNotLocked;
                };
                if (!versionSatisfies(range, e.version)) {
                    try printStderr(io, "qube: PKG011: locked '{s}@{s}' does not satisfy the manifest range '{s}'; run `qube lock`\n", .{ dep_name, e.version, range });
                    return error.LockedVersionMismatch;
                }
                const sha = e.sha256 orelse {
                    try printStderr(io, "qube: PKG011: '{s}' is locked from a path source but the manifest declares a registry range; run `qube lock`\n", .{dep_name});
                    return error.LockedVersionMismatch;
                };
                const home = try qubeHome(gpa, env);
                defer gpa.free(home);
                const cache_dir = try cacheDirForSha(gpa, home, sha);
                defer gpa.free(cache_dir);
                std.Io.Dir.cwd().access(io, cache_dir, .{}) catch {
                    try printStderr(io, "qube: PKG012: locked archive for '{s}@{s}' is not in the cache ({s}); run `qube add {s}@{s}`\n", .{ dep_name, e.version, cache_dir, dep_name, e.version });
                    return error.LockedArchiveMissing;
                };
                // The cached qube's entry file, from its manifest (default
                // src/lib.q) — the Continuum archive carries its own qube.json5.
                const entry_file = try depEntryFile(gpa, io, cache_dir);
                defer gpa.free(entry_file);
                const spec = try std.fmt.allocPrint(gpa, "{s}={s}", .{ dep_name, entry_file });
                try specs.append(gpa, spec);
            },
            else => {
                try printStderr(io, "qube: dependency '{s}' has an unsupported value shape\n", .{dep_name});
                return error.UnsupportedDependency;
            },
        }
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

    const json = json5.toJson(gpa, manifest_src) catch |err| {
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
    const entry_rel = resolve.entryOf(manifestString(root, "entry"), false);
    const entry_path = try std.fs.path.join(gpa, &.{ project_dir, entry_rel });
    defer gpa.free(entry_path);

    // Resolve dependencies → `--module name=dir` specs (ladder step 4).
    var module_specs = resolveModuleSpecs(gpa, io, env, project_dir, root) catch |err| {
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

/// `qube build [--component] [--addr wasm32|wasm64] [--release]` — compile the
/// qube to wasm (spec/qube-cli.md §build). Delegates to `q64 emit`, placing the
/// core module at `target/<profile>/<addr>/<name>.wasm`; with `--component`
/// (or `component.emit: true`) also wraps it in a component
/// (`<name>.component.wasm`) via `q64 emit --component`. Unlike `run`, this
/// builds libraries as well as applications and does not execute the result.
fn cmdBuild(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    args_it: *std.process.Args.Iterator,
) !void {
    var want_component = false;
    var addr: []const u8 = "wasm64"; // q64 emit's default; --addr overrides
    var profile: []const u8 = "debug";
    while (args_it.next()) |a| {
        if (std.mem.eql(u8, a, "--component")) {
            want_component = true;
        } else if (std.mem.eql(u8, a, "--release")) {
            profile = "release";
        } else if (std.mem.eql(u8, a, "--debug")) {
            profile = "debug";
        } else if (std.mem.eql(u8, a, "--addr")) {
            const v = args_it.next() orelse {
                try writeStderr(io, "qube build: --addr expects wasm32 or wasm64\n");
                std.process.exit(@intFromEnum(ExitCode.usage));
            };
            if (!std.mem.eql(u8, v, "wasm32") and !std.mem.eql(u8, v, "wasm64")) {
                try printStderr(io, "qube build: --addr expects wasm32 or wasm64, got '{s}'\n", .{v});
                std.process.exit(@intFromEnum(ExitCode.usage));
            }
            addr = v;
        } else {
            try printStderr(io, "qube build: ignoring unrecognised arg in v0: {s}\n", .{a});
        }
    }

    // Discover + parse qube.json5 (same front as `run`).
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
    const json = json5.toJson(gpa, manifest_src) catch |err| {
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
    // `component.emit: true` in the manifest turns component emission on; the
    // `--component` flag overrides (per qube-cli.md).
    if (!want_component) {
        if (root.get("component")) |comp| switch (comp) {
            .object => |co| if (co.get("emit")) |e| switch (e) {
                .bool => |bv| want_component = bv,
                else => {},
            },
            else => {},
        };
    }

    // A library defaults its entry to src/lib.q; an application to src/main.q.
    const type_str = manifestString(root, "type");
    const is_lib = if (type_str) |t| std.mem.eql(u8, t, "library") else false;
    const entry_rel = resolve.entryOf(manifestString(root, "entry"), is_lib);
    const entry_path = try std.fs.path.join(gpa, &.{ project_dir, entry_rel });
    defer gpa.free(entry_path);

    var module_specs = resolveModuleSpecs(gpa, io, env, project_dir, root) catch |err| {
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

    // Build output: target/<profile>/<addr>/<name>.wasm (qube-cli.md §"Build outputs").
    const out_dir = try std.fs.path.join(gpa, &.{ project_dir, "target", profile, addr });
    defer gpa.free(out_dir);
    try std.Io.Dir.cwd().createDirPath(io, out_dir);
    const wasm_name = try std.fmt.allocPrint(gpa, "{s}.wasm", .{name});
    defer gpa.free(wasm_name);
    const wasm_path = try std.fs.path.join(gpa, &.{ out_dir, wasm_name });
    defer gpa.free(wasm_path);

    // WIT rung 2: name the synthesized world + WIT package from the manifest
    // (`wit.world`/`wit.package`, defaulting from the qube name), so the
    // emitted `.wit` carries the qube's contract identity rather than the entry
    // filename (`src/lib.q` → `lib`). Only meaningful with `--component`.
    const world_name = resolveWorldName(root, name);
    const wit_package = try resolveWitPackage(gpa, root, name);
    defer gpa.free(wit_package);

    // WIT rung 5: foreign `.wit` packages this qube imports (`wit.imports` —
    // relative paths), declared in the emitted component so `wac` can link them.
    var wit_imports = try resolveWitImports(gpa, root, project_dir);
    defer {
        for (wit_imports.items) |w| gpa.free(w);
        wit_imports.deinit(gpa);
    }

    // `wit.interface`: export this library's surface as the named interface
    // `<wit.package>/<wit.interface>` (so a q64 consumer that imports it can be
    // `wac`-linked). Owned; null = bare-function exports.
    const export_interface: ?[]u8 = if (manifestNestedString(root, "wit", "interface")) |iface|
        try std.fmt.allocPrint(gpa, "{s}/{s}", .{ wit_package, iface })
    else
        null;
    defer if (export_interface) |e| gpa.free(e);

    // q64 emit <entry> <wasm> --addr <addr> [--module …] [--component --world … --wit-package … --wit-import … --export-interface …]
    {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ q64_bin, "emit", entry_path, wasm_path, "--addr", addr });
        for (module_specs.items) |spec| try argv.appendSlice(gpa, &.{ "--module", spec });
        if (want_component) {
            try argv.appendSlice(gpa, &.{ "--component", "--world", world_name, "--wit-package", wit_package });
            for (wit_imports.items) |w| try argv.appendSlice(gpa, &.{ "--wit-import", w });
            if (export_interface) |e| try argv.appendSlice(gpa, &.{ "--export-interface", e });
        }
        const term = try spawnInherit(io, argv.items);
        const code = termCode(term) orelse std.process.exit(@intFromEnum(ExitCode.compile));
        if (code != 0) std.process.exit(if (code == 1) @intFromEnum(ExitCode.compile) else code);
    }

    try printStderr(io, "qube: built {s}\n", .{wasm_path});
    if (want_component) {
        try printStderr(io, "qube: built {s}/{s}.component.wasm\n", .{ out_dir, name });
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
// qube wac — on-device component linker (link at build)
// ---------------------------------------------------------------------------
//
// `wac` is the WebAssembly Composition tool — the linker that satisfies one
// component's imports with another's exports, producing a single runnable
// component. `qube wac plug <socket> --plug <dep>` composes an application qube
// with the library qubes it imports; `qube wac compose <file.wac>` runs a `.wac`
// composition graph. It is the missing step between `qube build` (q64 →
// component, which now *declares* its foreign imports — WIT rung 5) and
// `qube run`.
//
// Engine: prefer the real `wac` (env `Q64_WAC`, else `vendor/wac/wac`, else
// `PATH`); fall back to the vendored `wasm-tools compose` (the documented
// fallback) for `plug`. The `.wac` graph language is wac-only.

/// Locate the `wac` binary if one is explicitly available (env or vendored). A
/// `null` result means: fall back to `wasm-tools compose`. Caller frees.
fn resolveWac(gpa: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, repo_root: ?[]const u8) !?[]u8 {
    if (env.get("Q64_WAC")) |v| {
        if (v.len > 0) return try gpa.dupe(u8, v);
    }
    if (repo_root) |root| {
        const candidate = try std.fs.path.join(gpa, &.{ root, "vendor/wac/wac" });
        std.Io.Dir.cwd().access(io, candidate, .{}) catch {
            gpa.free(candidate);
            return null;
        };
        return candidate;
    }
    return null;
}

fn cmdWac(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    args_it: *std.process.Args.Iterator,
) !void {
    const verb = args_it.next() orelse {
        try writeStderr(io, "usage: qube wac <plug|compose> [args]\n");
        std.process.exit(@intFromEnum(ExitCode.usage));
    };
    if (std.mem.eql(u8, verb, "plug")) return wacPlug(gpa, io, env, args_it);
    if (std.mem.eql(u8, verb, "compose")) return wacCompose(gpa, io, env, args_it);
    try printStderr(io, "qube wac: unknown verb '{s}' (plug|compose)\n", .{verb});
    std.process.exit(@intFromEnum(ExitCode.usage));
}

/// `qube wac plug <socket.wasm> --plug <p.wasm>… -o <out.wasm>` — satisfy the
/// socket's imports with the plugs' exports, writing one composed component.
fn wacPlug(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    args_it: *std.process.Args.Iterator,
) !void {
    var socket: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var plugs: std.ArrayList([]const u8) = .empty;
    defer plugs.deinit(gpa);
    while (args_it.next()) |a| {
        if (std.mem.eql(u8, a, "--plug")) {
            try plugs.append(gpa, args_it.next() orelse {
                try writeStderr(io, "qube wac plug: --plug needs a value\n");
                std.process.exit(@intFromEnum(ExitCode.usage));
            });
        } else if (std.mem.eql(u8, a, "-o") or std.mem.eql(u8, a, "--out")) {
            out_path = args_it.next() orelse {
                try writeStderr(io, "qube wac plug: -o needs a value\n");
                std.process.exit(@intFromEnum(ExitCode.usage));
            };
        } else if (std.mem.startsWith(u8, a, "-")) {
            try printStderr(io, "qube wac plug: unknown flag: {s}\n", .{a});
            std.process.exit(@intFromEnum(ExitCode.usage));
        } else if (socket == null) {
            socket = a;
        } else {
            try writeStderr(io, "qube wac plug: unexpected extra arg\n");
            std.process.exit(@intFromEnum(ExitCode.usage));
        }
    }
    const sock = socket orelse {
        try writeStderr(io, "usage: qube wac plug <socket.wasm> --plug <p.wasm>… -o <out.wasm>\n");
        std.process.exit(@intFromEnum(ExitCode.usage));
    };
    const out = out_path orelse {
        try writeStderr(io, "qube wac plug: -o <out.wasm> is required\n");
        std.process.exit(@intFromEnum(ExitCode.usage));
    };
    if (plugs.items.len == 0) {
        try writeStderr(io, "qube wac plug: at least one --plug is required\n");
        std.process.exit(@intFromEnum(ExitCode.usage));
    }

    const cwd_path = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd_path);
    const repo_root_opt = findRepoRoot(gpa, io, cwd_path) catch null;
    defer if (repo_root_opt) |r| gpa.free(r);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);

    const wac = try resolveWac(gpa, io, env, repo_root_opt);
    defer if (wac) |w| gpa.free(w);
    if (wac) |w| {
        // wac plug <socket> --plug <p>… -o <out>
        try argv.appendSlice(gpa, &.{ w, "plug", sock });
        for (plugs.items) |p| try argv.appendSlice(gpa, &.{ "--plug", p });
        try argv.appendSlice(gpa, &.{ "-o", out });
    } else {
        // Fallback: wasm-tools compose <socket> -d <plug>… -o <out>.
        const tools = try resolveBinary(gpa, io, env, "Q64_WASM_TOOLS", repo_root_opt, "vendor/wasm-tools/wasm-tools", "wasm-tools");
        defer gpa.free(tools);
        try argv.appendSlice(gpa, &.{ tools, "compose", sock });
        for (plugs.items) |p| try argv.appendSlice(gpa, &.{ "-d", p });
        try argv.appendSlice(gpa, &.{ "-o", out });
        const term = spawnInherit(io, argv.items) catch {
            try writeStderr(io, "qube wac plug: no composer found (set Q64_WAC or Q64_WASM_TOOLS, or run ./init.sh)\n");
            std.process.exit(@intFromEnum(ExitCode.internal));
        };
        const code = termCode(term) orelse 255;
        if (code != 0) std.process.exit(@intFromEnum(ExitCode.compile));
        try printStdout(io, "qube wac: linked {s} (wasm-tools compose)\n", .{out});
        return;
    }
    const term = spawnInherit(io, argv.items) catch {
        try writeStderr(io, "qube wac plug: failed to run wac\n");
        std.process.exit(@intFromEnum(ExitCode.internal));
    };
    const code = termCode(term) orelse 255;
    if (code != 0) std.process.exit(@intFromEnum(ExitCode.compile));
    try printStdout(io, "qube wac: linked {s} (wac plug)\n", .{out});
}

/// `qube wac compose <file.wac> [-o <out.wasm>]` — run a `.wac` composition
/// graph. wac-only (the `.wac` language has no wasm-tools equivalent).
fn wacCompose(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    args_it: *std.process.Args.Iterator,
) !void {
    var file: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    while (args_it.next()) |a| {
        if (std.mem.eql(u8, a, "-o") or std.mem.eql(u8, a, "--out")) {
            out_path = args_it.next() orelse {
                try writeStderr(io, "qube wac compose: -o needs a value\n");
                std.process.exit(@intFromEnum(ExitCode.usage));
            };
        } else if (std.mem.startsWith(u8, a, "-")) {
            try printStderr(io, "qube wac compose: unknown flag: {s}\n", .{a});
            std.process.exit(@intFromEnum(ExitCode.usage));
        } else if (file == null) {
            file = a;
        } else {
            try writeStderr(io, "qube wac compose: unexpected extra arg\n");
            std.process.exit(@intFromEnum(ExitCode.usage));
        }
    }
    const f = file orelse {
        try writeStderr(io, "usage: qube wac compose <file.wac> [-o <out.wasm>]\n");
        std.process.exit(@intFromEnum(ExitCode.usage));
    };

    const cwd_path = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd_path);
    const repo_root_opt = findRepoRoot(gpa, io, cwd_path) catch null;
    defer if (repo_root_opt) |r| gpa.free(r);
    const wac = (try resolveWac(gpa, io, env, repo_root_opt)) orelse {
        try writeStderr(io, "qube wac compose: the .wac graph language needs `wac` (set Q64_WAC or vendor it); `plug` works without it via wasm-tools compose\n");
        std.process.exit(@intFromEnum(ExitCode.internal));
    };
    defer gpa.free(wac);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ wac, "compose", f });
    if (out_path) |op| try argv.appendSlice(gpa, &.{ "-o", op });
    const term = spawnInherit(io, argv.items) catch {
        try writeStderr(io, "qube wac compose: failed to run wac\n");
        std.process.exit(@intFromEnum(ExitCode.internal));
    };
    const code = termCode(term) orelse 255;
    if (code != 0) std.process.exit(@intFromEnum(ExitCode.compile));
    if (out_path) |op| try printStdout(io, "qube wac: composed {s}\n", .{op});
}

// ---------------------------------------------------------------------------
// qube wit — first-class WIT contracts (WIT rung 4)
// ---------------------------------------------------------------------------
//
// Package-level WIT verbs (spec/qube-cli.md, spec/q64-cli.md §"q64 wit vs qube
// wit"): they resolve via the manifest + deps and call the compiler / wasm
// tooling, where `q64`'s primitives operate on a bare source file. `show`
// synthesizes this qube's world; `extract` pulls the embedded world from any
// component (any language) via wasm-tools; `check` confirms the source's
// synthesized world is well-formed and matches the manifest; `diff` reports
// breaking vs compatible changes between two worlds.

fn cmdWit(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    args_it: *std.process.Args.Iterator,
) !void {
    const verb = args_it.next() orelse {
        try writeStderr(io, "usage: qube wit <show|extract|check|diff> [args]\n");
        std.process.exit(@intFromEnum(ExitCode.usage));
    };
    if (std.mem.eql(u8, verb, "show")) return witShow(gpa, io, env, args_it);
    if (std.mem.eql(u8, verb, "extract")) return witExtract(gpa, io, env, args_it);
    if (std.mem.eql(u8, verb, "check")) return witCheck(gpa, io, env, args_it);
    if (std.mem.eql(u8, verb, "diff")) return witDiff(gpa, io, env, args_it);
    if (std.mem.eql(u8, verb, "import")) return witImport(gpa, io, env, args_it);
    try printStderr(io, "qube wit: unknown verb '{s}' (show|extract|check|diff|import)\n", .{verb});
    std.process.exit(@intFromEnum(ExitCode.usage));
}

/// Build the `q64 show world` argv for the current qube — entry, manifest-named
/// world/package, and `--module` deps. Caller owns every appended string and
/// the list. `q64_bin`/`world`/`package` are also owned (returned via out
/// params) so the caller frees them after the spawn.
const WorldInvocation = struct {
    argv: std.ArrayList([]const u8),
    q64_bin: []u8,
    entry: []u8,
    world: []u8,
    package: []u8,
    module_specs: std.ArrayList([]u8),

    fn deinit(self: *WorldInvocation, gpa: std.mem.Allocator) void {
        self.argv.deinit(gpa);
        gpa.free(self.q64_bin);
        gpa.free(self.entry);
        gpa.free(self.world);
        gpa.free(self.package);
        for (self.module_specs.items) |s| gpa.free(s);
        self.module_specs.deinit(gpa);
    }
};

fn buildWorldInvocation(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    m: *const LoadedManifest,
) !WorldInvocation {
    const project_dir = m.projectDir();
    const name = manifestString(m.root, "name") orelse {
        try writeStderr(io, "qube wit: manifest has no \"name\"\n");
        std.process.exit(@intFromEnum(ExitCode.input));
    };
    const type_str = manifestString(m.root, "type") orelse "library";
    const entry_rel = resolve.entryOf(manifestString(m.root, "entry"), !std.mem.eql(u8, type_str, "application"));
    const entry = try std.fs.path.join(gpa, &.{ project_dir, entry_rel });
    errdefer gpa.free(entry);

    const repo_root_opt = findRepoRoot(gpa, io, project_dir) catch null;
    defer if (repo_root_opt) |r| gpa.free(r);
    const q64_bin = try resolveBinary(gpa, io, env, "Q64_BIN", repo_root_opt, "q64/zig-out/bin/q64", "q64");
    errdefer gpa.free(q64_bin);

    const world = try gpa.dupe(u8, resolveWorldName(m.root, name));
    errdefer gpa.free(world);
    const package = try resolveWitPackage(gpa, m.root, name);
    errdefer gpa.free(package);

    var module_specs = try resolveModuleSpecs(gpa, io, env, project_dir, m.root);
    errdefer {
        for (module_specs.items) |s| gpa.free(s);
        module_specs.deinit(gpa);
    }

    // argv holds borrowed slices into this struct's owned fields, so it stays
    // valid for the lifetime of the WorldInvocation.
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ q64_bin, "show", "world", "--qube", entry, "--world", world, "--wit-package", package });
    for (module_specs.items) |spec| try argv.appendSlice(gpa, &.{ "--module", spec });
    return .{ .argv = argv, .q64_bin = q64_bin, .entry = entry, .world = world, .package = package, .module_specs = module_specs };
}

/// `qube wit show [--out <file>]` — synthesize and print this qube's world.
fn witShow(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    args_it: *std.process.Args.Iterator,
) !void {
    var out_path: ?[]const u8 = null;
    while (args_it.next()) |a| {
        if (std.mem.eql(u8, a, "--out")) {
            out_path = args_it.next() orelse {
                try writeStderr(io, "qube wit show: --out needs a value\n");
                std.process.exit(@intFromEnum(ExitCode.usage));
            };
        } else {
            try printStderr(io, "qube wit show: unknown arg: {s}\n", .{a});
            std.process.exit(@intFromEnum(ExitCode.usage));
        }
    }
    var m = try loadManifest(gpa, io);
    defer m.deinit(gpa);
    var inv = try buildWorldInvocation(gpa, io, env, &m);
    defer inv.deinit(gpa);
    if (out_path) |op| try inv.argv.appendSlice(gpa, &.{ "--out", op });
    const term = try spawnInherit(io, inv.argv.items);
    const code = termCode(term) orelse 255;
    if (code != 0) std.process.exit(if (code == 1) @intFromEnum(ExitCode.compile) else code);
}

/// `qube wit import <file.wit> [--out <file>]` — parse a foreign WIT package and
/// print its q64 binding preview (WIT rung 5, the consume direction). The
/// package-level wrapper over `q64 wit import` (the compiler owns the parser +
/// the WIT→q64 type mapping).
fn witImport(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    args_it: *std.process.Args.Iterator,
) !void {
    var input: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    while (args_it.next()) |a| {
        if (std.mem.eql(u8, a, "--out")) {
            out_path = args_it.next() orelse {
                try writeStderr(io, "qube wit import: --out needs a value\n");
                std.process.exit(@intFromEnum(ExitCode.usage));
            };
        } else if (std.mem.startsWith(u8, a, "-")) {
            try printStderr(io, "qube wit import: unknown flag: {s}\n", .{a});
            std.process.exit(@intFromEnum(ExitCode.usage));
        } else if (input == null) {
            input = a;
        } else {
            try writeStderr(io, "qube wit import: unexpected extra arg\n");
            std.process.exit(@intFromEnum(ExitCode.usage));
        }
    }
    const in = input orelse {
        try writeStderr(io, "usage: qube wit import <file.wit> [--out <file>]\n");
        std.process.exit(@intFromEnum(ExitCode.usage));
    };

    const cwd_path = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd_path);
    const repo_root_opt = findRepoRoot(gpa, io, cwd_path) catch null;
    defer if (repo_root_opt) |r| gpa.free(r);
    const q64_bin = try resolveBinary(gpa, io, env, "Q64_BIN", repo_root_opt, "q64/zig-out/bin/q64", "q64");
    defer gpa.free(q64_bin);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ q64_bin, "wit", "import", in });
    if (out_path) |op| try argv.appendSlice(gpa, &.{ "--out", op });
    const term = spawnInherit(io, argv.items) catch {
        try writeStderr(io, "qube wit import: q64 not found (set Q64_BIN or build q64)\n");
        std.process.exit(@intFromEnum(ExitCode.internal));
    };
    const code = termCode(term) orelse 255;
    if (code != 0) std.process.exit(if (code == 1) @intFromEnum(ExitCode.compile) else code);
}

/// `qube wit extract <component.wasm> [--out <file>]` — pull the embedded world
/// from any component via wasm-tools (any source language).
fn witExtract(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    args_it: *std.process.Args.Iterator,
) !void {
    var input: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    while (args_it.next()) |a| {
        if (std.mem.eql(u8, a, "--out")) {
            out_path = args_it.next() orelse {
                try writeStderr(io, "qube wit extract: --out needs a value\n");
                std.process.exit(@intFromEnum(ExitCode.usage));
            };
        } else if (std.mem.startsWith(u8, a, "-")) {
            try printStderr(io, "qube wit extract: unknown flag: {s}\n", .{a});
            std.process.exit(@intFromEnum(ExitCode.usage));
        } else if (input == null) {
            input = a;
        } else {
            try writeStderr(io, "qube wit extract: unexpected extra arg\n");
            std.process.exit(@intFromEnum(ExitCode.usage));
        }
    }
    const in = input orelse {
        try writeStderr(io, "usage: qube wit extract <component.wasm> [--out <file>]\n");
        std.process.exit(@intFromEnum(ExitCode.usage));
    };

    const cwd_path = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd_path);
    const repo_root_opt = findRepoRoot(gpa, io, cwd_path) catch null;
    defer if (repo_root_opt) |r| gpa.free(r);
    const tools = try resolveBinary(gpa, io, env, "Q64_WASM_TOOLS", repo_root_opt, "vendor/wasm-tools/wasm-tools", "wasm-tools");
    defer gpa.free(tools);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ tools, "component", "wit", in });
    if (out_path) |op| try argv.appendSlice(gpa, &.{ "-o", op });
    const term = spawnInherit(io, argv.items) catch {
        try writeStderr(io, "qube wit extract: wasm-tools not found (set Q64_WASM_TOOLS or run ./init.sh)\n");
        std.process.exit(@intFromEnum(ExitCode.internal));
    };
    const code = termCode(term) orelse 255;
    if (code != 0) std.process.exit(@intFromEnum(ExitCode.compile));
}

/// `qube wit check` — synthesize this qube's world and confirm it is well-formed
/// (and, for a pure library, parses as standalone WIT via wasm-tools). Exits 64
/// if the source doesn't compile to a world or the world is malformed.
fn witCheck(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    args_it: *std.process.Args.Iterator,
) !void {
    while (args_it.next()) |a| {
        try printStderr(io, "qube wit check: ignoring unrecognised arg: {s}\n", .{a});
    }
    var m = try loadManifest(gpa, io);
    defer m.deinit(gpa);
    var inv = try buildWorldInvocation(gpa, io, env, &m);
    defer inv.deinit(gpa);

    const res = runCapture(gpa, io, inv.argv.items) catch {
        try writeStderr(io, "qube wit check: q64 not found (set Q64_BIN or build q64)\n");
        std.process.exit(@intFromEnum(ExitCode.internal));
    };
    defer gpa.free(res.stdout);
    if ((res.code orelse 255) != 0) {
        try printStderr(io, "qube wit check: the qube does not compile to a WIT world (q64 exit {d})\n", .{res.code orelse 255});
        std.process.exit(@intFromEnum(ExitCode.compile));
    }
    const wit = res.stdout;

    // A pure-surface library imports nothing, so its world is standalone WIT —
    // validate it parses with wasm-tools. A qube whose world imports external
    // packages (e.g. an app's wasi:cli) can't be parsed in isolation, so we
    // stop at successful synthesis (the authoritative form is its component).
    const pure = std.mem.indexOf(u8, wit, "(none — pure surface)") != null;
    if (pure) {
        const cwd_path = try std.process.currentPathAlloc(io, gpa);
        defer gpa.free(cwd_path);
        const repo_root_opt = findRepoRoot(gpa, io, cwd_path) catch null;
        defer if (repo_root_opt) |r| gpa.free(r);
        const tools = try resolveBinary(gpa, io, env, "Q64_WASM_TOOLS", repo_root_opt, "vendor/wasm-tools/wasm-tools", "wasm-tools");
        defer gpa.free(tools);

        // Write the synthesized world to a temp file and ask wasm-tools to parse
        // it. A non-zero exit means the synthesized WIT is malformed.
        const tmp_path = try std.fmt.allocPrint(gpa, "{s}/target/wit-check.wit", .{m.projectDir()});
        defer gpa.free(tmp_path);
        std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(tmp_path) orelse ".") catch {};
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp_path, .data = wit }) catch {};
        const argv = [_][]const u8{ tools, "component", "wit", tmp_path };
        const vres = runCapture(gpa, io, &argv) catch {
            // wasm-tools absent — synthesis already succeeded; accept.
            try printStdout(io, "qube wit check: OK — world '{s}' ({s}) synthesizes (wasm-tools absent; skipped parse)\n", .{ inv.world, inv.package });
            std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
            return;
        };
        defer gpa.free(vres.stdout);
        std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
        if ((vres.code orelse 255) != 0) {
            try printStderr(io, "qube wit check: the synthesized world is not valid WIT\n", .{});
            std.process.exit(@intFromEnum(ExitCode.input));
        }
    }
    try printStdout(io, "qube wit check: OK — world '{s}' ({s})\n", .{ inv.world, inv.package });
}

/// `qube wit diff <a> <b>` — compare the export surfaces of two worlds (each a
/// `.wit` file or a component `.wasm`) and classify the change. A removed or
/// changed export is **breaking** (exit 1); added-only is **compatible** (exit
/// 0). A v0 surface diff over the synthesized canonical-ABI signatures.
fn witDiff(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    args_it: *std.process.Args.Iterator,
) !void {
    var a_in: ?[]const u8 = null;
    var b_in: ?[]const u8 = null;
    while (args_it.next()) |a| {
        if (std.mem.startsWith(u8, a, "-")) {
            try printStderr(io, "qube wit diff: unknown flag: {s}\n", .{a});
            std.process.exit(@intFromEnum(ExitCode.usage));
        } else if (a_in == null) {
            a_in = a;
        } else if (b_in == null) {
            b_in = a;
        } else {
            try writeStderr(io, "qube wit diff: expected exactly two inputs\n");
            std.process.exit(@intFromEnum(ExitCode.usage));
        }
    }
    const a_path = a_in orelse null;
    const b_path = b_in orelse null;
    if (a_path == null or b_path == null) {
        try writeStderr(io, "usage: qube wit diff <a.wit|a.wasm> <b.wit|b.wasm>\n");
        std.process.exit(@intFromEnum(ExitCode.usage));
    }

    const cwd_path = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd_path);
    const repo_root_opt = findRepoRoot(gpa, io, cwd_path) catch null;
    defer if (repo_root_opt) |r| gpa.free(r);
    const tools = try resolveBinary(gpa, io, env, "Q64_WASM_TOOLS", repo_root_opt, "vendor/wasm-tools/wasm-tools", "wasm-tools");
    defer gpa.free(tools);

    const a_text = try readWorldText(gpa, io, tools, a_path.?);
    defer gpa.free(a_text);
    const b_text = try readWorldText(gpa, io, tools, b_path.?);
    defer gpa.free(b_text);

    var a_exports = try collectExports(gpa, a_text);
    defer freeExports(gpa, &a_exports);
    var b_exports = try collectExports(gpa, b_text);
    defer freeExports(gpa, &b_exports);

    var breaking: usize = 0;
    var added: usize = 0;

    // Removed or changed exports — breaking.
    var ait = a_exports.iterator();
    while (ait.next()) |e| {
        const name = e.key_ptr.*;
        if (b_exports.get(name)) |bsig| {
            if (!std.mem.eql(u8, bsig, e.value_ptr.*)) {
                try printStdout(io, "~ changed (breaking): export {s}\n    a: {s}\n    b: {s}\n", .{ name, e.value_ptr.*, bsig });
                breaking += 1;
            }
        } else {
            try printStdout(io, "- removed (breaking): export {s}: {s}\n", .{ name, e.value_ptr.* });
            breaking += 1;
        }
    }
    // Added exports — compatible.
    var bit = b_exports.iterator();
    while (bit.next()) |e| {
        if (a_exports.get(e.key_ptr.*) == null) {
            try printStdout(io, "+ added (compatible): export {s}: {s}\n", .{ e.key_ptr.*, e.value_ptr.* });
            added += 1;
        }
    }

    if (breaking > 0) {
        try printStdout(io, "qube wit diff: {d} breaking, {d} added — BREAKING\n", .{ breaking, added });
        std.process.exit(@intFromEnum(ExitCode.compile));
    }
    try printStdout(io, "qube wit diff: 0 breaking, {d} added — compatible\n", .{added});
}

/// Read a world as text: a `.wasm` input is run through `wasm-tools component
/// wit`; anything else is read verbatim (a `.wit` file). Caller owns the slice.
fn readWorldText(gpa: std.mem.Allocator, io: std.Io, tools: []const u8, path: []const u8) ![]u8 {
    if (std.mem.endsWith(u8, path, ".wasm")) {
        const argv = [_][]const u8{ tools, "component", "wit", path };
        const res = try runCapture(gpa, io, &argv);
        if ((res.code orelse 255) != 0) {
            gpa.free(res.stdout);
            try printStderr(io, "qube wit diff: cannot extract world from {s}\n", .{path});
            std.process.exit(@intFromEnum(ExitCode.input));
        }
        return res.stdout;
    }
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4 * 1024 * 1024)) catch |err| {
        try printStderr(io, "qube wit diff: cannot read {s}: {s}\n", .{ path, @errorName(err) });
        std.process.exit(@intFromEnum(ExitCode.input));
    };
}

/// Parse `export <name>: <sig>;` items from a WIT document into a name→signature
/// map (both owned). Splits on `;` (the WIT item terminator) rather than lines,
/// so it is robust to multiple items per line; `//` comments are stripped first.
/// Interface-style exports (`export wasi:cli/run;`) key on the token with an
/// empty signature. A v0 surface diff over the canonical-ABI signatures — it
/// does not model nested interface bodies.
fn collectExports(gpa: std.mem.Allocator, wit: []const u8) !std.StringHashMapUnmanaged([]u8) {
    var map: std.StringHashMapUnmanaged([]u8) = .{};
    errdefer freeExports(gpa, &map);

    // Strip `//` line comments so a commented `export` (or a `;` in a comment)
    // never reaches the splitter.
    var cleaned: std.ArrayList(u8) = .empty;
    defer cleaned.deinit(gpa);
    var lines = std.mem.splitScalar(u8, wit, '\n');
    while (lines.next()) |raw| {
        const line = if (std.mem.indexOf(u8, raw, "//")) |i| raw[0..i] else raw;
        try cleaned.appendSlice(gpa, line);
        try cleaned.append(gpa, '\n');
    }

    var items = std.mem.splitScalar(u8, cleaned.items, ';');
    while (items.next()) |seg| {
        // The export keyword may be preceded by `world x {` / whitespace on the
        // same segment; take everything after the last `export ` token.
        const kw = std.mem.lastIndexOf(u8, seg, "export ") orelse continue;
        const rest = std.mem.trim(u8, seg[kw + "export ".len ..], " \t\r\n");
        if (rest.len == 0) continue;
        const name = if (std.mem.indexOfScalar(u8, rest, ':')) |c|
            std.mem.trim(u8, rest[0..c], " \t\r\n")
        else
            rest;
        const sig = if (std.mem.indexOfScalar(u8, rest, ':')) |c|
            std.mem.trim(u8, rest[c + 1 ..], " \t\r\n")
        else
            "";
        const key = try gpa.dupe(u8, name);
        const val = try gpa.dupe(u8, sig);
        const gop = try map.getOrPut(gpa, key);
        if (gop.found_existing) {
            gpa.free(key);
            gpa.free(gop.value_ptr.*);
        }
        gop.value_ptr.* = val;
    }
    return map;
}

fn freeExports(gpa: std.mem.Allocator, map: *std.StringHashMapUnmanaged([]u8)) void {
    var it = map.iterator();
    while (it.next()) |e| {
        gpa.free(e.key_ptr.*);
        gpa.free(e.value_ptr.*);
    }
    map.deinit(gpa);
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

    const json = json5.toJson(gpa, manifest_src) catch |err| {
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

    const entry_rel = resolve.entryOf(manifestString(root, "entry"), false);
    const entry_path = try std.fs.path.join(gpa, &.{ project_dir, entry_rel });
    defer gpa.free(entry_path);

    var module_specs = resolveModuleSpecs(gpa, io, env, project_dir, root) catch |err| {
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
    var w = std.Io.File.stdout().writerStreaming(io, &buf);
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

    // v0: passwords are bypass-only; no need to JSON-escape yet.
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
    \\for item in qube.json5 README.md src tests examples example wit; do
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

// ---------------------------------------------------------------------------
// Capability sync (spec/qube.json5.md §Capabilities, spec/env.md §disclosure)
//
// The manifest's `capabilities` field is generated, not authored: publish
// derives it from the compiler (`q64 show capabilities`) and rewrites the
// field in place, so the registry's ENV040/ENV041 backstop never fires for
// a toolchain publish.
// ---------------------------------------------------------------------------

/// The 1:1 effect-marker → capability-name table from
/// spec/qube.json5.md §Capabilities / spec/env.md. Umbrella effects with
/// no capability of their own (`@io`, `@pure`, …) map to null.
fn capabilityForEffect(effect: []const u8) ?[]const u8 {
    const map = [_]struct { effect: []const u8, capability: []const u8 }{
        .{ .effect = "@network", .capability = "Net" },
        .{ .effect = "@fs", .capability = "Fs" },
        .{ .effect = "@kv", .capability = "KeyValue" },
        .{ .effect = "@audio", .capability = "Audio" },
        .{ .effect = "@midi", .capability = "Midi" },
        .{ .effect = "@ui", .capability = "Ui" },
        .{ .effect = "@inference", .capability = "AiEnv" },
        .{ .effect = "@time", .capability = "Clock" },
        .{ .effect = "@random", .capability = "Rng" },
        .{ .effect = "@stdout", .capability = "Stdout" },
        .{ .effect = "@stderr", .capability = "Stderr" },
        .{ .effect = "@exit", .capability = "ExitFn" },
        .{ .effect = "@envvars", .capability = "EnvVars" },
    };
    for (map) |e| {
        if (std.mem.eql(u8, e.effect, effect)) return e.capability;
    }
    return null;
}

/// Map `q64 show capabilities` output (one effect marker per line) to the
/// sorted, deduplicated capability list. Allocated in `arena`.
fn capabilitiesFromEffects(arena: std.mem.Allocator, q64_output: []const u8) ![]const []const u8 {
    var caps: std.ArrayList([]const u8) = .empty;
    defer caps.deinit(arena);
    var it = std.mem.tokenizeAny(u8, q64_output, " \r\n\t");
    while (it.next()) |tok| {
        const cap = capabilityForEffect(tok) orelse continue;
        var dup = false;
        for (caps.items) |c| {
            if (std.mem.eql(u8, c, cap)) {
                dup = true;
                break;
            }
        }
        if (!dup) try caps.append(arena, cap);
    }
    const out = try arena.dupe([]const u8, caps.items);
    std.mem.sort([]const u8, out, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return out;
}

/// Render a capability list as the manifest array value: `["Net", "Stdout"]`.
fn renderCapabilitiesValue(gpa: std.mem.Allocator, caps: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.append(gpa, '[');
    for (caps, 0..) |c, i| {
        if (i > 0) try out.appendSlice(gpa, ", ");
        try out.print(gpa, "\"{s}\"", .{c});
    }
    try out.append(gpa, ']');
    return out.toOwnedSlice(gpa);
}

/// Return a copy of the JSON5 manifest `raw` with its `capabilities`
/// field's array replaced by `rendered`, inserting the field before the
/// final closing brace when absent. Handles quoted and unquoted keys;
/// preserves the rest of the text byte-for-byte.
fn replaceCapabilitiesField(gpa: std.mem.Allocator, raw: []const u8, rendered: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    const key_at: ?usize = std.mem.indexOf(u8, raw, "\"capabilities\"") orelse blk: {
        // Unquoted JSON5 key: a bare identifier in key position.
        var search: usize = 0;
        while (std.mem.indexOfPos(u8, raw, search, "capabilities")) |i| {
            const before_ok = i == 0 or switch (raw[i - 1]) {
                '{', ',', ' ', '\n', '\t', '\r' => true,
                else => false,
            };
            var j = i + "capabilities".len;
            while (j < raw.len and (raw[j] == ' ' or raw[j] == '\t')) j += 1;
            if (before_ok and j < raw.len and raw[j] == ':') break :blk i;
            search = i + 1;
        }
        break :blk null;
    };

    if (key_at) |k| {
        const colon = std.mem.indexOfScalarPos(u8, raw, k, ':') orelse return error.MalformedManifest;
        const open = std.mem.indexOfScalarPos(u8, raw, colon, '[') orelse return error.MalformedManifest;
        const close = std.mem.indexOfScalarPos(u8, raw, open, ']') orelse return error.MalformedManifest;
        try out.appendSlice(gpa, raw[0..open]);
        try out.appendSlice(gpa, rendered);
        try out.appendSlice(gpa, raw[close + 1 ..]);
    } else {
        const brace = std.mem.lastIndexOfScalar(u8, raw, '}') orelse return error.MalformedManifest;
        // Trim trailing whitespace before the brace; add a comma if the
        // last property lacks one.
        var k = brace;
        while (k > 0 and switch (raw[k - 1]) {
            ' ', '\n', '\t', '\r' => true,
            else => false,
        }) k -= 1;
        const needs_comma = k > 0 and raw[k - 1] != ',' and raw[k - 1] != '{';
        try out.appendSlice(gpa, raw[0..k]);
        if (needs_comma) try out.append(gpa, ',');
        try out.print(gpa, "\n  \"capabilities\": {s},\n", .{rendered});
        try out.appendSlice(gpa, raw[brace..]);
    }
    return out.toOwnedSlice(gpa);
}

test "capabilitiesFromEffects: maps, dedupes, sorts, ignores umbrellas" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const caps = try capabilitiesFromEffects(arena_state.allocator(), "@stdout\n@io\n@network\n@stdout\n@kv\n");
    try std.testing.expectEqual(@as(usize, 3), caps.len);
    try std.testing.expectEqualStrings("KeyValue", caps[0]);
    try std.testing.expectEqualStrings("Net", caps[1]);
    try std.testing.expectEqualStrings("Stdout", caps[2]);
}

test "replaceCapabilitiesField: replaces quoted and unquoted keys, inserts when absent" {
    const gpa = std.testing.allocator;

    const replaced = try replaceCapabilitiesField(gpa, "{ \"name\": \"x\", \"capabilities\": [\"Net\"], \"type\": \"library\" }", "[\"Stdout\"]");
    defer gpa.free(replaced);
    try std.testing.expectEqualStrings("{ \"name\": \"x\", \"capabilities\": [\"Stdout\"], \"type\": \"library\" }", replaced);

    const unquoted = try replaceCapabilitiesField(gpa, "{ name: 'x', capabilities: [], type: 'library' }", "[\"Stdout\"]");
    defer gpa.free(unquoted);
    try std.testing.expectEqualStrings("{ name: 'x', capabilities: [\"Stdout\"], type: 'library' }", unquoted);

    const inserted = try replaceCapabilitiesField(gpa, "{\n  \"name\": \"x\"\n}", "[\"Stdout\"]");
    defer gpa.free(inserted);
    try std.testing.expectEqualStrings("{\n  \"name\": \"x\",\n  \"capabilities\": [\"Stdout\"],\n}", inserted);

    const inserted_after_comma = try replaceCapabilitiesField(gpa, "{\n  \"name\": \"x\",\n}", "[]");
    defer gpa.free(inserted_after_comma);
    try std.testing.expectEqualStrings("{\n  \"name\": \"x\",\n  \"capabilities\": [],\n}", inserted_after_comma);
}

/// Derive the qube's capability set from the compiler and sync the
/// manifest's `capabilities` field in place. Soft-skips (with a warning)
/// when `q64` is not available; any compile failure is fatal — a qube
/// that does not compile must not publish.
fn syncManifestCapabilities(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    m: *const LoadedManifest,
) !void {
    const project_dir = m.projectDir();
    const repo_root_opt = findRepoRoot(gpa, io, project_dir) catch null;
    defer if (repo_root_opt) |r| gpa.free(r);
    const q64_bin = try resolveBinary(gpa, io, env, "Q64_BIN", repo_root_opt, "q64/zig-out/bin/q64", "q64");
    defer gpa.free(q64_bin);

    const type_str = manifestString(m.root, "type") orelse "library";
    const entry_rel = resolve.entryOf(manifestString(m.root, "entry"), !std.mem.eql(u8, type_str, "application"));
    const entry_path = try std.fs.path.join(gpa, &.{ project_dir, entry_rel });
    defer gpa.free(entry_path);

    var module_specs = resolveModuleSpecs(gpa, io, env, project_dir, m.root) catch |err| {
        try printStderr(io, "qube publish: dependency resolution failed: {s}\n", .{@errorName(err)});
        std.process.exit(@intFromEnum(ExitCode.dependency));
    };
    defer {
        for (module_specs.items) |s| gpa.free(s);
        module_specs.deinit(gpa);
    }

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ q64_bin, "show", "capabilities", "--qube", entry_path });
    for (module_specs.items) |spec| {
        try argv.appendSlice(gpa, &.{ "--module", spec });
    }

    const cap_out = runCapture(gpa, io, argv.items) catch {
        try writeStderr(io, "qube publish: q64 not found; skipping capability sync (the registry will cross-check)\n");
        return;
    };
    defer gpa.free(cap_out.stdout);
    const q64_code = cap_out.code orelse 255;
    if (q64_code != 0) {
        try printStderr(io, "qube publish: `q64 show capabilities` failed (exit {d}); cannot derive the capability set\n", .{q64_code});
        std.process.exit(@intFromEnum(ExitCode.compile));
    }

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const derived = try capabilitiesFromEffects(arena_state.allocator(), cap_out.stdout);

    const current: ?[]const std.json.Value = if (m.root.get("capabilities")) |v| switch (v) {
        .array => |a| a.items,
        else => null,
    } else null;

    const in_sync = blk: {
        const cur = current orelse break :blk derived.len == 0;
        if (cur.len != derived.len) break :blk false;
        for (derived) |d| {
            var found = false;
            for (cur) |cv| {
                if (cv == .string and std.mem.eql(u8, cv.string, d)) {
                    found = true;
                    break;
                }
            }
            if (!found) break :blk false;
        }
        break :blk true;
    };
    if (in_sync) return;

    const rendered = try renderCapabilitiesValue(gpa, derived);
    defer gpa.free(rendered);
    const updated = replaceCapabilitiesField(gpa, m.src, rendered) catch |err| {
        try printStderr(io, "qube publish: cannot rewrite the capabilities field: {s}\n", .{@errorName(err)});
        std.process.exit(@intFromEnum(ExitCode.input));
    };
    defer gpa.free(updated);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = m.path, .data = updated });
    try printStdout(io, "qube publish: capabilities synced to {s} (compiler-derived)\n", .{rendered});
}

/// Synthesize the qube's WIT world to a file under `target/publish/` and return
/// its path (caller frees), or null when no world can be produced (q64 absent,
/// or the qube doesn't compile). The world name + package come from the
/// manifest `wit` block (WIT rung 2), so the published contract matches the
/// `.wit` `qube build --component` emits. Best-effort: a synthesis failure must
/// not block publish — the registry treats the world as optional metadata.
fn synthesizeWitWorld(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    m: *const LoadedManifest,
    name: []const u8,
) !?[]u8 {
    const project_dir = m.projectDir();
    const repo_root_opt = findRepoRoot(gpa, io, project_dir) catch null;
    defer if (repo_root_opt) |r| gpa.free(r);
    const q64_bin = resolveBinary(gpa, io, env, "Q64_BIN", repo_root_opt, "q64/zig-out/bin/q64", "q64") catch return null;
    defer gpa.free(q64_bin);

    const type_str = manifestString(m.root, "type") orelse "library";
    const entry_rel = resolve.entryOf(manifestString(m.root, "entry"), !std.mem.eql(u8, type_str, "application"));
    const entry_path = try std.fs.path.join(gpa, &.{ project_dir, entry_rel });
    defer gpa.free(entry_path);

    const world_name = resolveWorldName(m.root, name);
    const wit_package = try resolveWitPackage(gpa, m.root, name);
    defer gpa.free(wit_package);

    const out_dir = try std.fs.path.join(gpa, &.{ project_dir, "target", "publish" });
    defer gpa.free(out_dir);
    std.Io.Dir.cwd().createDirPath(io, out_dir) catch {};
    const wit_file = try std.fmt.allocPrint(gpa, "{s}.wit", .{name});
    defer gpa.free(wit_file);
    const wit_path = try std.fs.path.join(gpa, &.{ out_dir, wit_file });
    errdefer gpa.free(wit_path);

    var module_specs = resolveModuleSpecs(gpa, io, env, project_dir, m.root) catch return null;
    defer {
        for (module_specs.items) |s| gpa.free(s);
        module_specs.deinit(gpa);
    }

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ q64_bin, "show", "world", "--qube", entry_path, "--world", world_name, "--wit-package", wit_package, "--out", wit_path });
    for (module_specs.items) |spec| try argv.appendSlice(gpa, &.{ "--module", spec });

    const res = runCapture(gpa, io, argv.items) catch return null;
    defer gpa.free(res.stdout);
    if ((res.code orelse 255) != 0) return null;
    try printStdout(io, "qube publish: attached WIT world '{s}' ({s})\n", .{ world_name, wit_package });
    return wit_path;
}

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

    var m = try loadManifest(gpa, io);
    defer m.deinit(gpa);
    const manifest_path = m.path;
    const project_dir = m.projectDir();

    const name = manifestString(m.root, "name") orelse {
        try writeStderr(io, "qube publish: manifest has no \"name\" field\n");
        std.process.exit(@intFromEnum(ExitCode.input));
    };
    const version = manifestString(m.root, "version") orelse {
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
    if (m.root.get("publish")) |v| {
        if (v == .bool and !v.bool) {
            try writeStderr(io, "qube publish: manifest sets publish: false; refusing\n");
            std.process.exit(@intFromEnum(ExitCode.input));
        }
    }

    // Sync the generated `capabilities` field from the compiler before
    // packing, so the uploaded manifest always matches the effect index
    // (spec/qube.json5.md §Capabilities).
    try syncManifestCapabilities(gpa, io, env, &m);

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

    // Attach the WIT world (rung 3): the Continuum stores SOURCE, not wasm, so the
    // world can't be derived registry-side — the toolchain attaches it here (like
    // `capabilities`). Two sources, in order:
    //   1. A hand-authored `.wit` named by `wit.file` in the manifest — for a
    //      FOREIGN component (e.g. a Zig library like quine) whose world the q64
    //      compiler can't synthesize. Published verbatim.
    //   2. Otherwise synthesize from q64 source (`q64 show world`).
    // Best-effort: publish proceeds without a world if neither is available.
    const wit_path: ?[]u8 = blk: {
        if (manifestNestedString(m.root, "wit", "file")) |rel| {
            const p = try std.fs.path.join(gpa, &.{ project_dir, rel });
            std.Io.Dir.cwd().access(io, p, .{}) catch {
                try printStderr(io, "qube publish: wit.file '{s}' not found\n", .{rel});
                gpa.free(p);
                std.process.exit(@intFromEnum(ExitCode.input));
            };
            try printStdout(io, "qube publish: attaching hand-authored WIT '{s}'\n", .{rel});
            break :blk p;
        }
        break :blk synthesizeWitWorld(gpa, io, env, &m, name) catch null;
    };
    defer if (wit_path) |p| gpa.free(p);

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

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{
        "curl",          "-sS",  "-w", "\n%{http_code}",
        "-X",            "POST", url,  "-H",
        auth,            "-F",   manifest_field,
        "-F",            archive_field,
    });
    // Attach the synthesized world when one was produced (WIT rung 3).
    const wit_field = if (wit_path) |p| try std.fmt.allocPrint(gpa, "wit=<{s}", .{p}) else null;
    defer if (wit_field) |f| gpa.free(f);
    if (wit_field) |f| try argv.appendSlice(gpa, &.{ "-F", f });

    const cap = try runCapture(gpa, io, argv.items);
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
    const cache_dir = try downloadAndCacheArchive(gpa, io, env, registry, name, cv.version, cv.archive_sha, "add");
    defer gpa.free(cache_dir);

    // Insert the dependency into the manifest.
    try insertDependency(gpa, io, manifest_path, name, cv.version);

    // Pin it in the lockfile (spec/qube.lock.md).
    const project_dir = std.fs.path.dirname(manifest_path) orelse ".";
    const lock_source = try std.fmt.allocPrint(gpa, "registry+{s}", .{registry});
    defer gpa.free(lock_source);
    try upsertLockEntry(gpa, io, project_dir, .{
        .name = name,
        .version = cv.version,
        .source = lock_source,
        .sha256 = cv.archive_sha,
    });

    try printStdout(io, "Added {s}@{s}\n  cached at {s}\n  locked in {s}\n", .{ name, cv.version, cache_dir, lock_file_name });
}

/// Download `<registry>/v1/qubes/<name>/<version>/archive`, verify the
/// expected SHA-256, and extract it into the content-addressed cache
/// (`~/.qube/cache/sha256/<ab>/<cd>/<digest>/`, spec/qube-cli.md).
/// Returns the extracted directory; caller owns it. `cmd` names the
/// caller for messages. Exits with registry / dependency codes on
/// failure, like the rest of the registry client.
fn downloadAndCacheArchive(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    registry: []const u8,
    name: []const u8,
    version: []const u8,
    expected_sha: []const u8,
    cmd: []const u8,
) ![]u8 {
    const home = try qubeHome(gpa, env);
    defer gpa.free(home);
    const cache_root = try std.fs.path.join(gpa, &.{ home, "cache" });
    defer gpa.free(cache_root);
    try std.Io.Dir.cwd().createDirPath(io, cache_root);
    const tmp_zip = try std.fmt.allocPrint(gpa, "{s}/{s}.part", .{ cache_root, expected_sha });
    defer gpa.free(tmp_zip);

    const archive_url = try std.fmt.allocPrint(gpa, "{s}/v1/qubes/{s}/{s}/archive", .{ registry, name, version });
    defer gpa.free(archive_url);
    const dl_status = try httpGetToFile(gpa, io, archive_url, tmp_zip);
    if (dl_status != 200) {
        try printStderr(io, "qube {s}: archive download returned {d}\n", .{ cmd, dl_status });
        std.process.exit(@intFromEnum(ExitCode.registry));
    }

    const got_sha = try sha256HexOfFile(gpa, io, tmp_zip);
    defer gpa.free(got_sha);
    if (!std.mem.eql(u8, got_sha, expected_sha)) {
        try printStderr(io, "qube {s}: archive SHA-256 mismatch\n  expected {s}\n  got      {s}\n", .{ cmd, expected_sha, got_sha });
        std.process.exit(@intFromEnum(ExitCode.dependency));
    }

    const cache_dir = try cacheDirForSha(gpa, home, expected_sha);
    errdefer gpa.free(cache_dir);
    {
        const argv = [_][]const u8{ "sh", "-c", extract_script, "sh", tmp_zip, cache_dir };
        const term = try spawnInherit(io, &argv);
        if (termCode(term) != 0) {
            try printStderr(io, "qube {s}: extracting the archive failed\n", .{cmd});
            std.process.exit(@intFromEnum(ExitCode.internal));
        }
    }
    std.Io.Dir.cwd().deleteFile(io, tmp_zip) catch {};
    return cache_dir;
}

/// The nearest manifest, discovered and parsed. `root` borrows from
/// `parsed`; `projectDir()` borrows from `path`.
const LoadedManifest = struct {
    path: []u8,
    src: []u8,
    json: []u8,
    parsed: std.json.Parsed(std.json.Value),
    root: std.json.ObjectMap,

    fn projectDir(self: *const LoadedManifest) []const u8 {
        return std.fs.path.dirname(self.path) orelse ".";
    }

    fn deinit(self: *LoadedManifest, gpa: std.mem.Allocator) void {
        self.parsed.deinit();
        gpa.free(self.json);
        gpa.free(self.src);
        gpa.free(self.path);
    }
};

/// Discover the nearest qube.json5 (walking up from cwd) and parse it.
/// Exits with input-error codes on failure, like the run/build path.
fn loadManifest(gpa: std.mem.Allocator, io: std.Io) !LoadedManifest {
    const cwd_path = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd_path);
    const manifest_path = try findManifestUpward(gpa, io, cwd_path) orelse {
        try writeStderr(io, "qube: no qube.json5 found in this directory or any parent\n");
        std.process.exit(@intFromEnum(ExitCode.input));
    };
    errdefer gpa.free(manifest_path);
    const manifest_src = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, gpa, .limited(1 * 1024 * 1024)) catch |err| {
        try printStderr(io, "qube: cannot read {s}: {s}\n", .{ manifest_path, @errorName(err) });
        std.process.exit(@intFromEnum(ExitCode.input));
    };
    errdefer gpa.free(manifest_src);
    const json = json5.toJson(gpa, manifest_src) catch |err| {
        try printStderr(io, "qube: cannot read {s}: {s}\n", .{ manifest_path, @errorName(err) });
        std.process.exit(@intFromEnum(ExitCode.input));
    };
    errdefer gpa.free(json);
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, json, .{}) catch |err| {
        try printStderr(io, "qube: cannot parse {s}: {s}\n", .{ manifest_path, @errorName(err) });
        std.process.exit(@intFromEnum(ExitCode.input));
    };
    errdefer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => {
            try writeStderr(io, "qube: manifest is not a JSON object\n");
            std.process.exit(@intFromEnum(ExitCode.input));
        },
    };
    return .{ .path = manifest_path, .src = manifest_src, .json = json, .parsed = parsed, .root = root };
}

/// Resolve the manifest's dependencies into lock entries
/// (spec/qube.lock.md). A path dep is recorded from its own manifest; a
/// registry range reuses the `old_lock` version when it still
/// satisfies, and otherwise resolves to the highest non-yanked
/// satisfying version from the registry's metadata (no archive download
/// — the sha comes from the index). With `offline`, a range that cannot
/// be reused is PKG010 instead of a fetch. Strings that outlive their
/// producers are allocated in `arena`; `cmd` names the caller for
/// messages.
fn buildLockEntries(
    gpa: std.mem.Allocator,
    io: std.Io,
    arena: std.mem.Allocator,
    project_dir: []const u8,
    root: std.json.ObjectMap,
    registry: []const u8,
    old_lock: ?std.json.Parsed(LockFile),
    offline: bool,
    cmd: []const u8,
    entries: *std.ArrayList(LockEntry),
) !void {
    const deps: ?std.json.ObjectMap = if (root.get("dependencies")) |v| switch (v) {
        .object => |o| o,
        else => null,
    } else null;

    if (deps) |d| {
        var it = d.iterator();
        while (it.next()) |entry| {
            const dep_name = entry.key_ptr.*;
            switch (entry.value_ptr.*) {
                .object => |o| {
                    const p = manifestString(o, "path") orelse {
                        try printStderr(io, "qube {s}: dependency '{s}' has no `path`\n", .{ cmd, dep_name });
                        std.process.exit(@intFromEnum(ExitCode.dependency));
                    };
                    const dep_version = pathDepVersion(gpa, io, arena, project_dir, p) catch "0.0.0";
                    try entries.append(gpa, .{
                        .name = dep_name,
                        .version = dep_version,
                        .source = try std.fmt.allocPrint(arena, "path+{s}", .{p}),
                    });
                },
                .string => |range| {
                    // Reuse the locked version while it still satisfies.
                    const reused: ?LockEntry = blk: {
                        const l = old_lock orelse break :blk null;
                        for (l.value.qubes) |e| {
                            if (std.mem.eql(u8, e.name, dep_name) and
                                e.sha256 != null and
                                std.mem.startsWith(u8, e.source, "registry+") and
                                versionSatisfies(range, e.version)) break :blk e;
                        }
                        break :blk null;
                    };
                    if (reused) |e| {
                        try entries.append(gpa, e);
                        continue;
                    }
                    if (offline) {
                        try printStderr(io, "qube {s}: PKG010: dependency '{s}' is not locked and --offline forbids resolving it\n", .{ cmd, dep_name });
                        std.process.exit(@intFromEnum(ExitCode.dependency));
                    }

                    const meta_url = try std.fmt.allocPrint(gpa, "{s}/v1/qubes/{s}", .{ registry, dep_name });
                    defer gpa.free(meta_url);
                    const resp = try httpGet(gpa, io, meta_url);
                    defer gpa.free(resp.raw);
                    if (resp.status == 404) {
                        try printStderr(io, "qube {s}: '{s}' not found on {s}\n", .{ cmd, dep_name, registry });
                        std.process.exit(@intFromEnum(ExitCode.dependency));
                    }
                    if (resp.status != 200) {
                        try printStderr(io, "qube {s}: registry returned {d}:\n{s}\n", .{ cmd, resp.status, resp.body });
                        std.process.exit(@intFromEnum(ExitCode.registry));
                    }
                    const meta_parsed = std.json.parseFromSlice(QubeMeta, gpa, resp.body, .{ .ignore_unknown_fields = true }) catch {
                        try printStderr(io, "qube {s}: could not parse registry metadata\n", .{cmd});
                        std.process.exit(@intFromEnum(ExitCode.registry));
                    };
                    defer meta_parsed.deinit();

                    var best: ?VersionMeta = null;
                    for (meta_parsed.value.versions) |v| {
                        if (v.yanked) continue;
                        if (!versionSatisfies(range, v.version)) continue;
                        if (best) |b| {
                            const vs = parseSemver(v.version) orelse continue;
                            const bs = parseSemver(b.version) orelse {
                                best = v;
                                continue;
                            };
                            if (!semverGte(vs, bs)) continue;
                        }
                        best = v;
                    }
                    const cv = best orelse {
                        try printStderr(io, "qube {s}: no version of '{s}' satisfies '{s}'\n", .{ cmd, dep_name, range });
                        std.process.exit(@intFromEnum(ExitCode.dependency));
                    };
                    try entries.append(gpa, .{
                        .name = dep_name,
                        .version = try arena.dupe(u8, cv.version),
                        .source = try std.fmt.allocPrint(arena, "registry+{s}", .{registry}),
                        .sha256 = try arena.dupe(u8, cv.archive_sha),
                    });
                },
                else => {
                    try printStderr(io, "qube {s}: dependency '{s}' has an unsupported value shape\n", .{ cmd, dep_name });
                    std.process.exit(@intFromEnum(ExitCode.dependency));
                },
            }
        }
    }
}

/// True when every manifest dependency has a lock entry of the matching
/// source kind whose version satisfies the declared range
/// (spec/qube.lock.md §Staleness).
fn lockSatisfiesManifest(root: std.json.ObjectMap, lock: LockFile) bool {
    const deps_v = root.get("dependencies") orelse return true;
    const deps = switch (deps_v) {
        .object => |o| o,
        else => return true,
    };
    var it = deps.iterator();
    while (it.next()) |entry| {
        const dep_name = entry.key_ptr.*;
        const locked: ?LockEntry = blk: {
            for (lock.qubes) |e| {
                if (std.mem.eql(u8, e.name, dep_name)) break :blk e;
            }
            break :blk null;
        };
        const e = locked orelse return false;
        switch (entry.value_ptr.*) {
            .string => |range| {
                if (e.sha256 == null) return false;
                if (!std.mem.startsWith(u8, e.source, "registry+")) return false;
                if (!versionSatisfies(range, e.version)) return false;
            },
            .object => |o| {
                const p = manifestString(o, "path") orelse return false;
                if (!std.mem.startsWith(u8, e.source, "path+")) return false;
                if (!std.mem.eql(u8, e.source["path+".len..], p)) return false;
            },
            else => return false,
        }
    }
    return true;
}

test "lockSatisfiesManifest: range, source kind, and presence checks" {
    const gpa = std.testing.allocator;
    const manifest =
        \\{ "name": "dev.q64.x", "dependencies": {
        \\  "dev.q64.reg": "^0.3",
        \\  "dev.q64.loc": { "path": "../loc" }
        \\} }
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, manifest, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    const good = [_]LockEntry{
        .{ .name = "dev.q64.reg", .version = "0.3.4", .source = "registry+https://qubes.q64.dev", .sha256 = "ab" },
        .{ .name = "dev.q64.loc", .version = "0.1.0", .source = "path+../loc" },
    };
    try std.testing.expect(lockSatisfiesManifest(root, .{ .qubes = @constCast(&good) }));

    const out_of_range = [_]LockEntry{
        .{ .name = "dev.q64.reg", .version = "0.4.0", .source = "registry+https://qubes.q64.dev", .sha256 = "ab" },
        .{ .name = "dev.q64.loc", .version = "0.1.0", .source = "path+../loc" },
    };
    try std.testing.expect(!lockSatisfiesManifest(root, .{ .qubes = @constCast(&out_of_range) }));

    const repointed_path = [_]LockEntry{
        .{ .name = "dev.q64.reg", .version = "0.3.4", .source = "registry+https://qubes.q64.dev", .sha256 = "ab" },
        .{ .name = "dev.q64.loc", .version = "0.1.0", .source = "path+../elsewhere" },
    };
    try std.testing.expect(!lockSatisfiesManifest(root, .{ .qubes = @constCast(&repointed_path) }));

    const missing = [_]LockEntry{
        .{ .name = "dev.q64.loc", .version = "0.1.0", .source = "path+../loc" },
    };
    try std.testing.expect(!lockSatisfiesManifest(root, .{ .qubes = @constCast(&missing) }));

    try std.testing.expect(!lockSatisfiesManifest(root, .{ .qubes = &.{} }));
}

/// `qube lock` — regenerate qube.lock from the manifest (spec/qube.lock.md).
fn cmdLock(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    args_it: *std.process.Args.Iterator,
) !void {
    _ = env;
    var registry: []const u8 = default_registry;
    while (args_it.next()) |a| {
        if (std.mem.eql(u8, a, "--registry")) {
            registry = args_it.next() orelse {
                try writeStderr(io, "qube lock: --registry needs a value\n");
                std.process.exit(@intFromEnum(ExitCode.usage));
            };
        } else {
            try printStderr(io, "qube lock: unexpected arg: {s}\n", .{a});
            std.process.exit(@intFromEnum(ExitCode.usage));
        }
    }

    var m = try loadManifest(gpa, io);
    defer m.deinit(gpa);
    const project_dir = m.projectDir();

    // The previous lockfile, for version reuse. A malformed one is
    // regenerated rather than fatal — `lock` is the repair command.
    const old_lock: ?std.json.Parsed(LockFile) = readLockFile(gpa, io, project_dir) catch |err| switch (err) {
        error.MalformedLockfile => blk: {
            try writeStderr(io, "qube lock: existing qube.lock is malformed; regenerating\n");
            break :blk null;
        },
        else => return err,
    };
    defer if (old_lock) |p| p.deinit();

    // Entry strings whose owners die before the write live in this arena.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var entries: std.ArrayList(LockEntry) = .empty;
    defer entries.deinit(gpa);
    try buildLockEntries(gpa, io, arena_state.allocator(), project_dir, m.root, registry, old_lock, false, "lock", &entries);

    try writeLockFileEntries(gpa, io, project_dir, entries.items);
    try printStdout(io, "Locked {d} dependencies -> {s}\n", .{ entries.items.len, lock_file_name });
}

/// `qube install` — make the cache satisfy the lockfile
/// (spec/qube.lock.md §Lifecycle, spec/continuum-api.md §Resolver
/// protocol). Relocks first when the lockfile is missing or stale, then
/// fetches every locked registry archive the cache is missing. With
/// `--offline`, both a needed relock and a cache miss are errors.
fn cmdInstall(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    args_it: *std.process.Args.Iterator,
) !void {
    var registry: []const u8 = default_registry;
    var offline = false;
    while (args_it.next()) |a| {
        if (std.mem.eql(u8, a, "--registry")) {
            registry = args_it.next() orelse {
                try writeStderr(io, "qube install: --registry needs a value\n");
                std.process.exit(@intFromEnum(ExitCode.usage));
            };
        } else if (std.mem.eql(u8, a, "--offline")) {
            offline = true;
        } else {
            try printStderr(io, "qube install: unexpected arg: {s}\n", .{a});
            std.process.exit(@intFromEnum(ExitCode.usage));
        }
    }

    var m = try loadManifest(gpa, io);
    defer m.deinit(gpa);
    const project_dir = m.projectDir();

    const old_lock: ?std.json.Parsed(LockFile) = readLockFile(gpa, io, project_dir) catch |err| switch (err) {
        error.MalformedLockfile => blk: {
            if (offline) {
                try writeStderr(io, "qube: PKG013: qube.lock is malformed and --offline forbids relocking\n");
                std.process.exit(@intFromEnum(ExitCode.dependency));
            }
            try writeStderr(io, "qube install: existing qube.lock is malformed; regenerating\n");
            break :blk null;
        },
        else => return err,
    };
    defer if (old_lock) |p| p.deinit();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var entries: std.ArrayList(LockEntry) = .empty;
    defer entries.deinit(gpa);

    const stale = if (old_lock) |p| !lockSatisfiesManifest(m.root, p.value) else true;
    if (stale) {
        try buildLockEntries(gpa, io, arena_state.allocator(), project_dir, m.root, registry, old_lock, offline, "install", &entries);
        try writeLockFileEntries(gpa, io, project_dir, entries.items);
    } else {
        for (old_lock.?.value.qubes) |e| try entries.append(gpa, e);
    }

    const home = try qubeHome(gpa, env);
    defer gpa.free(home);
    var fetched: usize = 0;
    var present: usize = 0;
    for (entries.items) |e| {
        const sha = e.sha256 orelse continue;
        if (!std.mem.startsWith(u8, e.source, "registry+")) continue;
        const cache_dir = try cacheDirForSha(gpa, home, sha);
        defer gpa.free(cache_dir);
        const cached = blk: {
            std.Io.Dir.cwd().access(io, cache_dir, .{}) catch break :blk false;
            break :blk true;
        };
        if (cached) {
            present += 1;
            continue;
        }
        if (offline) {
            try printStderr(io, "qube: PKG012: locked archive for '{s}@{s}' is not in the cache and --offline forbids fetching it\n", .{ e.name, e.version });
            std.process.exit(@intFromEnum(ExitCode.dependency));
        }
        const src_registry = e.source["registry+".len..];
        const dir = try downloadAndCacheArchive(gpa, io, env, src_registry, e.name, e.version, sha, "install");
        gpa.free(dir);
        fetched += 1;
    }
    try printStdout(io, "Installed: {d} fetched, {d} already cached ({d} locked)\n", .{ fetched, present, entries.items.len });
}

/// Version declared by a path dep's own manifest, allocated in `arena`.
fn pathDepVersion(
    gpa: std.mem.Allocator,
    io: std.Io,
    arena: std.mem.Allocator,
    project_dir: []const u8,
    rel: []const u8,
) ![]const u8 {
    const dep_manifest = try std.fs.path.resolve(gpa, &.{ project_dir, rel, "qube.json5" });
    defer gpa.free(dep_manifest);
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, dep_manifest, gpa, .limited(1024 * 1024));
    defer gpa.free(raw);
    const json = try json5.toJson(gpa, raw);
    defer gpa.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.MalformedManifest,
    };
    const v = manifestString(obj, "version") orelse return error.MalformedManifest;
    return arena.dupe(u8, v);
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

// Read a line from stdin with terminal echo disabled. POSIX uses termios;
// Windows toggles the console mode (see readPasswordSilentWindows). Either
// way, a non-interactive stdin (piped input, CI without QUBE_PASSWORD) falls
// back to a plain read.
fn readPasswordSilent(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    // builtin.os.tag is comptime-known, so the untaken branch is never
    // analysed — the POSIX termios code doesn't reach the Windows compile.
    if (builtin.os.tag == .windows) {
        return readPasswordSilentWindows(gpa, io);
    } else {
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
}

// Windows: disable console echo via SetConsoleMode for the duration of the
// read. kernel32's console-mode calls aren't surfaced by std, so declare them
// here (analysed only on a Windows build — this fn is unreferenced elsewhere).
fn readPasswordSilentWindows(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    const w = std.os.windows;
    const STD_INPUT_HANDLE: w.DWORD = 0xFFFFFFF6; // (DWORD)-10
    const ENABLE_ECHO_INPUT: w.DWORD = 0x0004;
    const k = struct {
        extern "kernel32" fn GetStdHandle(id: w.DWORD) callconv(.winapi) w.HANDLE;
        extern "kernel32" fn GetConsoleMode(h: w.HANDLE, mode: *w.DWORD) callconv(.winapi) w.BOOL;
        extern "kernel32" fn SetConsoleMode(h: w.HANDLE, mode: w.DWORD) callconv(.winapi) w.BOOL;
    };
    const h = k.GetStdHandle(STD_INPUT_HANDLE);
    var mode: w.DWORD = 0;
    if (h == w.INVALID_HANDLE_VALUE or !k.GetConsoleMode(h, &mode).toBool()) {
        // Redirected / not a console — read plainly (mirrors the POSIX path).
        return try readStdinLineAlloc(gpa, io);
    }
    _ = k.SetConsoleMode(h, mode & ~ENABLE_ECHO_INPUT);
    defer _ = k.SetConsoleMode(h, mode);
    return try readStdinLineAlloc(gpa, io);
}

// ---------------------------------------------------------------------------
// Scaffolding shared helpers (qube new/init, qube pod new/init)
// ---------------------------------------------------------------------------
//
// Two generation modes per spec discussion: flag-driven (any `--flag`
// present → fully non-interactive) and wizard-driven (no flags → prompt on
// stdin). Generated files are never overwritten; an existing manifest aborts.

const QubeKind = enum { library, application, workspace };

fn kindTypeStr(k: QubeKind) []const u8 {
    return switch (k) {
        .library => "library",
        .application => "application",
        .workspace => "workspace",
    };
}

const QubeConfig = struct {
    name: []const u8,
    kind: QubeKind,
    version: []const u8,
    license: []const u8,
    description: ?[]const u8,
};

fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn writeIfAbsent(io: std.Io, path: []const u8, data: []const u8) !void {
    if (fileExists(io, path)) return;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

/// Last dotted segment of a reverse-DNS name (`dev.acme.widget` → `widget`).
fn lastSegment(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |i| return name[i + 1 ..];
    return name;
}

/// Read the value following a flag, exiting with a usage error if absent.
fn flagValue(io: std.Io, args_it: *std.process.Args.Iterator, flag: []const u8) ![]const u8 {
    return args_it.next() orelse {
        try printStderr(io, "qube: {s} needs a value\n", .{flag});
        std.process.exit(@intFromEnum(ExitCode.usage));
    };
}

/// Read one line from a persistent stdin reader, stripping a trailing CR.
/// Returns a freshly-allocated slice, or null on EOF. A single reader must be
/// reused across a whole wizard: each reader buffers ahead of the delimiter,
/// so creating one per line would drop the buffered remainder of piped input.
fn readLine(gpa: std.mem.Allocator, r: *std.Io.Reader) ?[]u8 {
    // `takeDelimiter` advances *past* the newline (unlike the exclusive form,
    // which stops before it and would re-yield an empty line forever) and maps
    // end-of-stream to null, so a final unterminated line is still returned.
    const maybe = r.takeDelimiter('\n') catch return null;
    const line = maybe orelse return null;
    const trimmed = if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
    return gpa.dupe(u8, trimmed) catch null;
}

/// Print `label` (with `default` shown in brackets when non-empty) and read a
/// line from `r`. Empty input or EOF yields a dupe of `default` (or "" when
/// null). Caller owns the returned slice.
fn prompt(gpa: std.mem.Allocator, io: std.Io, r: *std.Io.Reader, label: []const u8, default: ?[]const u8) ![]u8 {
    if (default) |d| {
        if (d.len > 0) {
            try printStdout(io, "{s} [{s}]: ", .{ label, d });
        } else {
            try printStdout(io, "{s}: ", .{label});
        }
    } else {
        try printStdout(io, "{s}: ", .{label});
    }
    const got = readLine(gpa, r) orelse return gpa.dupe(u8, default orelse "");
    if (got.len == 0) {
        gpa.free(got);
        return gpa.dupe(u8, default orelse "");
    }
    return got;
}

// ---------------------------------------------------------------------------
// qube new / qube init
// ---------------------------------------------------------------------------

fn qubeHelp(io: std.Io) !void {
    try writeStdout(io,
        \\usage: qube new [name] [flags]   |   qube init [flags]
        \\
        \\Scaffold a qube. With no flags, an interactive wizard prompts for each
        \\field; passing any flag runs non-interactively.
        \\
        \\Flags:
        \\  --lib                  Library qube (default; type: "library", src/lib.q).
        \\  --app                  Application Qube (type: "application", src/main.q).
        \\  --workspace            Workspace root (type: "workspace").
        \\  --name <name>          Qube name. Use reverse-DNS, e.g. dev.q64.my_project.
        \\  --version <semver>     Version (default 0.1.0).
        \\  --license <spdx>       SPDX license (default "MIT OR Apache-2.0").
        \\  --description <text>   One-line description.
        \\  --dir <path>           Target directory (new only; default: last name segment).
        \\
    );
}

fn promptKind(gpa: std.mem.Allocator, io: std.Io, r: *std.Io.Reader) !QubeKind {
    const s = try prompt(gpa, io, r, "type (library/application/workspace)", "library");
    defer gpa.free(s);
    if (std.mem.eql(u8, s, "application") or std.mem.eql(u8, s, "app")) return .application;
    if (std.mem.eql(u8, s, "workspace") or std.mem.eql(u8, s, "ws")) return .workspace;
    return .library;
}

fn qubeWizard(gpa: std.mem.Allocator, io: std.Io, name_default: ?[]const u8) !QubeConfig {
    var buf: [4096]u8 = undefined;
    var fr = std.Io.File.stdin().reader(io, &buf);
    const r = &fr.interface;

    try writeStdout(io, "Creating a new qube. Press enter to accept the [default].\n");
    const name = try prompt(gpa, io, r, "name (reverse-DNS, e.g. dev.q64.my_project)", name_default);
    const kind = try promptKind(gpa, io, r);
    const version = try prompt(gpa, io, r, "version", "0.1.0");
    const license = try prompt(gpa, io, r, "license (SPDX)", "MIT OR Apache-2.0");
    const desc = try prompt(gpa, io, r, "description (optional)", null);
    const description: ?[]const u8 = if (desc.len == 0) blk: {
        gpa.free(desc);
        break :blk null;
    } else desc;
    return .{
        .name = name,
        .kind = kind,
        .version = version,
        .license = license,
        .description = description,
    };
}

fn freeQubeConfig(gpa: std.mem.Allocator, cfg: QubeConfig) void {
    gpa.free(cfg.name);
    gpa.free(cfg.version);
    gpa.free(cfg.license);
    if (cfg.description) |d| gpa.free(d);
}

fn buildQubeManifest(gpa: std.mem.Allocator, cfg: QubeConfig) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "{\n");
    try out.appendSlice(gpa, "  \"$schema\": \"https://q64.dev/schema/qube.json5\",\n");
    try out.print(gpa, "  \"name\": \"{s}\",\n", .{cfg.name});
    try out.print(gpa, "  \"version\": \"{s}\",\n", .{cfg.version});
    try out.print(gpa, "  \"license\": \"{s}\",\n", .{cfg.license});
    if (cfg.description) |d| {
        if (d.len > 0) try out.print(gpa, "  \"description\": \"{s}\",\n", .{d});
    }
    try out.print(gpa, "  \"type\": \"{s}\",\n", .{kindTypeStr(cfg.kind)});
    switch (cfg.kind) {
        .application => try out.appendSlice(gpa, "  \"entry\": \"src/main.q\",\n"),
        .library => try out.appendSlice(gpa, "  \"entry\": \"src/lib.q\",\n"),
        .workspace => try out.appendSlice(gpa, "  \"workspace\": {\n    \"members\": [],\n  },\n"),
    }
    try out.appendSlice(gpa, "}\n");
    return out.toOwnedSlice(gpa);
}

fn scaffoldQube(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, cfg: QubeConfig) !void {
    if (cfg.name.len == 0) {
        try writeStderr(io, "qube: a name is required\n");
        std.process.exit(@intFromEnum(ExitCode.usage));
    }

    try std.Io.Dir.cwd().createDirPath(io, dir);

    const manifest_path = try std.fs.path.join(gpa, &.{ dir, "qube.json5" });
    defer gpa.free(manifest_path);
    if (fileExists(io, manifest_path)) {
        try printStderr(io, "qube: {s} already exists; refusing to overwrite\n", .{manifest_path});
        std.process.exit(@intFromEnum(ExitCode.input));
    }

    const manifest = try buildQubeManifest(gpa, cfg);
    defer gpa.free(manifest);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = manifest_path, .data = manifest });

    switch (cfg.kind) {
        .application => {
            const src_dir = try std.fs.path.join(gpa, &.{ dir, "src" });
            defer gpa.free(src_dir);
            try std.Io.Dir.cwd().createDirPath(io, src_dir);
            const p = try std.fs.path.join(gpa, &.{ dir, "src", "main.q" });
            defer gpa.free(p);
            const body = try std.fmt.allocPrint(gpa, "fn main {{\n    env.out(\"Hello from {s}.\\n\")\n}}\n", .{cfg.name});
            defer gpa.free(body);
            try writeIfAbsent(io, p, body);
        },
        .library => {
            const src_dir = try std.fs.path.join(gpa, &.{ dir, "src" });
            defer gpa.free(src_dir);
            try std.Io.Dir.cwd().createDirPath(io, src_dir);
            const p = try std.fs.path.join(gpa, &.{ dir, "src", "lib.q" });
            defer gpa.free(p);
            const body = try std.fmt.allocPrint(gpa, "//! {s} - a q64 library qube.\n//! Public functions form the qube's exported surface.\n\npub fn greet(name: str) -> str {{\n    \"Hello, {{name}}.\"\n}}\n", .{cfg.name});
            defer gpa.free(body);
            try writeIfAbsent(io, p, body);
        },
        .workspace => {},
    }

    const readme_path = try std.fs.path.join(gpa, &.{ dir, "README.md" });
    defer gpa.free(readme_path);
    const readme = try std.fmt.allocPrint(gpa, "# {s}\n\nA q64 {s} qube.\n", .{ cfg.name, kindTypeStr(cfg.kind) });
    defer gpa.free(readme);
    try writeIfAbsent(io, readme_path, readme);

    try printStdout(io, "Created {s} qube '{s}' in {s}/\n", .{ kindTypeStr(cfg.kind), cfg.name, dir });
    if (cfg.kind != .workspace and !isPublishableName(cfg.name)) {
        try printStderr(io, "note: '{s}' is not a publishable name. Use reverse-DNS with >=2 lowercase segments (e.g. dev.q64.{s}) before `qube publish`.\n", .{ cfg.name, lastSegment(cfg.name) });
    }
}

/// Shared driver for `qube new` (in_place=false) and `qube init` (in_place=true).
fn scaffoldQubeCmd(gpa: std.mem.Allocator, io: std.Io, args_it: *std.process.Args.Iterator, in_place: bool) !void {
    var name_arg: ?[]const u8 = null;
    var kind: QubeKind = .library;
    var version: []const u8 = "0.1.0";
    var license: []const u8 = "MIT OR Apache-2.0";
    var description: ?[]const u8 = null;
    var dir_arg: ?[]const u8 = null;
    var any_flag = false;

    while (args_it.next()) |a| {
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            try qubeHelp(io);
            return;
        } else if (std.mem.eql(u8, a, "--lib")) {
            any_flag = true;
            kind = .library;
        } else if (std.mem.eql(u8, a, "--app")) {
            any_flag = true;
            kind = .application;
        } else if (std.mem.eql(u8, a, "--workspace")) {
            any_flag = true;
            kind = .workspace;
        } else if (std.mem.eql(u8, a, "--name")) {
            any_flag = true;
            name_arg = try flagValue(io, args_it, "--name");
        } else if (std.mem.eql(u8, a, "--version")) {
            any_flag = true;
            version = try flagValue(io, args_it, "--version");
        } else if (std.mem.eql(u8, a, "--license")) {
            any_flag = true;
            license = try flagValue(io, args_it, "--license");
        } else if (std.mem.eql(u8, a, "--description")) {
            any_flag = true;
            description = try flagValue(io, args_it, "--description");
        } else if (std.mem.eql(u8, a, "--dir")) {
            any_flag = true;
            dir_arg = try flagValue(io, args_it, "--dir");
        } else if (std.mem.startsWith(u8, a, "-")) {
            try printStderr(io, "qube: unknown flag: {s}\n", .{a});
            std.process.exit(@intFromEnum(ExitCode.usage));
        } else if (name_arg == null) {
            name_arg = a;
        } else {
            try printStderr(io, "qube: unexpected extra arg: {s}\n", .{a});
            std.process.exit(@intFromEnum(ExitCode.usage));
        }
    }

    // Default name suggestion for `init`: the current directory's basename.
    const cwd_path = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd_path);
    const cwd_base = std.fs.path.basename(cwd_path);

    var cfg: QubeConfig = undefined;
    var owned = false;
    if (any_flag) {
        const default_name: ?[]const u8 = if (in_place) cwd_base else null;
        cfg = .{
            .name = name_arg orelse default_name orelse {
                try writeStderr(io, "qube new: a name is required (positional <name> or --name)\n");
                std.process.exit(@intFromEnum(ExitCode.usage));
            },
            .kind = kind,
            .version = version,
            .license = license,
            .description = description,
        };
    } else {
        const default_name: ?[]const u8 = if (in_place) cwd_base else name_arg;
        cfg = try qubeWizard(gpa, io, default_name);
        owned = true;
    }

    const dir = if (in_place) "." else (dir_arg orelse cfg.name);
    try scaffoldQube(gpa, io, dir, cfg);
    if (owned) freeQubeConfig(gpa, cfg);
}

// ---------------------------------------------------------------------------
// qube pod new / qube pod init  (QubePod deploy manifest, qubepod.jsonc)
// ---------------------------------------------------------------------------
//
// The QubePod manifest schema lives in qubepods/packages/qubepod-schema.
// Mandatory fields: apiVersion, kind ("QubePod"), project (slug), name, and a
// component with `wasm` + `wit.{package,world}`. Everything else is optional.

const default_pod_api_version = "qubepods.dev/v0.1";
const default_http_interface = "qubepods:http/handler";

const PodConfig = struct {
    api_version: []const u8,
    project: []const u8,
    name: []const u8,
    version: ?[]const u8,
    language: ?[]const u8,
    wasm: []const u8,
    // Optional address-space list (comma-separated `wasm32` / `wasm64`). When
    // set, the component is emitted as a `variants` map (one build per address
    // space) instead of the single legacy `wasm`; each variant's path is derived
    // from `wasm` by inserting `.<addr>` before the `.wasm` extension.
    addr: ?[]const u8,
    wit_package: []const u8,
    wit_world: []const u8,
    http_route: ?[]const u8,
    http_interface: []const u8,
    assets_dir: ?[]const u8,
};

/// QubePod `project` slug: `[a-z0-9][a-z0-9-]*` (mirrors the zod schema).
fn isSlug(s: []const u8) bool {
    if (s.len == 0) return false;
    const c0 = s[0];
    if (!((c0 >= 'a' and c0 <= 'z') or (c0 >= '0' and c0 <= '9'))) return false;
    for (s[1..]) |c| {
        if (!((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-')) return false;
    }
    return true;
}

fn podHelp(io: std.Io) !void {
    try writeStdout(io,
        \\usage: qube pod <new [name] | init | login | logout | info | hostname> [flags]
        \\
        \\Auth (qubepods provider):
        \\  qube pod login [--token <t>] [--url <origin>]
        \\                         Save a qubepods token for deploys. The qubepods
        \\                         console mints the token; with no --token it is
        \\                         read (pasted) from stdin. Stored in
        \\                         ~/.qube/pods.toml (separate from `qube login`).
        \\                         The saved --url origin (default
        \\                         https://api.qubepods.com) becomes the default
        \\                         API for deploy / hostname / info.
        \\  qube pod info [--url <origin>]
        \\                         Show the provider, API origin, and auth status.
        \\  qube pod logout        Remove the saved qubepods token.
        \\
        \\Scaffold a QubePod deploy manifest (qubepod.jsonc). With no flags, an
        \\interactive wizard prompts for each field; passing any flag runs
        \\non-interactively. Mandatory: --project, --name, --wasm,
        \\--wit-package, --wit-world.
        \\
        \\Flags:
        \\  --project <slug>       Project slug, e.g. image-tools.        (required)
        \\  --name <name>          App/qube name.                          (required)
        \\  --wasm <path>          Path to the wasm component.             (required)
        \\  --wit-package <id>     WIT package id, e.g. qubepods:app@0.1.0.(required)
        \\  --wit-world <world>    WIT world name.                         (required)
        \\  --addr <list>          Address spaces to ship (wasm32,wasm64); emits a
        \\                         component.variants map. Per-variant paths derive
        \\                         from --wasm (./x.wasm -> ./x.wasm32.wasm). Omit
        \\                         for a single legacy component.wasm.
        \\  --language <lang>      Source language (optional).
        \\  --version <semver>     Manifest version (optional).
        \\  --api-version <ver>    apiVersion (default qubepods.dev/v0.1).
        \\  --http-route <route>   Add an http export at <route>, e.g. /resize.
        \\  --http-interface <id>  http export interface (default qubepods:http/handler).
        \\  --assets <dir>         Ship a static asset tree from <dir>, e.g. ./public.
        \\  --dir <path>           Target directory (new only; default: name).
        \\
        \\See `qube deploy --help` to pack and upload the bundle.
        \\
    );
}

fn podWizard(gpa: std.mem.Allocator, io: std.Io, name_default: ?[]const u8) !PodConfig {
    var buf: [4096]u8 = undefined;
    var fr = std.Io.File.stdin().reader(io, &buf);
    const r = &fr.interface;

    try writeStdout(io, "Creating a QubePod deploy manifest. Press enter to accept the [default].\n");
    const project = try prompt(gpa, io, r, "project (slug, e.g. image-tools)", null);
    const name = try prompt(gpa, io, r, "name (the app/qube name)", name_default);

    const wasm_def = try std.fmt.allocPrint(gpa, "./dist/{s}.wasm", .{name});
    defer gpa.free(wasm_def);
    const wasm = try prompt(gpa, io, r, "component.wasm path", wasm_def);

    const witpkg_def = try std.fmt.allocPrint(gpa, "qubepods:{s}@0.1.0", .{name});
    defer gpa.free(witpkg_def);
    const wit_package = try prompt(gpa, io, r, "component.wit.package", witpkg_def);

    const wit_world = try prompt(gpa, io, r, "component.wit.world", name);

    const addr_raw = try prompt(gpa, io, r, "address spaces (optional, e.g. wasm32,wasm64)", null);
    const addr: ?[]const u8 = if (addr_raw.len == 0) blk: {
        gpa.free(addr_raw);
        break :blk null;
    } else addr_raw;

    const language_raw = try prompt(gpa, io, r, "component.language (optional)", null);
    const language: ?[]const u8 = if (language_raw.len == 0) blk: {
        gpa.free(language_raw);
        break :blk null;
    } else language_raw;
    const api_version = try prompt(gpa, io, r, "apiVersion", default_pod_api_version);
    const route = try prompt(gpa, io, r, "http route (optional, e.g. /resize)", null);
    const http_route: ?[]const u8 = if (route.len == 0) blk: {
        gpa.free(route);
        break :blk null;
    } else route;

    const assets_raw = try prompt(gpa, io, r, "static assets directory (optional, e.g. ./public)", null);
    const assets_dir: ?[]const u8 = if (assets_raw.len == 0) blk: {
        gpa.free(assets_raw);
        break :blk null;
    } else assets_raw;

    return .{
        .api_version = api_version,
        .project = project,
        .name = name,
        .version = null,
        .language = language,
        .wasm = wasm,
        .addr = addr,
        .wit_package = wit_package,
        .wit_world = wit_world,
        .http_route = http_route,
        .http_interface = default_http_interface,
        .assets_dir = assets_dir,
    };
}

fn freePodConfig(gpa: std.mem.Allocator, cfg: PodConfig) void {
    gpa.free(cfg.api_version);
    gpa.free(cfg.project);
    gpa.free(cfg.name);
    gpa.free(cfg.wasm);
    gpa.free(cfg.wit_package);
    gpa.free(cfg.wit_world);
    if (cfg.addr) |a| gpa.free(a);
    if (cfg.language) |l| gpa.free(l);
    if (cfg.http_route) |r| gpa.free(r);
    if (cfg.assets_dir) |d| gpa.free(d);
}

/// Per-address-space wasm path for a `variants` entry: insert `.<addr>` before
/// the `.wasm` extension of the base path (`./dist/r.wasm` -> `./dist/r.wasm32.wasm`).
fn variantWasmPath(gpa: std.mem.Allocator, wasm: []const u8, addr: []const u8) ![]u8 {
    const base = if (std.mem.endsWith(u8, wasm, ".wasm")) wasm[0 .. wasm.len - ".wasm".len] else wasm;
    return std.fmt.allocPrint(gpa, "{s}.{s}.wasm", .{ base, addr });
}

fn buildPodManifest(gpa: std.mem.Allocator, cfg: PodConfig) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "{\n");
    try out.appendSlice(gpa, "  \"$schema\": \"https://schemas.qubepods.com/qubepod.schema.json\",\n");
    try out.print(gpa, "  \"apiVersion\": \"{s}\",\n", .{cfg.api_version});
    try out.appendSlice(gpa, "  \"kind\": \"QubePod\",\n\n");
    try out.print(gpa, "  \"project\": \"{s}\",\n", .{cfg.project});
    try out.print(gpa, "  \"name\": \"{s}\",\n", .{cfg.name});
    if (cfg.version) |v| {
        if (v.len > 0) try out.print(gpa, "  \"version\": \"{s}\",\n", .{v});
    }
    try out.appendSlice(gpa, "\n  \"component\": {\n");
    if (cfg.language) |l| {
        if (l.len > 0) try out.print(gpa, "    \"language\": \"{s}\",\n", .{l});
    }
    if (cfg.addr) |addr_spec| {
        // One wasm build per declared address space.
        try out.appendSlice(gpa, "    \"wit\": {\n");
        try out.print(gpa, "      \"package\": \"{s}\",\n", .{cfg.wit_package});
        try out.print(gpa, "      \"world\": \"{s}\",\n", .{cfg.wit_world});
        try out.appendSlice(gpa, "    },\n");
        try out.appendSlice(gpa, "    \"variants\": {\n");
        var it = std.mem.splitScalar(u8, addr_spec, ',');
        while (it.next()) |tok_raw| {
            const tok = std.mem.trim(u8, tok_raw, " ");
            if (tok.len == 0) continue;
            const vpath = try variantWasmPath(gpa, cfg.wasm, tok);
            defer gpa.free(vpath);
            try out.print(gpa, "      \"{s}\": {{ \"wasm\": \"{s}\" }},\n", .{ tok, vpath });
        }
        try out.appendSlice(gpa, "    },\n  },\n");
    } else {
        try out.print(gpa, "    \"wasm\": \"{s}\",\n", .{cfg.wasm});
        try out.appendSlice(gpa, "    \"wit\": {\n");
        try out.print(gpa, "      \"package\": \"{s}\",\n", .{cfg.wit_package});
        try out.print(gpa, "      \"world\": \"{s}\",\n", .{cfg.wit_world});
        try out.appendSlice(gpa, "    },\n  },\n");
    }
    if (cfg.http_route) |r| {
        if (r.len > 0) {
            try out.appendSlice(gpa, "\n  \"exports\": {\n    \"http\": {\n");
            try out.print(gpa, "      \"interface\": \"{s}\",\n", .{cfg.http_interface});
            try out.print(gpa, "      \"route\": \"{s}\",\n", .{r});
            try out.appendSlice(gpa, "    },\n  },\n");
        }
    }
    if (cfg.assets_dir) |d| {
        if (d.len > 0) {
            try out.appendSlice(gpa, "\n  \"assets\": {\n");
            try out.print(gpa, "    \"directory\": \"{s}\",\n", .{d});
            try out.appendSlice(gpa, "    \"route\": \"/\",\n");
            try out.appendSlice(gpa, "  },\n");
        }
    }
    try out.appendSlice(gpa, "}\n");
    return out.toOwnedSlice(gpa);
}

fn scaffoldPod(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, cfg: PodConfig) !void {
    if (!isSlug(cfg.project)) {
        try printStderr(io, "qube pod: project '{s}' must be a slug ([a-z0-9][a-z0-9-]*), e.g. image-tools\n", .{cfg.project});
        std.process.exit(@intFromEnum(ExitCode.input));
    }
    if (cfg.name.len == 0 or cfg.wasm.len == 0 or cfg.wit_package.len == 0 or cfg.wit_world.len == 0) {
        try writeStderr(io, "qube pod: name, --wasm, --wit-package and --wit-world are all required\n");
        std.process.exit(@intFromEnum(ExitCode.usage));
    }
    if (cfg.addr) |addr_spec| {
        var it = std.mem.splitScalar(u8, addr_spec, ',');
        var n: usize = 0;
        while (it.next()) |tok_raw| {
            const tok = std.mem.trim(u8, tok_raw, " ");
            if (tok.len == 0) continue;
            if (!std.mem.eql(u8, tok, "wasm32") and !std.mem.eql(u8, tok, "wasm64")) {
                try printStderr(io, "qube pod: --addr must be wasm32 or wasm64 (got '{s}')\n", .{tok});
                std.process.exit(@intFromEnum(ExitCode.input));
            }
            n += 1;
        }
        if (n == 0) {
            try writeStderr(io, "qube pod: --addr needs at least one of wasm32, wasm64\n");
            std.process.exit(@intFromEnum(ExitCode.input));
        }
    }

    try std.Io.Dir.cwd().createDirPath(io, dir);
    const path = try std.fs.path.join(gpa, &.{ dir, "qubepod.jsonc" });
    defer gpa.free(path);
    if (fileExists(io, path)) {
        try printStderr(io, "qube pod: {s} already exists; refusing to overwrite\n", .{path});
        std.process.exit(@intFromEnum(ExitCode.input));
    }

    const text = try buildPodManifest(gpa, cfg);
    defer gpa.free(text);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text });

    try printStdout(io, "Created QubePod manifest for '{s}/{s}' at {s}\n", .{ cfg.project, cfg.name, path });
}

fn cmdPod(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    args_it: *std.process.Args.Iterator,
) !void {
    const subsub = args_it.next() orelse {
        try writeStderr(io, "usage: qube pod <new|init|login|logout|info|hostname> [flags]\n");
        std.process.exit(@intFromEnum(ExitCode.usage));
    };
    if (std.mem.eql(u8, subsub, "--help") or std.mem.eql(u8, subsub, "-h")) {
        try podHelp(io);
        return;
    }
    if (std.mem.eql(u8, subsub, "new")) return scaffoldPodCmd(gpa, io, args_it, false);
    if (std.mem.eql(u8, subsub, "init")) return scaffoldPodCmd(gpa, io, args_it, true);
    if (std.mem.eql(u8, subsub, "login")) return cmdPodLogin(gpa, io, env, args_it);
    if (std.mem.eql(u8, subsub, "logout")) return cmdPodLogout(gpa, io, env, args_it);
    if (std.mem.eql(u8, subsub, "info")) return cmdPodInfo(gpa, io, env, args_it);
    if (std.mem.eql(u8, subsub, "deploy")) {
        // `qube pod deploy` was removed — deploy is the top-level `qube deploy`
        // (same command in the shell and a Linux terminal), reading qube.json5.
        try writeStderr(io, "qube pod deploy was removed — use `qube deploy` (reads qube.json5).\n");
        std.process.exit(@intFromEnum(ExitCode.usage));
    }
    if (std.mem.eql(u8, subsub, "hostname")) return cmdPodHostname(gpa, io, env, args_it);
    try printStderr(io, "qube pod: unknown subcommand: {s}\n", .{subsub});
    std.process.exit(@intFromEnum(ExitCode.usage));
}

// ---------------------------------------------------------------------------
// qubepods auth — `qube pod login` / `logout` / `info`
//
// Provider abstraction (today: only qubepods). Credentials live in
// `<qube home>/pods.toml`, separate from the Continuum `credentials.toml`, so
// the two never clobber each other. Token model: the qubepods API has no CLI
// token-issuance endpoint (its `/auth/login` is cookie-based for the console),
// so `qube pod login` saves a token you minted in the qubepods console; it does
// not do an interactive email/password exchange.
// ---------------------------------------------------------------------------

const QubepodsProvider = "qubepods";

fn podsCredPath(gpa: std.mem.Allocator, env: *std.process.Environ.Map) ![]u8 {
    const home = try qubeHome(gpa, env);
    defer gpa.free(home);
    return std.fs.path.join(gpa, &.{ home, "pods.toml" });
}

/// Read the saved qubepods token, or `error.NotLoggedIn` if none. v0 keeps a
/// single provider, so we take the first `token = "…"` line.
fn readPodToken(gpa: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map) ![]u8 {
    const path = try podsCredPath(gpa, env);
    defer gpa.free(path);
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024)) catch
        return error.NotLoggedIn;
    defer gpa.free(text);
    const key = "token = \"";
    const i = std.mem.indexOf(u8, text, key) orelse return error.NotLoggedIn;
    const start = i + key.len;
    const end = std.mem.indexOfScalarPos(u8, text, start, '"') orelse return error.NotLoggedIn;
    return gpa.dupe(u8, text[start..end]);
}

// ---------------------------------------------------------------------------

const default_pods_api = "https://api.qubepods.com";

/// Strip a leading "./" from a manifest-relative path.
fn stripDotSlash(s: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, s, "./")) s[2..] else s;
}

/// The API origin `qube pod login --url …` saved into pods.toml (the host is
/// the `[pods."<host>"]` table name; login strips the scheme, so https is
/// reconstructed here), or null when not logged in. Commands resolve the
/// origin as: `--url` flag > saved login host > `default_pods_api` — so a
/// bare `qube deploy` after `qube pod login --url <origin>` targets that
/// origin (previously the saved host was write-only and the default always
/// won, silently sending post-login deploys to the default API).
fn readPodUrl(gpa: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map) ?[]u8 {
    const path = podsCredPath(gpa, env) catch return null;
    defer gpa.free(path);
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024)) catch return null;
    defer gpa.free(text);
    const key = "[pods.\"";
    const i = std.mem.indexOf(u8, text, key) orelse return null;
    const start = i + key.len;
    const end = std.mem.indexOfScalarPos(u8, text, start, '"') orelse return null;
    if (end == start) return null;
    return std.fmt.allocPrint(gpa, "https://{s}", .{text[start..end]}) catch null;
}

fn cmdPodLogin(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    args_it: *std.process.Args.Iterator,
) !void {
    // qube pod login [--token <t>] [--url <origin>]
    var api_url: []const u8 = default_pods_api;
    var token_flag: ?[]const u8 = null;
    while (args_it.next()) |a| {
        if (std.mem.eql(u8, a, "--url")) {
            api_url = try flagValue(io, args_it, "--url");
        } else if (std.mem.eql(u8, a, "--token")) {
            token_flag = try flagValue(io, args_it, "--token");
        } else if (std.mem.startsWith(u8, a, "-")) {
            try printStderr(io, "qube pod login: unknown flag: {s}\n", .{a});
            std.process.exit(@intFromEnum(ExitCode.usage));
        } else {
            try printStderr(io, "qube pod login: unexpected arg: {s}\n", .{a});
            std.process.exit(@intFromEnum(ExitCode.usage));
        }
    }

    // The qubepods console (app.qubepods.com) mints project API tokens; the API
    // has no CLI token exchange, so we save a token rather than do an email/
    // password login. --token wins; else read one (pasted) from stdin.
    var token_owned: ?[]u8 = null;
    defer if (token_owned) |t| gpa.free(t);
    const token: []const u8 = if (token_flag) |t| t else blk: {
        try writeStdout(io, "Paste your qubepods token (from the console): ");
        const line = try readPasswordSilent(gpa, io);
        token_owned = line;
        try writeStdout(io, "\n");
        break :blk std.mem.trim(u8, line, " \t\r\n");
    };
    if (token.len == 0) {
        try writeStderr(io, "qube pod login: empty token\n");
        std.process.exit(@intFromEnum(ExitCode.usage));
    }

    const host = stripScheme(api_url);
    const home = try qubeHome(gpa, env);
    defer gpa.free(home);
    try std.Io.Dir.cwd().createDirPath(io, home);
    const path = try podsCredPath(gpa, env);
    defer gpa.free(path);

    const toml = try std.fmt.allocPrint(gpa,
        \\# qubepods credentials. Written by `qube pod login`.
        \\# Do not check in. The token grants deploy access to your qubes.
        \\
        \\provider = "{s}"
        \\
        \\[pods."{s}"]
        \\token = "{s}"
        \\
    , .{ QubepodsProvider, host, token });
    defer gpa.free(toml);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = toml });
    try printStdout(io, "Saved qubepods token for {s} in {s}.\n", .{ host, path });
}

fn cmdPodLogout(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    args_it: *std.process.Args.Iterator,
) !void {
    while (args_it.next()) |a| {
        try printStderr(io, "qube pod logout: unexpected arg: {s}\n", .{a});
        std.process.exit(@intFromEnum(ExitCode.usage));
    }
    const path = try podsCredPath(gpa, env);
    defer gpa.free(path);
    std.Io.Dir.cwd().deleteFile(io, path) catch {
        try writeStdout(io, "Not logged in to qubepods.\n");
        return;
    };
    try printStdout(io, "Logged out of qubepods (removed {s}).\n", .{path});
}

fn cmdPodInfo(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    args_it: *std.process.Args.Iterator,
) !void {
    var api_url: []const u8 = default_pods_api;
    var api_src: []const u8 = "default";
    while (args_it.next()) |a| {
        if (std.mem.eql(u8, a, "--url")) {
            api_url = try flagValue(io, args_it, "--url");
            api_src = "--url";
        } else {
            try printStderr(io, "qube pod info: unknown flag: {s}\n", .{a});
            std.process.exit(@intFromEnum(ExitCode.usage));
        }
    }
    var saved_url: ?[]u8 = null;
    defer if (saved_url) |u| gpa.free(u);
    if (std.mem.eql(u8, api_src, "default")) {
        if (readPodUrl(gpa, io, env)) |u| {
            saved_url = u;
            api_url = u;
            api_src = "saved by `qube pod login`";
        }
    }

    const authed = blk: {
        const t = readPodToken(gpa, io, env) catch break :blk false;
        gpa.free(t);
        break :blk true;
    };

    try printStdout(io,
        \\Provider:       {s}
        \\API:            {s}  ({s})
        \\Authenticated:  {s}
        \\
    , .{
        QubepodsProvider,
        api_url,
        api_src,
        if (authed) "yes  (token in pods.toml; run `qube pod logout` to clear)" else "no   (run `qube pod login`)",
    });
}

// qube deploy  (pack the bundle zip and upload it to qubepods)

// Stage the manifest, every component wasm (each at its manifest-relative path),
// and the asset tree, then zip them at the archive root (no wrapping folder).
// OUT is absolute so the trailing `zip` (run from $STAGE) writes to the right
// place. Wasm paths are passed as trailing args so a dual-variant qube ships
// both its wasm32 and wasm64 build.
const pod_pack_script =
    \\set -e
    \\PROJECT="$1"; OUT="$2"; MANIFEST="$3"; ASSETS="$4"; shift 4
    \\STAGE="$(mktemp -d)"
    \\mkdir -p "$(dirname "$OUT")"
    \\cd "$PROJECT"
    \\# The wire manifest is the synthesized, strict qubepod.jsonc (built from
    \\# qube.json5 by the caller) — the repo itself only carries qube.json5.
    \\cp "$MANIFEST" "$STAGE/qubepod.jsonc"
    \\for WASM in "$@"; do
    \\  mkdir -p "$STAGE/$(dirname "$WASM")"
    \\  cp "$WASM" "$STAGE/$WASM"
    \\done
    \\if [ -n "$ASSETS" ] && [ -d "$ASSETS" ]; then
    \\  mkdir -p "$STAGE/$ASSETS"
    \\  cp -R "$ASSETS/." "$STAGE/$ASSETS/"
    \\fi
    \\cd "$STAGE"
    \\find . -name .DS_Store -delete 2>/dev/null || true
    \\rm -f "$OUT"
    \\zip -rqX "$OUT" .
    \\rm -rf "$STAGE"
;

fn deployHelp(io: std.Io) !void {
    try writeStdout(io,
        \\usage: qube deploy [flags]
        \\
        \\Deploy this qube to qubepods. Reads qube.json5 (the qube's manifest — no
        \\separate deploy file). If it has a `build` command, run it first (cwd =
        \\manifest dir), then pack the bundle (qube.json5 + the component wasm or JS
        \\module + the asset tree named by assets.directory) into
        \\target/deploy/<name>.zip and upload it. Run from the qube directory.
        \\
        \\The SAME command in the qubepods web shell and a Linux terminal.
        \\
        \\Flags:
        \\  --env <name>     Target environment (default: production).
        \\  --url <origin>   API origin (default: the origin saved by `qube pod
        \\                   login`, else https://api.qubepods.com).
        \\  --token <jwt>    Bearer token (or set QUBEPODS_TOKEN).
        \\  --no-build       Skip the manifest `build` command; pack on-disk bytes.
        \\
    );
}

fn cmdDeploy(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    args_it: *std.process.Args.Iterator,
) !void {
    var api_url: []const u8 = default_pods_api;
    var url_flagged = false;
    var environment_name: []const u8 = "production";
    var token_flag: ?[]const u8 = null;
    var skip_build = false;
    while (args_it.next()) |a| {
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            try deployHelp(io);
            return;
        } else if (std.mem.eql(u8, a, "--url")) {
            api_url = try flagValue(io, args_it, "--url");
            url_flagged = true;
        } else if (std.mem.eql(u8, a, "--env")) {
            environment_name = try flagValue(io, args_it, "--env");
        } else if (std.mem.eql(u8, a, "--token")) {
            token_flag = try flagValue(io, args_it, "--token");
        } else if (std.mem.eql(u8, a, "--no-build")) {
            skip_build = true;
        } else {
            try printStderr(io, "qube deploy: unknown flag: {s}\n", .{a});
            std.process.exit(@intFromEnum(ExitCode.usage));
        }
    }

    // --url wins; else the origin saved by `qube pod login`; else the default.
    var saved_url: ?[]u8 = null;
    defer if (saved_url) |u| gpa.free(u);
    if (!url_flagged) {
        if (readPodUrl(gpa, io, env)) |u| {
            saved_url = u;
            api_url = u;
        }
    }

    const cwd_path = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd_path);

    // The qube's OWN manifest — qube.json5. There is no separate deploy file;
    // `qube deploy` reads the same manifest `qube run`/`qube build` do.
    const manifest_path = try std.fs.path.join(gpa, &.{ cwd_path, "qube.json5" });
    defer gpa.free(manifest_path);
    if (!fileExists(io, manifest_path)) {
        try writeStderr(io, "qube deploy: no qube.json5 in this directory\n");
        std.process.exit(@intFromEnum(ExitCode.input));
    }

    const raw = try std.Io.Dir.cwd().readFileAlloc(io, manifest_path, gpa, .limited(1024 * 1024));
    defer gpa.free(raw);

    // qube.json5 is JSON5 (unquoted keys, comments) — convert then parse, so
    // fields are read structurally, not by scanning the raw text.
    const manifest_json = json5.toJson(gpa, raw) catch |err| {
        try printStderr(io, "qube deploy: cannot parse qube.json5: {s}\n", .{@errorName(err)});
        std.process.exit(@intFromEnum(ExitCode.input));
    };
    defer gpa.free(manifest_json);

    const parsed = std.json.parseFromSlice(std.json.Value, gpa, manifest_json, .{}) catch |err| {
        try printStderr(io, "qube deploy: cannot parse qube.json5: {s}\n", .{@errorName(err)});
        std.process.exit(@intFromEnum(ExitCode.input));
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => {
            try writeStderr(io, "qube deploy: qube.json5 is not a JSON object\n");
            std.process.exit(@intFromEnum(ExitCode.input));
        },
    };

    const name = try gpa.dupe(u8, manifestString(root, "name") orelse {
        try writeStderr(io, "qube deploy: qube.json5 has no \"name\" field\n");
        std.process.exit(@intFromEnum(ExitCode.input));
    });
    defer gpa.free(name);

    // `project` (the qubepods project slug) is required by the deploy API and is
    // pinned to your deploy token. Fail early with a clear message rather than a
    // server-side schema rejection.
    if (manifestString(root, "project") == null) {
        try writeStderr(io, "qube deploy: qube.json5 has no \"project\" — set it to your qubepods project slug\n");
        std.process.exit(@intFromEnum(ExitCode.input));
    }

    // Optional `build` command: run it (cwd = manifest dir) BEFORE packing, so the
    // bundle ships freshly-compiled wasm/assets rather than stale on-disk bytes.
    // String form only for now (run via `sh -c`); an array form (argv) is a
    // follow-up. `--no-build` skips it.
    if (!skip_build) {
        if (manifestString(root, "build")) |build_cmd| {
            try printStdout(io, "qube deploy: build: {s}\n", .{build_cmd});
            // cwd is already the manifest dir (we read qube.json5 from cwd).
            const argv = [_][]const u8{ "sh", "-c", build_cmd };
            const term = spawnInherit(io, &argv) catch |err| {
                try printStderr(io, "qube deploy: cannot run build: {s}\n", .{@errorName(err)});
                std.process.exit(@intFromEnum(ExitCode.internal));
            };
            if (termCode(term) != 0) {
                try writeStderr(io, "qube deploy: build command failed\n");
                std.process.exit(@intFromEnum(ExitCode.internal));
            }
        }
    }

    // The component artifact(s) to ship, from `component`:
    //   module   -> a classic JS worker entry (no wasm on the server);
    //   wasm     -> a single wasm component / core module;
    //   variants -> one wasm per address space (wasm32 / wasm64).
    // The API bundler accepts a `.js` module as well as wasm (apps/api/src/bundle.ts),
    // so a classic JS qube deploys the same way — the packer just stages the named
    // entry file alongside the manifest + assets.
    var wasm_norms: std.ArrayList([]const u8) = .empty;
    defer {
        for (wasm_norms.items) |p| gpa.free(p);
        wasm_norms.deinit(gpa);
    }
    if (manifestNestedString(root, "component", "module")) |mod_rel| {
        try wasm_norms.append(gpa, try gpa.dupe(u8, stripDotSlash(mod_rel)));
    } else if (manifestNestedString(root, "component", "wasm")) |wasm_rel| {
        try wasm_norms.append(gpa, try gpa.dupe(u8, stripDotSlash(wasm_rel)));
    } else {
        // component.variants.{wasm32,wasm64}.wasm — one build per address space.
        if (root.get("component")) |comp| switch (comp) {
            .object => |co| if (co.get("variants")) |variants| switch (variants) {
                .object => |vo| {
                    for ([_][]const u8{ "wasm32", "wasm64" }) |addr| {
                        if (vo.get(addr)) |av| switch (av) {
                            .object => |ao| if (manifestString(ao, "wasm")) |p| {
                                try wasm_norms.append(gpa, try gpa.dupe(u8, stripDotSlash(p)));
                            },
                            else => {},
                        };
                    }
                },
                else => {},
            },
            else => {},
        };
        if (wasm_norms.items.len == 0) {
            // A static qube (`static: { dir }`, spec qube.json5.md §Static) has
            // no component by design — the deploy API accepts an assets-only
            // bundle, and the web shell has always shipped this shape. Anything
            // else without a component is an error.
            if (manifestNestedString(root, "static", "dir") == null) {
                try writeStderr(io, "qube deploy: qube.json5 has no component.module, component.wasm, component.variants, or static.dir\n");
                std.process.exit(@intFromEnum(ExitCode.input));
            }
        }
    }

    // Optional asset tree: assets.directory, or the static qube's `static.dir`
    // (which becomes `assets.directory` on the wire — see synthesizeQubepodJson).
    const assets_dir_opt = manifestNestedString(root, "assets", "directory") orelse
        manifestNestedString(root, "static", "dir");
    const assets_norm = if (assets_dir_opt) |d| stripDotSlash(d) else "";

    // Token: --token wins, else QUBEPODS_TOKEN, else the saved `qube pod login`
    // credentials. The first two are borrowed; the saved one is owned (freed).
    var saved_token: ?[]u8 = null;
    defer if (saved_token) |t| gpa.free(t);
    var token_source: []const u8 = "--token";
    const token: []const u8 = token_flag orelse blk0: {
        if (env.get("QUBEPODS_TOKEN")) |t| {
            token_source = "QUBEPODS_TOKEN";
            break :blk0 t;
        }
        const t = readPodToken(gpa, io, env) catch {
            try writeStderr(io, "qube deploy: no token; run `qube pod login`, pass --token, or set QUBEPODS_TOKEN\n");
            std.process.exit(@intFromEnum(ExitCode.registry));
        };
        token_source = "saved login (~/.qube/pods.toml)";
        saved_token = t;
        break :blk0 t;
    };

    // Pack target/deploy/<name>.zip (absolute, so the staged `zip` finds it).
    const out_zip = try std.fs.path.join(gpa, &.{ cwd_path, "target", "deploy", name });
    defer gpa.free(out_zip);
    const out_zip_full = try std.fmt.allocPrint(gpa, "{s}.zip", .{out_zip});
    defer gpa.free(out_zip_full);

    // Synthesize the strict qubepod.jsonc from qube.json5 and stage it on disk;
    // the packer copies it into the bundle as the wire manifest (the repo stays a
    // single qube.json5 — nothing to check in).
    const deploy_dir = try std.fs.path.join(gpa, &.{ cwd_path, "target", "deploy" });
    defer gpa.free(deploy_dir);
    try std.Io.Dir.cwd().createDirPath(io, deploy_dir);
    const manifest_out = try std.fs.path.join(gpa, &.{ deploy_dir, "qubepod.jsonc" });
    defer gpa.free(manifest_out);
    {
        // The wire manifest comes from the SHARED synthesis (deploy_manifest.zig)
        // — the same implementation the browser shell runs, so the two frontends
        // cannot emit different QubePods for the same qube.json5.
        const manifest_body = switch (deploy_manifest.synthesize(gpa, raw, .{})) {
            .ok => |m| m,
            .err => |e| {
                try printStderr(io, "qube deploy: {s}\n", .{e});
                std.process.exit(@intFromEnum(ExitCode.input));
            },
        };
        defer gpa.free(manifest_body);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = manifest_out, .data = manifest_body });
    }

    {
        // sh -c <script> sh PROJECT OUT MANIFEST ASSETS <wasm...>
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ "sh", "-c", pod_pack_script, "sh", cwd_path, out_zip_full, manifest_out, assets_norm });
        try argv.appendSlice(gpa, wasm_norms.items);
        const term = try spawnInherit(io, argv.items);
        if (termCode(term) != 0) {
            try writeStderr(io, "qube deploy: packing the bundle failed\n");
            std.process.exit(@intFromEnum(ExitCode.internal));
        }
    }
    try printStdout(io, "qube deploy: packed {s}\n", .{out_zip_full});

    // Upload the bundle (multipart: environment + bundle zip).
    const url = try std.fmt.allocPrint(gpa, "{s}/api/deploy", .{api_url});
    defer gpa.free(url);
    const auth = try std.fmt.allocPrint(gpa, "authorization: Bearer {s}", .{token});
    defer gpa.free(auth);
    const env_field = try std.fmt.allocPrint(gpa, "environment={s}", .{environment_name});
    defer gpa.free(env_field);
    const bundle_field = try std.fmt.allocPrint(gpa, "bundle=@{s};type=application/zip", .{out_zip_full});
    defer gpa.free(bundle_field);

    const argv = [_][]const u8{
        "curl",     "-sS",      "-w", "\n%{http_code}",
        "-X",       "POST",     url,  "-H",
        auth,       "-F",       env_field,
        "-F",       bundle_field,
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
        try printStdout(io, "Deployed {s} to {s}.\n{s}\n", .{ name, environment_name, body });
        return;
    }
    try printStderr(io, "qube deploy: api returned {d}:\n{s}\n", .{ status, body });
    // A wrong/stale key is the usual cause — show exactly which token
    // was sent and where it came from, so the mismatch is visible.
    try printStderr(io, "  token used ({s}): QUBEPODS_TOKEN={s}\n", .{ token_source, token });
    std.process.exit(@intFromEnum(ExitCode.registry));
}

// ---------------------------------------------------------------------------
// qube pod hostname — choose a subdomain (<name>.<root>) for this app
//
//   qube pod hostname                 show the current hostname + available roots
//   qube pod hostname <name> [--root qubepod.app|etiamo.app]   set it
//   qube pod hostname --clear         release the current hostname
//
// Reads project + app name from qubepod.jsonc in the cwd (the deploy target),
// and the saved token (qube pod login) / --token / QUBEPODS_TOKEN, same as deploy.
// ---------------------------------------------------------------------------
fn cmdPodHostname(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    args_it: *std.process.Args.Iterator,
) !void {
    var api_url: []const u8 = default_pods_api;
    var url_flagged = false;
    var token_flag: ?[]const u8 = null;
    var root: []const u8 = "qubepod.app";
    var name_arg: ?[]const u8 = null;
    var clear = false;
    while (args_it.next()) |a| {
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            try writeStdout(io,
                \\usage: qube pod hostname [<name>] [flags]
                \\
                \\Choose a subdomain (<name>.<root>) for this app, or show the current one.
                \\Run from the directory holding qubepod.jsonc.
                \\
                \\  (no name)        Show the current hostname and available roots.
                \\  <name>           Set the subdomain label (3–63 chars, [a-z0-9-]).
                \\  --root <root>    qubepod.app (default) or etiamo.app.
                \\  --clear          Release the current hostname.
                \\  --url <origin>   API origin (default: the origin saved by
                \\                   `qube pod login`, else api.qubepods.com).
                \\  --token <jwt>    Bearer token (or QUBEPODS_TOKEN / qube pod login).
                \\
            );
            return;
        } else if (std.mem.eql(u8, a, "--url")) {
            api_url = try flagValue(io, args_it, "--url");
            url_flagged = true;
        } else if (std.mem.eql(u8, a, "--token")) {
            token_flag = try flagValue(io, args_it, "--token");
        } else if (std.mem.eql(u8, a, "--root")) {
            root = try flagValue(io, args_it, "--root");
        } else if (std.mem.eql(u8, a, "--clear")) {
            clear = true;
        } else if (std.mem.startsWith(u8, a, "-")) {
            try printStderr(io, "qube pod hostname: unknown flag: {s}\n", .{a});
            std.process.exit(@intFromEnum(ExitCode.usage));
        } else {
            name_arg = a;
        }
    }

    // --url wins; else the origin saved by `qube pod login`; else the default.
    var saved_url: ?[]u8 = null;
    defer if (saved_url) |u| gpa.free(u);
    if (!url_flagged) {
        if (readPodUrl(gpa, io, env)) |u| {
            saved_url = u;
            api_url = u;
        }
    }

    // Project + app name from qubepod.jsonc.
    const cwd_path = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd_path);
    const manifest_path = try std.fs.path.join(gpa, &.{ cwd_path, "qubepod.jsonc" });
    defer gpa.free(manifest_path);
    if (!fileExists(io, manifest_path)) {
        try writeStderr(io, "qube pod hostname: no qubepod.jsonc in this directory\n");
        std.process.exit(@intFromEnum(ExitCode.input));
    }
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, manifest_path, gpa, .limited(1024 * 1024));
    defer gpa.free(raw);
    const project = extractStringField(raw, "\"project\"") orelse {
        try writeStderr(io, "qube pod hostname: manifest has no \"project\"\n");
        std.process.exit(@intFromEnum(ExitCode.input));
    };
    const app_name = extractStringField(raw, "\"name\"") orelse {
        try writeStderr(io, "qube pod hostname: manifest has no \"name\"\n");
        std.process.exit(@intFromEnum(ExitCode.input));
    };

    // Token: --token > QUBEPODS_TOKEN > saved login.
    var saved_token: ?[]u8 = null;
    defer if (saved_token) |t| gpa.free(t);
    var token_source: []const u8 = "--token";
    const token: []const u8 = token_flag orelse blk0: {
        if (env.get("QUBEPODS_TOKEN")) |t| {
            token_source = "QUBEPODS_TOKEN";
            break :blk0 t;
        }
        const t = readPodToken(gpa, io, env) catch {
            try writeStderr(io, "qube pod hostname: no token; run `qube pod login`, pass --token, or set QUBEPODS_TOKEN\n");
            std.process.exit(@intFromEnum(ExitCode.registry));
        };
        token_source = "saved login (~/.qube/pods.toml)";
        saved_token = t;
        break :blk0 t;
    };

    const base = try std.fmt.allocPrint(gpa, "{s}/me/projects/{s}/apps/{s}/hostname", .{ api_url, project, app_name });
    defer gpa.free(base);
    const auth = try std.fmt.allocPrint(gpa, "authorization: Bearer {s}", .{token});
    defer gpa.free(auth);

    // GET (show), PUT (set), or DELETE (clear).
    var cap: Captured = undefined;
    if (clear) {
        const argv = [_][]const u8{ "curl", "-sS", "-w", "\n%{http_code}", "-X", "DELETE", base, "-H", auth };
        cap = try runCapture(gpa, io, &argv);
    } else if (name_arg) |nm| {
        const body_json = try std.fmt.allocPrint(gpa, "{{\"name\":\"{s}\",\"root\":\"{s}\"}}", .{ nm, root });
        defer gpa.free(body_json);
        const argv = [_][]const u8{ "curl", "-sS", "-w", "\n%{http_code}", "-X", "PUT", base, "-H", auth, "-H", "content-type: application/json", "-d", body_json };
        cap = try runCapture(gpa, io, &argv);
    } else {
        const argv = [_][]const u8{ "curl", "-sS", "-w", "\n%{http_code}", base, "-H", auth };
        cap = try runCapture(gpa, io, &argv);
    }
    defer gpa.free(cap.stdout);

    const nl = std.mem.lastIndexOfScalar(u8, cap.stdout, '\n') orelse cap.stdout.len;
    const resp_body = cap.stdout[0..nl];
    const status = if (nl < cap.stdout.len)
        std.fmt.parseInt(u16, std.mem.trim(u8, cap.stdout[nl + 1 ..], " \r\n"), 10) catch 0
    else
        0;

    if (status >= 200 and status < 300) {
        if (extractStringField(resp_body, "\"hostnameUrl\"")) |u| {
            try printStdout(io, "{s}\n", .{u});
        } else if (clear) {
            try printStdout(io, "hostname released.\n", .{});
        } else {
            try printStdout(io, "{s}\n", .{resp_body});
        }
        if (extractStringField(resp_body, "\"warning\"")) |w| {
            try printStderr(io, "warning: {s}\n", .{w});
        }
        return;
    }
    try printStderr(io, "qube pod hostname: api returned {d}:\n{s}\n", .{ status, resp_body });
    try printStderr(io, "  token used ({s}): QUBEPODS_TOKEN={s}\n", .{ token_source, token });
    std.process.exit(@intFromEnum(ExitCode.registry));
}

/// Shared driver for `qube pod new` (in_place=false) and `qube pod init`.
fn scaffoldPodCmd(gpa: std.mem.Allocator, io: std.Io, args_it: *std.process.Args.Iterator, in_place: bool) !void {
    var name_arg: ?[]const u8 = null;
    var project: ?[]const u8 = null;
    var wasm: ?[]const u8 = null;
    var addr: ?[]const u8 = null;
    var wit_package: ?[]const u8 = null;
    var wit_world: ?[]const u8 = null;
    var language: ?[]const u8 = null;
    var version: ?[]const u8 = null;
    var api_version: []const u8 = default_pod_api_version;
    var http_route: ?[]const u8 = null;
    var http_interface: []const u8 = default_http_interface;
    var assets_dir: ?[]const u8 = null;
    var dir_arg: ?[]const u8 = null;
    var any_flag = false;

    while (args_it.next()) |a| {
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            try podHelp(io);
            return;
        } else if (std.mem.eql(u8, a, "--project")) {
            any_flag = true;
            project = try flagValue(io, args_it, "--project");
        } else if (std.mem.eql(u8, a, "--name")) {
            any_flag = true;
            name_arg = try flagValue(io, args_it, "--name");
        } else if (std.mem.eql(u8, a, "--wasm")) {
            any_flag = true;
            wasm = try flagValue(io, args_it, "--wasm");
        } else if (std.mem.eql(u8, a, "--addr")) {
            any_flag = true;
            addr = try flagValue(io, args_it, "--addr");
        } else if (std.mem.eql(u8, a, "--wit-package")) {
            any_flag = true;
            wit_package = try flagValue(io, args_it, "--wit-package");
        } else if (std.mem.eql(u8, a, "--wit-world")) {
            any_flag = true;
            wit_world = try flagValue(io, args_it, "--wit-world");
        } else if (std.mem.eql(u8, a, "--language")) {
            any_flag = true;
            language = try flagValue(io, args_it, "--language");
        } else if (std.mem.eql(u8, a, "--version")) {
            any_flag = true;
            version = try flagValue(io, args_it, "--version");
        } else if (std.mem.eql(u8, a, "--api-version")) {
            any_flag = true;
            api_version = try flagValue(io, args_it, "--api-version");
        } else if (std.mem.eql(u8, a, "--http-route")) {
            any_flag = true;
            http_route = try flagValue(io, args_it, "--http-route");
        } else if (std.mem.eql(u8, a, "--http-interface")) {
            any_flag = true;
            http_interface = try flagValue(io, args_it, "--http-interface");
        } else if (std.mem.eql(u8, a, "--assets")) {
            any_flag = true;
            assets_dir = try flagValue(io, args_it, "--assets");
        } else if (std.mem.eql(u8, a, "--dir")) {
            any_flag = true;
            dir_arg = try flagValue(io, args_it, "--dir");
        } else if (std.mem.startsWith(u8, a, "-")) {
            try printStderr(io, "qube pod: unknown flag: {s}\n", .{a});
            std.process.exit(@intFromEnum(ExitCode.usage));
        } else if (name_arg == null) {
            name_arg = a;
        } else {
            try printStderr(io, "qube pod: unexpected extra arg: {s}\n", .{a});
            std.process.exit(@intFromEnum(ExitCode.usage));
        }
    }

    const cwd_path = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd_path);
    const cwd_base = std.fs.path.basename(cwd_path);

    var cfg: PodConfig = undefined;
    var owned = false;
    if (any_flag) {
        cfg = .{
            .api_version = api_version,
            .project = project orelse {
                try writeStderr(io, "qube pod: --project is required\n");
                std.process.exit(@intFromEnum(ExitCode.usage));
            },
            .name = name_arg orelse (if (in_place) cwd_base else {
                try writeStderr(io, "qube pod: a name is required (positional <name> or --name)\n");
                std.process.exit(@intFromEnum(ExitCode.usage));
            }),
            .version = version,
            .language = language,
            .wasm = wasm orelse {
                try writeStderr(io, "qube pod: --wasm is required\n");
                std.process.exit(@intFromEnum(ExitCode.usage));
            },
            .addr = addr,
            .wit_package = wit_package orelse {
                try writeStderr(io, "qube pod: --wit-package is required\n");
                std.process.exit(@intFromEnum(ExitCode.usage));
            },
            .wit_world = wit_world orelse {
                try writeStderr(io, "qube pod: --wit-world is required\n");
                std.process.exit(@intFromEnum(ExitCode.usage));
            },
            .http_route = http_route,
            .http_interface = http_interface,
            .assets_dir = assets_dir,
        };
    } else {
        const default_name: ?[]const u8 = if (in_place) cwd_base else name_arg;
        cfg = try podWizard(gpa, io, default_name);
        owned = true;
    }

    const dir = if (in_place) "." else (dir_arg orelse cfg.name);
    try scaffoldPod(gpa, io, dir, cfg);
    if (owned) freePodConfig(gpa, cfg);
}

test {
    // Pull the shared deploy-manifest module into the test build (its tests
    // guard the wire contract both frontends emit).
    _ = deploy_manifest;
}
