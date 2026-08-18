// TEST: EFF110 — capability outside a `@realtime` function's set
// SPEC: effects.md#propagation-through-call-graphs
// EXPECTED: error
//
// `@realtime` permits only the realtime-safe `@time`/`@random`/`@audio`
// surfaces; an `env.out` write is `@io`-bearing and outside the set.

pub fn tick(x: i64) -> i64 @realtime {
    env.out("tick")
    x
}

fn main {
    let y = tick(1)
    env.out("{y}")
}
