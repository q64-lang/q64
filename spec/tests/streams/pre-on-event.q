// TEST: STR051 — `pre()` on `Event<T>`
// SPEC: streams.md#pre-for-feedback-cycles
// EXPECTED: error
//
// Events have no previous-tick notion.

@stage
fn echo(clicks: Event<Point>) -> Event<Point> {
    clicks.pre()
}

fn main {
    scope {
        let g = graph my_app {
            let _ = echo(env.ui.clicks())
        }
        let _ = g.start()
    }
}
