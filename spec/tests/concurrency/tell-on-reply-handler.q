// TEST: CONC020 — `tell` on a reply-bearing handler
// SPEC: concurrency.md#tell-vs-ask
// EXPECTED: error

actor Counter {
    state count: i64 = 0

    handle Get -> i64 {
        state.count
    }
}

fn main {
    scope {
        let c = Counter.spawn()
        c.tell(Get)
    }
}
