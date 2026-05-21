// TEST: TYP305 — `?` postfix on Result
// SPEC: errors.md#why-a-keyword-not-a-sigil
// EXPECTED: error

fn read_size(env: Env) -> Result<i64, IoError> {
    let bytes = env.fs.read("size.txt")?
    Ok(bytes.len())
}

fn main(env: Env) {
    match read_size(env) {
        Ok(n)  -> env.out("{n}"),
        Err(_) -> env.exit(1),
    }
}
