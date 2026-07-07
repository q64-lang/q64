// TEST: TYP361 — operand type mismatch in an operator expression
// SPEC: operators.md#diagnostics
// EXPECTED: error
//
// Operator fits are homogeneous in v0 (`Self × Self → Self`,
// spec/operators.md §Rules): mixing two different struct types in one
// operator expression has no dispatch, and there is no implicit
// conversion. The fix is an explicit conversion on one operand.

pub struct Vec2 { x: i64, y: i64 }
pub struct Color { r: i64, g: i64 }

pub fit Vec2 : Add {
    fn add(self, rhs: Vec2) -> Vec2 {
        Vec2 { x: self.x + rhs.x, y: self.y + rhs.y }
    }
}

fn main {
    let a = Vec2 { x: 1, y: 2 }
    let q = Color { r: 3, g: 4 }
    let c = a + q
    env.out("unreachable")
}
