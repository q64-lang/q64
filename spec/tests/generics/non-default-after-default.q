// TEST: TYP108 — non-default after default
// SPEC: generics.md#rules
// EXPECTED: error

pub struct Buffer<T = i64, const N: i64> {
    data: [T; N],
}

fn main {
    env.out("hello")
}
