//! Build script for the wasmtime runtime adapter.
//!
//! Produces `q64-wasmtime-host`, the prototype host that embeds
//! wasmtime, loads a `.wat` or `.wasm` module, provides the q64
//! capability-face imports, and calls `_start`.
//!
//! Vendor dependency: `../../vendor/wasmtime/` must exist (run
//! `./init.sh` from the repo root). The wasmtime C-API headers live
//! under `include/`, the shared object under `lib/`.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const wasmtime_include = b.path("../../vendor/wasmtime/include");
    const wasmtime_lib_dir = b.path("../../vendor/wasmtime/lib");

    const exe = b.addExecutable(.{
        .name = "q64-wasmtime-host",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.linkLibC();
    exe.addIncludePath(wasmtime_include);
    exe.addLibraryPath(wasmtime_lib_dir);
    exe.linkSystemLibrary("wasmtime");
    // Embed rpath so the binary finds libwasmtime.so at run time
    // without needing LD_LIBRARY_PATH. The path is absolute at build
    // time; for distribution we'll relocate the .so next to the
    // binary and switch to `$ORIGIN`-style rpath.
    exe.addRPath(wasmtime_lib_dir);
    b.installArtifact(exe);

    // `zig build run -- <args>` forwards args to the host.
    const run_exe = b.addRunArtifact(exe);
    if (b.args) |args| run_exe.addArgs(args);
    const run_step = b.step("run", "Run the host with the supplied arguments");
    run_step.dependOn(&run_exe.step);

    // `zig build hello` runs hello.wat through the host and asserts
    // the stdout. This is the end-to-end golden the rest of the
    // pipeline aims at.
    const hello_run = b.addRunArtifact(exe);
    hello_run.addFileArg(b.path("hello.wat"));
    hello_run.expectStdOutEqual("Hello, q64.\n");
    const hello_step = b.step("hello", "Run hello.wat and assert stdout");
    hello_step.dependOn(&hello_run.step);
}
