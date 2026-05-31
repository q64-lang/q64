//! Umbrella for the parser package — re-exports the sub-modules so
//! consumers (e.g. `codegen/`, future `typeck/`) can pull them in
//! through a single named module without hard-coding `..`-relative
//! file paths.
//!
//! Wired up in `build.zig` as the `parser` module dependency.

pub const cst = @import("cst.zig");
pub const lex = @import("lex.zig");
pub const diag = @import("diag.zig");
pub const parse = @import("parse.zig");
pub const ast = @import("ast.zig");
