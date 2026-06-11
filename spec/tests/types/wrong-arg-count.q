// TEST: TYP061 — wrong number of call arguments
// SPEC: types.md#call-site
// EXPECTED: error

fn add(a: i64, b: i64) -> i64 {
    a + b
}

fn main {
    env.out(add(1))
}
