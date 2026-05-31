// Parses cleanly but fails IR construction: `mystery` resolves to no
// function (NameNotFound). Used to check that `q64 show` surfaces the same
// honest diagnostic as `q64 emit` for a malformed program.
fn main {
    env.out(mystery())
}
