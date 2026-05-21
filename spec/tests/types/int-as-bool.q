// TEST: TYP051 — integer used as bool
// SPEC: types.md#bool
// EXPECTED: error

fn main {
    if 1 {
        env.out("yes")
    }
}
