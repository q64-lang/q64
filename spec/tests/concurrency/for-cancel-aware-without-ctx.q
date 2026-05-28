// TEST: CONC053 — `for x in rx` over cancel-aware receiver without ctx
// SPEC: concurrency.md#for-x-in-rx-loop-form
// EXPECTED: error

fn drain(rx: Receiver<i64, Backpressure>) {
    for x in rx {
        let _ = x
    }
}

fn main {
    scope {
        let (tx, rx) = channel<i64>(policy: Backpressure, capacity: 4)
        spawn { tx.send(ctx, 1) }
        drain(rx)
    }
}
