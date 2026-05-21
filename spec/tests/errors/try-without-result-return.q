// TEST: TYP300 — `try` requires `Result` return type
// SPEC: errors.md#type-system-rules
// EXPECTED: error

fn read_size(env: Env) -> i64 {
    let bytes = try env.fs.read("size.txt")
    bytes.len()
}

fn main(env: Env) {
    let n = read_size(env)
    env.out("{n}")
}
