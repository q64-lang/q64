//! Umbrella for the Q64 IR package — re-exports the two IR tiers and the
//! passes that build and lower them, so consumers (`codegen/`, future
//! `typeck/`, `q64 show`) pull them in through one named `ir` module.
//!
//! The two tiers:
//!   - `hir` — High-level / Semantic QIR ("what the program means").
//!   - `mir` — Mid-level / Executable QIR ("how it executes").
//! The passes:
//!   - `build_hir` — AST → HIR (imports `parser`).
//!   - `lower`     — HIR → MIR.
//!   - `print`     — text dumps of either tier.
//!
//! Neutrality invariant: nothing under `ir/` imports the Binaryen C API.
//! Only the codegen backend (`codegen/`) links Binaryen and consumes MIR.
//!
//! Wired up in `build.zig` as the `ir` module dependency.

pub const hir = @import("hir.zig");
pub const mir = @import("mir.zig");
pub const build_hir = @import("build_hir.zig");
pub const lower = @import("lower.zig");
pub const print = @import("print.zig");

// Pull every submodule's embedded tests into the `ir_tests` target (a plain
// `pub const … = @import(…)` doesn't make the test runner collect them).
test {
    _ = hir;
    _ = mir;
    _ = build_hir;
    _ = lower;
    _ = print;
}
