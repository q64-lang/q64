// TEST: TYP051 — integer used as bool
// SPEC: types.md#bool
// EXPECTED: error

fn main(env: Env) {
    if 1 {
        env.out("yes")
    }
}
