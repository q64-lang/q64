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

  // Dependencies
  dependencies: {
    "q64/audio": "^0.3",
    "q64/ai":    "^0.3",
    "q64/net":   "^0.3",
    "whisper":   { version: "^1.0", features: ["en"] },
    "local-llm": { path: "../llm" },
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

  // Capability disclosure (cross-checked at publish; see env.md ENV040)
  capabilities: ["Net", "Audio", "Stdout"],
}
```

## Field reference

### Identity

| Field         | Type     | Required | Notes                                                                    |
|---------------|----------|----------|--------------------------------------------------------------------------|
| `$schema`     | string   | no       | Schema URL. Recommended at the top of every manifest.                    |
| `name`        | string   | **yes**  | Kebab-case. Optionally namespaced as `org/qube`. Max 64 chars.           |
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

Per [`docs/history/design.md` §"Manifest"](../docs/history/design.md):
static configuration lives in `qube.json5`; `build.q` is the imperative escape
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
    host:     "browser" | "wasmtime" | "wasmer" | "audio-host" | "custom",
    optimize: "debug" | "size" | "speed",   // default "speed"
    wasm: {
      memory64:       true,
      "multi-memory": true,
      table64:        true,
      gc:             true,
      threads:        true,
      "stack-switching": true,
      simd:           true,
    },
    // Host-specific blocks (only the matching one is used):
    browser: {
      coop: "same-origin",            // default
      coep: "require-corp",           // default
      "dev-server-port": 5173,
    },
    wasmtime: { wasi: "preview2" },   // default "preview2"
    wasmer:   { wasi: "preview2" },   // or "preview1", "wasix"
    "audio-host": {
      formats: ["vst3", "au", "aax", "clap"],
    },
  }
}
```

The `wasm.*` flags are Wasm 3.0 feature toggles. All default to `true`
(matching the design's "Wasm 3.0 in 64-bit mode, full feature set assumed"
commitment). Setting any of them `false` is an explicit narrowing — `qube
build` errors out if any source uses the disabled feature.

User-defined target names are kebab-case (`browser`, `desktop`, `plugin`,
`edge-worker`, etc.) — the name is just a label; `host` decides everything.

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
| `@cancel`      | Function observes `ctx.cancelled()`. (Per `concurrency.md`.) |
| `@uncancellable`| Function cannot be interrupted by cancellation.              |

User-defined effects follow the same shape (`^@[a-z][a-z_]*$`). The
registry surfaces the union of declared effects per qube as part of the
capability disclosure UI.

### Capabilities

```json5
capabilities: ["Net", "Fs", "Stdout"]
```

The `capabilities` field is the developer-asserted summary of
which runtime capabilities (per [`env.md`](./env.md)) this qube
reaches. It is **cross-checked** at `qube publish` against the
compiler-derived set computed from the effect graph; mismatch is
`ENV040` and blocks publication.

The two records exist because they serve different audiences:

- The **manifest declaration** is human-readable and visible at
  the top of the file; reviewers and registry users see it
  immediately.
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
`env.md`). Listing a capability not used by the source is
`ENV041` at publish (warning). Listing a capability the source
*does* use, and one it *doesn't*, both raise — `ENV040` for the
missing entry, `ENV041` for the extraneous one — so the developer
gets one clean fix on each publish attempt.

User-defined capabilities (introduced by `fit MyAdapter : Net`
or by user-defined effect markers) are listed by the
PascalCase name of the underlying face.

### Publishing

| Field      | Type     | Default                                       | Notes                                                                  |
|------------|----------|-----------------------------------------------|------------------------------------------------------------------------|
| `publish`  | boolean  | `true`                                        | Set `false` to prevent `qube publish` from ever uploading.             |
| `registry` | URL      | continuum production URL                      | Override per-qube (private or alternate registries).                   |
| `include`  | string[] | omitted ⇒ default file set (see below)        | Globs **added to** the default set; never replaces it.                 |
| `exclude`  | string[] | none                                          | Globs excluded; applied after include resolution. May drop defaults.   |

The default tarball file set (when `include` is omitted) is
specified in [`continuum-api.md` §Tarball format](./continuum-api.md):
`qube.json5`, `src/**`, `tests/**`, the README, and
`LICENSE-*` files at the root. `include` adds files on top; it
does not replace the default. To drop a default file, use
`exclude`.

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
- [`env.md`](./env.md) — capability model and the `ENV040` /
  `ENV041` publish cross-checks for the `capabilities` field.
- [`concurrency.md`](./concurrency.md) — `@cancel` / `@uncancellable`
  semantics and the M:N task model that `@realtime` pins on.
- [`continuum-api.md`](./continuum-api.md) — how the registry
  surfaces declared + detected effects and capabilities at
  install.
- [`q64-cli.md`](./q64-cli.md) — `q64 show effects <qube>` and
  `q64 show capabilities <qube>` introspection.
- [`docs/history/design.md`](../docs/history/design.md) — original
  pre-spec design discussion (archived).
- [`docs/history/stdlib.md`](../docs/history/stdlib.md) — stdlib
  namespaces that show up in `dependencies` (`q64/math`,
  `q64/audio`, etc.).
