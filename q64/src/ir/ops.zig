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
    // Native binary float-math builtins (`x.min(y)`, `x.max(y)`,
    // `x.copysign(y)`) — one wasm instruction each, float operands only.
    fmin,
    fmax,
    fcopysign,
};

/// Unary operators: arithmetic negation, bitwise complement, and logical
/// not. `not` is the only one that yields a boolean (an `i32` 0/1 in MIR) —
/// it is truthiness on its operand (`x == 0 ? 1 : 0`), so it accepts any
/// integer operand, not just a 0/1.
pub const UnKind = enum {
    neg,
    bit_not,
    not,
    // Native float-math builtins (each is one wasm instruction; the operand
    // type, f64/f32, picks the variant). Spelled as method calls in source:
    // `x.sqrt()`, `x.abs()`, `x.floor()`, `x.ceil()`. Result type = operand.
    fabs,
    fsqrt,
    ffloor,
    fceil,
    ftrunc,
    fnearest,
};

/// Short-circuit logical operators. Unlike `BinKind`, these are *control
/// flow*, not value ops: the right operand is only evaluated when the left
/// doesn't already decide the result (`&&` on a false lhs, `||` on a true
/// lhs). They lower to a value-producing `if_`, never to a backend binary
/// op, and yield a boolean (an `i32` 0/1).
pub const LogicalKind = enum { and_, or_ };

/// SIMD lane interpretation of a `v128` value. A `v128` is one wasm storage
/// type but the instruction families differ per lane shape, and the wasm
/// type alone cannot recover the shape — so every SIMD op carries it
/// explicitly (the `Simd<f32, 4>` vs `Simd<i32, 4>` distinction, kept on
/// the op so instruction selection never has to guess).
pub const LaneShape = enum { f32x4, i32x4 };
