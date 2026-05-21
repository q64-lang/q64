// TEST: NAM003 — wildcard import is forbidden
// SPEC: modules.md#forbidden
// EXPECTED: error

import q64.math.*

fn main {
    env.out("hello")
}
