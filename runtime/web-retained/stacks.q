// HStack/VStack layout demo: an outer row (HStack) holding two columns (VStacks).
// The stacks OWN their children's positions — no absolute x/y on the children.
// Left column: a few controls. Right column: a vertical slider (h > w).
state v = 60

fn main {
  // Outer HStack at (24, 80): two columns, gap 32, top-aligned.
  qview.create(1, 1, 0)
  qview.set_attr(1, 0, 24)
  qview.set_attr(1, 1, 80)
  qview.set_attr(1, 19, 32)
  qview.set_attr(1, 21, 0)

  // Left VStack (column), gap 16.
  qview.create(10, 2, 1)
  qview.set_attr(10, 19, 16)
  // children: label, button, checkbox, switch — NO x/y, the stack places them.
  qview.create(11, 4, 10)
  qview.set_attr(11, 9, 1018)
  qview.create(12, 6, 10)
  qview.set_attr(12, 9, 1011)
  qview.create(13, 7, 10)
  qview.set_attr(13, 12, 1)
  qview.create(14, 8, 10)
  qview.set_attr(14, 12, 0)

  // Right VStack (column), gap 12, centered children.
  qview.create(20, 2, 1)
  qview.set_attr(20, 19, 12)
  qview.set_attr(20, 21, 1)
  // a label + a VERTICAL slider (w=28, h=160 -> vertical).
  qview.create(21, 4, 20)
  qview.set_attr(21, 9, 1007)
  qview.create(22, 10, 20)
  qview.set_attr(22, 2, 28)
  qview.set_attr(22, 3, 160)
  qview.set_attr(22, 15, 0)
  qview.set_attr(22, 16, 100)
  qview.set_attr(22, 17, v)
  qview.on(22, 0, 22)

  qview.present()
}

pub fn on_22(node: i64, event: i64, value: i64) {
  v = value
  qview.set_attr(22, 17, v)
  qview.present()
}
