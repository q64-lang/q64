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
state platform  = 1012 // dropdown: catalog id of the selected option (12 = iOS)
state grouped   = 1    // the checkbox inside the group widget
state picked    = 1020 // long-click menu: last picked item (20 = Copy)
state stackVal  = 60   // the vertical slider in the stacks section

fn main {
  // ---- pinned header (sticks; opaque solid bar) ----
  qview.create(90, 0, 0)
  qview.set_attr(90, 0, 0)
  qview.set_attr(90, 1, 0)
  qview.set_attr(90, 2, 412)
  qview.set_attr(90, 3, 56)
  qview.set_attr(90, 20, 1)
  qview.create(91, 4, 90)
  qview.set_attr(91, 0, 16)
  qview.set_attr(91, 1, 18)
  qview.set_attr(91, 9, 1000)

  // ---- the body: ONE outer VStack (column 100). It measures all its sections
  //      and computes the total height — nothing can fall off-frame unaccounted.
  //      pad 16 inside; gap 18 between sections; starts just below the header. ----
  qview.create(100, 2, 0)
  qview.set_attr(100, 0, 16)
  qview.set_attr(100, 1, 72)
  qview.set_attr(100, 19, 18)
  qview.set_attr(100, 22, 0)

  // Platform row (HStack 110): "Dropdown" label + the dropdown field.
  qview.create(110, 1, 100)
  qview.set_attr(110, 19, 16)
  qview.set_attr(110, 21, 1)
  qview.create(81, 4, 110)
  qview.set_attr(81, 9, 1009)
  qview.create(80, 12, 110)
  qview.set_attr(80, 2, 226)
  qview.set_attr(80, 3, 44)
  qview.set_attr(80, 15, 1012)
  qview.set_attr(80, 16, 4)
  qview.set_attr(80, 13, 0)
  qview.set_attr(80, 9, 1012)
  qview.on(80, 0, 80)

  // Divider.
  qview.create(5, 13, 100)
  qview.set_attr(5, 2, 348)
  qview.set_attr(5, 3, 1)

  // Label row (HStack 120): the Label widget + a name.
  qview.create(120, 1, 100)
  qview.set_attr(120, 19, 12)
  qview.set_attr(120, 21, 1)
  qview.create(10, 4, 120)
  qview.set_attr(10, 9, 1001)

  // Button row (HStack 130): button + taps count.
  qview.create(130, 1, 100)
  qview.set_attr(130, 19, 16)
  qview.set_attr(130, 21, 1)
  qview.create(20, 6, 130)
  qview.set_attr(20, 2, 150)
  qview.set_attr(20, 3, 48)
  qview.set_attr(20, 4, 12)
  qview.set_attr(20, 9, 1011)
  qview.on(20, 0, 20)
  qview.create(21, 4, 130)
  qview.set_attr(21, 9, taps)

  // Checkbox row (HStack 140): checkbox + name.
  qview.create(140, 1, 100)
  qview.set_attr(140, 19, 12)
  qview.set_attr(140, 21, 1)
  qview.create(30, 7, 140)
  qview.set_attr(30, 12, checked)
  qview.on(30, 0, 30)
  qview.create(31, 4, 140)
  qview.set_attr(31, 9, 1003)

  // Switch row (HStack 150): switch + name.
  qview.create(150, 1, 100)
  qview.set_attr(150, 19, 12)
  qview.set_attr(150, 21, 1)
  qview.create(40, 8, 150)
  qview.set_attr(40, 12, toggled)
  qview.on(40, 0, 40)
  qview.create(41, 4, 150)
  qview.set_attr(41, 9, 1004)

  // Radio row (HStack 160): Radio A + Radio B (each its own labeled hit row).
  qview.create(160, 1, 100)
  qview.set_attr(160, 19, 4)
  qview.set_attr(160, 21, 1)
  qview.create(50, 9, 160)
  qview.set_attr(50, 2, 92)
  qview.set_attr(50, 3, 44)
  qview.set_attr(50, 14, 1)
  qview.set_attr(50, 13, 1)
  qview.on(50, 0, 50)
  qview.create(51, 4, 160)
  qview.set_attr(51, 9, 1005)
  qview.create(52, 9, 160)
  qview.set_attr(52, 2, 92)
  qview.set_attr(52, 3, 44)
  qview.set_attr(52, 14, 1)
  qview.set_attr(52, 13, 0)
  qview.on(52, 0, 52)
  qview.create(53, 4, 160)
  qview.set_attr(53, 9, 1006)

  // Slider section (VStack 170): name above the control.
  qview.create(170, 2, 100)
  qview.set_attr(170, 19, 6)
  qview.create(61, 4, 170)
  qview.set_attr(61, 9, 1007)
  qview.create(60, 10, 170)
  qview.set_attr(60, 2, 348)
  qview.set_attr(60, 3, 28)
  qview.set_attr(60, 15, 0)
  qview.set_attr(60, 16, 100)
  qview.set_attr(60, 17, sliderVal)
  qview.on(60, 0, 60)

  // Progress section (VStack 180): name above the control (tracks the slider).
  qview.create(180, 2, 100)
  qview.set_attr(180, 19, 6)
  qview.create(71, 4, 180)
  qview.set_attr(71, 9, 1008)
  qview.create(70, 11, 180)
  qview.set_attr(70, 2, 348)
  qview.set_attr(70, 3, 10)
  qview.set_attr(70, 15, 0)
  qview.set_attr(70, 16, 100)
  qview.set_attr(70, 17, sliderVal)

  // Group section (group 6): a titled panel holding a label + checkbox column.
  qview.create(6, 14, 100)
  qview.set_attr(6, 2, 348)
  qview.set_attr(6, 3, 92)
  qview.set_attr(6, 9, 1016)
  // its content VStack (190), offset below the heading.
  qview.create(190, 2, 6)
  qview.set_attr(190, 0, 14)
  qview.set_attr(190, 1, 44)
  qview.set_attr(190, 19, 8)
  qview.create(7, 4, 190)
  qview.set_attr(7, 9, 1017)
  qview.create(8, 7, 190)
  qview.set_attr(8, 12, grouped)
  qview.on(8, 0, 8)

  // Long-click box (9): context-menu surface with a centered label.
  qview.create(9, 0, 100)
  qview.set_attr(9, 2, 348)
  qview.set_attr(9, 3, 64)
  qview.set_attr(9, 4, 12)
  qview.set_attr(9, 5, 1)
  qview.set_attr(9, 9, 1018)
  qview.set_attr(9, 15, 1019)
  qview.set_attr(9, 16, 3)
  qview.set_attr(9, 13, 1020)
  qview.on(9, 1, 9)

  // Fader + meter section (HStack 300): a VERTICAL slider on the LEFT drives a
  // vertical STEREO PEAK METER on the right. Dragging the fader sets both meter
  // channels + the peak hold. Each is a labeled VStack column.
  qview.create(300, 1, 100)
  qview.set_attr(300, 19, 28)
  // Left: "Fader" label over the vertical slider (322).
  qview.create(320, 2, 300)
  qview.set_attr(320, 19, 10)
  qview.set_attr(320, 21, 1)
  qview.create(321, 4, 320)
  qview.set_attr(321, 9, 1022)
  qview.create(322, 10, 320)
  qview.set_attr(322, 2, 28)
  qview.set_attr(322, 3, 150)
  qview.set_attr(322, 15, 0)
  qview.set_attr(322, 16, 100)
  qview.set_attr(322, 17, stackVal)
  qview.on(322, 0, 322)
  // Right: "Meter" label over the vertical stereo peak meter (332).
  qview.create(330, 2, 300)
  qview.set_attr(330, 19, 10)
  qview.set_attr(330, 21, 1)
  qview.create(331, 4, 330)
  qview.set_attr(331, 9, 1023)
  qview.create(332, 15, 330)
  qview.set_attr(332, 2, 28)
  qview.set_attr(332, 3, 150)
  qview.set_attr(332, 15, 0)
  qview.set_attr(332, 16, 100)
  qview.set_attr(332, 17, stackVal)
  qview.set_attr(332, 23, stackVal)
  qview.set_attr(332, 24, stackVal)
  qview.set_attr(332, 25, stackVal)

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
// Slider: the host passes the value computed from the touch/drag position as
// `value` (the event payload). Set state to it; progress (70) mirrors it.
pub fn on_60(node: i64, event: i64, value: i64) {
  sliderVal = value
  qview.set_attr(60, 17, sliderVal)
  qview.set_attr(70, 17, sliderVal)
  qview.present()
}
// Dropdown: the host passes the chosen option's catalog id (12..15) as `value`.
// Set the field's text_id to it (shows the platform) and selected index to the
// offset from the base (12). min/max stay the option base/count.
pub fn on_80(node: i64, event: i64, value: i64) {
  platform = value
  qview.set_attr(80, 9, platform)
  qview.set_attr(80, 13, platform - 1012)
  qview.present()
}
// Grouped checkbox: toggles like any other — proves a child of a group node
// still receives touch and mutates surgically.
pub fn on_8(node: i64, event: i64) {
  grouped = 1 - grouped
  qview.set_attr(8, 12, grouped)
  qview.present()
}
// Long-click area: the context menu passes the chosen item's catalog id (19..21
// = Cut/Copy/Paste) as `value`. Mark it selected (checkmark) for next time.
pub fn on_9(node: i64, event: i64, value: i64) {
  picked = value
  qview.set_attr(9, 13, picked)
  qview.present()
}
// The fader drives the stereo peak meter. The right LEVEL is dimmed a touch for
// a stereo feel, but BOTH peak-holds reach the full fader value (a peak marker
// sits at the recent max, not the dimmed level) — so both peaks hit the top.
pub fn on_322(node: i64, event: i64, value: i64) {
  stackVal = value
  qview.set_attr(322, 17, stackVal)
  qview.set_attr(332, 17, stackVal)
  qview.set_attr(332, 23, stackVal * 9 / 10)
  qview.set_attr(332, 24, stackVal)
  qview.set_attr(332, 25, stackVal)
  qview.present()
}
