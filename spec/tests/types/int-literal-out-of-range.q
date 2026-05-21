// TEST: TYP040 — integer literal out of range
// SPEC: types.md#numeric-literals-and-suffixes
// EXPECTED: error

fn main(env: Env) {
    let e: u8 = 256
    env.out("{e}")
}
