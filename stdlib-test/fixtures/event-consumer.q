//! Consumer smoke: a program importing q64.event should compile once the
//! namespace exists. Uses only names from stdlib/event/README.md.

import q64.event.{Tap}

fn main {
    env.out("q64.event import resolved")
}
