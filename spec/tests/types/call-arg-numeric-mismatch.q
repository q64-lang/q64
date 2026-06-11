// TEST: TYP041 — numeric type mismatch
// SPEC: types.md#arithmetic
// EXPECTED: error

fn takes64(n: i64) {
    env.out(n)
}

fn main {
    let a: i32 = 1
    takes64(a)
}
