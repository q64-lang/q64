// TEST: TYP202 — wrong fit form for multi-param face
// SPEC: faces.md#fit-declaration
// EXPECTED: error
//
// `Convert<From, To>` is multi-parameter; the fit must be written
// `fit Convert<A, B>`, not `fit A : Convert<B>`.

pub face Convert<From, To> {
    fn convert(x: From) -> To
}

pub struct Celsius(f64)
pub struct Fahrenheit(f64)

pub fit Celsius : Convert<Fahrenheit> {
    fn convert(x: Celsius) -> Fahrenheit {
        Fahrenheit(x.0 * 9.0 / 5.0 + 32.0)
    }
}
