// TEST: golden — face, fit, generic fn triangle
// SPEC: faces.md#canonical-example
// EXPECTED: ok

//! gfx-demo — colors and a tiny printer.

pub face Display {
    fn fmt(self) -> str @pure
}

pub struct Color { r: u8, g: u8, b: u8 }

pub fit Color : Display {
    fn fmt(self) -> str {
        "#{self.r:02x}{self.g:02x}{self.b:02x}"
    }
}

pub fn print_all<T: Display>(env: Env, items: [T]) {
    for item in items {
        env.out("{item.fmt()}")
    }
}

fn main(env: Env) {
    print_all(env, [
        Color { r: 255, g: 0,   b: 0   },
        Color { r: 0,   g: 255, b: 0   },
        Color { r: 0,   g: 0,   b: 255 },
    ])
}
