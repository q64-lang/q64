# stdlib/net → `q64.net`

HTTP, WebSocket, and URL primitives. Accessed via the `env.net` capability.

> **Status: not yet implemented.**

## Surface (planned)

- **`Url`** — a distinct kind from `str`. Built from `url"..."` literals
  (comptime-validated) or `Url.parse` at runtime. Interpolated values are
  percent-encoded automatically.
- **`Net`** — the network capability passed via `env.net`. Convenience
  methods: `get`, `post`, `put`, `delete`; full-control `request` accepting a
  `Request` struct.
- **`Request`** — `Builder`-derived with sensible defaults.
- **`Response`** — `.status()`, `.headers()`, `.bytes()`, `.text()`,
  `.json[T]()` (typed parse, driven by `@derive(FromJson)`).
- **WebSocket** — bidirectional `Stream[WsMessage]` pair, lifetime-bound to
  the enclosing scope.
- **Streaming bodies** — `Response.stream()` returns `Stream[Bytes]` with
  TCP-window backpressure flowing through.

All operations carry `@io @network` effects. `@realtime` stages cannot call
them; `qube audit` discloses network usage per dependency.
