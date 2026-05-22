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

    // -----------------------------------------------------------
    // The binary.
    // -----------------------------------------------------------
    const exe = b.addExecutable(.{
        .name = "q64",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkBinaryen(exe, binaryen_include, binaryen_lib);
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

    const codegen_tests = b.addTest(.{
        .root_source_file = b.path("src/codegen/emit.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkBinaryen(codegen_tests, binaryen_include, binaryen_lib);
    test_step.dependOn(&b.addRunArtifact(codegen_tests).step);
}

fn linkBinaryen(
    artifact: *std.Build.Step.Compile,
    include_path: std.Build.LazyPath,
    lib_path: std.Build.LazyPath,
) void {
    artifact.linkLibC();
    artifact.addIncludePath(include_path);
    artifact.addObjectFile(lib_path);
    // libbinaryen.a is built against libstdc++ on Linux (gcc CI),
    // not libc++. Zig's `linkSystemLibrary("stdc++")` is intercepted
    // by isLibCxxLibName and forced to libc++ (wrong symbol mangling),
    // so we add libstdc++.so directly as an object file. The linker
    // treats the .so as a positional dynamic dependency.
    const stdcpp = resolveLib("libstdc++.so.6", "LIBSTDCXX_PATH") orelse @panic(
        "libstdc++ not found in standard locations; install libstdc++-dev " ++
            "or set LIBSTDCXX_PATH env var",
    );
    artifact.addObjectFile(.{ .cwd_relative = stdcpp });
    // libstdc++ pulls in libgcc's unwind support (_Unwind_Resume et al.)
    // for C++ exception handling. Link the system libgcc_s for those.
    const gcc_s = resolveLib("libgcc_s.so.1", "LIBGCC_S_PATH") orelse @panic(
        "libgcc_s not found in standard locations; install libgcc-s1 " ++
            "or set LIBGCC_S_PATH env var",
    );
    artifact.addObjectFile(.{ .cwd_relative = gcc_s });
}

fn resolveLib(name: []const u8, env_var: []const u8) ?[]const u8 {
    if (std.posix.getenv(env_var)) |p| return p;
    const dirs = [_][]const u8{
        "/usr/lib/x86_64-linux-gnu",
        "/usr/lib/aarch64-linux-gnu",
        "/usr/lib64",
        "/usr/lib",
    };
    var buf: [256]u8 = undefined;
    for (dirs) |dir| {
        const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch continue;
        std.fs.accessAbsolute(path, .{}) catch continue;
        // bufPrint result is only valid until the next call — dup
        // into the build allocator so the path outlives this fn.
        // Using std.heap.page_allocator here since the build script
        // is short-lived.
        return std.heap.page_allocator.dupe(u8, path) catch continue;
    }
    return null;
}
