// TEST: TYP200 — type does not fit face
// SPEC: faces.md#diagnostic-codes
// EXPECTED: error
//
// `print_all` requires `T: Display`, but `Plain` declares no
// `fit Plain : Display`, so the call's inferred element type does not
// satisfy the bound.

pub face Display {
    fn fmt(self) -> str @pure
}

pub struct Plain { v: i64 }

pub fn print_all<T: Display>(items: [T]) {
    for item in items {
        env.out("{item.fmt()}")
    }
}

fn main {
    print_all([Plain { v: 1 }, Plain { v: 2 }])
}
