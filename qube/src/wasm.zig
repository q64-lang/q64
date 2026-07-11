//! qube-resolve.wasm — the `qube` manifest-resolution core, compiled to wasm so
//! the browser shell runs the SAME logic as the native CLI instead of a port.
//!
//! Two slices of `qube run`/`build`'s resolution, both sharing `json5.zig` +
//! `resolve.zig` with the native binary (one implementation, native + on-device):
//!
//!   * `qube_resolve_entry(manifest)` — the pure entry rule (manifest → entry
//!     path), the bit that drifted (`main.q` vs `src/main.q`).
//!   * `qube_resolve(cwd)` — the full link resolution: read the project manifest,
//!     its entry source, and the **transitive** dependency module set (each
//!     dep's manifest `entry` is authoritative — never a guessed `lib.q`), all
//!     via a host `read` import, returned as JSON the shell hands to the compiler.
//!
//! ABI (minimal linear-memory string ABI; no wasm-bindgen):
//!   import env.read(path_ptr,len) -> u64   host reads the file, copies bytes into
//!                                          wasm memory (via qube_alloc), returns
//!                                          (ptr<<32|len); 0 = not found.
//!   qube_alloc(n) -> ptr                   host fills `n` bytes (input / read result)
//!   qube_free(ptr,n)                        release a buffer
//!   qube_resolve_entry(p,n) -> u64          (ptr<<32|len) of the entry path; 0 = error
//!   qube_resolve(p,n)       -> u64          (ptr<<32|len) of a JSON result; 0 = error
//!     JSON: { "entryPath": "src/main.q", "main": "<src>",
//!             "modules": [ { "name": "...", "source": "<src>" } ] }
//!
//! Next slice graduates this to driving compile + run via host imports — then
//! `qube.wasm` owns the whole flow and `qube.ts` is deleted.

const std = @import("std");
const json5 = @import("json5.zig");
const resolve = @import("resolve.zig");
const dispatch = @import("dispatch.zig");
const deploy_manifest = @import("deploy_manifest.zig");

const gpa = std.heap.wasm_allocator;

/// Host-provided file read. Given a path in wasm memory, the host copies the
/// file's bytes into wasm memory (allocating via `qube_alloc`) and returns them
/// packed `(ptr<<32|len)`, or 0 if the file does not exist.
extern "env" fn read(path_ptr: [*]const u8, path_len: usize) u64;

fn hostRead(path: []const u8) ?[]u8 {
    const r = read(path.ptr, path.len);
    if (r == 0) return null;
    const p: [*]u8 = @ptrFromInt(@as(usize, @intCast(r >> 32)));
    const n: usize = @intCast(r & 0xffff_ffff);
    return p[0..n];
}

/// Allocate `n` bytes for the host to fill (manifest input, or a `read` result).
export fn qube_alloc(n: usize) ?[*]u8 {
    const buf = gpa.alloc(u8, n) catch return null;
    return buf.ptr;
}

export fn qube_free(ptr: [*]u8, n: usize) void {
    gpa.free(ptr[0..n]);
}

fn pack(buf: []const u8) u64 {
    return (@as(u64, @intFromPtr(buf.ptr)) << 32) | @as(u64, buf.len);
}

/// The `entry`/`type` a manifest declares, via the shared rule. Parses the JSON5
/// text; returns the entry default for the type when unset.
fn manifestEntry(manifest: []const u8) ?[]const u8 {
    const json = json5.toJson(gpa, manifest) catch return null;
    defer gpa.free(json);
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, json, .{}) catch return null;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const type_str: []const u8 = if (root.get("type")) |t| switch (t) {
        .string => |s| s,
        else => "library",
    } else "library";
    const is_lib = !std.mem.eql(u8, type_str, "application");
    const entry_field: ?[]const u8 = if (root.get("entry")) |e| switch (e) {
        .string => |s| s,
        else => null,
    } else null;
    // dupe — entryOf may return a slice into `parsed`, freed below.
    return gpa.dupe(u8, resolve.entryOf(entry_field, is_lib)) catch null;
}

/// Resolve the entry source path from a JSON5 manifest. `(ptr<<32|len)`; 0 = error.
export fn qube_resolve_entry(ptr: [*]const u8, len: usize) u64 {
    const entry = manifestEntry(ptr[0..len]) orelse return 0;
    return pack(entry);
}

/// Synthesize the wire QubePod manifest (qubepod.jsonc) for `qube deploy` —
/// the SHARED implementation (deploy_manifest.zig) the native CLI uses, so a
/// shell deploy and a terminal deploy are byte-compatible by construction.
///
/// Input (ptr,len): JSON `{ "manifest": "<qube.json5 text>", "overrides": {
///   "project"?: "...", "name"?: "...", "assetsDirectory"?: "..." } }`.
/// Returns packed JSON `{ "ok": true, "qubepod": { … } }` or
/// `{ "ok": false, "error": "…" }`. `(ptr<<32|len)`; 0 = malformed input.
export fn qube_deploy_manifest(ptr: [*]const u8, len: usize) u64 {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, ptr[0..len], .{}) catch return 0;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return 0,
    };
    const manifest: []const u8 = switch (root.get("manifest") orelse return 0) {
        .string => |m| m,
        else => return 0,
    };
    var ov: deploy_manifest.Overrides = .{};
    if (root.get("overrides")) |ovv| switch (ovv) {
        .object => |oo| {
            if (oo.get("project")) |v| switch (v) {
                .string => |p| ov.project = p,
                else => {},
            };
            if (oo.get("name")) |v| switch (v) {
                .string => |n| ov.name = n,
                else => {},
            };
            if (oo.get("assetsDirectory")) |v| switch (v) {
                .string => |d| ov.assets_directory = d,
                else => {},
            };
        },
        else => {},
    };
    var out: std.ArrayList(u8) = .empty;
    switch (deploy_manifest.synthesize(gpa, manifest, ov)) {
        .ok => |wire| {
            defer gpa.free(wire);
            out.appendSlice(gpa, "{\"ok\":true,\"qubepod\":") catch return 0;
            out.appendSlice(gpa, wire) catch return 0;
            out.append(gpa, '}') catch return 0;
        },
        .err => |e| {
            out.appendSlice(gpa, "{\"ok\":false,\"error\":") catch return 0;
            const es = std.json.Stringify.valueAlloc(gpa, std.json.Value{ .string = e }, .{}) catch return 0;
            defer gpa.free(es);
            out.appendSlice(gpa, es) catch return 0;
            out.append(gpa, '}') catch return 0;
        },
    }
    const buf = out.toOwnedSlice(gpa) catch return 0;
    return pack(buf);
}

/// Route a `qube` invocation. `args_json` (ptr,len) is a JSON array of the arg
/// strings AFTER `qube` (e.g. `["build","main.q"]`). Returns packed JSON the
/// front-end acts on — the routing/usage/version/unknown logic lives ONCE here
/// (shared with the native CLI via dispatch.zig), so the browser shell no longer
/// re-codes the command switch. `(ptr<<32|len)`; 0 = malformed input.
///
///   { "kind":"terminal", "exit":N, "stream":"stdout"|"stderr", "text":"…" }
///   { "kind":"command",  "cmd":"build|run|wac|webgpu|pod", "rest":[ … ] }
///
/// A `terminal` is printed verbatim and exits; a `command` is the one thing the
/// host must do with a capability (compile/run/link/probe-gpu) it supplies.
export fn qube_dispatch(args_ptr: [*]const u8, args_len: usize) u64 {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, args_ptr[0..args_len], .{}) catch return 0;
    defer parsed.deinit();
    const arr = switch (parsed.value) {
        .array => |a| a,
        else => return 0,
    };
    const args = gpa.alloc([]const u8, arr.items.len) catch return 0;
    defer gpa.free(args);
    for (arr.items, 0..) |v, i| args[i] = switch (v) {
        .string => |s| s,
        else => return 0,
    };

    var out: std.ArrayList(u8) = .empty;
    switch (dispatch.route(args)) {
        .terminal => |t| {
            out.appendSlice(gpa, "{\"kind\":\"terminal\",\"exit\":") catch return 0;
            out.print(gpa, "{d}", .{t.code}) catch return 0;
            out.appendSlice(gpa, ",\"stream\":\"") catch return 0;
            out.appendSlice(gpa, if (t.stream == .stdout) "stdout" else "stderr") catch return 0;
            out.appendSlice(gpa, "\",\"text\":") catch return 0;
            appendJsonString(&out, t.text) catch return 0;
            out.append(gpa, '}') catch return 0;
        },
        .unknown => |nm| {
            // Build the final text the host prints verbatim: the error + usage.
            var text: std.ArrayList(u8) = .empty;
            defer text.deinit(gpa);
            text.appendSlice(gpa, "qube: unknown subcommand '") catch return 0;
            text.appendSlice(gpa, nm) catch return 0;
            text.appendSlice(gpa, "'\n\n") catch return 0;
            text.appendSlice(gpa, dispatch.usage_text) catch return 0;
            out.appendSlice(gpa, "{\"kind\":\"terminal\",\"exit\":2,\"stream\":\"stderr\",\"text\":") catch return 0;
            appendJsonString(&out, text.items) catch return 0;
            out.append(gpa, '}') catch return 0;
        },
        .command => |c| {
            out.appendSlice(gpa, "{\"kind\":\"command\",\"cmd\":\"") catch return 0;
            out.appendSlice(gpa, dispatch.name(c.cmd)) catch return 0;
            out.appendSlice(gpa, "\",\"rest\":[") catch return 0;
            for (c.rest, 0..) |a, i| {
                if (i > 0) out.append(gpa, ',') catch return 0;
                appendJsonString(&out, a) catch return 0;
            }
            out.appendSlice(gpa, "]}") catch return 0;
        },
    }
    return pack(out.toOwnedSlice(gpa) catch return 0);
}

/// Join `base` + `/` + `rel` and collapse `.`/`..` segments (paths are POSIX,
/// forward-slash; dep paths are relative to the manifest dir). Caller owns.
fn joinNormalize(base: []const u8, rel: []const u8) ![]u8 {
    var segs: std.ArrayList([]const u8) = .empty;
    defer segs.deinit(gpa);
    const absolute = base.len > 0 and base[0] == '/';
    var it = std.mem.tokenizeScalar(u8, base, '/');
    while (it.next()) |s| try pushSeg(&segs, s);
    var it2 = std.mem.tokenizeScalar(u8, rel, '/');
    while (it2.next()) |s| try pushSeg(&segs, s);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    if (absolute) try out.append(gpa, '/');
    for (segs.items, 0..) |s, i| {
        if (i > 0) try out.append(gpa, '/');
        try out.appendSlice(gpa, s);
    }
    return out.toOwnedSlice(gpa);
}

fn pushSeg(segs: *std.ArrayList([]const u8), s: []const u8) !void {
    if (s.len == 0 or std.mem.eql(u8, s, ".")) return;
    if (std.mem.eql(u8, s, "..")) {
        if (segs.items.len > 0 and !std.mem.eql(u8, segs.items[segs.items.len - 1], "..")) {
            _ = segs.pop();
        } else {
            try segs.append(gpa, s);
        }
        return;
    }
    try segs.append(gpa, s);
}

/// Append `s` as a JSON string literal (with surrounding quotes), escaping per
/// RFC 8259 — source code carries `"`, `\`, and control bytes.
fn appendJsonString(out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(gpa, '"');
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        '\t' => try out.appendSlice(gpa, "\\t"),
        0x08 => try out.appendSlice(gpa, "\\b"),
        0x0c => try out.appendSlice(gpa, "\\f"),
        else => if (c < 0x20) {
            const hex = "0123456789abcdef";
            try out.appendSlice(gpa, "\\u00");
            try out.append(gpa, hex[(c >> 4) & 0xf]);
            try out.append(gpa, hex[c & 0xf]);
        } else {
            try out.append(gpa, c);
        },
    };
    try out.append(gpa, '"');
}

/// One link module to emit: its module name and its entry source.
const Module = struct { name: []const u8, source: []const u8 };

/// Expand `dir`'s `dependencies` (transitively): for each, read its manifest for
/// the authoritative entry, read that entry source, and collect `{name, source}`.
/// Mirrors the native resolver + the shell's `readModules`. `seen` dedups names;
/// `queue` carries dirs still to expand.
fn expandDeps(
    dir: []const u8,
    modules: *std.ArrayList(Module),
    seen: *std.StringHashMap(void),
    queue: *std.ArrayList([]const u8),
) !void {
    const manifest = hostRead(try joinNormalize(dir, "qube.json5")) orelse return;
    const json = json5.toJson(gpa, manifest) catch return;
    defer gpa.free(json);
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, json, .{}) catch return;
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return,
    };
    const deps = switch (root.get("dependencies") orelse return) {
        .object => |o| o,
        else => return,
    };
    var it = deps.iterator();
    while (it.next()) |e| {
        const name = e.key_ptr.*;
        const path: []const u8 = switch (e.value_ptr.*) {
            .object => |o| if (o.get("path")) |p| switch (p) {
                .string => |s| s,
                else => continue,
            } else continue,
            else => continue, // registry deps need the cache (host-resolved); v0 path-only
        };
        const dep_dir = try joinNormalize(dir, path);
        const dep_manifest = hostRead(try joinNormalize(dep_dir, "qube.json5")) orelse continue;
        const dep_entry = manifestEntry(dep_manifest) orelse "src/lib.q";
        const source = hostRead(try joinNormalize(dep_dir, dep_entry)) orelse continue;
        if (!seen.contains(name)) {
            try seen.put(try gpa.dupe(u8, name), {});
            try modules.append(gpa, .{ .name = try gpa.dupe(u8, name), .source = source });
        }
        try queue.append(gpa, dep_dir); // expand its own deps (transitive)
    }
}

/// Full `qube run`/`build` resolution from the project dir `cwd`: the entry path
/// + entry source + the transitive dependency module set, as JSON the shell
/// compiles. `(ptr<<32|len)`; 0 = error (no manifest / no entry source).
export fn qube_resolve(cwd_ptr: [*]const u8, cwd_len: usize) u64 {
    const cwd = cwd_ptr[0..cwd_len];
    const manifest = hostRead(joinNormalize(cwd, "qube.json5") catch return 0) orelse return 0;
    const entry = manifestEntry(manifest) orelse return 0;
    const main_src = hostRead(joinNormalize(cwd, entry) catch return 0) orelse return 0;

    var modules: std.ArrayList(Module) = .empty;
    var seen = std.StringHashMap(void).init(gpa);
    var queue: std.ArrayList([]const u8) = .empty;
    queue.append(gpa, gpa.dupe(u8, cwd) catch return 0) catch return 0;
    var qi: usize = 0;
    while (qi < queue.items.len) : (qi += 1) {
        expandDeps(queue.items[qi], &modules, &seen, &queue) catch {};
    }

    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(gpa, "{\"entryPath\":") catch return 0;
    appendJsonString(&out, entry) catch return 0;
    out.appendSlice(gpa, ",\"main\":") catch return 0;
    appendJsonString(&out, main_src) catch return 0;
    out.appendSlice(gpa, ",\"modules\":[") catch return 0;
    for (modules.items, 0..) |m, i| {
        if (i > 0) out.append(gpa, ',') catch return 0;
        out.appendSlice(gpa, "{\"name\":") catch return 0;
        appendJsonString(&out, m.name) catch return 0;
        out.appendSlice(gpa, ",\"source\":") catch return 0;
        appendJsonString(&out, m.source) catch return 0;
        out.append(gpa, '}') catch return 0;
    }
    out.appendSlice(gpa, "]}") catch return 0;
    return pack(out.toOwnedSlice(gpa) catch return 0);
}
