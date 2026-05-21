// TEST: ENV055 — `with_capabilities(use:)` field not on `Env`
// SPEC: env.md#overriding-the-ambient-binding
// EXPECTED: error
//
// `quack` is not a field of `Env`; the `use:` map only accepts
// names that correspond to declared sub-capabilities.

fn main {
    with_capabilities(use: { quack: MockQuack.new() }) {
        env.out("hello")
    }
}
