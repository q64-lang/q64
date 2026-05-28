# stdlib/kv → `q64.kv`

Key-value storage via the `env.kv` capability.

> **Status: not yet implemented.**

## Surface (planned)

The `KeyValue` capability face (defined in [`spec/env.md`](../../spec/env.md)
§"Capabilities as faces"). Keys are `str`; values are `Bytes`.

- **Read / write** — `env.kv.get(key)`, `env.kv.set(key, bytes)`,
  `env.kv.delete(key)`, `env.kv.exists(key)`, all returning
  `Result<T, IoError>`.
- **Listing** — `env.kv.list(cursor)` → `Result<KvPage, IoError>`, where
  `KvPage { keys: [str], cursor: Option<str> }` (cursor `None` = complete).
- **Atomics** — `env.kv.increment(key, delta)` and
  `env.kv.cas(key, expected, value)` (compare-and-swap), for counters and
  lock-free updates.

All operations carry `@kv` (which implies `@io`). `@realtime` stages cannot
call them.

## The opened bucket

`env.kv` is an **already-opened bucket** — the WASI
`wasi:keyvalue/store.open(identifier)` step is the host's, not the qube's. The
runtime hands the program a bucket pinned to its own identity; the program
never names a namespace and cannot reach another tenant's keys. This is the
capability-faces realization of multi-tenancy: isolation is a property of the
handed-in capability, not of caller-supplied strings.

On **qubepods**, the host pins the bucket to `org/project/app`, so each
deployed application sees a private keyspace over a shared backing store. (The
host implementation prefixes keys with the tenant tuple; the qube only ever
sees its own clean keys.)

## Host backing

Maps to the `wasi:keyvalue` proposal (`store` + `atomics`). Backing varies by
host: Cloudflare KV on qubepods (eventually consistent, read-your-writes —
which matches the proposal's documented semantics); `wasmtime-wasi-keyvalue`
for the native / container path; an in-memory fit (`MockKv`) for tests via
`with_capabilities(use: { kv: MockKv.new() })`. The user-facing surface is
identical across hosts.

## Example

```q64
// Per-visitor counter, stored in the qube's own bucket.
@http_handler
pub fn handle(req: Request) -> Response @kv + @network {
    let hits = try env.kv.increment("hits", 1)
    Response.ok("visit #{hits}")
}
```
