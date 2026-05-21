# Conformance test suite

Source-level tests that any q64 implementation must pass to claim
conformance. Each test is a `.q` source file paired with an
`.expected.json` envelope describing the diagnostics the implementation
must emit. The spec is the answer key; this directory is the answer
key's expression as runnable test cases.

> **Status: bootstrapping.** Coverage starts with the named diagnostic
> codes scattered through `spec/*.md` and grows as the implementation
> stresses the corner cases. There is no runner yet — the tests are
> specifications first, runnable second.

## Layout

```
spec/tests/
├── README.md           (* this file *)
├── INDEX.md            (* code → test mapping *)
├── lexical/            (* LEX0xx — tokens, literals, comments *)
├── parser/             (* PAR0xx — syntactic disambiguation *)
├── modules/            (* NAM* — imports, visibility, re-exports *)
├── types/              (* TYP040–TYP099 — numeric tower, modes, bindings *)
├── generics/           (* TYP100–TYP149, PAR040 *)
├── faces/              (* TYP200–TYP249 *)
├── errors/             (* TYP300–TYP307 *)
├── memory/             (* REG* *)
├── effects/            (* EFF* *)
├── concurrency/        (* CONC* *)
├── streams/            (* STR* *)
├── env/                (* ENV* *)
└── golden/             (* end-to-end programs that must parse + type-check *)
```

The subdirectory mirrors the diagnostic-code prefix's owning spec, with
`golden/` reserved for positive end-to-end cases that cross multiple
specs.

## File pair convention

Each test is two files sharing a stem:

| Filename            | Content                                                    |
|---------------------|------------------------------------------------------------|
| `<stem>.q`          | The q64 source under test.                                 |
| `<stem>.expected.json` | The diagnostic envelope the implementation must produce. |

The stem is kebab-case, descriptive of the failure (or the positive
case), and matches the diagnostic code's short message where natural.
`spec/tests/types/numeric-mismatch-no-implicit.q` is paired with
`spec/tests/types/numeric-mismatch-no-implicit.expected.json`.

Every `.q` file begins with a header comment:

```q64
// TEST: <code> — <one-line description>
// SPEC: <spec-file>#<anchor>
// EXPECTED: <ok | error>
```

The header is informational; the `.expected.json` is the source of truth
for what the runner asserts.

## Envelope shape

The envelope matches [`../diagnostics.md`](../diagnostics.md) §"Envelope
shape", reduced to the fields a conformance runner cares about. The
runner is permitted (but not required) to inspect additional fields the
implementation emits.

### Positive case (parses + type-checks cleanly)

```json
{ "ok": true, "diagnostics": [] }
```

A `.expected.json` whose `diagnostics` array is empty asserts the
implementation produces *no* error-severity diagnostics. Warnings, notes,
and help-severity diagnostics may still appear and are ignored unless
`allow_extra` is set to `false` (see "Strict mode" below).

### Negative case (a specific diagnostic must fire)

```json
{
  "ok": false,
  "diagnostics": [
    { "code": "TYP041", "severity": "error" }
  ]
}
```

A negative test asserts that **every** listed diagnostic appears in the
implementation's output (matched by `code` and `severity`). Order is not
significant. Additional diagnostics beyond the listed ones are permitted
by default — the implementation may flag the same source with multiple
codes — unless the test pins `"allow_extra": false`.

### Optional location pinning

```json
{
  "ok": false,
  "diagnostics": [
    {
      "code": "TYP041",
      "severity": "error",
      "location": { "line": 12, "col": 18 }
    }
  ]
}
```

When `location` is present, the runner asserts the diagnostic's primary
span starts at the named line and column. When absent, the runner does
not check spans — implementations may differ in how tightly they bracket
the offending region. Pin spans only when the test's intent is to
verify "this exact token is the source of the error."

`file` may also appear in `location`; when absent, the runner uses the
`.q` file's own path. Multi-file tests are not supported in this layout;
when needed, a future revision will add a `<stem>.dir/` convention.

### Strict mode (`allow_extra: false`)

```json
{
  "ok": false,
  "allow_extra": false,
  "diagnostics": [ … ]
}
```

When `allow_extra` is `false`, the runner additionally asserts that
**no** error-severity diagnostics appear outside the listed set. Use
sparingly — typically a parser error cascades into a typechecker error
in the same file, and the test should not pin both.

## Matching rules

The runner matches diagnostics in this order:

1. `ok` field of the expected envelope must equal the implementation's
   `ok`. A test marked `ok: true` fails on any error-severity diagnostic.
2. Each expected entry in `diagnostics[]` must match exactly one
   emitted entry, by `code` and `severity`. Matching is greedy and
   left-to-right over the expected list.
3. If `location` is present in an expected entry, its `line` / `col`
   must match the matched emitted entry's primary span. `end_line` /
   `end_col` are ignored unless also present in the expected entry.
4. If `allow_extra` is `false`, the runner counts emitted
   `error`-severity diagnostics; the count must equal the expected
   list's length.

The runner does **not** compare `message` text. Diagnostic codes are
stable; message wording is not.

## Test design rules

These conventions exist to keep the corpus useful as the implementation
grows.

- **One code per test.** A test that exercises `TYP041` should not also
  rely on `EFF120` being emitted by the same source. If two codes
  naturally fire together, write two tests with different sources.
- **Self-contained.** A `.q` file should be readable cold. Imports
  needed to set up the failure are spelled out; the file does not
  reference helpers from another test.
- **Minimal.** Strip every line that doesn't contribute to the
  diagnostic. The smallest failing case is the most useful test.
- **Spec-anchored.** The header's `SPEC:` line points at the spec
  paragraph the test enforces. When the spec changes, `grep` finds the
  affected tests.
- **No host effects.** A test that requires `env.fs.read` is fine as a
  syntactic / typechecking input — the runner does not execute the
  body. Conformance tests check the diagnostic surface, not runtime
  behaviour. (Runtime conformance is a separate corpus and lives
  alongside the runtime spec when written.)

## Golden tests

`golden/` holds positive end-to-end programs drawn from the spec's
illustrative examples. They serve two purposes:

1. **Coverage.** A program that uses every major construct — `face`,
   `fit`, `fn`, `scope`, `spawn`, `channel`, `graph`, `|>` — exercises
   the parser and typechecker against a realistic workload.
2. **Regression.** When a spec change tightens a rule, the golden
   tests are the first to break. They are the corpus's canary.

Each golden test is a single `.q` file with `.expected.json` =
`{ "ok": true, "diagnostics": [] }`.

## How an implementation runs the suite

The contract is documented here ahead of any implementation existing:

1. The implementation invokes itself once per `.q` file with the
   `--diagnostics json` flag (per
   [`../q64-cli.md`](../q64-cli.md)) and captures stderr.
2. It parses each emitted envelope as a JSON object matching
   [`../diagnostics.schema.json`](../diagnostics.schema.json).
3. It applies the matching rules above against the test's companion
   `.expected.json`.
4. It reports pass / fail per test and an aggregate count.

The implementation's own test runner (`q64 test --spec`, future) is the
expected driver but is not required; any harness that follows the
matching rules above produces equivalent results.

## Cross-references

- [`../diagnostics.md`](../diagnostics.md) — envelope shape and field
  definitions.
- [`../diagnostics.schema.json`](../diagnostics.schema.json) — JSON
  schema for the envelope.
- [`../grammar.md`](../grammar.md) — the grammar every parse-test
  exercises.
- [`INDEX.md`](./INDEX.md) — the code-to-test map, maintained by hand.
