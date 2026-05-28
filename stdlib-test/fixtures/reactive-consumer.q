//! Consumer smoke: a program importing q64.reactive should compile once the
//! namespace exists. Uses only names from stdlib/reactive/README.md.

import q64.reactive.{Signal}

fn main {
    env.out("q64.reactive import resolved")
}
