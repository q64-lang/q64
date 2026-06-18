const std = @import("std");

// Spike (Option B): compile q64's codegen to wasm32-wasi WITHOUT linking
// Binaryen, so every Binaryen C-API call becomes a wasm import that a JS host
// fills via binaryen.js. Proves the q64 side cooperates and enumerates the
// import contract the shim must implement. Paths are relative to this build
// root (same convention as q64-lsp/packages/core-wasm).
pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi });

    const parser_mod = b.createModule(.{
        .root_source_file = b.path("../../q64/src/parser/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    const sema_mod = b.createModule(.{
        .root_source_file = b.path("../../q64/src/sema/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    sema_mod.addImport("parser", parser_mod);

    const ir_mod = b.createModule(.{
        .root_source_file = b.path("../../q64/src/ir/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    ir_mod.addImport("parser", parser_mod);
    ir_mod.addImport("sema", sema_mod);

    const codegen_mod = b.createModule(.{
        .root_source_file = b.path("../../q64/src/codegen/emit.zig"),
        .target = target,
        .optimize = optimize,
    });
    codegen_mod.addImport("parser", parser_mod);
    codegen_mod.addImport("ir", ir_mod);
    codegen_mod.addImport("sema", sema_mod);
    codegen_mod.link_libc = true; // so @cInclude("binaryen-c.h") resolves <stdint.h> etc.
    codegen_mod.addIncludePath(b.path("../../vendor/binaryen/include"));
    // NOTE: intentionally NO addObjectFile(libbinaryen.a) — the Binaryen symbols
    // stay undefined and surface as wasm imports (the contract for the JS shim).

    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/wasm.zig"),
        .target = target,
        .optimize = optimize,
    });
    wasm_mod.addImport("emit", codegen_mod);
    // The ABI layer also needs the parser's diagnostics machinery (parse +
    // diag) and the sema passes (the same analysis `q64 check` runs) to produce
    // the spec/diagnostics.md envelope on the diagnostics path.
    wasm_mod.addImport("parser", parser_mod);
    wasm_mod.addImport("sema", sema_mod);

    const wasm = b.addExecutable(.{ .name = "q64-emit", .root_module = wasm_mod });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    b.installArtifact(wasm);
}
