// TEST: NAM011 — dash in bare module path
// SPEC: modules.md#qube-name--module-path
// EXPECTED: error

import audio-filters.{LowPass}

fn main {
    env.out("hello")
}
