// Prelude Option (no import): the match covers Some but not None and
// has no `_` — TYP062 (spec/types.md, spec/errors.md §"Result and Option").
fn main {
    let o = Some(5)
    match o {
        Some(v) -> env.out(v),
    }
}
