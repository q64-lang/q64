// TEST: ENV052 — `main` signature mismatch
// SPEC: env.md#main-signature
// EXPECTED: error
//
// `main` must take `env: Env`; this version takes a wrong-typed parameter.

fn main(args: [str]) {
    let _ = args
}
