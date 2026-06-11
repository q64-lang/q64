// A single-parameter face (prelude `Eq`) written in the bare
// multi-param form — must be `fit Point : Eq` (spec/faces.md
// §"Fit declaration").
struct Point { x: i64, y: i64 }

fit Eq<Point> {
    fn eq(self, other: Self) -> bool { true }
}
