// Stage-1 retained QView reference screen (spec/qview-protocol.md).
// Builds a retained node tree via create/set_attr/on, mutates it surgically
// from the on_event dispatcher. Two reference widget kinds: label + button.
//
// Enum tags (must match the host + spec/qview-protocol.md):
//   kind:  box=0 label=4 button=6
//   attr:  x=0 y=1 w=2 h=3 radius=4 fill=6 text_id=9 fg=8
//   event: press=0
// Node ids are producer-assigned and stable across frames (id 0 = root).
// Host glyph catalog: text_id 0 = "Taps", 1 = "Tap +1".

state count = 0

// `main` builds the initial retained tree once. After this, the tree persists;
// only the on_event handler emits further mutations.
fn main {
  // A title label (node 1).
  qview.create(1, 4, 0)
  qview.set_attr(1, 0, 40)
  qview.set_attr(1, 1, 56)
  qview.set_attr(1, 9, 0)

  // A live count label (node 2). text_id is overloaded as the integer in Stage 1
  // (host renders the value the producer passes), matching the POC's number path.
  qview.create(2, 4, 0)
  qview.set_attr(2, 0, 40)
  qview.set_attr(2, 1, 104)
  qview.set_attr(2, 9, count)

  // A button (node 3): a box-backed control with a centered label, wired to press.
  qview.create(3, 6, 0)
  qview.set_attr(3, 0, 40)
  qview.set_attr(3, 1, 168)
  qview.set_attr(3, 2, 280)
  qview.set_attr(3, 3, 72)
  qview.set_attr(3, 4, 16)
  qview.set_attr(3, 9, 1)
  qview.on(3, 0, 1)

  qview.present()
}

// The single event dispatcher (spec §Events). The host calls on_event(node, event)
// when a wired input fires; we mutate state + the exact node, then present().
// This emits ONE set_attr — the surgical-update demonstration.
pub fn on_event(node: i64, event: i64) {
  count = count + 1
  qview.set_attr(2, 9, count)
  qview.present()
}
