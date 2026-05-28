// TEST: EFF120 — contradictory effects declared
// SPEC: effects.md#effect-annotations-on-functions
// EXPECTED: error
//
// `@realtime` forbids `@io`; declaring both is a contradiction.

pub fn render @realtime + @io {
    env.out("rendering")
}

fn main {
    render()
}
