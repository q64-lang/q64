// TEST: PAR040 — generic vs less-than ambiguity
// SPEC: generics.md#why-no-turbofish
// EXPECTED: error

fn main(env: Env) {
    let a = 1
    let b = 2
    let c = 3
    if a < b > (c) {
        env.out("ambiguous")
    }
}
