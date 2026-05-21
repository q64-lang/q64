# `q64` CLI — language tool reference

The CLI surface of the `q64` binary. `q64` operates on q64 *source* —
single files, the language server, formatting, introspection. Project-
level operations live in [`qube`](./qube-cli.md), which invokes `q64`
internally per source file.

> **Status: draft (v0).**

## Synopsis

```
q64 <subcommand> [options] [args...]
q64 <file.q> [args...]            # implicit run
q64 --version | -v
q64 --help    | -h
```

If the first positional argument ends in `.q` and is not a known
subcommand, it is treated as `q64 run <file>`.

## Subcommands

| Subcommand              | Purpose                                                       |
|-------------------------|---------------------------------------------------------------|
| `q64 run <file>`        | Compile to wasm in memory and run                             |
| `q64 build <file>`      | Compile to wasm; emit `<file>.wasm` (or `--out` path)         |
| `q64 fmt [path]`        | Format source in-place (file or directory); add `--stdout` to print to stdout instead and read from stdin when `path` is omitted |
| `q64 lsp`               | Run the language server (stdin/stdout LSP)                    |
| `q64 show <kind> <arg>` | Introspection (see below)                                     |
| `q64 explain <code>`    | Print structured documentation for a diagnostic code          |
| `q64 repl`              | Interactive REPL (eventual; not in v0)                        |

### `q64 show` kinds

| Form                       | Output                                                   |
|----------------------------|----------------------------------------------------------|
| `q64 show types <expr>`    | Inferred type of `<expr>`                                |
| `q64 show effects <fn>`    | Effect set of `<fn>`                                     |
| `q64 show regions <fn>`    | Regions `<fn>` uses or borrows from                      |
| `q64 show graph <stage>`   | Stream-graph topology rooted at `<stage>`                |
| `q64 show layout <type>`   | Memory layout of `<type>`                                |
| `q64 show send <type>`     | `@send`-derivation explanation                           |
| `q64 show memories`        | Wasm memory declarations the program produces            |

Each form takes additional `--qube <path>` or `--module <name>=<path>`
flags as needed (see "Global options").

### `q64 fmt` options

| Flag        | Meaning                                                                          |
|-------------|----------------------------------------------------------------------------------|
| `--stdout`  | Read source from stdin (when `path` is omitted) or from `path`, write the formatted result to stdout. Leaves the input file untouched. Used by the MCP server and editors that own the file's on-disk state. |
| `--lint`    | Report formatting issues as diagnostics on stderr; do not modify files.          |
| `--check`   | Exit `64` if any file would be reformatted; do not modify files.                 |

## Global options

| Flag                              | Meaning                                                                   |
|-----------------------------------|---------------------------------------------------------------------------|
| `--diagnostics <text\|json>`      | Diagnostic format. Default `text` interactive, `json` when stdout is not a TTY or when run by `qube`. |
| `--out <path>`                    | Output path for `build` (defaults to `<input>.wasm`)                      |
| `--target <name>`                 | Target name to compile for (resolves via the qube manifest if present)    |
| `--module <name>=<path>`          | Map a module name to a source directory. Repeatable. Set by `qube`.       |
| `--no-color`                      | Disable ANSI color in text diagnostics                                    |
| `--quiet` / `-q`                  | Suppress non-error output                                                 |
| `--verbose` / `-v`                | Verbose logging to stderr                                                 |
| `--version`                       | Print the version and exit                                                |
| `--help`                          | Print help and exit                                                       |

`--module` is the bridge between `qube`'s dependency resolver and the
compiler. `qube build` invokes:

```
q64 build src/main.q
  --module q64.math=/home/user/.qube/cache/q64-math-0.3.1/src
  --module q64.audio=/home/user/.qube/cache/q64-audio-0.3.0/src
  --module q64.net=/home/user/.qube/cache/q64-net-0.3.4/src
  --diagnostics json
  --out target/main.wasm
```

The compiler resolves `import q64.math` against the supplied map; it
never reads `qube.json5` itself.

## Stdin / stdout / stderr conventions

| Channel | When running a program             | When `lsp`                      | Otherwise                       |
|---------|------------------------------------|---------------------------------|---------------------------------|
| stdin   | Forwarded to the program's `env.in`| LSP wire protocol               | Unused                          |
| stdout  | Program's `env.out`                | LSP wire protocol               | Subcommand-specific (e.g. `show` prints to stdout) |
| stderr  | Diagnostics + `env.err` from program | LSP traces                    | Diagnostics                     |

Diagnostics on stderr are always whole-envelope JSON when
`--diagnostics json`. The diagnostic envelope is documented in
[`diagnostics.md`](./diagnostics.md). Programs piping to other commands
(`q64 script.q | grep foo`) stay clean: diagnostics never pollute
stdout.

## Exit codes

| Exit  | Meaning                                                          |
|-------|------------------------------------------------------------------|
| `0`   | Success                                                          |
| `1`   | Program panicked (`panic!(...)` in user code)                    |
| `2`   | Usage error (bad flags, missing args)                            |
| `64`  | Compile error (any `error`-severity diagnostic)                  |
| `65`  | Input error (file not found, unreadable)                         |
| `70`  | Internal compiler error (ICE); diagnostic is in the `Q9xxx` band |
| `N`   | Program called `env.exit(N)` with `N > 0`                        |

Conventions match sysexits where possible. Subprocess callers (`qube`)
distinguish "user error" (`64`) from "ICE" (`70`) so they can choose
whether to retry, report, or surface to the human.

## Subprocess invocation contract

The `qube` binary invokes `q64` per source file. Stable contract for that
boundary:

1. **Always pass `--diagnostics json`.** Text rendering is `qube`'s job.
2. **Always pass `--module` for every dependency.** `q64` does no
   dependency discovery itself.
3. **Parse the entire stderr stream as one or more JSON envelopes.**
   Each envelope is a single line of JSON terminated by `\n`
   (newline-delimited JSON), so streaming parsers can read them
   incrementally.
4. **Treat exit code `70` as "do not retry, report upstream."** Surface
   the embedded `report_url` to the user.
5. **Do not interpret stdout when `--diagnostics json` is set on
   `build`** — it carries only the program's output if `run` was
   invoked. Build mode writes the wasm artifact to `--out` and produces
   no stdout.

## `q64 explain <code>`

Returns structured documentation for any diagnostic code emitted by
the toolchain — `NAM*`, `TYP*`, `REG*`, `EFF*`, `FMT*`, `LSP*`,
`Q9xxx`, etc.

```
$ q64 explain TYP041 --diagnostics json
{
  "code": "TYP041",
  "subsystem": "Type checking",
  "title": "Numeric type mismatch",
  "summary": "An expression of one numeric type was used where a different numeric type was expected. q64 has no implicit numeric coercions.",
  "examples": [
    {
      "wrong":   "let x: i64 = compute(); let y: f64 = x;",
      "right":   "let x: i64 = compute(); let y: f64 = f64(x);"
    }
  ],
  "see_also": ["TYP040", "TYP042"],
  "url": "https://q64.dev/diagnostics/TYP041"
}
```

Without `--diagnostics json`, renders to readable text on stdout. Useful
for AI agents asking *"what does this error code mean and how do I
fix it?"* without scraping prose documentation. Mirrors Vercel Zero's
`zero explain <code>` precedent.

The data backing each code is generated from the per-spec diagnostic
tables (`spec/modules.md`, `spec/faces.md`, `spec/errors.md`, …) at
compiler build time; the registry is part of the compiler binary.

## LSP

`q64 lsp` speaks LSP 3.17 on stdin/stdout. Logging and progress
notifications go to stderr (also as LSP).

Supported requests in v0:
- `textDocument/diagnostic` (using the diagnostic envelope mapped to LSP
  `Diagnostic[]`)
- `textDocument/hover`
- `textDocument/definition`
- `textDocument/formatting` (delegates to `q64 fmt`)
- `textDocument/codeAction` (surfaces `repair` objects as LSP actions)

Eventual: completion, references, rename, semantic tokens, inlay hints.
