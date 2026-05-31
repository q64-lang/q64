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
state platform  = 12   // dropdown: catalog id of the selected option (12 = iOS)
state grouped   = 1    // the checkbox inside the group widget

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

  // Platform dropdown at the TOP (80) + name (81). Options are catalog ids
  // 12..15 = iOS / Android / Windows / Linux. min=base id, max=count, selected
  // index. The field text_id = 12 + selected, so it shows the chosen platform.
  // (Popup overlays everything, so the field can sit at the top.)
  qview.create(81, 4, 0)
  qview.set_attr(81, 0, 40)
  qview.set_attr(81, 1, 92)
  qview.set_attr(81, 9, 9)
  qview.create(80, 12, 0)
  qview.set_attr(80, 0, 150)
  qview.set_attr(80, 1, 84)
  qview.set_attr(80, 2, 226)
  qview.set_attr(80, 3, 44)
  qview.set_attr(80, 15, 12)
  qview.set_attr(80, 16, 4)
  qview.set_attr(80, 13, 0)
  qview.set_attr(80, 9, 12)
  qview.on(80, 0, 80)

  // Thin divider (5) under the dropdown — separates the platform selector from
  // the widget list. kind divider=13; h = thickness (1px).
  qview.create(5, 13, 0)
  qview.set_attr(5, 0, 40)
  qview.set_attr(5, 1, 144)
  qview.set_attr(5, 2, 336)
  qview.set_attr(5, 3, 1)

  // Label demo (10) — the "Label" widget, just below the divider.
  qview.create(10, 4, 0)
  qview.set_attr(10, 0, 40)
  qview.set_attr(10, 1, 168)
  qview.set_attr(10, 9, 1)

  // Button (20) -> handler 20, name (21 taps count to its right)
  qview.create(20, 6, 0)
  qview.set_attr(20, 0, 40)
  qview.set_attr(20, 1, 196)
  qview.set_attr(20, 2, 150)
  qview.set_attr(20, 3, 48)
  qview.set_attr(20, 4, 12)
  qview.set_attr(20, 9, 11)
  qview.on(20, 0, 20)
  qview.create(21, 4, 0)
  qview.set_attr(21, 0, 210)
  qview.set_attr(21, 1, 210)
  qview.set_attr(21, 9, taps)

  // Checkbox (30) -> handler 30, name (31)
  qview.create(30, 7, 0)
  qview.set_attr(30, 0, 40)
  qview.set_attr(30, 1, 252)
  qview.on(30, 0, 30)
  qview.set_attr(30, 12, checked)
  qview.create(31, 4, 0)
  qview.set_attr(31, 0, 80)
  qview.set_attr(31, 1, 254)
  qview.set_attr(31, 9, 3)

  // Switch (40) -> handler 40, name (41)
  qview.create(40, 8, 0)
  qview.set_attr(40, 0, 40)
  qview.set_attr(40, 1, 304)
  qview.on(40, 0, 40)
  qview.set_attr(40, 12, toggled)
  qview.create(41, 4, 0)
  qview.set_attr(41, 0, 108)
  qview.set_attr(41, 1, 306)
  qview.set_attr(41, 9, 4)

  // Radio A (50) -> 50, name (51); Radio B (52) -> 52, name (53). group 1.
  // Each radio's w/h is a LARGE hit row (circle + label), the two halves of the
  // line, non-overlapping. The circle draws anchored-left inside; the label sits
  // within the same row so tapping anywhere on "Radio A" selects it.
  qview.create(50, 9, 0)
  qview.set_attr(50, 0, 32)
  qview.set_attr(50, 1, 356)
  qview.set_attr(50, 2, 172)
  qview.set_attr(50, 3, 56)
  qview.set_attr(50, 14, 1)
  qview.set_attr(50, 13, 1)
  qview.on(50, 0, 50)
  qview.create(51, 4, 0)
  qview.set_attr(51, 0, 72)
  qview.set_attr(51, 1, 374)
  qview.set_attr(51, 9, 5)
  qview.create(52, 9, 0)
  qview.set_attr(52, 0, 208)
  qview.set_attr(52, 1, 356)
  qview.set_attr(52, 2, 172)
  qview.set_attr(52, 3, 56)
  qview.set_attr(52, 14, 1)
  qview.set_attr(52, 13, 0)
  qview.on(52, 0, 52)
  qview.create(53, 4, 0)
  qview.set_attr(53, 0, 248)
  qview.set_attr(53, 1, 374)
  qview.set_attr(53, 9, 6)

  // Slider row: name (61) above the control (60).
  qview.create(61, 4, 0)
  qview.set_attr(61, 0, 40)
  qview.set_attr(61, 1, 408)
  qview.set_attr(61, 9, 7)
  qview.create(60, 10, 0)
  qview.set_attr(60, 0, 40)
  qview.set_attr(60, 1, 434)
  qview.set_attr(60, 2, 320)
  qview.set_attr(60, 15, 0)
  qview.set_attr(60, 16, 100)
  qview.set_attr(60, 17, sliderVal)
  qview.on(60, 0, 60)

  // Progress row: name (71) above the control (70).
  qview.create(71, 4, 0)
  qview.set_attr(71, 0, 40)
  qview.set_attr(71, 1, 486)
  qview.set_attr(71, 9, 8)
  qview.create(70, 11, 0)
  qview.set_attr(70, 0, 40)
  qview.set_attr(70, 1, 512)
  qview.set_attr(70, 2, 320)
  qview.set_attr(70, 15, 0)
  qview.set_attr(70, 16, 100)
  qview.set_attr(70, 17, sliderVal)

  // Group widget (6): a titled panel holding sub-widgets. kind group=14;
  // text_id 16 = "Grouped". Its children (a label + a checkbox) are positioned
  // inside it and drawn on top by the tree walk — any widget can be grouped.
  qview.create(6, 14, 0)
  qview.set_attr(6, 0, 40)
  qview.set_attr(6, 1, 552)
  qview.set_attr(6, 2, 320)
  qview.set_attr(6, 3, 96)
  qview.set_attr(6, 9, 16)
  // sub-label (7) inside the group
  qview.create(7, 4, 6)
  qview.set_attr(7, 0, 56)
  qview.set_attr(7, 1, 600)
  qview.set_attr(7, 9, 17)
  // sub-checkbox (8) inside the group — wired to handler 8 to prove a grouped
  // child still receives touch.
  qview.create(8, 7, 6)
  qview.set_attr(8, 0, 280)
  qview.set_attr(8, 1, 596)
  qview.set_attr(8, 12, grouped)
  qview.on(8, 0, 8)

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
  qview.set_attr(80, 13, platform - 12)
  qview.present()
}
// Grouped checkbox: toggles like any other — proves a child of a group node
// still receives touch and mutates surgically.
pub fn on_8(node: i64, event: i64) {
  grouped = 1 - grouped
  qview.set_attr(8, 12, grouped)
  qview.present()
}
