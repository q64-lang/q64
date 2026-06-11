// TEST: NAM005 — name collision in import scope
// SPEC: modules.md#name-collisions
// EXPECTED: error

import dev.q64.util.{helper}

fn helper {
    env.out("local")
}

fn main {
    env.out("hello")
}
