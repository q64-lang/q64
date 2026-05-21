// TEST: LEX010 — stray carriage return
// SPEC: grammar.md#source-encoding-and-whitespace
// EXPECTED: error
//
// A bare \r (carriage return without a following \n) is rejected
// during tokenization. The .q file below contains a CR byte after
// the function header — the runner is responsible for materializing
// the byte; this comment documents intent.

fn main {
    env.out("line one")
    env.out("line two")
}
