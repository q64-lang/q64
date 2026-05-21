// TEST: REG050 — unknown transfer verb
// SPEC: memory.md#cross-region-transfers
// EXPECTED: error
//
// The single verb is `transfer(to: …)`. `copy_to`, `pin_to`, and
// `intern` are not in the language.

fn main {
    region arena1: Arena<1.MB> {
        let a: Vec<u8, arena1> = Vec.new()
        region arena2: Arena<1.MB> {
            let _b = a.copy_to(arena2)
        }
    }
}
