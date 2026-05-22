//! qube — the package and build tool. CLI surface specified in
//! spec/qube-cli.md, manifest schema in spec/qube.json5.md.
//!
//! v0 scope: `qube run`, `qube web`, and `qube --version`. Everything
//! else prints "not implemented yet" and exits 2. `qube run`
//! discovers the nearest `qube.json5`, parses minimal fields (strict
//! JSON for now), shells out to `q64 emit` then `q64-wasmtime-host`.
//! `qube web` shells out to `q64 emit`, copies the browser adapter
//! into `target/web/`, serves it via `python3 -m http.server`, and
//! opens the default browser.

const std = @import("std");
const builtin = @import("builtin");

const version_string = "qube 0.0.1 (pre-alpha)";

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
    internal = 70,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const env = init.environ_map;

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

    // Documented subcommands that are not implemented yet. Listed
    // explicitly so unknown names still hit the usage fallback.
    const stub_subs = [_][]const u8{
        "new",     "init",   "add",      "remove",  "build",
        "test",    "install", "lock",    "publish", "outdated",
        "audit",   "clean",  "explain",  "fix",     "fmt",
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
        \\  --version, -v           Print the version and exit.
        \\  --help, -h              Print this help and exit.
        \\
        \\Other subcommands from the spec (new, init, build, test, publish,
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

const Manifest = struct {
    // TODO: full json5 parsing per spec/qube.json5.md. v0 reads strict
    // JSON via std.json. Once the parser lands, swap this for it.
    name: []const u8,
    version: ?[]const u8 = null,
    @"type": ?[]const u8 = null,
    entry: ?[]const u8 = null,
};

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

    const parsed = std.json.parseFromSlice(Manifest, gpa, manifest_src, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        try printStderr(io, "qube: cannot parse {s}: {s}\n", .{ manifest_path, @errorName(err) });
        try writeStderr(io, "qube: note: v0 accepts strict JSON only; JSON5 features are not yet supported\n");
        std.process.exit(@intFromEnum(ExitCode.input));
    };
    defer parsed.deinit();

    const m = parsed.value;
    const is_app = if (m.@"type") |t| std.mem.eql(u8, t, "application") else true;
    if (!is_app) {
        try printStderr(io, "qube: cannot run a {s} qube\n", .{m.@"type".?});
        std.process.exit(@intFromEnum(ExitCode.usage));
    }

    // Resolve entry; default per spec is src/main.q for applications.
    const entry_rel = m.entry orelse "src/main.q";
    const entry_path = try std.fs.path.join(gpa, &.{ project_dir, entry_rel });
    defer gpa.free(entry_path);

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

    const wasm_name = try std.fmt.allocPrint(gpa, "{s}.wasm", .{m.name});
    defer gpa.free(wasm_name);
    const wasm_path = try std.fs.path.join(gpa, &.{ out_dir, wasm_name });
    defer gpa.free(wasm_path);

    // 1. q64 emit <entry> <wasm>
    {
        const argv = [_][]const u8{ q64_bin, "emit", entry_path, wasm_path };
        const term = try spawnInherit(io, &argv);
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

    const parsed = std.json.parseFromSlice(Manifest, gpa, manifest_src, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        try printStderr(io, "qube: cannot parse {s}: {s}\n", .{ manifest_path, @errorName(err) });
        try writeStderr(io, "qube: note: v0 accepts strict JSON only; JSON5 features are not yet supported\n");
        std.process.exit(@intFromEnum(ExitCode.input));
    };
    defer parsed.deinit();

    const m = parsed.value;
    const is_app = if (m.@"type") |t| std.mem.eql(u8, t, "application") else true;
    if (!is_app) {
        try printStderr(io, "qube: cannot serve a {s} qube\n", .{m.@"type".?});
        std.process.exit(@intFromEnum(ExitCode.usage));
    }

    const entry_rel = m.entry orelse "src/main.q";
    const entry_path = try std.fs.path.join(gpa, &.{ project_dir, entry_rel });
    defer gpa.free(entry_path);

    const repo_root_opt = findRepoRoot(gpa, io, project_dir) catch null;
    defer if (repo_root_opt) |r| gpa.free(r);

    const q64_bin = try resolveBinary(gpa, io, env, "Q64_BIN", repo_root_opt, "q64/zig-out/bin/q64", "q64");
    defer gpa.free(q64_bin);

    const adapter_dir = try resolveAdapterDir(gpa, io, env, repo_root_opt);
    defer gpa.free(adapter_dir);

    const web_dir = try std.fs.path.join(gpa, &.{ project_dir, "target", "web" });
    defer gpa.free(web_dir);
    try std.Io.Dir.cwd().createDirPath(io, web_dir);

    const wasm_name = try std.fmt.allocPrint(gpa, "{s}.wasm", .{m.name});
    defer gpa.free(wasm_name);
    const wasm_path = try std.fs.path.join(gpa, &.{ web_dir, wasm_name });
    defer gpa.free(wasm_path);

    // 1. q64 emit <entry> <wasm>
    {
        const argv = [_][]const u8{ q64_bin, "emit", entry_path, wasm_path };
        const term = try spawnInherit(io, &argv);
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
    const user_version = m.version orelse "0.0.0";
    const html_subs = [_]Sub{
        .{ .needle = "{{WASM}}", .value = wasm_name },
        .{ .needle = "{{NAME}}", .value = m.name },
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
