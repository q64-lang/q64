fn main {
    for t in 0..24 {
        for y in 0..16 {
            for x in 0..16 {
                let r = (x * 16 + t * 10) % 256
                let g = (y * 16 + t * 8) % 256
                let b = (x * 8 + y * 8 + t * 12) % 256
                let color = r * 65536 + g * 256 + b
                qview.box(x * 18, y * 18, 17, 17, color)
            }
        }
        qview.present()
    }
}
