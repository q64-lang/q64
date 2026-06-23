//! Build script for the qube binary.
//!
//! Produces the `qube` executable from src/main.zig. Pure Zig — no
//! external C libraries. Modeled after q64/build.zig.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "qube",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    if (b.args) |args| run_exe.addArgs(args);
    const run_step = b.step("run", "Run qube with the supplied arguments");
    run_step.dependOn(&run_exe.step);

    const unit_tests = b.addTest(.{ .root_module = exe_mod });
    const test_step = b.step("test", "Run qube unit tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    // Black-box CLI suite (Bun). Builds the binary, then runs `bun test`
    // in the sibling ../qube-test against zig-out/bin/qube. Only runs when
    // invoked explicitly; needs `bun` on PATH.
    const cli_tests = b.addSystemCommand(&.{ "bun", "test" });
    cli_tests.setCwd(b.path("../qube-test"));
    cli_tests.setEnvironmentVariable("QUBE_BIN", "../qube/zig-out/bin/qube");
    cli_tests.step.dependOn(b.getInstallStep());
    const cli_tests_step = b.step("cli-tests", "Run the qube CLI black-box suite (bun test)");
    cli_tests_step.dependOn(&cli_tests.step);

    // qube-resolve.wasm — the manifest-resolution core (src/wasm.zig) compiled to
    // wasm32, so the browser shell runs the SAME `qube` logic as the native CLI
    // (one implementation; see src/wasm.zig). `zig build wasm`.
    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/wasm.zig"),
        .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
        .optimize = .ReleaseSmall,
    });
    const wasm = b.addExecutable(.{ .name = "qube-resolve", .root_module = wasm_mod });
    wasm.entry = .disabled; // a library of exports, no _start
    wasm.rdynamic = true; // keep the `export fn`s
    const wasm_step = b.step("wasm", "Build qube-resolve.wasm (the wasm resolution core)");
    wasm_step.dependOn(&b.addInstallArtifact(wasm, .{}).step);
}
