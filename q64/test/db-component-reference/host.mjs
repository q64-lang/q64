// A generic `q64:db/sql` host over real in-memory SQLite (node:sqlite) — the
// role the qubepods host plays. Transpile the component with jco
// (`verify-q64.sh` does this), then this drives it: setup/add/count/namelen
// against a real database, asserting the canonical-ABI glue round-trips —
// string sql, `result<u64,error>` exec, `result<option<s64>,error>` query-value
// (the 8-aligned option: option-disc @8, s64 @16), `result<option<string>,error>`
// query-text, and the lazily-opened adapter-held connection.
//
//   node host.mjs <jco-out-dir>   # e.g. node host.mjs ./jcoout
//
// Exits non-zero on any mismatch. The v0 scalar surface (exec + first-cell
// query) is exactly what q64 can decode with the landed box machinery; typed
// multi-row Rows is deferred.
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';

const outDir = process.argv[2] ?? './jcoout';
const { instantiate } = await import(new URL(outDir + '/dbout.component.js', import.meta.url));

const sqlite = new DatabaseSync(':memory:');
class Connection {
  // result<u64, error>: rows affected.
  exec(sql) {
    const r = sqlite.prepare(sql).run();
    return BigInt(r.changes ?? 0);
  }
  // result<option<s64>, error>: first column of first row as int, or none.
  queryValue(sql) {
    const row = sqlite.prepare(sql).get();
    if (!row) return undefined;
    const v = Object.values(row)[0];
    return v == null ? undefined : BigInt(v);
  }
  // result<option<string>, error>: first column of first row as text, or none.
  queryText(sql) {
    const row = sqlite.prepare(sql).get();
    if (!row) return undefined;
    const v = Object.values(row)[0];
    return v == null ? undefined : String(v);
  }
  // result<option<list<s64>>, error>: the first row's INTEGER columns, in
  // SELECT order (jco lowers the returned array as the canonical list<s64>).
  // The guest maps them positionally onto its row struct — the qube's SELECT
  // must return one integer per struct field. `undefined` = Ok(None).
  queryOne(sql) {
    const row = sqlite.prepare(sql).get();
    if (!row) return undefined;
    return Object.values(row).map((v) => BigInt(v));
  }
}
const theConn = new Connection();

const imports = {
  'q64:db/sql': {
    Connection,
    error: class {},
    // identity is host-pinned; the qube opens with an empty identifier.
    open: () => theConn,
  },
};

const getCore = (name) =>
  WebAssembly.compile(readFileSync(new URL(outDir + '/' + name, import.meta.url)));

const inst = await instantiate(getCore, imports);

const expect = (label, got, want) => {
  if (got !== want) {
    console.error(`FAIL: ${label} = ${got}, expected ${want}`);
    process.exit(1);
  }
  console.log(`  ${label} -> ${got}`);
};

expect('setup', inst.setup(), 1n); // CREATE TABLE -> Ok
expect('add', inst.add(), 1n); // INSERT -> Ok(1 row affected)
expect('add again', inst.add(), 1n);
expect('count', inst.count(), 2n); // query_value COUNT(*) -> Ok(Some(2)) — 8-aligned option
expect('namelen', inst.namelen(), 3n); // query_text "ada" -> Ok(Some("ada")) -> len 3
// query_one<Row> over the first user: (id=1, LENGTH('ada')=3) decoded zero-copy
// onto struct Row { id, namelen } -> id*100 + namelen = 103. Proves the typed
// row's canonical list<s64> ↔ record mapping (both columns, not just the first).
expect('firstrow', inst.firstrow(), 103n);
console.log('OK — the q64 db component runs on a real SQLite q64:db/sql host.');
