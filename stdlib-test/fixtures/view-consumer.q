//! Consumer smoke: a program importing q64.view should compile once the
//! namespace exists. Uses only names from stdlib/view/README.md.

import q64.view.{View}

fn main {
    env.out("q64.view import resolved")
}
