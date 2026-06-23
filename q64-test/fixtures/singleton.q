//! singleton — a module-level actor singleton (`let twin = Counter.spawn()`).
//!
//! The instance's state record is allocated ONCE at instantiation (by the
//! synthesized wasm `start` function) and its self-pointer kept in a module
//! global, so the shared `n` survives across `ping()` calls: 1, 2, 3, …

actor Counter {
    state n: i64 = 0
    handle Bump {
        n = n + 1
    }
    handle Get -> i64 {
        n
    }
}

let twin = Counter.spawn()

pub fn ping() -> i64 {
    twin.tell(Bump)
    twin.ask(Get)
}
