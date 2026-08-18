//! Build script for the native CLAP runtime.
//!
//! Produces:
//!   - `libq64clap.so` — a native CLAP plugin embedding wasmtime that
//!     runs a q64-compiled wasm32 audio module (rename to `.clap` for a
//!     DAW; the wasm ships as `q64.wasm` beside it, or `Q64_CLAP_WASM`
//!     points at it).
//!   - `q64-clap-check` — the honest native host harness: dlopens the
//!     plugin like a DAW and drives the full lifecycle.
//!
//! Vendor dependency: `../../vendor/wasmtime/` (run `./init.sh`).

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    const wasmtime_include = b.path("../../vendor/wasmtime/include");
    const wasmtime_lib_dir = b.path("../../vendor/wasmtime/lib");

    const clap_mod = b.createModule(.{
        .root_source_file = b.path("src/clap.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.link_libc = true;
    lib_mod.addIncludePath(wasmtime_include);
    lib_mod.addLibraryPath(wasmtime_lib_dir);
    lib_mod.linkSystemLibrary("wasmtime", .{});
    // The plugin sits at runtime/audio-host/zig-out/lib/; the vendored
    // libwasmtime.so is four levels up. A DAW deployment instead ships
    // libwasmtime.so beside the .clap — hence also $ORIGIN itself.
    lib_mod.addRPathSpecial("$ORIGIN");
    lib_mod.addRPathSpecial("$ORIGIN/../../../../vendor/wasmtime/lib");

    const lib = b.addLibrary(.{
        .name = "q64clap",
        .root_module = lib_mod,
        .linkage = .dynamic,
    });
    b.installArtifact(lib);

    const check_mod = b.createModule(.{
        .root_source_file = b.path("check/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    check_mod.link_libc = true;
    check_mod.addImport("clap", clap_mod);
    const check = b.addExecutable(.{
        .name = "q64-clap-check",
        .root_module = check_mod,
    });
    b.installArtifact(check);
}
