# jsi

Host adapter for **JSI-hosted shells** — React Native today, any other
JavaScriptCore / Hermes embedder that exposes the JSI ABI in the
future. The adapter lets a q64 component run inside a mobile (or
desktop) app shell that already owns the screen, the input loop, and
the native rendering surface.

> **Status: not yet implemented.** This README describes the
> adapter's responsibility.

## What this adapter owns

Per [`runtime/README.md`](../README.md), the adapter encapsulates
everything the user shouldn't see. For JSI hosts, that means:

- **The JSI bridge.** Wasm linear-memory views handed to JS as typed
  arrays; JS callbacks lifted into q64 capability imports; BigInt
  marshaling for `i64` across the JS boundary.
- **The wRPC transport.** **WebSocket**, forwarded through the JS-side
  bridge — the host owns the socket; the adapter forwards frames
  to/from the Wasm component. See
  [`spec/rpc.md` §Transports](../../spec/rpc.md#transports).
- **View-tree op marshaling.** The `Renderer` face (per the planned
  `q64.view` stdlib module) is implemented on the JS side; the adapter
  carries `create_node` / `set_attr` / `mutate(diff)` / `present`
  operations across JSI to the host's native renderer.
- **Input as streams.** Touch, gesture, key, and lifecycle events from
  the host shell are lifted into `q64.event` streams.
- **Concurrency mapping.** `scope` / `spawn` / `channel<T>` map onto
  the host's JS event loop and any worker threads the embedder
  exposes (e.g. RN's worklet runtimes for off-main-thread work).

## What this adapter does *not* own

- **The renderer itself.** The host ships the renderer (e.g. a React
  Native module). This adapter is the q64 side of the bridge; the
  host side is a separate package shipped via the shell's package
  ecosystem (npm, CocoaPods, Maven), versioned independently and
  installed into the app binary before any q64 program targeting it
  can run.
- **A specific framework.** "JSI" is the integration surface; React
  Native is one consumer. A pure-Hermes embedder or a custom JSC
  host can use this adapter without React Native.
- **Component-side UI primitives.** Those live in `stdlib/view` /
  `stdlib/layout` / `stdlib/event` and are renderer-agnostic.
