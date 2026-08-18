// TEST: EFF112 — allocation in a `@no_alloc` function
// SPEC: effects.md#what-no_alloc-and-no_suspend-forbid
// EXPECTED: error
//
// `Vec.new()` allocates on the heap; a `@no_alloc` body forbids it.
// The audio path reads pool-backed buffers positioned outside the
// asserted function.

pub fn fill(n: i64) -> i64 @no_alloc {
    var v: Vec<i64> = Vec.new()
    n
}

fn main {
    let y = fill(4)
    env.out("{y}")
}
