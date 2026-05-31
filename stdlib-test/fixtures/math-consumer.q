//! Consumer smoke: a program importing q64.math should compile once the
//! namespace exists. Uses only names from stdlib/math/README.md.

import q64.math.{Vec}

fn main {
    env.out("q64.math import resolved")
}
