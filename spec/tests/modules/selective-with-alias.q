// TEST: NAM004 — selective import combined with alias
// SPEC: modules.md#forbidden
// EXPECTED: error

import q64.math.{Vec3, dot} as v

fn main(env: Env) {
    env.out("hello")
}
