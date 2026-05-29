// QView demo: wasm-owned reactive state. `count` is a module-level state global;
// on_press increments it and redraws. Label ids match the host catalog
// (0: title, 1: button label).
state count = 0

fn main {
  qview.text(40, 56, 0)
  qview.number(40, 120, count)
  qview.button(1, 40, 180, 280, 72, 1)
  qview.present()
}

pub fn on_press(id: i64) {
  count = count + 1
  qview.text(40, 56, 0)
  qview.number(40, 120, count)
  qview.button(1, 40, 180, 280, 72, 1)
  qview.present()
}
