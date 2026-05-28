// TEST: TYP201 — wrong fit form for single-param face
// SPEC: faces.md#fit-declaration
// EXPECTED: error
//
// `Eq` is a single-parameter face; the fit must be written
// `fit Type : Eq`, not `fit Eq<Type>`.

pub struct Point { x: i64, y: i64 }

pub fit Eq<Point> {
    fn eq(self, other: Self) -> bool @pure {
        self.x == other.x && self.y == other.y
    }
}
