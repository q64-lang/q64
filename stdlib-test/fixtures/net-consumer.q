//! Consumer smoke: a program importing q64.net should compile once the
//! namespace exists. Uses only names from stdlib/net/README.md; no method
//! signatures are assumed.

import q64.net.{Url}

fn main {
    env.out("q64.net import resolved")
}
