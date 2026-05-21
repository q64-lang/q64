// TEST: TYP042 — implicit numeric conversion is forbidden
// SPEC: types.md#arithmetic
// EXPECTED: error

fn main(env: Env) {
    let a: i32 = 1
    let b: i64 = 2
    let c = a + b
    env.out("{c}")
}
