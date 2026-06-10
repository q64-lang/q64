// TEST: TYP047 — optional type not narrowed
// SPEC: types.md#optional-types-and-flow-narrowing
// EXPECTED: error

struct User { name: str }

fn process(user: User?) -> str {
    // The `if let None` body falls through (no exit), so nothing
    // narrows on the path after it — `user` is still `User?`.
    if let None = user { let _ = "missing user" }
    user.name
}

fn main {
    env.out(process(None))
}
