# test-framework

The test surface. How `@test` functions are declared, discovered,
run, and reported; how assertions fail with structured
diagnostics; how capability mocking and property tests integrate
with the rest of the language; and what the `Arbitrary` face
contract is.

> **Status: draft (v0).** The annotation surface (`@test`,
> `@skip_laws`) and the existing diagnostic codes (`TYP218`,
> `TYP219`, `ENV020`) are already in play across other specs;
> this file consolidates them and introduces the `TST`
> diagnostic band for test-specific failures. Open items at the
> end name what a v1 revision could expand on.

## Design goals

- **Tests are ordinary functions.** A `@test`-annotated `fn` is a
  function that q64 already understands. No DSL, no separate
  build target, no macro layer. The test runner finds them,
  invokes them, and reports what they do.
- **Failures are diagnostics.** A failing assertion emits the
  same envelope shape the compiler does (per
  [`diagnostics.md`](./diagnostics.md)). The test runner is a
  diagnostic source like the type-checker — same renderer, same
  machine-readable output, same `severity` field.
- **Capability mocks share one mechanism.** The
  `with_capabilities` block from [`env.md`](./env.md) is the
  only mocking surface. Tests don't get a parallel
  dependency-injection framework.
- **Property tests reuse face laws.** A `law` declaration on a
  face is a property test for every fit of that face per
  [`faces.md` §Laws](./faces.md). The framework does not
  introduce a second predicate language.
- **Determinism by default.** Every test gets a seeded RNG;
  every property test records the seed in the failure report.
  Two runs of the same suite with the same seeds produce the
  same results.

## Vocabulary

| Word                   | Meaning                                                                                                        |
|------------------------|----------------------------------------------------------------------------------------------------------------|
| **test function**      | A free `fn` annotated `@test`. Discovered by `qube test`.                                                      |
| **assertion**          | A call to `assert(...)`, `assert_eq(...)`, etc. that fails by emitting a `TST` diagnostic.                     |
| **property test**      | A test generated from a face `law` per [`faces.md`](./faces.md). Runs random `Arbitrary` inputs through the law. |
| **fixture**            | A value constructed for a test's duration. q64 has no `@fixture` keyword; fixtures are scope-local bindings. |
| **mock**               | A capability fit produced by `Face.mock(...)`, installed via `with_capabilities`.                              |
| **shrink**             | The reduction of a counter-example to a smaller failing input. Performed by `Arbitrary::shrink`.               |

## The `@test` annotation

`@test` is a category-1 compiler-known marker per
[`annotations.md`](./annotations.md). It registers a function
with the test runner.

### Position and signature

`@test` attaches to a free `fn`. Methods, fits, faces, stages,
and nested closures cannot be tests.

```q64
@test
fn user_round_trip() {
    let original = User { name: "Ada", age: 30 }
    let encoded  = original.to_json()
    let decoded  = User.from_json(encoded)
    assert_eq(original, decoded)
}
```

Permitted signatures:

```q64
@test fn name()                                  // returns (); failure via assertion
@test fn name() -> Result<(), TestFailure>       // returns Err to fail; try inside
```

Other return types are `TST001`. Parameters of any kind are
`TST002`; a test function takes zero arguments and reads
capabilities (mocked or real) ambiently per
[`env.md`](./env.md).

### Effect inference

The compiler infers the effect set of a `@test` body normally.
A test that touches the network picks up `@network`; a test
that allocates picks up nothing special (allocation is the
default). The runner enforces no inferred-effect restriction; a
`@realtime` assertion inside a test is the body's choice.

The test runner itself is a `@no_realtime`, `@io`, `@time`
context — it logs progress, schedules tests, and reports
results. A `@test` body that needs `@realtime` semantics in its
subject under test invokes that subject through the normal
effect rules.

### Discovery

`qube test` discovers tests two ways:

1. **In-source tests.** Any `@test`-annotated `fn` in a module
   reachable from the qube's `src/` is a test.
2. **`tests/` directory.** Any module under `tests/` at the
   qube root is compiled as a separate crate with the qube as
   a `pub` dependency. `@test`-annotated `fn`s in it are
   discovered the same way.

`tests/` modules can import the qube's `pub` surface freely;
they cannot reach the qube's internal items (this is the same
rule the registry boundary enforces). For tests that need
private-symbol access, declare them inside `src/` next to the
code they cover.

### Filtering

```
qube test                    # run every test
qube test user               # run tests whose fully-qualified name contains "user"
qube test --exact user_id    # run only tests whose name is exactly "user_id"
qube test --members "math/*" # workspace filter (per qube-cli.md)
```

The filter is a substring match on the test's
fully-qualified name (`my_qube::auth::test_login`) unless
`--exact` is given.

## Assertion API

Assertions live in the auto-prelude. Each assertion that fails
emits a `TST020` diagnostic and aborts the test (via `panic
TestFailure`) — the test runner catches that panic at the test
boundary, records the failure, and continues with the next
test.

| Assertion                              | Fails when                                                       |
|----------------------------------------|------------------------------------------------------------------|
| `assert(cond)`                         | `cond` is `false`.                                               |
| `assert(cond, msg)`                    | `cond` is `false`; `msg` (any `Display`) is included in the report. |
| `assert_eq(a, b)`                      | `a != b` per `Eq`.                                               |
| `assert_neq(a, b)`                     | `a == b` per `Eq`.                                               |
| `assert_matches(value, Pattern)`       | `value` does not match the pattern; pattern syntax per `grammar.md` §Patterns. |
| `assert_approx_eq(a, b, eps: f64)`     | `|a - b| > eps`. For floats; `a`, `b` carry the same unit per `units.md` if unit-tagged. |
| `assert_panics(\|\| { … })`            | The closure does **not** panic. Returns the panic payload for inspection. |
| `assert_panics_with(\|\| { … }, P)`    | The closure does not panic, or panics with a payload not matching pattern `P`. |
| `unreachable_test()`                   | Marker for paths that should be unreachable in test (`TST022`). Distinct from runtime `unreachable!()` per `errors.md`. |

`assert_eq` and `assert_neq` require both arguments fit `Eq`
and `Debug` (the latter for the failure report). `TST030` is
emitted at compile time when the arguments don't fit `Debug`.

### Source-location capture

Assertion source locations are captured at the call site, not
inside the assertion implementation. The compiler synthesizes
the location from the lexer span; assertion authors do not
write `@caller`-style annotations.

### Custom assertions

User code may declare its own assertion helpers; they are
ordinary functions that panic `TestFailure`:

```q64
fn assert_sorted<T: Ord>(items: [T]) {
    for i in 1..items.len() {
        if items[i] < items[i - 1] {
            panic TestFailure {
                message: "items not sorted at index {i}",
                location: env.test.caller(),
            }
        }
    }
}
```

`env.test.caller()` returns a `Location` for the call site of
the function it appears in; it is `@test`-context-only
(`TST040` otherwise).

## The `TestFailure` panic type

```q64
pub struct TestFailure {
    message:  str,
    location: Location,
    context:  Map<str, str>,   // optional key-value attachments
}

fit TestFailure : Panic {
    fn code() -> Option<str> { Some("TST020") }
}
```

`TestFailure` is auto-prelude. It is the carrier the assertion
API panics with; the test runner catches it at the test
boundary and converts it to a `TST020` envelope. Per
[`errors.md`](./errors.md), `panic TestFailure { … }` allocates
in the scope arena and unwinds to the nearest scope, which the
runner installs around each test.

A test that prefers `Result<(), TestFailure>` over panicking
constructs the same value and returns `Err(…)`; the runner
treats either form identically.

## Mocking — the `with_capabilities` pattern

The mock pattern is the `use:` override on
`with_capabilities`, per
[`env.md` §"Testing with mocks"](./env.md). The test framework
adds no new mechanism; it pins the conventions.

### The `.mock()` convention

A capability face exposes a `.mock(...)` constructor by
convention. The constructor returns a fit suitable for use as
the `use:` value:

```q64
pub fit MockNet : Net {
    fn get(self, url: Url) -> Result<Response, IoError> { … }
    pub fn new() -> MockNet { … }
    pub fn on_get(self, url: Url, body: str) -> MockNet { … }
}

impl Net {
    pub fn mock() -> MockNet @test {
        MockNet.new()
    }
}
```

`Net.mock()` is `@test`-only — calling it outside a `@test`
function (or a function transitively called from one) is
`ENV020` per [`env.md`](./env.md). The `@test` effect marker on
the `mock` method is how the compiler tracks the boundary; it
is the same marker the `@test` annotation produces in the
inferred set of the test body.

### Test usage

```q64
@test
fn fetch_users_parses_response() {
    with_capabilities(use: { net: Net.mock()
        .on_get(url"https://api.example.com/users",
                body: r#"[{"name":"Ada"}]"#) }) {
        let users = try fetch_users(url"https://api.example.com/users")
        assert_eq(users.len(), 1)
        assert_eq(users[0].name, "Ada")
    }
}
```

The production `fetch_users` reads `env.net` ambiently; the
test shadows the binding; the test's `MockNet` is what the
synthesized parameter resolves to. No alternative entry point,
no dependency-injection framework.

### Strictness modes

Mocks are **strict by default**: any capability call not
explicitly configured fails the test with `TST050`. A test
that wants a permissive mock declares so:

```q64
with_capabilities(use: { net: Net.mock().permissive() }) { … }
```

`permissive()` returns the same fit with unconfigured calls
falling through to a default (empty `Response`, zero bytes
read, etc.). The strict/permissive choice is a per-fit method,
not a framework flag.

## Property tests and the `Arbitrary` face

Property tests are generated from face `law` declarations per
[`faces.md` §Laws](./faces.md). The framework runs each law
against `Arbitrary`-generated inputs and reports
counter-examples as `TYP218` diagnostics (the band is owned by
faces.md, not this spec).

### The `Arbitrary` face

```q64
pub face Arbitrary<T> {
    fn generate(rng: ref Rng) -> T
    fn shrink(value: T) -> [T]                  // smaller candidates
}
```

`Arbitrary<T>` is auto-prelude. Stdlib provides fits for every
primitive type and auto-derives `Arbitrary` for any `struct` /
`enum` whose fields all fit `Arbitrary`. User code only writes
a manual fit when the auto-derived generator would produce
useless inputs (e.g., a `Url` parser whose generator would
almost never produce well-formed URLs).

The auto-derive lives under `@derive(Arbitrary)` per
[`faces.md`](./faces.md) §"Auto-derive". It is opt-in for user
types — adding `Arbitrary` to a type that has laws and no
manual fit is `TYP217` (missing-derive).

### Generation strategy

`Arbitrary::generate` reads from a seeded `Rng` (one per test,
per property). The framework guarantees:

- **Determinism per seed.** Two runs with the same seed produce
  the same input sequence.
- **Seed reporting.** The seed is included in every counter-
  example report so the failure is reproducible:

  ```
  error[TYP218]: property test law violated: associative
    --> src/math.q:42:5
     |
   42 |     law associative: forall a, b, c => …
     |
     = note: seed 0xfaceb00c
     = note: minimal counter-example: a = 1, b = 2, c = 0
  ```

- **Per-test seed source.** The seed defaults to a stable hash
  of the test's fully-qualified name. `QUBE_TEST_SEED=<u64>` in
  the environment overrides every test to use the same seed.

### Shrinking

When a counter-example is found, the framework invokes
`Arbitrary::shrink` repeatedly: each smaller candidate is
re-tested, and the smallest still-failing input is reported.
Shrinking terminates when `shrink` returns an empty array or
when every candidate passes.

`shrink` has no determinism guarantee beyond "every candidate
should be smaller than the input under some structural order."
The framework treats `shrink` as advisory; an inefficient
shrinker produces larger counter-examples but does not affect
correctness.

### Skip via `@skip_laws`

A fit that declares laws but cannot satisfy them (e.g.,
`Monoid<f64>` per [`faces.md`](./faces.md) §"Opting out") uses
`@skip_laws`:

```q64
@skip_laws
pub fit Monoid<f64> { … }
```

The fit still works; `qube test` skips the property tests for
it and emits no `TYP218`. `TYP219` is the diagnostic for
`@skip_laws` on a fit whose face has no laws.

## Fixtures and lifecycle

q64 has no `@before_all` / `@after_each` annotation surface.
The scope mechanism from [`memory.md` §"Scope's implicit
arena"](./memory.md) is the fixture mechanism:

```q64
@test
fn integration_db_query() {
    scope {
        let db = TestDb.start()           // setup
        defer db.shutdown()                // teardown — runs on scope exit
        let result = run_query(db, "SELECT 1")
        assert_eq(result, 1)
    }
}
```

`defer` runs on scope exit (normal or panicking); the
`TestDb.shutdown()` call is the teardown. The scope arena
collects any intermediate allocations.

### Shared fixtures across tests

A fixture that's expensive to construct (a populated database,
a compiled model) is shared by wrapping the per-test scope:

```q64
fn with_loaded_model<R>(f: |Model| -> R) -> R {
    static MODEL: Lazy<Model> = Lazy { || Model.load("test-fixtures/tiny.bin") }
    scope {
        f(MODEL.get())
    }
}

@test fn classify_smoke()   { with_loaded_model(|m| assert(m.classify("hi").confidence > 0.5)) }
@test fn classify_unicode() { with_loaded_model(|m| assert(m.classify("👋").confidence > 0.5)) }
```

`Lazy` is a property wrapper per
[`annotations.md`](./annotations.md); the `static` binding
constructs the value once across all tests. Tests run
sequentially within a single qube unless `--parallel` is
passed; with parallelism, the user is responsible for shared-
fixture safety.

### Parallelism

```
qube test                # serial; the v0 default
qube test --parallel N   # run up to N tests concurrently
```

Parallel test isolation is at the scope arena boundary: each
test gets its own scope and its own ambient `env`. Shared
mutable state (`static var`, `@shared` structs) is the user's
responsibility; the framework does not synchronize it.

A test that depends on a host resource (e.g., a fixed network
port) declares so via `@allow(TST060)` if the implicit
serialization assumption is intentional; the framework cannot
detect cross-test resource conflicts otherwise.

## Test output and the diagnostic envelope

`qube test` emits the same envelope shape as the compiler per
[`diagnostics.md`](./diagnostics.md). The `code` field carries
the test-specific band (`TST020` for assertion failure,
`TYP218` for property-law violation, `TST050` for unmocked
capability) so downstream tools can filter by failure kind.

Test outcomes are reported per test as a `note`-severity
envelope on success and an `error`-severity envelope on
failure. The summary at end-of-run is a plain text line; it is
not part of the structured envelope stream.

```
ok    user_round_trip                 (3ms)
ok    fetch_users_parses_response     (12ms)
FAIL  classify_smoke                  (87ms)
  error[TST020]: assertion failed: expected 0.5, got 0.42
    --> src/ml.q:84:9
     |
   84 |         assert(m.classify("hi").confidence > 0.5)
     |
3 tests, 1 failed
```

The exit code is `1` per [`qube-cli.md`](./qube-cli.md) when
any test fails; `0` otherwise.

## Diagnostic codes

Test diagnostics use the `TST` prefix; the prefix is reserved
in [`diagnostics.md` §"Code conventions"](./diagnostics.md).
Numbers are stable, never reused.

| Code     | Short message                                       | When                                                                              |
|----------|-----------------------------------------------------|-----------------------------------------------------------------------------------|
| `TST001` | `@test` function has unsupported return type        | Must be `()` or `Result<(), TestFailure>`.                                        |
| `TST002` | `@test` function takes parameters                   | A test function takes zero arguments.                                             |
| `TST003` | `@test` on a non-free function                      | `@test` on a method, fit, stage, or nested closure.                               |
| `TST020` | assertion failed                                    | Any `assert*` failure at runtime.                                                 |
| `TST021` | panic in test body was not `TestFailure`            | A test panicked with a non-`TestFailure` payload. Surfaced as a test failure, attributing the original panic. |
| `TST022` | `unreachable_test()` reached                        | A `unreachable_test()` marker executed.                                           |
| `TST030` | assertion arguments don't fit `Debug`               | `assert_eq(a, b)` where `a` or `b` cannot be debug-printed. Compile-time.         |
| `TST031` | assertion arguments don't fit `Eq`                  | `assert_eq` / `assert_neq` where the type has no `Eq` fit.                        |
| `TST040` | `env.test` API used outside test context            | A function calling `env.test.caller()` is not transitively reachable from a `@test`. Compile-time. |
| `TST050` | unmocked capability call in strict mock             | A test's strict mock saw a capability call it wasn't configured for.              |
| `TST051` | mock-configuration unreached                        | A configured mock entry was never invoked during the test. Warning by default.    |
| `TST060` | suggestion: parallel-unsafe test in parallel run    | (Note severity.) A test with `@allow(TST060)` runs in `--parallel` mode; the framework warns that the suppression may be wrong now. |

Property-test counter-examples remain on `TYP218` (owned by
[`faces.md`](./faces.md)). The choice keeps law-checking under
the faces namespace; only test-specific failures (assertions,
mock policy, fixture lifecycle) live under `TST`.

All codes are emitted using the standard envelope from
[`diagnostics.md`](./diagnostics.md).

## Examples

### A minimal unit test

```q64
@test
fn parse_empty_string() {
    let result = parse("")
    assert_matches(result, Err(ParseError::Empty))
}
```

### A test with a fixture and teardown

```q64
@test
fn write_then_read() {
    scope {
        let tmp = TempFile.create()
        defer tmp.cleanup()
        tmp.write("hello")
        assert_eq(tmp.read(), "hello")
    }
}
```

### A capability-mocked test

```q64
@test
fn fetch_404_returns_not_found_error() {
    with_capabilities(use: { net: Net.mock()
        .on_get(url"https://api.example.com/missing",
                status: 404, body: "") }) {
        let r = fetch(url"https://api.example.com/missing")
        assert_matches(r, Err(FetchError::NotFound))
    }
}
```

### A property test (via face laws)

```q64
pub face Monoid<T> {
    fn zero() -> T
    fn combine(a: T, b: T) -> T

    law left_id:     forall a: T       => combine(zero(), a) == a
    law right_id:    forall a: T       => combine(a, zero()) == a
    law associative: forall a, b, c: T => combine(combine(a, b), c) == combine(a, combine(b, c))
}

pub fit Monoid<String> {
    fn zero() -> String { "" }
    fn combine(a: String, b: String) -> String { a + b }
}

// No @test needed — `qube test` runs the three laws against random Strings.
```

### A manual `Arbitrary` fit

```q64
pub fit Arbitrary<Url> {
    fn generate(rng: ref Rng) -> Url {
        let host = pick(rng, ["example.com", "q64.dev", "localhost"])
        let path = "/" + rng.alphanumeric(0..16)
        Url.parse("https://{host}{path}").unwrap()
    }

    fn shrink(u: Url) -> [Url] {
        // Try the host root, then drop path segments one at a time.
        if u.path.is_empty() { [] } else { [u.with_path("")] }
    }
}
```

### A test that expects a panic

```q64
@test
fn division_by_zero_panics() {
    let payload = assert_panics(|| { divide(1, 0) })
    assert(payload.code() == Some("ARITH001"))
}
```

## Open items deferred

- **Per-test budgets.** Wall-clock timeout, allocation cap,
  per-test sample count for property tests. v0 has a flat
  default (100 samples per property test, no timeout); the
  knobs to override per-test are deferred.
- **Snapshot testing.** `assert_snapshot(value)` comparing
  against an on-disk golden file. Convenient for diagnostic-
  envelope tests but requires a stable filesystem layout per
  qube; deferred.
- **Test-only items.** A `@test` modifier on `struct`, `fn`, or
  `mod` declarations to gate code on `cfg(test)`-style
  conditional compilation. Today, helpers used only by tests
  live under `tests/` or accept being part of the qube's
  surface.
- **Distributed test execution.** Running `qube test --parallel
  N` across multiple machines; v0 runs in one process.
- **Coverage instrumentation.** Branch and line coverage. A
  codegen concern more than a test-framework one; lands when
  codegen does.
- **Fuzz integration.** A `@fuzz` annotation distinct from
  property tests, with corpus management and crash bucketing.
  Out of scope for v0.
- **`Arbitrary` generators with explicit weights.** The current
  generation is uniform; user-supplied weights for enum variant
  frequency or string-length distribution land later.
- **Test-time effect overrides.** Whether `@test` should
  weaken some effect bounds (e.g., allow `@realtime` violation
  inside a stub) for ergonomic mocking. Today the user wraps
  the call site.

## Related specs

- [`annotations.md`](./annotations.md) — `@test` is a
  category-1 marker; `@skip_laws` is the per-fit law-opt-out.
- [`faces.md`](./faces.md) — `law` declarations; the
  `Arbitrary` face is auto-prelude here; property-test
  diagnostics live under `TYP218` / `TYP219`.
- [`env.md`](./env.md) — `with_capabilities(use: { … })` is
  the mock-installation mechanism; `ENV020` enforces the
  `.mock()`-outside-test rule.
- [`errors.md`](./errors.md) — `panic`, `Panic` face, `Result`
  / `try`; `TestFailure` participates in the same machinery.
- [`memory.md`](./memory.md) — scope arena and `defer` are the
  fixture lifecycle mechanism; no test-specific `@before_all`
  needed.
- [`concurrency.md`](./concurrency.md) — test parallelism uses
  the same scope-and-spawn machinery as production code; no
  test-only scheduler.
- [`diagnostics.md`](./diagnostics.md) — envelope format for
  the `TST` code band; the renderer is shared with the
  compiler.
- [`qube-cli.md`](./qube-cli.md) — `qube test` subcommand,
  exit codes, member filtering.
- [`modules.md`](./modules.md) — `Arbitrary` is auto-prelude;
  the `tests/` directory's visibility rules.
