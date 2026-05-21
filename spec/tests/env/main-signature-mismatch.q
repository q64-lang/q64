// TEST: ENV052 — `main` signature mismatch
// SPEC: env.md#main-signature
// EXPECTED: error
//
// `main` must match one of the four permitted shapes (with or
// without `env: Env` parameter, with or without `Result` return);
// this version takes a wrong-typed parameter.

fn main(args: [str]) {
    let _ = args
}
