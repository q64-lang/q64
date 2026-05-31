// fixture: wildcard import is forbidden (NAM003) — a diagnostic the parser
// emits today, so it exercises the real `q64 check` error path.

import q64.math.*

fn main {
    env.out("hello")
}
