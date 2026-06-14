fn main {
    for y in 0..16 {
        for x in 0..16 {
            let px = x * 22
            let py = y * 22
            let r = x * 17
            let g = y * 17
            let b = 160
            let color = r * 65536 + g * 256 + b
            qview.box(px, py, 20, 20, color)
        }
    }
    qview.present()
}
