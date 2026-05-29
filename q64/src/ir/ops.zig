//! Operator vocabulary shared by both IR tiers. Operators are neither
//! "semantic" nor "executable" — they're just operators — so HIR and MIR
//! reference the same enums (and a backend maps them to its target ops).

/// Binary operators. Arithmetic/bitwise yield the operand type; the
/// comparisons (`eq`..`ge`) yield a boolean (an `i32` 0/1 in MIR). Division
/// and remainder are signed for `i64`.
pub const BinKind = enum {
    add,
    sub,
    mul,
    div,
    rem,
    bit_and,
    bit_or,
    bit_xor,
    shl,
    shr,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
};

/// Unary operators: arithmetic negation, bitwise complement, and logical
/// not. `not` is the only one that yields a boolean (an `i32` 0/1 in MIR) —
/// it is truthiness on its operand (`x == 0 ? 1 : 0`), so it accepts any
/// integer operand, not just a 0/1.
pub const UnKind = enum { neg, bit_not, not };
