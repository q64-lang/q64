// TEST: LEX020 — unknown string-literal prefix
// SPEC: types.md#typed-prefix-form
// EXPECTED: error

fn main {
    let bogus = xyz"hello"
    env.out(bogus)
}
