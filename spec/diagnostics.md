# Diagnostics — JSON envelope and code conventions

The structured format every q64 toolchain binary uses to report
diagnostics. Editors, CI tools, and `qube` consume this format to render
errors uniformly.

> **Status: draft (v0).** Schema lives next to this file at
> [`diagnostics.schema.json`](./diagnostics.schema.json).

## When the envelope is used

- `q64` and `qube` emit the JSON envelope on **stderr** whenever
  `--diagnostics json` is set (the default for the LSP and when invoked
  as a subprocess by `qube`).
- Without the flag, both binaries emit human-readable text on stderr and
  use the same diagnostic *content* — only the rendering differs.
- The envelope is also written when a CLI subcommand exits non-zero with
  a diagnostic to deliver.
- When `qube` invokes `q64` as a subprocess, it **forwards `q64`'s
  envelopes verbatim** rather than wrapping them; the consumer
  parses one stream of `NAM* / TYP* / UNI* / ANN* / REG* / EFF* /
  STR* / TST* / CONC* / ENV*` envelopes from `q64` plus `qube`'s own `PKG* / REG2*`
  envelopes (manifest validation, registry, resolver) in the same
  format. `q64` flushes stderr after every envelope so downstream
  parsers can react incrementally; this is the only flush
  guarantee — `qube` may stream progress on this basis.

## Envelope shape

```json
{
  "ok": false,
  "diagnostics": [
    {
      "code": "TYP041",
      "severity": "error",
      "message": "expected `i64`, got `f64`",
      "location": {
        "file": "src/foo.q",
        "line": 12,
        "col": 18,
        "end_line": 12,
        "end_col": 21
      },
      "labels": [
        {
          "location": { "file": "src/foo.q", "line": 5, "col": 10 },
          "message": "this is `f64`"
        }
      ],
      "notes": ["q64 has no implicit numeric coercions"],
      "repair": {
        "id": "wrap-cast",
        "safety": "safe",
        "edits": [
          {
            "location": { "file": "src/foo.q", "line": 12, "col": 18 },
            "replacement": "f64_to_i64(x)"
          }
        ]
      }
    }
  ]
}
```

`ok` is `true` when no `error`-severity diagnostic is present (warnings,
notes, and help can be present in a successful run).

## Diagnostic fields

| Field      | Type                                           | Notes                                                              |
|------------|------------------------------------------------|--------------------------------------------------------------------|
| `code`     | string                                         | Stable, machine-readable identifier (e.g. `TYP041`, `Q9001`).      |
| `severity` | enum: `error`, `warning`, `note`, `help`, `internal` | `internal` is reserved for ICEs.                              |
| `message`  | string                                         | One-line human summary.                                            |
| `location` | object (optional)                              | Primary span; see "Location object" below.                         |
| `labels`   | array (optional)                               | Secondary spans with their own messages — "this is `f64`".         |
| `notes`    | array of strings (optional)                    | Trailing notes printed after the diagnostic body.                  |
| `repair`   | object (optional)                              | Machine-applicable fix; see "Repair object" below.                 |
| `kind`     | string (optional)                              | Subclass within a code namespace; e.g. `"ice"` for `Q9xxx`.        |
| `context`  | object (optional)                              | Tool version / build / platform; standard on `internal` severity.  |
| `trace`    | array of strings (optional)                    | Tool-internal call trace; standard on `internal` severity.         |

### Location object

```json
{ "file": "src/foo.q", "line": 12, "col": 18, "end_line": 12, "end_col": 21 }
```

- `line`, `col` are 1-based; `col` counts UTF-8 code points (not bytes).
- `end_line` and `end_col` are optional; default to `line + 1, col` for
  point spans.
- `file` is relative to the qube root when emitted from inside a qube
  build; absolute otherwise.

### Repair object

```json
{
  "id": "wrap-cast",
  "safety": "safe",
  "edits": [
    { "location": { ... }, "replacement": "f64_to_i64(x)" }
  ]
}
```

- `id` — stable identifier so editors can show "Apply: wrap-cast".
- `safety` — `safe` (always applicable), `unsafe` (changes behavior;
  user must confirm), or `n/a` (informational only, no edit).
- `edits` — array of `{ location, replacement }` covering the change.
  Multi-file repairs allowed; ordering follows the array. Omit
  entirely when no edit is possible (e.g. `severity: internal` ICEs).
- `report_url` — URL to a bug report or documentation page.
  Expected on `severity: internal` (ICEs, where no machine-applicable
  fix exists); permitted on any severity as a pointer to external
  context. Independent of `edits`: both may be present, either may
  be omitted.

## Code conventions

Each diagnostic's `code` belongs to a namespace prefix that tells the
reader which subsystem raised it:

| Prefix  | Subsystem                                       |
|---------|-------------------------------------------------|
| `LEX`   | Lexer                                           |
| `PAR`   | Parser                                          |
| `NAM`   | Name resolution                                 |
| `TYP`   | Type checking                                   |
| `UNI`   | Units of measure                                |
| `ANN`   | Annotations (`@`-form catalog)                  |
| `REG`   | Region / lifetime analysis                      |
| `EFF`   | Effect analysis                                 |
| `STR`   | Stream graph analysis                           |
| `TST`   | Test framework (`@test`, assertions, mocks)     |
| `CMT`   | Comptime evaluation                             |
| `CGN`   | Codegen                                         |
| `LNK`   | Linker / wasm assembly                          |
| `CMP`   | Component emission (WIT world synthesis, canonical-ABI lowering) |
| `WIT`   | WIT ingestion (foreign `.wit` parsing, WIT→q64 type mapping)     |
| `RPC`   | Remote procedure call (`@wire`, wRPC wire, transports)          |
| `FMT`   | Formatter                                       |
| `LSP`   | Language server                                 |
| `PKG`   | qube — manifest / resolver                      |
| `REG2`  | qube — registry client                          |
| `Q9xxx` | **Reserved for ICEs (internal compiler errors)** |

Each prefix uses a three-digit suffix (`TYP041`, `REG003`). Numbers are
assigned once and never reused; a removed diagnostic leaves a gap.

## ICE convention

When the toolchain itself crashes (formatter chokes, codegen invariant
violated), three converging signals tell an agent **not** to edit user
code:

1. `code` in the `Q9xxx` band.
2. `severity: "internal"`.
3. `repair.id: "report-upstream"` with `safety: "n/a"` and a
   `report_url`.

```json
{
  "ok": false,
  "diagnostics": [
    {
      "code": "Q9001",
      "severity": "internal",
      "kind": "ice",
      "message": "formatter crashed: stack overflow in normalize_decl",
      "location": { "file": "src/foo.q", "line": 142, "col": 8 },
      "context": {
        "tool": "q64 fmt",
        "version": "0.7.2",
        "build": "abc123f",
        "platform": "wasm-wasi-x86_64"
      },
      "trace": [
        "normalize_decl decl.q:88",
        "normalize_stmt stmt.q:42"
      ],
      "repair": {
        "id": "report-upstream",
        "safety": "n/a",
        "report_url": "https://q64.dev/ice?code=Q9001&v=0.7.2"
      }
    }
  ]
}
```

Exit code is `70` (sysexits `EX_SOFTWARE`). The crashed tool writes the
user's file atomically (write-on-success only), so an ICE never
corrupts source on disk.

## Plain-text rendering

When `--diagnostics text` (or no flag, the default for interactive use),
each diagnostic renders as:

```
error[TYP041]: expected `i64`, got `f64`
  --> src/foo.q:12:18
   |
12 |     let x = compute(y)
   |                  ^^^ expected `i64`
   |
   = note: q64 has no implicit numeric coercions
   = help: wrap-cast — replace with `f64_to_i64(x)`
```

The shape is borrowed from Rust's `rustc` output. Colour and Unicode
box-drawing are used when stderr is a TTY; ASCII is used otherwise.

## Empty success

A successful run with no diagnostics emits **no envelope** in text mode
and `{ "ok": true, "diagnostics": [] }` in JSON mode. Consumers should
not treat the absence of an envelope in JSON mode as success — always
parse the envelope.

## Suppressing a diagnostic — `@allow(<code>)`

The `@allow` attribute suppresses a specific lint at the
declaration it precedes. Form: `@allow(<code>)` or
`@allow(<code1>, <code2>, …)` — each `<code>` is a diagnostic
code as written in the envelope (`ENV010`, `CONC040`, etc.).

```q64
@allow(CONC051)
fn drain(rx: Receiver<i64, Unbounded>) { … }       // suppresses the Unbounded-channel lint
```

Scope of suppression is the **immediately following item** — a
function, struct, fit, face, const declaration, etc. To suppress
the same code across a whole file, attach `@allow` to each item
that triggers it; there is no block or module-level form in v0.

Restrictions:

- `@allow` only suppresses diagnostics with `severity` of
  `warning`, `note`, or `help`. An `error`-severity diagnostic
  (`severity: "error"`) cannot be suppressed — it represents a
  build-stopping violation. Attempting `@allow(TYP041)` is
  `FMT060` ("`@allow` on error-severity code").
- `@allow(<code>)` for a code that does not exist is `FMT061`
  (warning).
- `@allow(<code>)` for a code that the wrapped item does not
  actually emit is `FMT062` (warning; redundant-allow).

The full annotation surface (`@allow`, `@test`, `@derive`,
`@kind`, …) is consolidated in [`annotations.md`](./annotations.md);
this file owns only `@allow` itself and the `FMT06x` codes for
its misuse.

## Compatibility

Future versions of the envelope may add fields; consumers must ignore
unknown fields. Field removal or semantic change requires a major version
bump (announced via the `$schema` URL path).
