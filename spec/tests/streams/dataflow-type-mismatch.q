// TEST: STR020 — dataflow type mismatch in pipeline
// SPEC: streams.md#why-three-types-instead-of-one
// EXPECTED: error
//
// `render` expects a Signal, but `clicks` is an Event.

@stage
fn render(scene: Signal<Scene, 60.Hz>) -> Signal<Frame, 60.Hz> {
    scene.map(|s| Frame.from(s))
}

fn main {
    scope {
        let clicks: Event<Point> = env.ui.clicks()
        let g = graph my_app {
            let _ = render(clicks)
        }
        let _ = g.start()
    }
}
