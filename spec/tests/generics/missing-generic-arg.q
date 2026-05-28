// TEST: TYP102 — missing required generic argument
// SPEC: generics.md#inference-then-default
// EXPECTED: error

pub fn buffer<T, const N: i64 = 16>() -> [T; N] {
    [T.default(); N]
}

fn main {
    let c = buffer()
    env.out("{c.len()}")
}
