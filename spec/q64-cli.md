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
| `q64 build <file>`      | Compile to wasm; emit `<file>.wasm` (or `--out` path). Requires an address space via `--addr` or a `--target` (no default). |
| `q64 fmt [path]`        | Format source in-place (file or directory); add `--stdout` to print to stdout instead and read from stdin when `path` is omitted |
| `q64 lsp`               | Run the language server (stdin/stdout LSP)                    |
| `q64 show <kind> <arg>` | Introspection (see below)                                     |
| `q64 explain <code>`    | Print structured documentation for a diagnostic code          |
| `q64 repl`              | Interactive REPL (eventual; not in v0)                        |

### `q64 show` kinds

| Form                            | Output                                                         |
|---------------------------------|----------------------------------------------------------------|
| `q64 show types <expr>`         | Inferred type of `<expr>`                                      |
| `q64 show effects <fn>`         | Effect set of `<fn>`                                           |
| `q64 show regions <fn>`         | Regions `<fn>` uses or borrows from                            |
| `q64 show alloc <fn>`           | Per-allocation-site region attribution for `<fn>`              |
| `q64 show graph <stage>`        | Stream-graph topology rooted at `<stage>`                      |
| `q64 show layout <type>`        | Memory layout of `<type>`                                      |
| `q64 show send <type>`          | `@send`-derivation explanation                                 |
| `q64 show memories`             | Wasm memory declarations the program produces                  |
| `q64 show modules`              | Module tree: each file's path, header doc, exported names      |
| `q64 show modules --prelude`    | Auto-prelude listing — the set of names reachable without an `import`, including the transitive prelude-face-reachable types (per [`modules.md` §"Reachable through a capability face"](./modules.md)) |
| `q64 show capabilities <qube>`  | Compiler-derived capability set for `<qube>`'s `pub` surface  |
| `q64 show denials <fn>`         | Call-graph reachability into `with_capabilities(deny: …)` blocks |
| `q64 show world <qube>`         | Synthesized WIT world for `<qube>`: exports (public surface) and imports (derived capability set + any imported remote worlds). The component-emission counterpart of `show capabilities`. See [`modules.md` §"The qube as a component"](./modules.md). |
| `q64 show hir <file.q>`         | Text dump of the **HIR** (Semantic QIR) for `<file.q>` — the name-resolved, desugared tier. Takes the same `--module name=dir` flags as `emit`. Compiler-introspection: the dump format is for humans/tests, not a stable serialization. See [`ARCHITECTURE.md` §ir](../ARCHITECTURE.md). |
| `q64 show mir <file.q>`         | Text dump of the **MIR** (Executable QIR) — the ABI-lowered tier a backend consumes (`str` = `(ptr,len)`, structured control flow, the static memory image). Same `--module` flags. Compiler-introspection (unstable format). |

The source qube is given positionally for `hir`/`mir` (`q64 show hir
<file.q>`) and via `--qube <file.q>` for the kinds whose positional argument is
a subject — a function, expression, type, or stage (`q64 show effects main
--qube app.q`). The qube-level kinds (`capabilities`, `world`, `modules`) take
only `--qube <file.q>`. All forms accept the same `--module name=dir` flags as
`emit`.

**Implemented today:** `hir`, `mir`, `effects`, `capabilities`, `world` — the
last three over the effect-annotated HIR (the effect pass infers a function's
capability set; `world` synthesizes the WIT world per [`modules.md` §"The qube
as a component"](./modules.md) and the effect→WIT-import table in
[`effects.md`](./effects.md)). The remaining kinds are specified but not yet
implemented (an unknown/unimplemented kind is a usage error, exit 2).

The `hir` / `mir` kinds run the front of the compile pipeline (parse →
resolve imports → build HIR, then lower for `mir`) and print the result to
stdout; a malformed program surfaces the same honest diagnostic `emit` would
(e.g. `NameNotFound`, `NotConstExpr`) on stderr with a non-zero exit.

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
| `--out <path>`                    | Output path for `build` (defaults to `<input>.wasm`). One output per invocation. |
| `--component`                     | Also wrap the core module in a WebAssembly component (per [`modules.md` §"The qube as a component"](./modules.md)). Writes `<out>.component.wasm` *in addition to* the core `--out` module — the core module is still produced. Set by `qube build --component`. **v0 coverage:** lifts an import-free core module's scalar export surface (`s64`/`bool`/`f64`); and, on `--addr wasm32`, lowers an app's single `env.out` capability import to a component `log: func(string)` (canonical-ABI indirection pattern) with `_start` lifted as `run`. `str`/list exports and the wasm64 import ABI are skipped pending the canonical-ABI memory glue; a wasm64 capability-importing qube errors (`ComponentNeedsImportLowering`). |
| `--target <name>`                 | Target name to compile for (resolves via the qube manifest if present)    |
| `--addr <wasm32\|wasm64>`         | Address space to compile for. **Required** — there is no default: `q64` errors with a diagnostic if neither `--addr` nor a `--target` that fixes an `addressSpace` is given. `wasm32` = 32-bit (`i32` pointers, WebKit/iPad baseline); `wasm64` = 64-bit (Memory64 + Table64, `i64` pointers). See [`memory.md` §"The platform"](./memory.md). |
| `--module <name>=<path>`          | Map a module name to a source directory. Repeatable. Set by `qube`. Paths are always absolute (also for local-path dependencies, which `qube` resolves to filesystem paths before invocation). |
| `--features <comma-list>`         | Feature flags active in this build, e.g. `--features fft,mp3`. Repeatable; the union of all `--features` flags is the active set. `qube build` derives this from the manifest's `dependencies[].features` and `default-features` per-dependency rules. |
| `--no-color`                      | Disable ANSI color in text diagnostics                                    |
| `--quiet` / `-q`                  | Suppress non-error output                                                 |
| `--verbose` / `-v`                | Verbose logging to stderr                                                 |
| `--version`                       | Print the version and exit                                                |
| `--help`                          | Print help and exit                                                       |

`--module` is the bridge between `qube`'s dependency resolver and the
compiler. `qube build` invokes:

```
q64 build src/main.q
  --addr wasm32
  --module dev.q64.audio=/home/user/.qube/cache/dev.q64.audio-0.3.0/src
  --module dev.q64.ai=/home/user/.qube/cache/dev.q64.ai-0.3.0/src
  --module com.openai.whisper=/home/user/.qube/cache/com.openai.whisper-1.0.2/src
  --diagnostics json
  --out target/debug/wasm32/main.wasm
```

To produce both address-space builds, `qube` invokes `q64` once per address
space (`--addr wasm32` and `--addr wasm64`), writing each under its own
`target/<profile>/<addr>/` directory.

The compiler resolves `import dev.q64.audio` against the supplied map; it
never reads `qube.json5` itself. (Core stdlib `q64.*` is built in and
needs no `--module`.)

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
| `1`   | Program panicked (`panic <payload>` in user code; uncaught at top level) — or, when the payload also fits `Error`, the value of `payload.exit_code()` (default `1`). |
| `2`   | Usage error (bad flags, missing args)                            |
| `64`  | Compile error (any `error`-severity diagnostic)                  |
| `65`  | Input error (file not found, unreadable)                         |
| `70`  | Internal compiler error (ICE); diagnostic is in the `Q9xxx` band |
| `N`   | Program called `env.exit(N)` with `N > 0`; or `main` Form 2 returned `Err(e)` and `e.exit_code()` is `N` (per [`errors.md` §"The `Error` face"](./errors.md) and [`env.md` §"`main` signature"](./env.md)). |

Conventions match sysexits where possible. Subprocess callers (`qube`)
distinguish "user error" (`64`) from "ICE" (`70`) so they can choose
whether to retry, report, or surface to the human.

## Subprocess invocation contract

The `qube` binary invokes `q64` per source file. Stable contract for that
boundary:

1. **One invocation per top-level source file**, with one `--out`
   per invocation. `q64` does not batch multiple inputs into a
   single wasm; `qube` is responsible for sequencing invocations and
   linking the resulting objects (or letting each invocation emit a
   self-contained wasm if no cross-file linking is required).
2. **Always pass `--diagnostics json`.** Text rendering is `qube`'s job.
3. **Always pass `--module` for every dependency**, including local
   path dependencies (which `qube` resolves to a filesystem path
   before passing). `q64` does no dependency discovery itself and
   never reads `qube.json5`.
4. **Pass `--features` whenever any dependency declares feature
   flags**, or whenever the consuming `qube.json5` enables features
   non-default. The compiler uses this list to gate
   `@feature("foo")`-annotated items (forthcoming; tracked under
   the comptime spec).
5. **Parse the entire stderr stream as one or more JSON envelopes.**
   Each envelope is a single line of JSON terminated by `\n`
   (newline-delimited JSON), so streaming parsers can read them
   incrementally. `q64` flushes stderr after every envelope; a
   diagnostic emitted in the middle of a long build is visible to
   the parent without waiting for the build to complete. (This is
   the only flush guarantee `qube` may rely on for progress
   reporting.)
6. **Treat exit code `70` as "do not retry, report upstream."** Surface
   the embedded `report_url` to the user.
7. **Do not interpret stdout when `--diagnostics json` is set on
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
