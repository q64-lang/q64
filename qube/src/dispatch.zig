//! Shared, wasm-safe command **routing** for `qube` — the single dispatch table
//! the on-device (wasm) shell consults instead of re-coding the switch in
//! TypeScript. Pure, allocation-free, no fs/spawn/argv — same discipline as
//! `resolve.zig` and `json5.zig`, so the command set, help text, exit codes, and
//! unknown-subcommand handling live in ONE place and can't drift from the CLI.
//!
//! Why this exists: the browser shell (`qube.ts`) had its own `switch` + usage
//! text that drifted from the native `qube`. Routing is logic, not a capability —
//! so it belongs in the one wasm `qube`. What a command DOES that needs the
//! outside world (compile, run, link, probe the GPU) stays a host capability the
//! front-end supplies; deciding WHICH command runs, with what args and what help,
//! is decided here.

const std = @import("std");

/// The canonical version line. One string, native + on-device — a front-end may
/// add its own context note, but the version itself is shared.
pub const version_text = "qube 0.0.6 (pre-alpha)";

/// Usage for the on-device command surface (the subset a browser shell runs;
/// the native CLI additionally does packaging/registry work that needs a real
/// OS). Kept here so help text can't drift from the dispatch table below.
pub const usage_text =
    \\qube — build and run q64 qubes on device
    \\
    \\usage: qube <command> [args]
    \\
    \\commands:
    \\  build [file.q]          compile the manifest entry (or file.q) -> target/<name>.wasm
    \\  run   [file.q|.wasm]    build the manifest entry (or a file) and run it
    \\  wac plug <socket> ...   link components on device
    \\  webgpu                  probe the browser's WebGPU support (adapter, device, render)
    \\  deploy                  deploy this qube to qubepods (reads qube.json5; needs a login token)
    \\  help                    show this help
    \\
    \\run from a qube directory (where qube.json5 is); the entry defaults to src/main.q.
;

/// A command the front-end must execute — it needs a host capability (compile,
/// run, link, GPU probe) the pure router can't perform itself.
pub const Command = enum { build, run, wac, webgpu, pod, deploy };

/// The routing decision for one `qube <args>` invocation.
pub const Route = union(enum) {
    /// Print `text` to the named stream and exit with `code` — help, version,
    /// the bare-`qube` usage error. No capability needed.
    terminal: Terminal,
    /// Unknown subcommand `name`: the front-end prints the error + usage and
    /// exits 2. Carried as the raw slice so the router stays allocation-free.
    unknown: []const u8,
    /// Run `cmd` with `rest` (the args after the subcommand).
    command: Dispatch,
};

pub const Stream = enum { stdout, stderr };
pub const Terminal = struct { code: u8, stream: Stream, text: []const u8 };
pub const Dispatch = struct { cmd: Command, rest: []const []const u8 };

/// Route `args` (everything after the program name; `args[0]` is the
/// subcommand). The SAME decision the native CLI makes for the shared command
/// set — there must be one answer to "what does `qube <x>` do", on-device or not.
pub fn route(args: []const []const u8) Route {
    if (args.len == 0) {
        // Bare `qube` is a usage error (exit 2), usage to stderr.
        return .{ .terminal = .{ .code = 2, .stream = .stderr, .text = usage_text } };
    }
    const sub = args[0];
    const rest = args[1..];

    if (eq(sub, "help") or eq(sub, "--help") or eq(sub, "-h"))
        return .{ .terminal = .{ .code = 0, .stream = .stdout, .text = usage_text } };
    if (eq(sub, "--version") or eq(sub, "-v") or eq(sub, "version"))
        return .{ .terminal = .{ .code = 0, .stream = .stdout, .text = version_text } };

    if (eq(sub, "build")) return .{ .command = .{ .cmd = .build, .rest = rest } };
    if (eq(sub, "run")) return .{ .command = .{ .cmd = .run, .rest = rest } };
    if (eq(sub, "wac")) return .{ .command = .{ .cmd = .wac, .rest = rest } };
    if (eq(sub, "webgpu") or eq(sub, "gpu")) return .{ .command = .{ .cmd = .webgpu, .rest = rest } };
    if (eq(sub, "deploy")) return .{ .command = .{ .cmd = .deploy, .rest = rest } };
    if (eq(sub, "pod")) return .{ .command = .{ .cmd = .pod, .rest = rest } };

    return .{ .unknown = sub };
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// The canonical lowercase name of a command (for the wasm JSON / logging).
pub fn name(cmd: Command) []const u8 {
    return switch (cmd) {
        .build => "build",
        .run => "run",
        .wac => "wac",
        .webgpu => "webgpu",
        .pod => "pod",
        .deploy => "deploy",
    };
}

test "route: help / version / bare" {
    const t = std.testing;
    try t.expect(route(&.{}) == .terminal);
    try t.expectEqual(@as(u8, 2), route(&.{}).terminal.code);
    try t.expectEqual(Stream.stderr, route(&.{}).terminal.stream);

    inline for (.{ "help", "--help", "-h" }) |h| {
        const r = route(&.{h});
        try t.expect(r == .terminal);
        try t.expectEqual(@as(u8, 0), r.terminal.code);
        try t.expectEqual(Stream.stdout, r.terminal.stream);
        try t.expectEqualStrings(usage_text, r.terminal.text);
    }
    inline for (.{ "--version", "-v", "version" }) |v| {
        const r = route(&.{v});
        try t.expect(r == .terminal);
        try t.expectEqualStrings(version_text, r.terminal.text);
    }
}

test "route: real commands carry the rest" {
    const t = std.testing;
    const r = route(&.{ "build", "main.q" });
    try t.expect(r == .command);
    try t.expectEqual(Command.build, r.command.cmd);
    try t.expectEqual(@as(usize, 1), r.command.rest.len);
    try t.expectEqualStrings("main.q", r.command.rest[0]);

    try t.expectEqual(Command.webgpu, route(&.{"webgpu"}).command.cmd);
    try t.expectEqual(Command.webgpu, route(&.{"gpu"}).command.cmd);
    try t.expectEqual(Command.run, route(&.{"run"}).command.cmd);
    try t.expectEqual(Command.wac, route(&.{ "wac", "plug" }).command.cmd);
    try t.expectEqual(Command.deploy, route(&.{"deploy"}).command.cmd);
}

test "route: unknown subcommand" {
    const t = std.testing;
    const r = route(&.{"frobnicate"});
    try t.expect(r == .unknown);
    try t.expectEqualStrings("frobnicate", r.unknown);
}
