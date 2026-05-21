// TEST: golden — minimal hello-world
// SPEC: env.md#hello-world
// EXPECTED: ok

//! hello — entry point.

fn main(env: Env) {
    env.out("Hello, q64.")
}
