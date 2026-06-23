//! frontend — the twin half that renders.
//!
//! Holds one live channel to the backend twin: it sends `Tap` up on each press
//! and receives the count down. A spawned loop redraws on every value the twin
//! broadcasts, so a tap on *any* device updates this screen too. Compiles to
//! wasm32, renders via WebGPU (qview).
//!
//! `connect<counter.join>()` opens the dual end of the backend's `join` channel
//! (the local name `counter` is bound to the backend in qube.json5's
//! `rpc.import`). The call carries `@wire` — disclosed in `qube audit`.

import counter.{join}

struct Tap {}

state count = 0

fn main @wire {
    let twin = connect<counter.join>()              // Channel<Tap, i64>: send Tap, recv counts
    spawn { for n in twin { count = n; paint() } }  // live: redraw on every broadcast

    // HOST SEAM 2 — press source. qview delivers presses through the
    // `on_press(id)` callback, not as an event stream; turning each press into
    // `twin.send(Tap)` is the wiring to pin down. Shown as a loop over a press
    // stream for the event-loop shape (env.md's channel frontend).
    for _press in presses() {
        twin.send(Tap)
    }
}

// Label ids index the host glyph catalog (0: heading, 1: button label).
fn paint {
    qview.text(40, 56, 0)
    qview.number(40, 120, count)
    qview.button(1, 40, 180, 280, 72, 1)
    qview.present()
}
