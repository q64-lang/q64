# qube.json5 — Manifest reference

The manifest file that describes a qube. Every qube has one at its root.

> **Status: draft (v0).** This spec moves with the language. Breaking
> changes are still possible. The formal JSON Schema lives next to this
> file at [`qube.json5.schema.json`](./qube.json5.schema.json).

## Format

JSON5 — JSON with comments, trailing commas, unquoted keys, and single-quoted
strings. The manifest filename is always literally `qube.json5`.

Every manifest should begin with a `$schema` reference for editor tooling
(autocomplete, validation, hover docs):

```json5
{
  $schema: "https://q64.dev/schema/qube.json5",
  // ...
}
```

## Minimal example (library qube)

```json5
{
  $schema: "https://q64.dev/schema/qube.json5",
  name:    "audio-filters",
  version: "0.1.0",
  license: "MIT OR Apache-2.0",
}
```

That is a complete, publishable library qube. The default `entry` is
`src/lib.q`; the default `type` is `library`; everything else is optional.

## Project layout

The canonical layout keeps source under **`src/`**, separated from the manifest
and build output:

```
my-qube/
├── qube.json5        # the manifest
├── qube.lock         # resolved dependencies (generated)
├── src/
│   ├── main.q        # an application's entry  (type: "application")
│   └── lib.q         # a library's entry        (type: "library")
└── target/           # build output (generated; gitignore it)
```

**`entry` is the one knob** that says where the entry source lives — every
`qube` front-end (the native CLI and the on-device wasm shell) builds exactly
what it names. It defaults to `src/main.q` (applications) / `src/lib.q`
(libraries), so a qube using the standard layout may omit it; a qube that puts
its entry elsewhere (e.g. a one-file demo with `entry: "hello.q"`) states it
explicitly. There is no second rule — `src/` is the default value of `entry`,
not a separate convention, so the layout can never disagree with what builds.
A dependency's source is read from `<dep>/src/` the same way.

## Full example (application qube)

```json5
{
  $schema: "https://q64.dev/schema/qube.json5",

  // Identity
  name:        "voice-agent",
  version:     "0.2.0",
  license:     "MIT OR Apache-2.0",
  description: "Real-time microphone → ASR → LLM → TTS → speaker pipeline.",
  authors:     ["Alice Example <alice@example.com>"],
  repository:  "https://github.com/example/voice-agent",
  keywords:    ["audio", "ai", "real-time"],

  // Code shape
  type:  "application",
  entry: "src/main.q",

  // Dependencies. Keys are full qube names (= module paths). Core stdlib
  // (`q64.*`, e.g. `q64.net`) is built in and never listed here.
  dependencies: {
    "dev.q64.audio":      "^0.3",
    "dev.q64.ai":         "^0.3",
    "com.openai.whisper": { version: "^1.0", features: ["en"] },
    "dev.example.llm":    { path: "../llm" },
  },

  // Build targets
  targets: {
    desktop: {
      host: "wasmtime",
      optimize: "speed",
    },
    browser: {
      host: "browser",
      browser: {
        coop: "same-origin",
        coep: "require-corp",
      },
    },
    plugin: {
      host: "audio-host",
      "audio-host": {
        formats: ["vst3", "au"],
      },
    },
  },

  // Effect disclosure
  effects: {
    declared: ["@realtime", "@io", "@network"],
    deny:     ["@unrestricted_fs"],
  },

  // Capability disclosure (generated — `qube publish` syncs it from the
  // compiler; see §Capabilities below)
  capabilities: ["Audio", "Net", "Stdout"],
}
```

## Field reference

### Identity

| Field         | Type     | Required | Notes                                                                    |
|---------------|----------|----------|--------------------------------------------------------------------------|
| `$schema`     | string   | no       | Schema URL. Recommended at the top of every manifest.                    |
| `name`        | string   | **yes**  | Dotted path; each segment a lowercase identifier `[a-z][a-z0-9_]*` (snake_case, no dashes), `.`-separated. The name **is** the module path (no transform) — see [`modules.md`](./modules.md). Publishable qubes (library/application) must use a reverse-DNS form with ≥2 segments (enforced at publish); a workspace root may use a single-segment label. `q64.*` is reserved for the built-in stdlib. Max 128 chars. e.g. `dev.q64.webmcp_client`, `com.acme.widget`. |
| `version`     | string   | **yes**  | Semver.                                                                  |
| `license`     | string   | **yes**  | SPDX expression. Use `"MIT OR Apache-2.0"` for the q64 ecosystem default.|
| `description` | string   | no       | One-line summary, max 280 chars, shown on the registry.                  |
| `authors`     | string[] | no       | Each entry is `"Name"` or `"Name <email>"`.                              |
| `repository`  | URL      | no       | Source repository.                                                       |
| `homepage`    | URL      | no       | Project homepage.                                                        |
| `documentation` | URL    | no       | Hosted docs.                                                             |
| `readme`      | string   | no       | Path to README rendered on registry. Defaults to `README.md` if present. |
| `keywords`    | string[] | no       | Up to 8 short, kebab-case keywords for registry search.                  |
| `categories`  | string[] | no       | Up to 5; closed vocabulary published by the registry.                    |

### Code shape

| Field   | Type   | Default                                                                       | Notes                                                          |
|---------|--------|-------------------------------------------------------------------------------|----------------------------------------------------------------|
| `type`  | enum   | inferred from `entry`                                                         | One of `"library"`, `"application"`, `"workspace"`.            |
| `entry` | string | `src/lib.q` for libraries, `src/main.q` for applications                      | Path to the main `.q` source file.                             |
| `build` | string | none                                                                          | Optional path to `build.q` for computed configuration.         |

Static configuration lives in `qube.json5`; `build.q` is the imperative escape
hatch for projects that need to compute target configuration at build time.

### Dependencies

Three sibling maps:

| Field                  | Purpose                                                          |
|------------------------|------------------------------------------------------------------|
| `dependencies`         | Required at runtime by this qube.                                |
| `dev-dependencies`     | Required for `qube test` / local dev, not shipped to consumers.  |
| `build-dependencies`   | Required by `build.q` if present; not shipped, not test-time.    |

Each map is `{ "qube-name": VersionSpec }`. A `VersionSpec` is either a
**string** (semver range) or an **object**:

```json5
// String form — semver range
{ "audio-utils": "^0.4.2" }

// Object form
{
  "audio-utils": {
    version:  "^0.4.2",        // omit when 'path' or 'git' is set
    registry: "https://...",   // optional; override default registry
    path:     "../audio-utils", // local path (mutually exclusive with version/git)
    git:      "https://...",   // git source (mutually exclusive with version/path)
    branch:   "main",
    tag:      "v0.4.2",
    rev:      "abc123…",
    features: ["fft", "mp3"],  // feature flags on the dependency
    "default-features": true,  // default true; set false to skip defaults
    optional: false,           // default false
  }
}
```

`features` and `optional` mirror Cargo's model. Exactly one of `version`,
`path`, or `git` must be set in the object form.

### Workspace

When `type` is `"workspace"`, the manifest binds multiple member qubes:

```json5
{
  $schema: "https://q64.dev/schema/qube.json5",
  name:    "stdlib",
  version: "0.0.0",
  license: "MIT OR Apache-2.0",
  type:    "workspace",
  workspace: {
    members: ["math", "anim", "ai", "net", "audio", "gfx", "video", "fs"],
    // exclude: ["scratch", "experimental"]
  },
}
```

`members` accepts glob patterns. `qube build` from a workspace root walks
all members; from inside a member it builds just that qube.

### Targets

```json5
targets: {
  "<name>": {
    host:         "browser" | "wasmtime" | "wasmer" | "audio-host" | "custom",
    addressSpace: "wasm32" | "wasm64",       // REQUIRED — no default (see below)
    optimize:     "debug" | "size" | "speed",   // default "speed"
    wasm: {
      // memory64 / table64 are NOT free toggles: they follow `addressSpace`
      // (wasm64 ⇒ on, wasm32 ⇒ off). Listing them is redundant; contradicting
      // `addressSpace` (e.g. memory64: true under wasm32) is an error.
      "multi-memory":    true,
      gc:                true,
      threads:           true,
      "stack-switching": true,
      simd:              true,
    },
    // Host-specific blocks (only the matching one is used):
    browser: {
      coop: "same-origin",            // default
      coep: "require-corp",           // default
      "dev-server-port": 5173,
    },
    wasmtime: { wasi: "preview3" },   // default "preview3" (WASIp3 RC); "preview1" for legacy core-module hosts
    wasmer:   { wasi: "preview3" },   // or "preview1" (legacy core module), "wasix"
    "audio-host": {
      formats: ["vst3", "au", "aax", "clap"],
    },
  }
}
```

Every target **must** set `addressSpace` — there is no default. It selects
the linear-memory address space the build is compiled for:

- **`wasm32`** — 32-bit linear memory (`i32` pointers, ≤ 4 GiB). The
  universal baseline; the only address space Apple WebKit (Safari and every
  iPad/iOS browser) runs as of 2026, and the **safe fallback** a deploy host
  serves when it can't confirm 64-bit support.
- **`wasm64`** — 64-bit linear memory (Memory64 + Table64, `i64` pointers).
  Unlocks > 4 GiB but does **not** run on WebKit.

`qube build` errors (with a diagnostic, see [`qube-cli.md`](./qube-cli.md)) if
the selected target has no `addressSpace`, or if `--addr` is also absent. To
ship a qube that runs everywhere *and* exploits 64-bit where available,
declare two targets (one per address space) and publish **both** artifacts —
the deploy host then probes the client and serves the match, falling back to
`wasm32`. On qubepods this is the QubePod manifest's `component.variants` map.
See [`memory.md` §"The platform"](./memory.md) for the full rationale.

The other `wasm.*` flags are Wasm 3.0 feature toggles that default to `true`.
Setting one `false` is an explicit narrowing — `qube build` errors if any
source uses a disabled feature. `memory64` and `table64` are **not** set here
directly; they follow `addressSpace`.

User-defined target names are kebab-case (`browser`, `desktop`, `plugin`,
`edge-worker`, etc.) — the name is just a label; `host` and `addressSpace`
decide everything.

### Effects

```json5
effects: {
  declared: ["@io", "@network"],
  deny:     ["@unrestricted_fs"],
}
```

| Field      | Purpose                                                                                    |
|------------|--------------------------------------------------------------------------------------------|
| `declared` | Effects this qube is allowed to use. The compiler verifies that source matches this set; declaring `@network` here while using only `@io` is a warning. |
| `deny`     | Effects this qube refuses to transitively pull in. Build fails if any dependency requires a denied effect. |

Core effect markers (per [`effects.md`](./effects.md), with
`@cancel` / `@uncancellable` per [`concurrency.md`](./concurrency.md)):

| Marker         | Meaning                                                       |
|----------------|---------------------------------------------------------------|
| `@realtime`    | Bounded execution, no alloc, no blocking, no suspending.      |
| `@no_alloc`    | No heap allocation (linear or managed).                       |
| `@no_suspend`  | Cannot yield to the scheduler.                                |
| `@no_panic`    | Does not invoke `panic`.                                      |
| `@no_trap`     | Does not invoke `trap`.                                       |
| `@send`        | Safe to transfer across thread boundaries.                    |
| `@pure`        | No mutation, no observable side effects.                      |
| `@io`          | Performs I/O.                                                 |
| `@network`     | Performs network operations. Implies `@io`.                   |
| `@fs`          | Performs filesystem operations. Implies `@io`.                |
| `@stdout`      | Writes to stdout. Implies `@io`.                              |
| `@stderr`      | Writes to stderr. Implies `@io`.                              |
| `@audio`       | Performs audio I/O.                                           |
| `@midi`        | Performs MIDI I/O.                                            |
| `@ui`          | Reads UI input events; writes frames.                         |
| `@inference`   | Performs AI model load or inference.                          |
| `@time`        | Reads clock time.                                             |
| `@random`      | Reads from the system RNG.                                    |
| `@exit`        | Terminates the program via `env.exit(…)`.                     |
| `@envvars`     | Reads process environment variables.                          |
| `@wire`        | Performs a remote (RPC) call. Implies `@io`. (Per `rpc.md`.)  |
| `@cancel`      | Function observes `ctx.cancelled()`. (Per `concurrency.md`.) |
| `@uncancellable`| Function cannot be interrupted by cancellation.              |

User-defined effects follow the same shape (`^@[a-z][a-z_]*$`). The
registry surfaces the union of declared effects per qube as part of the
capability disclosure UI.

### Capabilities

```json5
capabilities: ["Net", "Fs", "Stdout"]
```

The `capabilities` field is **generated, not authored**. It is the
human-readable summary of which runtime capabilities (per
[`env.md`](./env.md)) this qube reaches — but its content is owned
by the compiler, not the developer: `qube publish` derives the set
(via `q64 show capabilities`, the effect graph's capability
closure) and **rewrites the field in place** before packing, the
way `qube add` maintains `dependencies`. A missing field is added;
a stale hand-edited one is corrected (and the sync is reported);
an in-sync manifest is untouched. Hand-editing the field is
therefore harmless but pointless — the next publish restores the
derived truth.

The two records exist because they serve different audiences:

- The **manifest field** is human-readable and visible at the top
  of the file; reviewers and registry users see it immediately.
- The **compiler-derived set** is emitted into a Wasm custom
  section (`q64.capabilities`) and is the ground truth used by
  the registry's installation prompt.

The mapping from effect markers to capability names (per
`env.md` §"Capability disclosure") is 1:1 — every capability
reachable through `Env` is gated by exactly one effect marker:

| Effect       | Implies capability   |
|--------------|----------------------|
| `@network`   | `Net`                |
| `@fs`        | `Fs`                 |
| `@kv`        | `KeyValue`           |
| `@audio`     | `Audio`              |
| `@midi`      | `Midi`               |
| `@ui`        | `Ui`                 |
| `@inference` | `AiEnv`              |
| `@time`      | `Clock`              |
| `@random`    | `Rng`                |
| `@stdout`    | `Stdout`             |
| `@stderr`    | `Stderr`             |
| `@exit`      | `ExitFn`             |
| `@envvars`   | `EnvVars`            |

Capability names are PascalCase (matching the face names in
`env.md`), sorted, deduplicated.

The registry **cross-checks anyway**: an uploaded manifest whose
`capabilities` omit a detected capability is `ENV040`, an
extraneous entry is `ENV041` (per
[`continuum-api.md`](./continuum-api.md) §"Write — publish").
Because the toolchain generates the field, these codes act as a
backstop — they fire only for an upload produced by a stale or
non-toolchain client, never for an ordinary `qube publish`.

User-defined capabilities (introduced by `fit MyAdapter : Net`
or by user-defined effect markers) are listed by the
PascalCase name of the underlying face.

### Component

Opt-in WebAssembly Component Model emission. The default build produces a
**core module**; this block requests an additional **component** wrapper
(per [`modules.md` §"The qube as a component"](./modules.md) and
[`README.md` §"Wasm 3.0 is the platform"](./README.md)).

```json5
component: {
  emit:   false,        // default — primary artifact stays a core module
  world:  "my-app",     // synthesized world name; default = qube name
  worlds: [],           // additional WIT worlds to target, e.g. "wasi:http/proxy"
  // WASI version is not pinned here; it tracks targets.<name>.wasmtime.wasi
  // (default "preview3" — the WASIp3 RC snapshot q64 tracks, per env.md).
}
```

| Field    | Type     | Default       | Notes                                                             |
|----------|----------|---------------|-------------------------------------------------------------------|
| `emit`   | bool     | `false`       | When `true`, `qube build` also emits `target/<host>/<name>.component.wasm` alongside the core module. The core module remains the primary artifact. |
| `world`  | string   | qube name     | Name of the synthesized WIT world (exports = public surface, imports = derived capability set). |
| `worlds` | string[] | `[]`          | Additional standard worlds the component targets, e.g. `"wasi:cli/command"`, `"wasi:http/proxy"`. |

Equivalent to `component.emit: true` for a one-off build:
`qube build --component` (which delegates to `q64 build --component`).

An HTTP-serving qube (per [`env.md` §"HTTP service entry point"](./env.md))
opts in with:

```json5
component: { emit: true, world: "my-api", worlds: ["wasi:http/proxy"] }
```

This makes the qube a drop-in **qubepods** endpoint runnable under generic
Component Model HTTP lifting, with no qubepods-specific ABI.

### WIT (the published contract)

A **library qube**'s published surface *is* its WIT world — the contract
consumers resolve and link against (per [`modules.md` §"The qube as a
component"](./modules.md)). The `wit` block names that contract; it is what
the Continuum stores/serves and what `wac` links against.

```json5
wit: {
  package: "dev-q64:math",  // WIT package id; default derived from `name`
  world:   "math",          // world name; default = last segment of `name`
  path:    "synthesized",   // "synthesized" (q64 generates) | relative .wit path
  imports: [],              // foreign .wit packages this qube imports (rung 5)
  interface: "math",        // export the surface as <package>/<interface>
}
```

| Field       | Type     | Default                | Notes                                                                                          |
|-------------|----------|------------------------|------------------------------------------------------------------------------------------------|
| `package`   | string   | derived from `name`    | WIT package id `namespace:name`. Default maps the dotted qube `name` — namespace = the prefix with `.`→`-`, package = the last segment (`dev.q64.math` → `dev-q64:math`). |
| `world`     | string   | last segment of `name` | The synthesized world's name (`dev.q64.math` → `math`). `qube build --component` passes it to `q64 emit --world`, so the emitted `<name>.wit` matches the manifest rather than the entry filename. |
| `path`      | string   | `"synthesized"`        | `"synthesized"` — q64 generates the world from source at build (the design rule: a qube's **own** world is synthesized, not authored, see [`modules.md`](./modules.md)). A relative path names a checked-in `.wit` to publish instead — **reserved**, not yet consumed. |
| `imports`   | string[] | `[]`                   | Foreign `.wit` packages this qube **imports** (WIT rung 5, the consume direction). Each relative path is parsed and its scalar-signature interfaces are declared in the emitted component's world (what `wac` links at build); `qube build --component` passes them to `q64 emit --wit-import`. |
| `interface` | string   | *(none)*               | Export this **library**'s surface as the named WIT interface `<package>/<interface>` (e.g. `acme:mathlib/math`) instead of bare top-level functions. `qube build --component` passes it to `q64 emit --export-interface`. So a consumer qube that lists this interface in its `imports` can be `wac`-linked against this provider — the q64↔q64 link. Omit for bare-function exports. |

The world name resolves `wit.world` → `component.world` → last segment of
`name`; the package resolves `wit.package` → derived from `name`. `wit.world`
is preferred over the legacy `component.world` for a library's contract.
Component-model labels are kebab-case, so q64 kebab-cases the world name and
every export/parameter when it synthesizes the `.wit`.

### RPC

Qube-to-qube remote calls over the synthesized world (full semantics in
[`rpc.md`](./rpc.md)). Requires `component.emit: true` — RPC rides the
component's WIT world.

```json5
rpc: {
  export: true,                          // expose this qube's world as a wRPC service
  import: {                              // remote qubes this qube calls
    "billing": "wrpc://billing.example.com",
  },
}
```

| Field    | Type            | Default | Notes                                                                       |
|----------|-----------------|---------|-----------------------------------------------------------------------------|
| `export` | bool            | `false` | When `true`, the component's exports are served over wRPC by the host adapter. |
| `import` | { name: addr }  | `{}`    | Maps a remote qube's local binding name to its wRPC address (a qubepods endpoint or continuum-resolved address). Calls into an imported remote function carry the `@wire` effect. |

A remote address may be a literal `wrpc://…` URL or a continuum-registered
qube name resolved at build/deploy time (see
[`continuum-api.md`](./continuum-api.md)). Importing a remote qube adds
`@wire` to the caller's effect set and the remote world to the component's
imports, so the dependency is disclosed in `qube audit` like any capability.

### Publishing

| Field      | Type     | Default                                       | Notes                                                                  |
|------------|----------|-----------------------------------------------|------------------------------------------------------------------------|
| `publish`  | boolean  | `true`                                        | Set `false` to prevent `qube publish` from ever uploading.             |
| `registry` | URL      | continuum production URL                      | Override per-qube (private or alternate registries).                   |
| `include`  | string[] | omitted ⇒ default file set (see below)        | Globs **added to** the default set; never replaces it.                 |
| `exclude`  | string[] | none                                          | Globs excluded; applied after include resolution. May drop defaults.   |

The default archive file set (when `include` is omitted) is
specified in [`continuum-api.md` §Archive format](./continuum-api.md):
`qube.json5`, `src/**`, `tests/**`, `examples/**` (and a top-level
`example/`), the README, and `LICENSE-*` files at the root. Examples
ship so an installed qube carries runnable usage guidance for humans
and coding agents. `include` adds files on top; it does not replace
the default. To drop a default file, use `exclude`.

## Versioning policy for the schema

The schema itself follows semver, surfaced as the path of the `$schema`
URL: `https://q64.dev/schema/qube.json5` is the latest minor release of
the current major version. A breaking change moves the schema to a new
URL (`/schema/v2/qube.json5`), and the `qube` CLI accepts both for one
major version's grace period.

While the language is pre-1.0, the schema is also pre-1.0 — fields can be
added, removed, or renamed between minor releases. Pin schema and CLI
versions together until 1.0.

## Related

- [`effects.md`](./effects.md) — the formal effect-marker registry;
  `effects.declared` and `effects.deny` semantics; the cross-check that
  produces `EFF130` / `EFF131` at publish.
- [`env.md`](./env.md) — capability model, the `qube publish` sync
  for the `capabilities` field, and the `ENV040` / `ENV041`
  registry backstop.
- [`concurrency.md`](./concurrency.md) — `@cancel` / `@uncancellable`
  semantics and the M:N task model that `@realtime` pins on.
- [`continuum-api.md`](./continuum-api.md) — how the registry
  surfaces declared + detected effects and capabilities at
  install.
- [`q64-cli.md`](./q64-cli.md) — `q64 show effects <qube>` and
  `q64 show capabilities <qube>` introspection.
- The built-in `q64.*` stdlib namespaces (`q64.math`, `q64.net`, etc.)
  are reserved and shipped with the toolchain, so they never appear in
  `dependencies`.
