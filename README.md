# q64

A stream-first language for Wasm 3.0, with managed and unmanaged memory as
first-class peers.

This repository is the q64 implementation monorepo. The language design
discussion that preceded the spec is archived in
[`docs/history/`](./docs/history); the
[`q64-lang/design`](https://github.com/q64-lang/design) repo is a tombstone
pointing here.

> **Status: pre-alpha.** Folders are scaffolded; most are not yet implemented.

## Layout

| Folder         | Purpose                                                                                       |
|----------------|-----------------------------------------------------------------------------------------------|
| [`continuum/`](./continuum) | Qube registry server (Cloudflare Workers; hosts qubes published from `qube publish`) |
| [`docs/`](./docs)           | Language reference and tutorials (source; rendered by `web/`)                        |
| [`examples/`](./examples)   | Sample qubes (voice-agent, audio DSP, 3D demo)                                       |
| [`mcp/`](./mcp)             | MCP server exposing the q64 toolchain to AI agents (Bun/TypeScript)                  |
| [`q64/`](./q64)             | Zig project → `q64` binary — the language tool (`fmt`, `lsp`, `show`, single-file)   |
| [`qube/`](./qube)           | Zig project → `qube` binary — the package and build tool                             |
| [`runtime/`](./runtime)     | Host adapters: `browser/`, `wasmtime/`, `wasmer/`, `audio-host/`                     |
| [`spec/`](./spec)           | Formal language spec and conformance tests                                           |
| [`stdlib/`](./stdlib)       | q64 standard library workspace (`math`, `anim`, `ai`, `net`, `audio`, `gfx`, `video`, `fs`) |
| [`web/`](./web)             | q64.dev site, registry UI, browser playground (Astro + Starlight; Cloudflare Pages)  |

## Vocabulary

- **qube** — the unit of distribution. A qube is what you publish, depend on, and
  import. It is described by a `qube.json5` manifest at its root.
- **continuum** — the qube registry. Where all qubes exist.
- **q64** — the language binary; operates on q64 source files.
- **qube** *(the binary)* — the package and build tool; operates on qube projects.

The CLI split mirrors `rustc` + `cargo`: `qube build` invokes `q64` internally,
the same way `cargo build` invokes `rustc`.

## Implementation languages

- **`q64/` and `qube/`** — written in **Zig**. Zig was chosen for: clean
  Binaryen C-API interop (the Wasm 3.0 emission path), excellent
  cross-compilation, tiny static binaries with no LLVM dependency, and
  cultural alignment with q64's comptime / explicit-allocator design.
- **`stdlib/`** — written in **q64** itself, compiled by the `q64` binary. The
  numeric primitives `Simd`, `Tensor`, and `DynTensor` are baked into the
  compiler as builtin types.
- **`runtime/<host>/`** — written in the **host's native language** (Zig for
  Wasmtime/Wasmer/audio-host adapters; TypeScript for the browser adapter).
- **`continuum/`** — **TypeScript** on Cloudflare Workers, using D1, R2, and
  KV.
- **`mcp/`** — **TypeScript on Bun**. Thin shim that re-exposes `q64`, `qube`,
  and `continuum` surfaces as MCP tools for AI agents (`q64.show.*`,
  `qube.audit`, `continuum.search`, etc.). Adds no new contracts —
  wraps the existing CLI flags and HTTP endpoints.
- **`web/`** — **Astro + Starlight**. Starlight runs the docs; marketing
  pages are plain Astro routes; the playground and registry UI are Astro
  islands. The playground loads a wasm build of `q64/` to compile q64 source
  in the browser.

## Building

To be written. The bootstrap order:

1. Build `q64/` with `zig build` → produces the `q64` binary.
2. Build `qube/` with `zig build` → produces the `qube` binary.
3. From the repo root, `qube build` walks `stdlib/` and compiles each
   namespace qube to wasm.
4. `cd web && pnpm install && pnpm dev` runs the site locally; the
   playground picks up the wasm build of `q64/` from `web/public/`.

## License

Dual-licensed under either of

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
- MIT license ([LICENSE-MIT](LICENSE-MIT))

at your option.

### Contribution

Unless you explicitly state otherwise, any contribution intentionally
submitted for inclusion in q64 by you, as defined in the Apache-2.0 license,
shall be dual licensed as above, without any additional terms or conditions.
