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
  // Title (1)
  qview.create(1, 4, 0)
  qview.set_attr(1, 0, 32)
  qview.set_attr(1, 1, 28)
  qview.set_attr(1, 9, 0)

  // Backing box panel (2)
  qview.create(2, 0, 0)
  qview.set_attr(2, 0, 24)
  qview.set_attr(2, 1, 72)
  qview.set_attr(2, 2, 360)
  qview.set_attr(2, 3, 560)
  qview.set_attr(2, 4, 18)
  qview.set_attr(2, 5, 1)

  // Label demo (10)
  qview.create(10, 4, 0)
  qview.set_attr(10, 0, 48)
  qview.set_attr(10, 1, 100)
  qview.set_attr(10, 9, 1)

  // Button (20) -> handler 20
  qview.create(20, 6, 0)
  qview.set_attr(20, 0, 48)
  qview.set_attr(20, 1, 140)
  qview.set_attr(20, 2, 180)
  qview.set_attr(20, 3, 56)
  qview.set_attr(20, 4, 14)
  qview.set_attr(20, 9, 11)
  qview.on(20, 0, 20)
  // taps count (21)
  qview.create(21, 4, 0)
  qview.set_attr(21, 0, 244)
  qview.set_attr(21, 1, 156)
  qview.set_attr(21, 9, taps)

  // Checkbox (30) -> handler 30, + label (31)
  qview.create(30, 7, 0)
  qview.set_attr(30, 0, 48)
  qview.set_attr(30, 1, 216)
  qview.set_attr(30, 12, checked)
  qview.on(30, 0, 30)
  qview.create(31, 4, 0)
  qview.set_attr(31, 0, 84)
  qview.set_attr(31, 1, 218)
  qview.set_attr(31, 9, 3)

  // Switch (40) -> handler 40, + label (41)
  qview.create(40, 8, 0)
  qview.set_attr(40, 0, 48)
  qview.set_attr(40, 1, 260)
  qview.set_attr(40, 12, toggled)
  qview.on(40, 0, 40)
  qview.create(41, 4, 0)
  qview.set_attr(41, 0, 110)
  qview.set_attr(41, 1, 262)
  qview.set_attr(41, 9, 4)

  // Radio A (50) -> handler 50, Radio B (52) -> handler 52, group 1
  qview.create(50, 9, 0)
  qview.set_attr(50, 0, 48)
  qview.set_attr(50, 1, 304)
  qview.set_attr(50, 14, 1)
  qview.set_attr(50, 13, 1)
  qview.on(50, 0, 50)
  qview.create(51, 4, 0)
  qview.set_attr(51, 0, 84)
  qview.set_attr(51, 1, 306)
  qview.set_attr(51, 9, 5)
  qview.create(52, 9, 0)
  qview.set_attr(52, 0, 180)
  qview.set_attr(52, 1, 304)
  qview.set_attr(52, 14, 1)
  qview.set_attr(52, 13, 0)
  qview.on(52, 0, 52)
  qview.create(53, 4, 0)
  qview.set_attr(53, 0, 216)
  qview.set_attr(53, 1, 306)
  qview.set_attr(53, 9, 6)

  // Slider (60) -> handler 60, + label (61)
  qview.create(60, 10, 0)
  qview.set_attr(60, 0, 48)
  qview.set_attr(60, 1, 352)
  qview.set_attr(60, 2, 220)
  qview.set_attr(60, 15, 0)
  qview.set_attr(60, 16, 100)
  qview.set_attr(60, 17, sliderVal)
  qview.on(60, 0, 60)
  qview.create(61, 4, 0)
  qview.set_attr(61, 0, 48)
  qview.set_attr(61, 1, 330)
  qview.set_attr(61, 9, 7)

  // Progress (70) tracks the slider, + label (71)
  qview.create(70, 11, 0)
  qview.set_attr(70, 0, 48)
  qview.set_attr(70, 1, 408)
  qview.set_attr(70, 2, 220)
  qview.set_attr(70, 15, 0)
  qview.set_attr(70, 16, 100)
  qview.set_attr(70, 17, sliderVal)
  qview.create(71, 4, 0)
  qview.set_attr(71, 0, 48)
  qview.set_attr(71, 1, 388)
  qview.set_attr(71, 9, 8)

  // Dropdown (80) -> handler 80, + label (81)
  qview.create(80, 12, 0)
  qview.set_attr(80, 0, 48)
  qview.set_attr(80, 1, 452)
  qview.set_attr(80, 2, 220)
  qview.set_attr(80, 3, 40)
  qview.set_attr(80, 13, 0)
  qview.set_attr(80, 9, 9)
  qview.on(80, 0, 80)
  qview.create(81, 4, 0)
  qview.set_attr(81, 0, 48)
  qview.set_attr(81, 1, 430)
  qview.set_attr(81, 9, 9)

  // Translucent material top bar (90) — created LAST so the tree walk draws it
  // over the title/content beneath, showing the frosted material per platform.
  // surface=3 (materialThin); the host resolves the platform's material token.
  // attr surface=20.
  qview.create(90, 0, 0)
  qview.set_attr(90, 0, 0)
  qview.set_attr(90, 1, 0)
  qview.set_attr(90, 2, 408)
  qview.set_attr(90, 3, 64)
  qview.set_attr(90, 4, 0)
  qview.set_attr(90, 20, 3)
  // Bar title (91), over the material.
  qview.create(91, 4, 0)
  qview.set_attr(91, 0, 20)
  qview.set_attr(91, 1, 22)
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
