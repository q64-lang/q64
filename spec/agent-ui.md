# Agent-driven UI — the command stream is the agent surface

> **Status: design note / draft.** A consequence of the command-driven renderer
> (see [`reactivity.md`](./reactivity.md)) and the capability/effect model
> ([`env.md`](./env.md), [`effects.md`](./effects.md)): an AI agent is just another
> *producer* of the same UI command stream a q64 program compiles to. This note
> states the property, the safety boundary, and what it requires of the protocol.

## The core property

QView renders a **command/mutation stream** (`create_node` / `set_attr` /
`mutate` / `remove` / `present` against a retained, node-addressed GPU scene —
*not* pixels or fixed widgets). The renderer does not care **who** produces the
stream. Today it's a q64-compiled wasm; it can equally be an **agent**. So
generative/adaptive UI is not a new subsystem — it's a new producer of an
existing, typed, capability-gated contract.

## Two levels an agent can target

| Level | What the agent produces | Properties | Use |
|---|---|---|---|
| **Command stream** | the Renderer ops directly (`create_node`, `set_attr`, …) | ephemeral, instant, no compile, no type/reactivity guarantees | on-the-fly panels, generated forms, adaptive layouts, live edits |
| **q64 source** | a `screen { state … draw … }` program → compiled to wasm32 | typed, reactive, durable, validated | a real qube the agent authors |

Pick ephemeral vs durable per use. Both hit the same renderer.

## Server-driven, per-user, surgical

Because a **twin** pushes view diffs over the WS channel, an agent running as/behind
a twin can **generate and adapt the UI live, per user** — inject a card, rewrite a
panel, tailor a form. The retained **node-id** model makes this *surgical*: an agent
emits `set_attr #5 …` or "insert under #3", i.e. **fine-grained edits to a live
interface**, never a blind full-screen regeneration. (This is why retained +
node-addressed + typed beats immediate-mode/opaque-pixels: only this surface is
precisely agent-targetable.)

## Safe by construction

The command stream is **declarative + capability-gated**, so agent-authored UI runs
inside the *same* effect/capability sandbox as human-authored qubes:

- An agent may **describe views** (draw ops) freely, and **invoke capabilities**
  it has been granted — and nothing else. No arbitrary code, no undeclared
  network/storage, no capability it wasn't given. **Agent reach = the manifest's
  declared capabilities, period.**
- Two enforcement points the host MUST apply to an incoming agent stream:
  1. **Schema-validate** every op (well-formed, valid node refs, known
     widget/attr kinds) — reject malformed/dangling mutations.
  2. **Authority-check** every capability invocation against the qube's granted
     set (an agent can't forge a `@kv`/`@network`/twin call it doesn't hold).
- Add the usual operational guards: **rate/quota** on agent-driven mutations,
  and treat agent-supplied content as untrusted (escape on render).

## Bidirectionally agent-native (closes the AI-visibility loop)

Command-driven UI + the capability model make a qube agent-native **both ways**:

- **Read** — the manifest / QAD / `.well-known` let an agent *discover* what a qube
  exposes (state, commands, capabilities).
- **Write** — the renderer command vocabulary + the granted capabilities let an
  agent *drive and generate* the UI.

So the **mutation protocol is the agent's UI API**: the same contract a human's q64
compiles to is the contract an agent emits against. It is an MCP-shaped surface
where the "tools" are the qube's declared capabilities and "rendering" is the
command stream.

## Consequence: the command vocabulary is a first-class, versioned contract

The renderer's op set is now **both** the compiler's backend target **and** the
agent-facing API. It must therefore be specified and **versioned** like any public
API, not left implicit in the host:

- **Ops:** `create_node(id, kind, parent)`, `set_attr(id, attr, value)`,
  `remove(id)`, `on(id, event, handler)`, `present()`.
- **Enums:** node `kind` (text/number/box/button/image/scroll/…), `attr`
  (x/y/w/h/radius/border/color/label/enabled/transform/z/…), `event`
  (press/drag/key/focus/…) — closed, versioned sets.
- **Capability invocation form:** how a stream names + calls a granted capability
  (typed args; authority-checked), distinct from draw ops.
- **Versioning:** a protocol version in the handshake so producers (q64 compiler,
  agents) and the renderer negotiate the op/enum set.

## Relationship to the rest

- **`reactivity.md`** — the mutation protocol + retained scene this builds on;
  `state`/`@state(scope)` lower onto the same ops.
- **Twins / BFF proxy** — agents generate UI server-side and the twin carries diffs
  to the view; same capability mediation.
- **QAD / AI-visibility** — discovery (read) + this (write) = the full agent surface.

## Open questions

- The exact **validation + authority** model for an inbound agent stream (where it
  runs, how capabilities are bound/attenuated per agent).
- **Ephemeral-vs-durable boundary**: when an agent's command stream should be
  promoted to (or backed by) generated q64.
- **Provenance/audit**: labeling agent-produced UI/mutations (honesty: a generated
  panel is marked as such, not passed off as authored).
- **Protocol versioning** cadence and back-compat for the op/enum vocabulary.
