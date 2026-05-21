// TEST: TYP060 — parameter mode keyword in call argument
// SPEC: types.md#call-site
// EXPECTED: error

fn process(ref state: i64) {
    state = state + 1
}

fn main(env: Env) {
    var s: i64 = 0
    process(ref: s)
    env.out("{s}")
}
