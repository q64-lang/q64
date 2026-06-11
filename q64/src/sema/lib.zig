//! Umbrella for the sema package (name resolution + type checking).
//! See README.md for the pass placement and the ladder rungs; today this
//! re-exports the A0 scaffold (the file-level symbol table).

pub const symbols = @import("symbols.zig");
pub const resolve = @import("resolve.zig");
pub const types = @import("types.zig");
pub const exprtype = @import("exprtype.zig");
pub const link = @import("link.zig");
pub const check = @import("check.zig");
pub const prelude = @import("prelude.zig");
pub const fits = @import("fits.zig");

pub const SymbolTable = symbols.SymbolTable;
pub const Symbol = symbols.Symbol;
pub const SymbolKind = symbols.SymbolKind;
pub const build = symbols.build;
pub const showSymbols = symbols.showSymbols;
pub const fileDiagnostics = symbols.fileDiagnostics;
pub const resolveBodies = resolve.resolveBodies;
pub const Resolution = resolve.Resolution;
pub const TypeStore = types.TypeStore;
pub const TypeId = types.TypeId;

test {
    @import("std").testing.refAllDecls(@This());
}
