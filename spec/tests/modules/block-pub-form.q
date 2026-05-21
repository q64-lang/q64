// TEST: NAM009 — block `pub` form is forbidden
// SPEC: modules.md#block-pub-is-forbidden
// EXPECTED: error

pub {
    fn a() -> i64 { 1 }
    fn b() -> i64 { 2 }
}
