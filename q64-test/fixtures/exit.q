//! fixture: terminates via env.exit(3) — exercises exit-code propagation
//! (spec/q64-cli.md §"Exit codes": `env.exit(N)` exits with code N).

fn main {
    env.exit(3)
}
