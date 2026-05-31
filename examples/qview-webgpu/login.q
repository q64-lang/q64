// QView WebGPU proof (Path A, wasm32). Integer-driven: the host owns the glyph
// catalog; the wasm drives layout + which widgets/labels to draw via the qview
// host face. Label ids: 0 "Welcome back", 1 "Email", 2 "Password", 3 "Sign in".
fn main {
  qview.text(24, 60, 0)
  qview.text(24, 132, 1)
  qview.text(24, 204, 2)
  qview.button(1, 24, 276, 240, 48, 3)
  qview.present()
}
