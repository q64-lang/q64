// TEST: TYP062 — non-exhaustive match on prelude Option
// SPEC: errors.md#result-and-option
// EXPECTED: error
//
// `Option` lives in the auto-prelude (no import); the match covers
// `Some` but not `None` and has no `_`.

fn main {
    let o = Some(5)
    match o {
        Some(v) -> env.out("{v}"),
    }
}
