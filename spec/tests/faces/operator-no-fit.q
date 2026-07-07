// TEST: TYP360 — operator on a type with no fit for its face
// SPEC: operators.md#diagnostics
// EXPECTED: error
//
// `a + b` desugars to `a.add(b)` (spec/operators.md), but `Vec2`
// declares no `fit Vec2 : Add`, so the operator has no dispatch target.

pub struct Vec2 { x: i64, y: i64 }

fn main {
    let a = Vec2 { x: 1, y: 2 }
    let b = Vec2 { x: 3, y: 4 }
    let c = a + b
    env.out("unreachable")
}
