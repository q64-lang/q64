//! db-scalar — the minimal `env.db` example, emitted as a WebAssembly component.
//!
//! `setup()` creates a table, `add()` inserts a row (returning rows-affected),
//! `count()` reads a scalar integer (COUNT(*)), `namelen()` reads a scalar text
//! column (its length). All go through `env.db` — the SQL capability — which
//! lowers to imports of `q64:db/sql` when emitted as a component
//! (spec/env.md §`env.db`).
//!
//! Build (the component path):
//!
//!   qube build --component --addr wasm32
//!   wasm-tools component wit …/db-scalar.component.wasm
//!   # → world imports q64:db/sql, exports setup/add/count/namelen
//!
//! Proves: a capability face lowers to a real host **import**. The connection
//! is host-opened and identity-pinned (org/project/app on qubepods), so this
//! same source is multi-tenant with no database name in it — exactly like
//! `env.kv` / `env.blob`.
//!
//! v0 SCOPE: `execute` (DDL / INSERT / UPDATE / DELETE, rows affected) +
//! `query_value` (first column of first row as an integer — COUNT(*), SUM, id)
//! + `query_text` (as text) + `query_one<Row>` (the first row's INTEGER columns
//! as a typed `struct`, decoded zero-copy over the canonical `list<s64>`).
//! Text columns in a query_one struct, multi-row `Vec<Row>`, positional params,
//! and `batch` are deferred (they need floors q64 does not yet lift); v0 takes
//! literal SQL. env.db targets a q64-owned `q64:db/sql`, not raw wasi:sql — see
//! the WIT header and test/db-component-reference/.

// Create the table if it doesn't exist; return 1 on success.
pub fn setup() -> i64 {
    match env.db.execute("CREATE TABLE IF NOT EXISTS users(id INTEGER PRIMARY KEY, name TEXT)") {
        Ok(_)  -> 1
        Err(_) -> 0 - 1
    }
}

// Insert a row; return the number of rows affected (1).
pub fn add() -> i64 {
    match env.db.execute("INSERT INTO users(name) VALUES('ada')") {
        Ok(rows) -> rows
        Err(_)   -> 0 - 1
    }
}

// Count the rows: the first column of the first row, as an integer.
pub fn count() -> i64 {
    match env.db.query_value("SELECT COUNT(*) FROM users") {
        Ok(Some(n)) -> n
        Ok(None)    -> 0
        Err(_)      -> 0 - 1
    }
}

// Read a text column (a name) and return its byte length.
pub fn namelen() -> i64 {
    match env.db.query_text("SELECT name FROM users LIMIT 1") {
        Ok(Some(s)) -> s.len
        Ok(None)    -> 0 - 1
        Err(_)      -> 0 - 2
    }
}

// A typed row: the first row's integer columns mapped positionally onto a
// struct. The canonical `list<s64>` the host returns is N contiguous 8-byte
// cells — exactly an all-`i64` record's layout — so the row binds ZERO-COPY
// (the record pointer IS the list pointer). Every field must be `i64` (v0).
struct Row { id: i64, namelen: i64 }

// Return the first user's id and name length folded into one integer
// (id * 100 + namelen), proving both columns decode. `Ok(None)` on no row.
pub fn firstrow() -> i64 {
    match env.db.query_one<Row>("SELECT id, LENGTH(name) FROM users ORDER BY id LIMIT 1") {
        Ok(Some(row)) -> row.id * 100 + row.namelen
        Ok(None)      -> 0 - 1
        Err(_)        -> 0 - 2
    }
}
