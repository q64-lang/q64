// TEST: TYP306 — `panic` payload does not fit `Panic`
// SPEC: errors.md#panic-and-trap
// EXPECTED: error

struct NotAPanic { x: i64 }

fn main {
    panic NotAPanic { x: 42 }
}
