// Barer QView/WebGPU proof (wasm32). The host owns the glyph catalog by id; the
// wasm drives layout + which widgets to draw via the qview host face.
//   label 0 = "q64 -> wasm32 -> WebGPU"   button label 1 = "Tap me"
// `qview.number(x,y,n)` draws an integer (the click counter) — host renders it.
fn main {
  qview.text(40, 56, 0)
  qview.number(40, 110, 0)
  qview.button(1, 40, 168, 280, 72, 1)
  qview.present()
}
