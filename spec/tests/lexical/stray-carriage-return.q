// TEST: LEX010 — stray carriage return
// SPEC: grammar.md#source-encoding-and-whitespace
// EXPECTED: error

fn main {    env.out("hi")
}
