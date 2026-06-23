//! connect — the importer side of a remote channel (`connect<iface.fn>()`).
//!
//! Opens the dual end of an imported channel export and drains its inbound
//! stream into a module `state`. `for n in twin` binds each i64 payload (a
//! value-bearing Rx); the loop ends when the peer closes. Lowers to the
//! host-import seam: `env.channel_connect` (open) + `env.channel_recv` (1 =
//! message, 0 = closed) + `env.channel_take` (the payload). `last()` reads the
//! final value the stream delivered.

state count = 0

fn main @wire {
    let twin = connect<counter.join>()
    for n in twin {
        count = n
    }
}

pub fn last() -> i64 {
    count
}
