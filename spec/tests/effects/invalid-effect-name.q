// TEST: EFF141 — invalid effect name
// SPEC: effects.md#naming-and-collisions
// EXPECTED: error
//
// User effect names must match ^@[a-z][a-z_]*$ — no PascalCase.

pub effect @Logging

fn main(env: Env) {
    env.out("hello")
}
