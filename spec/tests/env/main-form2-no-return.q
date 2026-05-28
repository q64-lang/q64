// TEST: ENV050 — `main` Form 2 ends without explicit return
// SPEC: env.md#main-signature
// EXPECTED: error

fn main -> Result<(), Error> {
    env.out("hello")
}
