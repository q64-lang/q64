// TEST: LEX021 — `&` in type position
// SPEC: types.md#references
// EXPECTED: error

fn first_byte(buf: &[u8]) -> u8 {
    buf[0]
}
