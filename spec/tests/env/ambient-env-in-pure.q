// TEST: ENV056 — `env` reference from `@pure` function
// SPEC: env.md#diagnostic-codes
// EXPECTED: error
//
// A `@pure` function cannot reference `env.X` — ambient capability
// use is incompatible with purity. The body would synthesize a
// capability parameter; `@pure` forbids that effect category.

pub fn impure_pure(x: i64) -> i64 @pure {
    env.out("computing")
    x * 2
}

fn main {
    let _ = impure_pure(21)
}
