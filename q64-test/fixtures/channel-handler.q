//! channel-handler — a remote channel entry point (`@channel_handler`).
//!
//! The session's inbound stream drives the loop (`for _tap in session`): the
//! body runs once per received message and the loop ends when the peer closes.
//! Each tap sends one value back out (`session.send`). Lowers to the host-import
//! seam: `env.channel_recv` (1 = message, 0 = closed) + `env.channel_send`.

struct Tap {}

@channel_handler
pub fn pump(session: Channel<i64, Tap>) @wire {
    for _tap in session {
        session.send(1)
    }
}
