//! Consumer smoke: a program importing q64.layout should compile once the
//! namespace exists. Uses only names from stdlib/layout/README.md.

import q64.layout.{Rect}

fn main {
    env.out("q64.layout import resolved")
}
