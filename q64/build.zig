//! Build script for the q64 binary.
//!
//! Produces the `q64` executable from src/main.zig and a `test`
//! step that runs every module's embedded tests.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -----------------------------------------------------------
    // The binary.
    // -----------------------------------------------------------
    const exe = b.addExecutable(.{
        .name = "q64",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
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
    const test_step = b.step("test", "Run unit tests across the parser modules");

    const cst_tests = b.addTest(.{
        .root_source_file = b.path("src/parser/cst.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(cst_tests).step);

    const lex_tests = b.addTest(.{
        .root_source_file = b.path("src/parser/lex.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(lex_tests).step);

    const diag_tests = b.addTest(.{
        .root_source_file = b.path("src/parser/diag.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(diag_tests).step);

    const parse_tests = b.addTest(.{
        .root_source_file = b.path("src/parser/parse.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(parse_tests).step);

    const ast_tests = b.addTest(.{
        .root_source_file = b.path("src/parser/ast.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(ast_tests).step);
}
