// TEST: golden — face, fit, generic fn triangle
// SPEC: faces.md#canonical-example
// EXPECTED: ok

//! gfx-demo — colors and a tiny printer.

pub face Display {
    fn fmt(self) -> str @pure
}

pub struct Color { r: u8, g: u8, b: u8 }

pub fit Color : Display {
    // v0 interpolation has no format specs (types.md §"String types" —
    // {value:02x} is a deferred open item), so Display renders decimal.
    fn fmt(self) -> str {
        "rgb({self.r}, {self.g}, {self.b})"
    }
}

pub fn print_all<T: Display>(items: [T]) {
    for item in items {
        env.out("{item.fmt()}")
    }
}

fn main {
    print_all([
        Color { r: 255, g: 0,   b: 0   },
        Color { r: 0,   g: 255, b: 0   },
        Color { r: 0,   g: 0,   b: 255 },
    ])
}
