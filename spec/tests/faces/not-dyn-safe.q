// TEST: TYP207 — face is not dyn-safe
// SPEC: faces.md#dyn-safety
// EXPECTED: error
//
// `Clone.clone` returns `Self`, which precludes dyn dispatch.

fn render(target: dyn Clone) {
    let _copy = target.clone()
}

fn main {
    env.out("hello")
}
