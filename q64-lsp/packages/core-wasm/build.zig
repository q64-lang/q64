//! Build script for q64-core.wasm.
//!
//! Compiles q64's *analysis* modules (parser + sema; effect/region checks
//! live inside sema today) to a freestanding wasm32 module exporting a small
//! C ABI.
//!
//! Critically, this build NEVER links Binaryen. The analysis path
//! (parse → diagnostics) is pure Zig, which is exactly what lets the same
//! source that produces the native `q64` binary also compile to wasm and
//! run in a browser / Worker. If this build ever needs Binaryen, an
//! analysis module has wrongly grown a codegen dependency — fix the
//! dependency, not this file.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    // q64's parser package, compiled for wasm32. Path-relative to the
    // sibling q64 Zig project (../../../q64 from this package).
    const parser_mod = b.createModule(.{
        .root_source_file = b.path("../../../q64/src/parser/lib.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });

    // q64's sema package (name resolution + type/effect/region checks). It
    // depends only on `std` and `parser` — NOT on ir/codegen/Binaryen — which is
    // exactly what lets it cross the same freestanding-wasm line the parser does.
    // Wired the same way the native build.zig does (sema_mod -> parser_mod).
    const sema_mod = b.createModule(.{
        .root_source_file = b.path("../../../q64/src/sema/lib.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });
    sema_mod.addImport("parser", parser_mod);

    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/wasm.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });
    wasm_mod.addImport("parser", parser_mod);
    wasm_mod.addImport("sema", sema_mod);

    const wasm = b.addExecutable(.{
        .name = "q64-core",
        .root_module = wasm_mod,
    });
    // A freestanding wasm module has no `main`; it exposes exported
    // functions only. Disable the entry point and keep exports live.
    wasm.entry = .disabled;
    wasm.rdynamic = true;

    b.installArtifact(wasm);
}
