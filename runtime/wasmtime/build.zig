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

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.link_libc = true;
    exe_mod.addIncludePath(wasmtime_include);
    exe_mod.addLibraryPath(wasmtime_lib_dir);
    exe_mod.linkSystemLibrary("wasmtime", .{});
    // Embed rpath so the binary finds libwasmtime.so at run time
    // without needing LD_LIBRARY_PATH. The path is absolute at build
    // time; for distribution we'll relocate the .so next to the
    // binary and switch to `$ORIGIN`-style rpath.
    exe_mod.addRPath(wasmtime_lib_dir);

    const exe = b.addExecutable(.{
        .name = "q64-wasmtime-host",
        .root_module = exe_mod,
    });
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

    // q64-component-check — validates a WebAssembly component with wasmtime's
    // component-model compiler (and optionally calls a scalar export). Used by
    // the component-build tests to prove `q64 build --component` output is real.
    const check_mod = b.createModule(.{
        .root_source_file = b.path("src/component_check.zig"),
        .target = target,
        .optimize = optimize,
    });
    check_mod.link_libc = true;
    check_mod.addIncludePath(wasmtime_include);
    check_mod.addLibraryPath(wasmtime_lib_dir);
    check_mod.linkSystemLibrary("wasmtime", .{});
    check_mod.addRPath(wasmtime_lib_dir);
    const check_exe = b.addExecutable(.{
        .name = "q64-component-check",
        .root_module = check_mod,
    });
    b.installArtifact(check_exe);
}
