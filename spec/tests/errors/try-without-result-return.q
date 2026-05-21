// TEST: TYP300 — `try` requires `Result` return type
// SPEC: errors.md#type-system-rules
// EXPECTED: error

fn read_size -> i64 {
    let bytes = try env.fs.read("size.txt")
    bytes.len()
}

fn main {
    let n = read_size()
    env.out("{n}")
}
