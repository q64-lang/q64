//! backend — the twin you write.
//!
//! One instance per project. It owns the set of connected frontends and the
//! shared count, and pushes every change out to everyone — so a tap on any
//! device updates all of them (live fan-out).
//!
//!   • the count is kept in a WASI key-value store (`env.kv` → `wasi:keyvalue`),
//!     bound to the project's store at boot;
//!   • the live fan-out is a q64 **actor** holding the subscriber set
//!     (concurrency.md §Actors): private state, a serial inbox, one message at a
//!     time — the consistency boundary.
//!
//! `component.emit: true` + `rpc.export: true` (qube.json5) serve the channel
//! entry point below over wRPC. See ../fan-out.md for the design and the two
//! platform seams marked HOST below.

// What a frontend sends up the channel: "I tapped."
struct Tap {}

// The twin: private state + a typed, serial message inbox.
actor Counter {
    state subs: Vec<Sender<i64, Unbounded>> = Vec.new()

    // A frontend joined: hand it the current value, then keep its sender.
    handle Join(tx: Sender<i64, Unbounded>) @kv {
        tx.send(read())
        state.subs.push(move tx)
    }

    // A frontend tapped: bump the shared count, fan the new value out to all.
    handle Bump @kv {
        let n = bump()
        for tx in state.subs { tx.send(n) }
    }
}

// HOST SEAM 1 — one twin per project. This singleton is the hosted twin (on
// qubepods, a Durable Object, one instance per project; the first-class q64
// sugar for "one shared actor per scope" is `@state(scope)`). It's spelled as a
// module-level actor here so the handler can reach it.
let twin = Counter.spawn()

// The channel entry point: each frontend connection registers with the twin and
// forwards its taps. (env.md §"Channel entry point" + rpc.md §"Remote channels".)
@channel_handler
pub fn join(session: Channel<i64, Tap>) @wire {
    let (tx, rx) = channel<i64>(policy: Unbounded)  // local: twin → this session
    twin.tell(Join(move tx))                      // register this session with the twin
    spawn { for n in rx { session.send(n) } }     // pump the twin's pushes out to the frontend
    for _tap in session { twin.tell(Bump) }       // forward this session's taps to the twin
}

// The shared count lives in the WASI key-value store.
// `increment` lowers to wasi:keyvalue/atomics.increment, so concurrent taps
// never lose a count; reading is a bump of zero.
fn bump() -> i64 @kv {
    match env.kv.increment("count", 1) {
        Ok(n)  -> n
        Err(_) -> 0
    }
}

fn read() -> i64 @kv {
    match env.kv.increment("count", 0) {
        Ok(n)  -> n
        Err(_) -> 0
    }
}
