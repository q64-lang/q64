// fixture: an `if` condition must be bool, not an integer (TYP051).
// Mirrors spec/tests/types/int-as-bool.q.

fn main {
    if 1 {
        env.out("yes")
    }
}
