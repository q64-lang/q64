# q64/vendor

Vendored external dependencies of the `q64` Zig project.

> **Status: not yet populated.**

## Planned contents

| Folder       | Source                                                   |
|--------------|----------------------------------------------------------|
| `binaryen/`  | The Binaryen C API. Wasm 3.0 emission backend used by `../src/codegen/`. |

## How it gets here

Two acceptable mechanisms; pick per dependency:

1. **`build.zig.zon` dependency** — modern Zig package manager;
   resolves to a content-addressed download at build time. Preferred
   when upstream publishes a tarball.
2. **Git submodule** — for dependencies whose upstream is git-only or
   whose build needs an in-tree checkout.

Binaryen: currently leaning toward `build.zig.zon` since the project
publishes tagged releases. Final choice is tracked in the plan
file's open items.
