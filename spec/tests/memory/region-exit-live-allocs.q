// TEST: REG040 — region exited with live allocations
// SPEC: memory.md#region-literal-syntax
// EXPECTED: error

fn leak(env: Env) -> Box<i64, FreeList> {
    region heap: FreeList {
        let b = Box<i64, heap>.new(42)
        b
    }
}

fn main(env: Env) {
    let _ = leak(env)
}
