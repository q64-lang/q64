// TEST: TYP050 — bool used as integer
// SPEC: types.md#bool
// EXPECTED: error

fn main {
    let x: i32 = true
    env.out("{x}")
}
