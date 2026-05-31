// TEST: CONC050 — channel policy required
// SPEC: concurrency.md#channel-construction
// EXPECTED: error

fn main {
    scope {
        let (tx, rx) = channel<i64>(capacity: 16)
        spawn { tx.send(ctx, 1) }
        let _ = rx.recv(ctx)
    }
}
