fn main {
    for t in 0..9 {
        for y in 0..8 {
            for x in 0..8 {
                let v = (x + y + t) * 8
                let g = 255 - v
                let color = v * 65536 + g * 256 + 140
                qview.box(x * 16, y * 16, 15, 15, color)
            }
        }
        qview.present()
    }
}
