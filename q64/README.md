# q64

The Zig project that produces the `q64` binary — the q64 **language tool**.

> **Status: not yet implemented.** The `build.zig`, source tree, and
> Binaryen vendor will land in a follow-up commit.

## Scope

`q64` operates on q64 *source* (single files, language-server requests).
Project-level operations (dependencies, builds, publishing) belong to the
[`qube`](../qube) binary.

Planned subcommands:

| Subcommand              | Purpose                                                       |
|-------------------------|---------------------------------------------------------------|
| `q64 file.q`            | Compile-and-run a single source file                          |
| `q64 fmt [path]`        | Format q64 source                                             |
| `q64 lsp`               | Run the language server (stdin/stdout LSP)                    |
| `q64 show types <expr>` | Print inferred types                                          |
| `q64 show effects <fn>` | Print the effect set of a function                            |
| `q64 show regions <fn>` | Print the regions a function uses or borrows from             |
| `q64 show graph <stage>`| Print the dataflow graph for a stream stage                   |
| `q64 repl`              | Interactive REPL (eventual)                                   |

## Planned structure

```
q64/
  build.zig
  build.zig.zon
  src/
    main.zig            # CLI entry + subcommand dispatch
    parser/             # source → AST
    typeck/             # type inference and checking
    region/             # region tracking and lifetime checking
    effect/             # effect inference and propagation
    codegen/            # AST → Wasm 3.0 (via Binaryen)
    fmt/                # formatter
    lsp/                # language server
    show/               # introspection commands
  vendor/
    binaryen/           # Binaryen C API (submodule or zon dep)
```

## Implementation language

Zig. Reasons:

- Binaryen C API drops in cleanly via Zig's C interop.
- Cross-compilation is Zig's headline strength — one host builds `q64` for
  linux/mac/windows/wasi.
- Tiny static binaries, no LLVM dependency, no runtime.
- Cultural alignment: Zig's comptime and explicit-allocator culture are
  exactly the patterns q64 borrows from
  [`design/influences.md`](https://github.com/q64-lang/design/blob/main/influences.md).

## Output

`zig-out/bin/q64`.
