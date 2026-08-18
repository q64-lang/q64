// TEST: EFF112 — assert violated by an unannotated callee
// SPEC: effects.md#propagation-through-call-graphs
// EXPECTED: error
//
// The callee is unannotated, so its effects are inferred: it panics.
// A `@realtime` caller implies `@no_panic`, which the callee violates.

fn helper(x: i64) -> i64 {
    if x < 0 { panic "bad" }
    x
}

pub fn process(x: i64) -> i64 @realtime {
    helper(x)
}

fn main {
    let y = process(1)
    env.out("{y}")
}
