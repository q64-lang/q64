// A face-bounded generic call whose inferred element type has no fit
// for the bound: `print_all` requires `T: Display`, `Plain` declares
// no `fit Plain : Display` — TYP200 (spec/faces.md §"Diagnostic
// codes").
face Display { fn fmt(self) -> str }

struct Plain { v: i64 }

fn print_all<T: Display>(items: [T]) {
    for item in items {
        env.out("{item.fmt()}")
    }
}

fn main {
    print_all([Plain { v: 1 }])
}
