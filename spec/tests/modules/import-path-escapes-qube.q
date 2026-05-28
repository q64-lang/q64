// TEST: NAM002 — import path escapes qube
// SPEC: modules.md#import-grammar
// EXPECTED: error

import "../../../other-qube/src/foo.q"

fn main {
    env.out("hello")
}
