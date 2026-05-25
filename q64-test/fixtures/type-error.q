// fixture: implicit numeric conversion is forbidden (TYP042).
// Mirrors spec/tests/types/numeric-mismatch-no-implicit.q.

fn main {
    let a: i32 = 1
    let b: i64 = 2
    let c = a + b
    env.out("{c}")
}
