// TEST: TYP047 — optional type not narrowed
// SPEC: types.md#optional-types-and-flow-narrowing
// EXPECTED: error

struct User { name: str }

fn process(user: User?) -> str {
    if let None = user { return "anonymous" }
    user.name
}

fn main(env: Env) {
    env.out(process(None))
}
