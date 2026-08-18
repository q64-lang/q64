// TEST: EFF100 — `panic` in a `@no_panic` function
// SPEC: effects.md#what-no_alloc-and-no_suspend-forbid
// EXPECTED: error
//
// `@no_panic` (here implied by `@realtime`) forbids `panic` in the body:
// a panic unwinds and its payload allocates.

pub fn process(x: i64) -> i64 @realtime {
    if x < 0 { panic "negative sample index" }
    x
}

fn main {
    let y = process(1)
    env.out("{y}")
}
