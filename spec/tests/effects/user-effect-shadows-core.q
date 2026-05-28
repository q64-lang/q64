// TEST: EFF140 — user effect shadows core marker
// SPEC: effects.md#naming-and-collisions
// EXPECTED: error

pub effect @realtime

fn main {
    env.out("hello")
}
