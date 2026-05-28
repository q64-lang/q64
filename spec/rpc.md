# RPC

Qube-to-qube remote procedure calls. How a qube imports another qube's
interface and calls it across a process or network boundary — built on the
synthesized WIT `world` (per [`modules.md` §"The qube as a component"](./modules.md)),
with wire-crossing made visible in the type system.

> **Status: draft (v0).** The shape is settled: the synthesized world is the
> contract, **wRPC** is the framework, **component-value encoding** is the
> wire, and the **`@wire`** effect makes remote calls visible. Async RPC —
> `future<T>` / `stream<T>` over the wire — rides WASIp3's native `future` /
> `stream` (q64 tracks the WASIp3 RC; see [`env.md`](./env.md)). Sending WIT
> resources over the wire remains deferred until the upstream resource-transfer
> story lands.

## Design goals

1. **No separate IDL.** The WIT `world` synthesized from a qube's public
   surface (`modules.md`) *is* the RPC contract on both ends. A qube that
   exports an RPC service and a qube that imports it agree on the world; no
   hand-written interface definition.
2. **The type lowering is the wire format.** The canonical-ABI value
   encoding used for component boundaries (`modules.md` §"Lowering q64 types
   to the canonical ABI") is exactly what travels on the wire. One table
   governs both.
3. **Wire-crossing is visible in the type.** A remote call carries the
   `@wire` effect (per [`effects.md`](./effects.md)), so it shows up in every
   transitive signature and in `qube audit`, never hidden behind an
   innocent-looking function call.
4. **Resources stay process-local.** Handles to instance-local state are
   never serialized; only value types cross the wire.
5. **Transport-agnostic.** wRPC abstracts the transport; each runtime
   adapter provides one (WebTransport in the browser, QUIC/TCP on native
   hosts, WebSocket on JSI shells).

## Vocabulary

| Word | Meaning |
|------|---------|
| **wRPC**   | The WIT-native RPC framework q64 targets. Dispatches against a `world`; transport-agnostic. |
| **`@wire`** | The effect a remote call carries (per [`effects.md`](./effects.md)). Positive (capability-style); propagates up; implies `@io`. |
| **remote world** | A remote qube's synthesized `world`, imported by a caller and invoked over wRPC. |
| **transport** | The byte-moving layer beneath wRPC, supplied by the runtime adapter (WebTransport / QUIC / TCP / WebSocket / local IPC). |
| **endpoint** | The address (a `wrpc://…` URL or continuum-resolved qube name) at which a remote world is served. |

## Model

A qube participates in RPC in two directions, independently:

- **Export** — the qube's component exports (its public surface, per
  `modules.md`) are served over wRPC. Opt in with `rpc.export: true` in the
  manifest ([`qube.json5.md` §RPC](./qube.json5.md)). The host adapter binds
  the world to a transport and answers incoming calls.
- **Import** — the qube names a remote qube and calls its exports as
  ordinary q64 functions. Opt in with `rpc.import` in the manifest, mapping a
  local binding name to an endpoint. Every call into an imported remote
  function carries `@wire`.

```q64
// Caller: manifest declares rpc.import = { "billing": "wrpc://billing.example.com" }
import billing.{charge}                 // remote qube's re-exported fn

pub fn checkout(cart: Cart) -> Result<Receipt, Error> @wire {
    let receipt = try charge(cart.total)   // @wire — this crosses a boundary
    Ok(receipt)
}
```

The imported `billing` world is the same artifact `billing`'s author built
with `component.emit: true`; the caller and callee share it. No IDL is
authored on either side.

## Wire encoding — wRPC + component values

RPC arguments and return values are encoded with the **component-value
encoding** — the canonical-ABI serialization of the WIT types produced by
the lowering table in [`modules.md` §"Lowering q64 types to the canonical
ABI"](./modules.md). That table is reused verbatim; the **lowerable set is
the serializable set**.

The direct consequence: **an RPC signature may use only value types.** The
unlowerable set from `modules.md` — `ref T`, region-parameterized types,
managed / WasmGC references, closures, faces-as-values, and WIT
**resources** — is **not transmissible**. Resources in particular stay
**process-local**: a handle references state inside one component instance
and is meaningless on the far side of a wire. A `pub fn` exposed for RPC
with a non-value parameter or return type is `RPC010`.

This is not a new rule — it is the `modules.md` canonical-ABI constraint with
a second justification. A type that cannot lift across a component boundary
also cannot cross a wire.

## The `@wire` effect

A call into an imported remote function carries `@wire`, registered as a
core capability marker in [`effects.md`](./effects.md):

- **Propagates up** like any capability: a function calling a `@wire`
  function picks up `@wire` in its inferred set, all the way to `main`.
- **Implies `@io`.** Because `@realtime ⇒ @no_alloc + @no_suspend` and
  `@realtime + @io` is `EFF120`, **`@realtime` code can never make a remote
  call** — it falls out of the existing contradiction with no special rule.
- **Does not imply `@network`.** A transport may be local IPC. When the
  active transport is network-backed, the runtime adapter *additionally*
  discloses `@network`, so the network reach is still visible — but `@wire`
  itself only asserts "this leaves the process," not "this touches the
  network."
- **Disclosed like every capability.** `@wire` appears in the
  compiler-derived set, in `qube audit`, and — when the qube is built as a
  component — in the synthesized world's imports (the imported remote
  world). It has no `Env` field (per [`env.md`](./env.md)); it is the one
  capability that comes from an RPC import rather than the ambient `env`.

## Transports

wRPC is transport-agnostic; the byte-moving layer is supplied by the runtime
adapter (`runtime/<host>/`), the same place WASI lowering lives. q64 code
sees only typed calls.

| Host | Transport |
|------|-----------|
| Browser (`runtime/browser`)   | **WebTransport** (HTTP/3 streams + datagrams) |
| Wasmtime / Wasmer (native)    | **QUIC** preferred, **TCP** fallback          |
| JSI (`runtime/jsi`)           | **WebSocket** (forwarded through the JS-side JSI bridge) |
| (any)                         | local IPC for in-process / same-host calls    |

The adapter owns connection setup, multiplexing, and reconnection. A
network-backed transport contributes `@network` to disclosure (see above);
a local-IPC transport does not.

## Addressing & discovery

A remote world is located by an **endpoint**:

- A literal `wrpc://<host>[:port]` URL in `rpc.import`
  ([`qube.json5.md` §RPC](./qube.json5.md)).
- A **continuum-registered** qube name resolved to an endpoint at build or
  deploy time (per [`continuum-api.md`](./continuum-api.md)). The registry
  surfaces a qube's served world and address alongside its existing
  capability/effect disclosure, so adding a remote dependency shows the
  `@wire` reach and the remote world at `qube add` time.

A **qubepods** endpoint (per [`env.md` §"HTTP service entry point"](./env.md))
doubles as a wRPC server: a qube built `--component` and deployed to qubepods
is reachable both as `wasi:http` and, when `rpc.export: true`, as a wRPC
service at the same endpoint.

## Async results and streaming (WASIp3)

Async and streaming RPC ride WASIp3's native canonical-ABI `future` / `stream`.
A `pub fn` exposed for RPC may return (or take) a `Future<T>` or `Stream<T, R>`
of otherwise-lowerable value types; these lower to WIT `future<T>` / `stream<T>`
and travel over wRPC without a polling shim — the same bridge the
`Signal` / `Event` / `Stream` family uses at the component boundary
([`streams.md`](./streams.md)). RPC requires the Component Model, and the only
Component Model WASI target is `preview3` (the default and sole component
target — there is no Preview 2 fallback; see [`env.md`](./env.md)), so native
async is available wherever RPC is. A `future<T>` / `stream<T>` in an RPC
signature under a non-component target such as `preview1` is `RPC012`.

Because q64 tracks the WASIp3 **release candidate**, the wire encoding for
`future` / `stream` follows the pinned snapshot (see [`env.md`](./env.md)) and
moves with each upstream RC until WASI 1.0.

## Remote channels

A **remote channel** is the local channel of
[`concurrency.md` §Channels](./concurrency.md) with its two halves on opposite
sides of a wire. `Channel<Tx, Rx>` is a bidirectional endpoint: it **sends**
`Tx` and **receives** `Rx`; the peer holds the dual `Channel<Rx, Tx>`. It is
**sugar over a pair of WASIp3 streams** — an outbound `stream<Tx>` and an
inbound `stream<Rx>` — so it adds **no new wire-resource** (see §Deferred) and
rides the same canonical-ABI lowering as any streamed RPC value.

The endpoint reuses the `Sender` / `Receiver` surface from `concurrency.md`, so
local and remote channels are used identically — the only difference is that
remote `send` / `recv` carry `@wire`:

```q64
pub face Channel<Tx, Rx> {
    fn send  (self, ctx: Cancel, move x: Tx)  -> Result<(), SendError<Tx>> @wire + @cancel  // → stream<Tx>
    fn recv  (self, ctx: Cancel)              -> Result<Rx, RecvError>      @wire + @cancel  // ← stream<Rx>
    fn close (self)                                                                          // close both directions
}
// Iterable on its Rx side: `for msg in chan { … }`; usable in `select`.
```

- **Backpressure is the wire's.** WebTransport (browser) / QUIC (native) stream
  flow control realizes `Backpressure` end to end: a slow reader pauses the
  writer's `stream<T>`, with no unbounded application buffering. The JSI
  WebSocket transport rides a single TCP flow-control signal across the
  socket, so all multiplexed `stream<T>` channels share one backpressure
  budget — a slow reader on one logical stream applies backpressure to every
  other stream on the same connection. This is correctness-preserving but
  coarser; latency-sensitive channels should be opened on separate
  WebSocket connections where this matters.
- **Messages are value types.** `Tx` and `Rx` obey the §"Wire encoding" rule; a
  non-lowerable message type is `RPC010`.
- **Establishment** mirrors §Model. The **exporter** receives the server end
  through a channel entry point ([`env.md` §"Channel entry point"](./env.md));
  the **importer** opens the client (dual) end with `connect`, deriving the
  channel type from the imported export's signature:

```q64
// importer: rpc.import = { "agent": "wrpc://my-agent.qubepods.app" }
let agent: Channel<str, str> = connect<agent.chat>(ctx)   // @wire
```

The canonical use case — a text stream between a user (frontend qube) and an
agent (backend qube) — is worked end to end in
[`env.md` §"Channel entry point"](./env.md).

## Deferred

- **Resources over the wire.** v0 keeps resources process-local. Sending a
  handle (with its lifecycle and ownership semantics) across a wire waits for
  the upstream resource-transfer story to stabilize. This is independent of
  WASIp3 async, which is in scope above.

## Diagnostic codes

All RPC diagnostics use the `RPC` prefix (per
[`diagnostics.md`](./diagnostics.md)). Numbers are stable, never reused.

| Code     | Short message                              | When                                                                              |
|----------|--------------------------------------------|-----------------------------------------------------------------------------------|
| `RPC010` | non-value type in RPC signature            | A `pub fn` exposed for RPC uses an unlowerable type (`ref`, region, managed, closure, face-value, resource) in a parameter or return position. |
| `RPC011` | `rpc.export` without `component.emit`      | The manifest sets `rpc.export: true` but does not emit a component; RPC rides the component world. |
| `RPC012` | async RPC type under non-component target | A `future<T>` / `stream<T>` appears in an RPC signature, but the active target's `wasi` setting is not the Component Model target `preview3` (e.g. `preview1`); native async lowering is unavailable. |
| `RPC020` | remote world unavailable                   | An imported endpoint could not be reached or served no matching world at build/resolve time. |
| `RPC021` | remote world version mismatch              | The imported endpoint's world is incompatible with the locally resolved contract. |

All codes are emitted using the standard envelope from
[`diagnostics.md`](./diagnostics.md).

## Related specs

- [`modules.md`](./modules.md) — the synthesized `world` (the RPC contract)
  and the canonical-ABI type-lowering table (the wire format).
- [`effects.md`](./effects.md) — the `@wire` marker, its implication
  (`@wire ⇒ @io`), and the effect→WIT-import synthesis.
- [`env.md`](./env.md) — capability disclosure; `@wire` as the one capability
  effect with no `Env` field; the `wasi:http` endpoint that doubles as a wRPC
  server.
- [`qube.json5.md`](./qube.json5.md) — the `component` and `rpc` manifest
  blocks.
- [`continuum-api.md`](./continuum-api.md) — resolving a qube name to a wRPC
  endpoint; registry disclosure of served worlds.
- [`diagnostics.md`](./diagnostics.md) — the `RPC` and `CMP` diagnostic
  bands.
- [`streams.md`](./streams.md) — the `Signal`/`Event`/`Stream` family, whose
  WIT-async bridge rides the same WASIp3 native `stream<T>` / `future<T>`.
