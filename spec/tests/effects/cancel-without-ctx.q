// TEST: EFF160 — @cancel without ctx parameter
// SPEC: effects.md#cancel-and-uncancellable
// EXPECTED: error
//
// Declaring `@cancel` requires a `ctx: Cancel` parameter in the
// signature.

pub fn watcher(env: Env) @cancel {
    env.out("watching")
}

fn main(env: Env) {
    watcher(env)
}
