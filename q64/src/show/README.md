# q64/src/show

The `q64 show` introspection subcommand family.

> **Status: not yet implemented.**

## Scope

**Owns:** the implementation of every `q64 show <kind> <arg>` form.

| Form                       | Output                                                   |
|----------------------------|----------------------------------------------------------|
| `q64 show types <expr>`    | Inferred type of `<expr>`                                |
| `q64 show effects <fn>`    | Effect set of `<fn>`                                     |
| `q64 show regions <fn>`    | Regions `<fn>` uses or borrows from                      |
| `q64 show graph <stage>`   | Stream-graph topology rooted at `<stage>`                |
| `q64 show layout <type>`   | Memory layout of `<type>`                                |
| `q64 show send <type>`     | `@send`-derivation explanation                           |
| `q64 show memories`        | Wasm memory declarations the program produces            |

**Does not own:**
- The analyses themselves — `typeck/`, `region/`, `effect/`, `codegen/`
  produce the data. `show/` is the presentation layer.

## Inputs / outputs

- **In:** source file(s) + the expression / function / stage / type
  named on the command line. Loads modules per `--module` flags.
- **Out:** formatted text on stdout (default) or JSON on stdout with
  `--diagnostics json`. Diagnostics on stderr per the standard
  envelope.

## External

None. Pure Zig.

## Notes

The `show` surface is the data backing agent and editor introspection
— any tool that asks "what's the type of this expression" or
"what does this graph look like" goes through `q64 show` rather than
reimplementing inference.
