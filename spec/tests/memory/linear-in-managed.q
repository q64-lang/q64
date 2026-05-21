// TEST: REG020 — linear pointer in @managed struct
// SPEC: memory.md#marking-a-struct-managed
// EXPECTED: error

@managed
struct GameState {
    label:  ref [u8],
    counter: i64,
}

fn main(env: Env) {
    env.out("hello")
}
