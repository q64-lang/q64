// QView retained widget gallery (spec/qview-protocol.md). Instantiates every
// Stage-1 widget kind so the WebGPU host renders the full set on one page.
//
// Enum tags (match protocol.js):
//   kind:  box=0 row=1 column=2 stack=3 label=4 image=5 button=6
//          checkbox=7 switch=8 radio=9 slider=10 progress=11 dropdown=12
//   attr:  x=0 y=1 w=2 h=3 radius=4 border_w=5 fill=6 border=7 fg=8 text_id=9
//          checked=12 selected=13 group=14 min=15 max=16 value=17
//   event: press=0
// Host glyph catalog ids (app.js CATALOG):
//   0 Widget gallery  1 Label  2 Button  3 Checkbox  4 Switch  5 Radio A
//   6 Radio B  7 Slider  8 Progress  9 Dropdown  10 Box  11 Tap +1
//
// Each interactive control is wired (qview.on) to its OWN handler id, so the
// host calls a distinct branchless `on_<id>` export — no in-handler branching.

state checked   = 1
state toggled   = 0
state choice    = 0
state sliderVal = 40
state taps      = 0

fn main {
  // Layout grid: a control column at x=24 and a name-label column at x=150,
  // rows spaced ~52px starting under the 56px top bar. Labels are ~17px now.

  // Backing box panel (2) — sits below the bar.
  qview.create(2, 0, 0)
  qview.set_attr(2, 0, 16)
  qview.set_attr(2, 1, 72)
  qview.set_attr(2, 2, 380)
  qview.set_attr(2, 3, 600)
  qview.set_attr(2, 4, 18)
  qview.set_attr(2, 5, 1)

  // Label row (10 control, 11 name)
  qview.create(10, 4, 0)
  qview.set_attr(10, 0, 40)
  qview.set_attr(10, 1, 96)
  qview.set_attr(10, 9, 1)

  // Button (20) -> handler 20, name (21 taps count to its right)
  qview.create(20, 6, 0)
  qview.set_attr(20, 0, 40)
  qview.set_attr(20, 1, 132)
  qview.set_attr(20, 2, 150)
  qview.set_attr(20, 3, 48)
  qview.set_attr(20, 4, 12)
  qview.set_attr(20, 9, 11)
  qview.on(20, 0, 20)
  qview.create(21, 4, 0)
  qview.set_attr(21, 0, 210)
  qview.set_attr(21, 1, 146)
  qview.set_attr(21, 9, taps)

  // Checkbox (30) -> handler 30, name (31)
  qview.create(30, 7, 0)
  qview.set_attr(30, 0, 40)
  qview.set_attr(30, 1, 200)
  qview.on(30, 0, 30)
  qview.set_attr(30, 12, checked)
  qview.create(31, 4, 0)
  qview.set_attr(31, 0, 80)
  qview.set_attr(31, 1, 202)
  qview.set_attr(31, 9, 3)

  // Switch (40) -> handler 40, name (41)
  qview.create(40, 8, 0)
  qview.set_attr(40, 0, 40)
  qview.set_attr(40, 1, 248)
  qview.on(40, 0, 40)
  qview.set_attr(40, 12, toggled)
  qview.create(41, 4, 0)
  qview.set_attr(41, 0, 108)
  qview.set_attr(41, 1, 250)
  qview.set_attr(41, 9, 4)

  // Radio A (50) -> 50, name (51); Radio B (52) -> 52, name (53). group 1.
  // Each radio's w/h is a LARGE hit row (circle + label), the two halves of the
  // line, non-overlapping. The circle draws anchored-left inside; the label sits
  // within the same row so tapping anywhere on "Radio A" selects it.
  qview.create(50, 9, 0)
  qview.set_attr(50, 0, 32)
  qview.set_attr(50, 1, 290)
  qview.set_attr(50, 2, 172)
  qview.set_attr(50, 3, 56)
  qview.set_attr(50, 14, 1)
  qview.set_attr(50, 13, 1)
  qview.on(50, 0, 50)
  qview.create(51, 4, 0)
  qview.set_attr(51, 0, 72)
  qview.set_attr(51, 1, 308)
  qview.set_attr(51, 9, 5)
  qview.create(52, 9, 0)
  qview.set_attr(52, 0, 208)
  qview.set_attr(52, 1, 290)
  qview.set_attr(52, 2, 172)
  qview.set_attr(52, 3, 56)
  qview.set_attr(52, 14, 1)
  qview.set_attr(52, 13, 0)
  qview.on(52, 0, 52)
  qview.create(53, 4, 0)
  qview.set_attr(53, 0, 248)
  qview.set_attr(53, 1, 308)
  qview.set_attr(53, 9, 6)

  // Slider row: name (61) above the control (60).
  qview.create(61, 4, 0)
  qview.set_attr(61, 0, 40)
  qview.set_attr(61, 1, 348)
  qview.set_attr(61, 9, 7)
  qview.create(60, 10, 0)
  qview.set_attr(60, 0, 40)
  qview.set_attr(60, 1, 374)
  qview.set_attr(60, 2, 320)
  qview.set_attr(60, 15, 0)
  qview.set_attr(60, 16, 100)
  qview.set_attr(60, 17, sliderVal)
  qview.on(60, 0, 60)

  // Progress row: name (71) above the control (70).
  qview.create(71, 4, 0)
  qview.set_attr(71, 0, 40)
  qview.set_attr(71, 1, 424)
  qview.set_attr(71, 9, 8)
  qview.create(70, 11, 0)
  qview.set_attr(70, 0, 40)
  qview.set_attr(70, 1, 450)
  qview.set_attr(70, 2, 320)
  qview.set_attr(70, 15, 0)
  qview.set_attr(70, 16, 100)
  qview.set_attr(70, 17, sliderVal)

  // Dropdown row: name (81) above the control (80). Value text_id = 12.
  qview.create(81, 4, 0)
  qview.set_attr(81, 0, 40)
  qview.set_attr(81, 1, 488)
  qview.set_attr(81, 9, 9)
  qview.create(80, 12, 0)
  qview.set_attr(80, 0, 40)
  qview.set_attr(80, 1, 514)
  qview.set_attr(80, 2, 320)
  qview.set_attr(80, 3, 40)
  qview.set_attr(80, 13, 0)
  qview.set_attr(80, 9, 12)
  qview.on(80, 0, 80)

  // Translucent material top bar (90), created LAST so it overlays nothing but
  // the panel's top edge — showing the platform material. surface=3 materialThin.
  qview.create(90, 0, 0)
  qview.set_attr(90, 0, 0)
  qview.set_attr(90, 1, 0)
  qview.set_attr(90, 2, 412)
  qview.set_attr(90, 3, 56)
  qview.set_attr(90, 4, 0)
  qview.set_attr(90, 20, 3)
  // Bar title (91).
  qview.create(91, 4, 0)
  qview.set_attr(91, 0, 16)
  qview.set_attr(91, 1, 18)
  qview.set_attr(91, 9, 0)

  qview.present()
}

// One branchless handler per control (the on_<id> dispatch shape).
pub fn on_20(node: i64, event: i64) {
  taps = taps + 1
  qview.set_attr(21, 9, taps)
  qview.present()
}
pub fn on_30(node: i64, event: i64) {
  checked = 1 - checked
  qview.set_attr(30, 12, checked)
  qview.present()
}
pub fn on_40(node: i64, event: i64) {
  toggled = 1 - toggled
  qview.set_attr(40, 12, toggled)
  qview.present()
}
pub fn on_50(node: i64, event: i64) {
  choice = 0
  qview.set_attr(50, 13, 1)
  qview.set_attr(52, 13, 0)
  qview.present()
}
pub fn on_52(node: i64, event: i64) {
  choice = 1
  qview.set_attr(50, 13, 0)
  qview.set_attr(52, 13, 1)
  qview.present()
}
pub fn on_60(node: i64, event: i64) {
  sliderVal = (sliderVal + 10) % 110
  qview.set_attr(60, 17, sliderVal)
  qview.set_attr(70, 17, sliderVal)
  qview.present()
}
pub fn on_80(node: i64, event: i64) {
  qview.present()
}
