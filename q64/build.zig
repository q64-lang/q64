//! Build script for the q64 binary.
//!
//! Produces the `q64` executable from src/main.zig and a `test`
//! step that runs every module's embedded tests. Links Binaryen
//! statically for the codegen path (vendored at ../vendor/binaryen/
//! via init.sh).

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const binaryen_include = b.path("../vendor/binaryen/include");
    const binaryen_lib = b.path("../vendor/binaryen/lib/libbinaryen.a");

    // Named module for the parser package. Codegen + future passes
    // pull this in via @import("parser"); the umbrella file at
    // src/parser/lib.zig re-exports each sub-module.
    const parser_mod = b.createModule(.{
        .root_source_file = b.path("src/parser/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // -----------------------------------------------------------
    // The binary.
    // -----------------------------------------------------------
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("parser", parser_mod);
    linkBinaryen(exe_mod, binaryen_include, binaryen_lib);

    const exe = b.addExecutable(.{
        .name = "q64",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    if (b.args) |args| run_exe.addArgs(args);
    const run_step = b.step("run", "Run q64 with the supplied arguments");
    run_step.dependOn(&run_exe.step);

    // -----------------------------------------------------------
    // Tests. One `addTest` per module that has embedded tests;
    // dependencies between modules need explicit `addImport`.
    // -----------------------------------------------------------
    const test_step = b.step("test", "Run unit tests across the parser + codegen modules");

    addPlainTest(b, test_step, target, optimize, "src/parser/cst.zig");
    addPlainTest(b, test_step, target, optimize, "src/parser/lex.zig");
    addPlainTest(b, test_step, target, optimize, "src/parser/diag.zig");
    addPlainTest(b, test_step, target, optimize, "src/parser/parse.zig");
    addPlainTest(b, test_step, target, optimize, "src/parser/ast.zig");

    const codegen_mod = b.createModule(.{
        .root_source_file = b.path("src/codegen/emit.zig"),
        .target = target,
        .optimize = optimize,
    });
    codegen_mod.addImport("parser", parser_mod);
    linkBinaryen(codegen_mod, binaryen_include, binaryen_lib);
    const codegen_tests = b.addTest(.{ .root_module = codegen_mod });
    test_step.dependOn(&b.addRunArtifact(codegen_tests).step);

    // End-to-end: parse + emit + run via the wasmtime host.
    // The script builds both binaries on its own — we just expose
    // it so `zig build hello-roundtrip` is the one-step smoke.
    const hello_script = b.addSystemCommand(&.{
        "bash",
        "../scripts/hello-roundtrip.sh",
    });
    const hello_step = b.step("hello-roundtrip", "Run the end-to-end hello-world smoke test");
    hello_step.dependOn(&hello_script.step);
}

fn addPlainTest(
    b: *std.Build,
    test_step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    src: []const u8,
) void {
    const mod = b.createModule(.{
        .root_source_file = b.path(src),
        .target = target,
        .optimize = optimize,
    });
    const t = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(t).step);
}

// Binaryen is vendored as a static archive (libbinaryen.a) built from
// source by ../init.sh on every host. Because the archive is produced
// by the host's C++ toolchain (Apple Clang on macOS, gcc on Linux,
// MSVC on Windows), it is automatically ABI-consistent with whatever
// linkLibCpp() resolves to on that target — no per-OS shenanigans
// needed.
fn linkBinaryen(
    mod: *std.Build.Module,
    include_path: std.Build.LazyPath,
    lib_path: std.Build.LazyPath,
) void {
    mod.link_libc = true;
    mod.link_libcpp = true;
    mod.addIncludePath(include_path);
    mod.addObjectFile(lib_path);
}
