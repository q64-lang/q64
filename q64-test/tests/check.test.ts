/**
 * `q64 check <file> [--diagnostics json]` — parse a single file and emit the
 * diagnostic envelope on stderr. This is the implemented diagnostic entry
 * point (the conformance runner drives it; see run-conformance.sh) and the
 * v0 stand-in for the spec's `run`/`build` diagnostic surface.
 */
import { describe, expect, test } from "bun:test";
import { binaryAvailable, fixture, hasDiagnostic, runCli } from "../src/harness";

describe.skipIf(!binaryAvailable())("q64 check", () => {
  test("clean source: ok:true, no diagnostics, exit 0", () => {
    const r = runCli(["check", fixture("hello.q"), "--diagnostics", "json"]);
    expect(r.envelope?.ok).toBe(true);
    expect(r.envelope?.diagnostics ?? []).toHaveLength(0);
    expect(r.exitCode).toBe(0);
  });

  test("source with a parser diagnostic: ok:false with NAM003, non-zero exit", () => {
    const r = runCli(["check", fixture("parse-error.q"), "--diagnostics", "json"]);
    expect(r.envelope?.ok).toBe(false);
    expect(hasDiagnostic(r.envelope, "NAM003", "error")).toBe(true);
    expect(r.exitCode).not.toBe(0);
  });

  test("envelope is emitted on stderr, never stdout", () => {
    const r = runCli(["check", fixture("parse-error.q"), "--diagnostics", "json"]);
    expect(r.stdout).toBe("");
    expect(r.stderr).toContain("\"diagnostics\"");
  });

  test("sema diagnostic: import-vs-declaration collision is NAM005, non-zero exit", () => {
    // `check` = parse + the sema file-level pass (q64/src/sema): an import
    // and a local declaration binding one name is NAM005 (spec/modules.md),
    // located at the second binding.
    const r = runCli(["check", fixture("import-collision.q"), "--diagnostics", "json"]);
    expect(r.envelope?.ok).toBe(false);
    expect(hasDiagnostic(r.envelope, "NAM005", "error")).toBe(true);
    expect(r.exitCode).not.toBe(0);
  });

  // The A4 sema check pass: mixed numeric arithmetic on annotated
  // bindings is TYP042 (spec/types.md §arithmetic). Was test.failing
  // from the day the fixture landed; green since the check pass.
  test("surfaces a type error (TYP042) for type-error.q", () => {
    const r = runCli(["check", fixture("type-error.q"), "--diagnostics", "json"]);
    expect(r.envelope?.ok).toBe(false);
    expect(hasDiagnostic(r.envelope, "TYP042", "error")).toBe(true);
    expect(r.exitCode).not.toBe(0);
  });

  test("integer condition is TYP051 (spec/types.md §bool)", () => {
    const r = runCli(["check", fixture("int-condition.q"), "--diagnostics", "json"]);
    expect(hasDiagnostic(r.envelope, "TYP051", "error")).toBe(true);
  });

  test("non-exhaustive match on prelude Option is TYP062 (spec/errors.md)", () => {
    // Option/Result live in the auto-prelude: bare `Some(5)` types as
    // an Option value, and a match missing `None` is non-exhaustive.
    const r = runCli(["check", fixture("option-missing-none.q"), "--diagnostics", "json"]);
    expect(r.envelope?.ok).toBe(false);
    expect(hasDiagnostic(r.envelope, "TYP062", "error")).toBe(true);
    expect(r.exitCode).not.toBe(0);
  });

  test("wrong fit form for a single-param face is TYP201 (spec/faces.md)", () => {
    // The fit registry (q64/src/sema/fits.zig): `Eq` is a prelude
    // single-param face, so the bare `fit Eq<Point>` form is rejected.
    const r = runCli(["check", fixture("wrong-fit-form.q"), "--diagnostics", "json"]);
    expect(r.envelope?.ok).toBe(false);
    expect(hasDiagnostic(r.envelope, "TYP201", "error")).toBe(true);
    expect(r.exitCode).not.toBe(0);
  });

  test("bounded generic call with a non-fitting type is TYP200 (spec/faces.md)", () => {
    // The check pass's generic bound check: `print_all<T: Display>`
    // called with `[Plain { … }]` and no `fit Plain : Display`.
    const r = runCli(["check", fixture("no-fit-for-bound.q"), "--diagnostics", "json"]);
    expect(r.envelope?.ok).toBe(false);
    expect(hasDiagnostic(r.envelope, "TYP200", "error")).toBe(true);
    expect(r.exitCode).not.toBe(0);
  });

  test("missing file: input error, exit non-zero", () => {
    const r = runCli(["check", fixture("does-not-exist.q"), "--diagnostics", "json"]);
    expect(r.exitCode).not.toBe(0);
  });

  test("no file argument: usage error, exit 2", () => {
    const r = runCli(["check"]);
    expect(r.exitCode).toBe(2);
  });

  test("text mode (no --diagnostics json) renders no JSON envelope", () => {
    const r = runCli(["check", fixture("parse-error.q")]);
    expect(r.envelope).toBeUndefined();
  });
});
