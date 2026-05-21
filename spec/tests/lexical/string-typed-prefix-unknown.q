// TEST: LEX020 — unknown string-literal prefix
// SPEC: types.md#typed-prefix-form
// EXPECTED: error

fn main(env: Env) {
    let bogus = xyz"hello"
    env.out(bogus)
}
