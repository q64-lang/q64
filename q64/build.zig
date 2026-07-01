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

    // Named module for the sema package (src/sema/lib.zig) — name
    // resolution + type checking between parse and build_hir. Imports
    // `parser` only (never ir/, never Binaryen); see src/sema/README.md
    // for the pass placement and ladder.
    const sema_mod = b.createModule(.{
        .root_source_file = b.path("src/sema/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    sema_mod.addImport("parser", parser_mod);

    // Named module for the Q64 IR package (src/ir/lib.zig). The builder
    // consumes parser AST views and sema's type lowering (A3); nothing
    // under ir/ links Binaryen, so the IR stays backend-neutral.
    const ir_mod = b.createModule(.{
        .root_source_file = b.path("src/ir/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    ir_mod.addImport("parser", parser_mod);
    ir_mod.addImport("sema", sema_mod);

    // -----------------------------------------------------------
    // The binary.
    // -----------------------------------------------------------
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    // WIT ingestion (src/wit/wit.zig) — a self-contained WIT parser + WIT→q64
    // type mapping (WIT rung 5). Pure Zig, no cross-module imports.
    const wit_mod = b.createModule(.{
        .root_source_file = b.path("src/wit/wit.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe_mod.addImport("parser", parser_mod);
    exe_mod.addImport("ir", ir_mod);
    exe_mod.addImport("sema", sema_mod);
    exe_mod.addImport("wit", wit_mod);
    linkBinaryen(exe_mod, target, binaryen_include, binaryen_lib);

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
    addPlainTest(b, test_step, target, optimize, "src/wit/wit.zig");

    // IR tests are pure Zig (no Binaryen link), but need the `parser`
    // import, so they can't use addPlainTest. A fresh module rooted at the
    // umbrella runs every embedded test under ir/.
    const ir_tests_mod = b.createModule(.{
        .root_source_file = b.path("src/ir/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    ir_tests_mod.addImport("parser", parser_mod);
    ir_tests_mod.addImport("sema", sema_mod);
    const ir_tests = b.addTest(.{ .root_module = ir_tests_mod });
    test_step.dependOn(&b.addRunArtifact(ir_tests).step);

    // Sema tests are pure Zig (no Binaryen link) but need `parser`,
    // same shape as the IR tests.
    const sema_tests_mod = b.createModule(.{
        .root_source_file = b.path("src/sema/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    sema_tests_mod.addImport("parser", parser_mod);
    const sema_tests = b.addTest(.{ .root_module = sema_tests_mod });
    test_step.dependOn(&b.addRunArtifact(sema_tests).step);

    // `doc` (q64 doc --json) is parser-only — no Binaryen link — but needs the
    // `parser` import, so it gets its own test module like the IR tests.
    const doc_tests_mod = b.createModule(.{
        .root_source_file = b.path("src/doc.zig"),
        .target = target,
        .optimize = optimize,
    });
    doc_tests_mod.addImport("parser", parser_mod);
    const doc_tests = b.addTest(.{ .root_module = doc_tests_mod });
    test_step.dependOn(&b.addRunArtifact(doc_tests).step);

    // `fmt` (q64 fmt) is parser-only — no Binaryen link — but needs the
    // `parser` import, so it gets its own test module like the doc tests.
    const fmt_tests_mod = b.createModule(.{
        .root_source_file = b.path("src/fmt/fmt.zig"),
        .target = target,
        .optimize = optimize,
    });
    fmt_tests_mod.addImport("parser", parser_mod);
    const fmt_tests = b.addTest(.{ .root_module = fmt_tests_mod });
    test_step.dependOn(&b.addRunArtifact(fmt_tests).step);

    const codegen_mod = b.createModule(.{
        .root_source_file = b.path("src/codegen/emit.zig"),
        .target = target,
        .optimize = optimize,
    });
    codegen_mod.addImport("parser", parser_mod);
    codegen_mod.addImport("ir", ir_mod);
    codegen_mod.addImport("sema", sema_mod);
    linkBinaryen(codegen_mod, target, binaryen_include, binaryen_lib);
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

    // End-to-end: emit a component and validate + call it with wasmtime.
    const component_script = b.addSystemCommand(&.{
        "bash",
        "../scripts/component-roundtrip.sh",
    });
    const component_step = b.step("component-roundtrip", "Emit a component and validate it with wasmtime");
    component_step.dependOn(&component_script.step);

    // End-to-end: link two components with `qube wac` (link at build) and verify
    // the import is satisfied. Uses the real `wac` when available, else the
    // vendored `wasm-tools compose` fallback.
    const wac_script = b.addSystemCommand(&.{ "bash", "../scripts/wac-roundtrip.sh" });
    const wac_step = b.step("wac-roundtrip", "Link components with qube wac and validate");
    wac_step.dependOn(&wac_script.step);

    // Black-box CLI suite (Bun). Builds the binary, then runs `bun test`
    // in the sibling ../q64-test against zig-out/bin/q64. Only runs when
    // invoked explicitly; needs `bun` on PATH.
    const cli_tests = b.addSystemCommand(&.{ "bun", "test" });
    cli_tests.setCwd(b.path("../q64-test"));
    cli_tests.setEnvironmentVariable("Q64_BIN", "../q64/zig-out/bin/q64");
    cli_tests.step.dependOn(b.getInstallStep());
    // `q64 run` executes through the wasmtime host; build it (the sibling zig
    // project) and point the suite at it so the `run` tests are exercised.
    // (cwd is `q64/` here, mirroring the `../scripts/` roundtrips above.)
    const build_run_host = b.addSystemCommand(&.{ "bash", "-c", "cd .. && vendor/zig/zig build --build-file runtime/wasmtime/build.zig" });
    cli_tests.step.dependOn(&build_run_host.step);
    cli_tests.setEnvironmentVariable("Q64_WASMTIME_HOST", "../runtime/wasmtime/zig-out/bin/q64-wasmtime-host");
    const cli_tests_step = b.step("cli-tests", "Run the q64 CLI black-box suite (bun test)");
    cli_tests_step.dependOn(&cli_tests.step);
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

// Binaryen is vendored as a static archive (libbinaryen.a) built from source
// by ../init.sh (or restored from the CDN cache). It is built with `zig c++`
// on every platform, so it carries zig's bundled libc++ ABI — meaning a single
// `link_libcpp = true` is ABI-correct for every target, including Linux, and
// the whole thing cross-compiles from one host (the macOS/windows/linux-arm64
// release binaries are all produced this way).
fn linkBinaryen(
    mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    include_path: std.Build.LazyPath,
    lib_path: std.Build.LazyPath,
) void {
    _ = target;
    mod.link_libc = true;
    mod.addIncludePath(include_path);
    mod.addObjectFile(lib_path);
    // Zig's bundled libc++ — matches how libbinaryen.a is compiled (zig c++)
    // on all platforms, and is arch-agnostic so cross-linking just works.
    mod.link_libcpp = true;
}
