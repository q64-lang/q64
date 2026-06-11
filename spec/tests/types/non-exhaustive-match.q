// TEST: TYP062 — non-exhaustive match
// SPEC: types.md#diagnostic-codes
// EXPECTED: error
//
// `Light` has three variants; the match covers two and has no `_`.

enum Light { Red, Yellow, Green }

fn main {
    var l = Light.Yellow
    match l {
        Red -> env.out("stop"),
        Yellow -> env.out("slow"),
    }
}
