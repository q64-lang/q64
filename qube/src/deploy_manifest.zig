//! deploy_manifest.zig — qube.json5 → the wire QubePod manifest (qubepod.jsonc)
//! the qubepods deploy API accepts.
//!
//! Shared by the native CLI (main.zig `qube deploy`) and the browser shell
//! (wasm.zig `qube_deploy_manifest`) — ONE implementation of the wire contract,
//! so the two frontends cannot drift. (Static-qube support landed in the
//! shell's TS synthesis a version before the native CLI learned it; this module
//! is the fix for that CLASS of bug, not just that instance.)
//!
//! The frontends differ only in what they INJECT, never in what they emit:
//! the shell deploys with the console's current project and a re-rooted
//! static tree; the native CLI reads everything from the manifest. Those
//! differences are the explicit `Overrides` input.

const std = @import("std");
const json5 = @import("json5.zig");

pub const Overrides = struct {
    /// Frontend-supplied project slug (the web shell deploys into the console's
    /// current project; a manifest deployed there may omit `project`).
    project: ?[]const u8 = null,
    /// Frontend-supplied qube name (the shell falls back to the project name
    /// and slugifies — the CHOICE stays frontend policy; the wire emit is ours).
    name: ?[]const u8 = null,
    /// Re-rooted asset tree: the shell zips a static tree at ".", so the wire
    /// `assets.directory` must say "." regardless of the manifest's folder.
    assets_directory: ?[]const u8 = null,
};

pub const Result = union(enum) {
    /// The wire manifest JSON. Caller owns (free with the same allocator).
    ok: []u8,
    /// A static diagnostic — print as `qube deploy: <err>`.
    err: []const u8,
};

fn objGet(root: std.json.ObjectMap, key: []const u8) ?std.json.Value {
    return root.get(key);
}

fn strField(root: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = root.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn nestedStr(root: std.json.ObjectMap, a: []const u8, b: []const u8) ?[]const u8 {
    const outer = root.get(a) orelse return null;
    const o = switch (outer) {
        .object => |m| m,
        else => return null,
    };
    return switch (o.get(b) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn stripDotSlash(p: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, p, "./")) p[2..] else p;
}

/// True when the manifest names at least one component artifact.
pub fn hasComponentArtifact(root: std.json.ObjectMap) bool {
    if (nestedStr(root, "component", "module") != null) return true;
    if (nestedStr(root, "component", "wasm") != null) return true;
    if (root.get("component")) |comp| switch (comp) {
        .object => |co| if (co.get("variants") != null) return true,
        else => {},
    };
    return false;
}

/// Build the strict wire manifest from a qube.json5 text. Validates the fields
/// every deploy needs (name, project, component-or-static) so both frontends
/// fail with the SAME diagnostics.
pub fn synthesize(gpa: std.mem.Allocator, manifest_json5: []const u8, ov: Overrides) Result {
    const json = json5.toJson(gpa, manifest_json5) catch return .{ .err = "cannot parse qube.json5" };
    defer gpa.free(json);
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, json, .{}) catch
        return .{ .err = "cannot parse qube.json5" };
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return .{ .err = "qube.json5 is not a JSON object" },
    };

    const name = ov.name orelse strField(root, "name") orelse
        return .{ .err = "qube.json5 has no \"name\" field" };
    const project = ov.project orelse strField(root, "project") orelse
        return .{ .err = "qube.json5 has no \"project\" — set it to your qubepods project slug" };
    const static_dir = nestedStr(root, "static", "dir");
    if (!hasComponentArtifact(root) and static_dir == null) {
        return .{ .err = "qube.json5 has no component.module, component.wasm, component.variants, or static.dir" };
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    return synthesizeInner(gpa, &out, root, name, project, static_dir, ov) catch .{ .err = "out of memory" };
}

fn synthesizeInner(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    root: std.json.ObjectMap,
    name: []const u8,
    project: []const u8,
    static_dir: ?[]const u8,
    ov: Overrides,
) !Result {
    const appendValue = struct {
        fn f(a: std.mem.Allocator, o: *std.ArrayList(u8), v: std.json.Value) !void {
            const s = try std.json.Stringify.valueAlloc(a, v, .{});
            defer a.free(s);
            try o.appendSlice(a, s);
        }
    }.f;

    try out.appendSlice(gpa, "{\"apiVersion\":");
    try appendValue(gpa, out, root.get("apiVersion") orelse .{ .string = "qubepods.dev/v0.1" });
    try out.appendSlice(gpa, ",\"kind\":\"QubePod\",\"project\":");
    try appendValue(gpa, out, .{ .string = project });
    try out.appendSlice(gpa, ",\"name\":");
    try appendValue(gpa, out, .{ .string = name });
    try out.appendSlice(gpa, ",\"version\":");
    try appendValue(gpa, out, root.get("version") orelse .{ .string = "0.1.0" });

    // runtime: default stateless — what the web shell has always sent and the
    // shape every live deploy runs with.
    try out.appendSlice(gpa, ",\"runtime\":");
    try appendValue(gpa, out, root.get("runtime") orelse .{ .string = "stateless" });

    // component: verbatim, except `language` defaults to javascript when a
    // classic `module` is named without one (shell parity; the API's bundler
    // keys its treatment of the entry on the language).
    if (root.get("component")) |comp| emit_component: {
        if (comp == .object) {
            const co = comp.object;
            if (co.get("module") != null and co.get("language") == null) {
                try out.appendSlice(gpa, ",\"component\":{\"language\":\"javascript\"");
                var it = co.iterator();
                while (it.next()) |e| {
                    try out.appendSlice(gpa, ",\"");
                    try out.appendSlice(gpa, e.key_ptr.*);
                    try out.appendSlice(gpa, "\":");
                    try appendValue(gpa, out, e.value_ptr.*);
                }
                try out.append(gpa, '}');
                break :emit_component;
            }
        }
        try out.appendSlice(gpa, ",\"component\":");
        try appendValue(gpa, out, comp);
    }

    // Remaining strict-schema keys, verbatim.
    const passthrough = [_][]const u8{ "$schema", "exports", "imports", "providers" };
    for (passthrough) |k| {
        if (root.get(k)) |v| {
            try out.appendSlice(gpa, ",\"");
            try out.appendSlice(gpa, k);
            try out.appendSlice(gpa, "\":");
            try appendValue(gpa, out, v);
        }
    }

    // Asset tree, one of (in precedence order):
    //   1. the frontend's re-rooted directory (shell static deploys zip at "."),
    //   2. the manifest's explicit `assets` block, verbatim,
    //   3. `static: { dir, notFound }` sugar → assets{directory,notFoundHandling}
    //      (spec qube.json5.md §Static).
    const not_found = nestedStr(root, "static", "notFound") orelse "single-page-application";
    if (ov.assets_directory) |dir| {
        try out.appendSlice(gpa, ",\"assets\":{\"directory\":");
        try appendValue(gpa, out, .{ .string = dir });
        try out.appendSlice(gpa, ",\"notFoundHandling\":");
        try appendValue(gpa, out, .{ .string = not_found });
        try out.append(gpa, '}');
    } else if (root.get("assets")) |v| {
        try out.appendSlice(gpa, ",\"assets\":");
        try appendValue(gpa, out, v);
    } else if (static_dir) |dir| {
        try out.appendSlice(gpa, ",\"assets\":{\"directory\":");
        try appendValue(gpa, out, .{ .string = stripDotSlash(dir) });
        try out.appendSlice(gpa, ",\"notFoundHandling\":");
        try appendValue(gpa, out, .{ .string = not_found });
        try out.append(gpa, '}');
    }

    try out.append(gpa, '}');
    return .{ .ok = try out.toOwnedSlice(gpa) };
}

// ---------------------------------------------------------------------------

test "synthesize: static sugar becomes assets + stateless runtime" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const r = synthesize(a,
        \\{ name: "org.site", version: "0.1.0", project: "site", static: { dir: "./web", notFound: "404-page" } }
    , .{});
    const out = r.ok;
    try std.testing.expect(std.mem.indexOf(u8, out, "\"static\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"assets\":{\"directory\":\"web\",\"notFoundHandling\":\"404-page\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"runtime\":\"stateless\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"project\":\"site\"") != null);
}

test "synthesize: classic module gains language + runtime + version defaults" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const r = synthesize(a,
        \\{ name: "org.api", project: "api", component: { module: "worker.js" } }
    , .{});
    const out = r.ok;
    try std.testing.expect(std.mem.indexOf(u8, out, "\"component\":{\"language\":\"javascript\",\"module\":\"worker.js\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"runtime\":\"stateless\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"version\":\"0.1.0\"") != null);
}

test "synthesize: overrides win — project, name, re-rooted assets" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const r = synthesize(a,
        \\{ name: "org.site", version: "1.0.0", static: { dir: "web" } }
    , .{ .project = "myproj", .name = "site-slug", .assets_directory = "." });
    const out = r.ok;
    try std.testing.expect(std.mem.indexOf(u8, out, "\"project\":\"myproj\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"site-slug\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"assets\":{\"directory\":\".\",\"notFoundHandling\":\"single-page-application\"}") != null);
}

test "synthesize: diagnostics — missing project, nothing deployable" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const no_project = synthesize(a,
        \\{ name: "org.x", static: { dir: "web" } }
    , .{});
    try std.testing.expect(no_project == .err);
    const nothing = synthesize(a,
        \\{ name: "org.x", project: "p" }
    , .{});
    try std.testing.expect(nothing == .err);
    try std.testing.expect(std.mem.indexOf(u8, nothing.err, "static.dir") != null);
}
