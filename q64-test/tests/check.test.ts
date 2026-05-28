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

  // `check` is parser-only in v0; type-checking diagnostics (TYP*) are not
  // emitted yet, so type-error.q parses clean today. Test-first: red until the
  // type-checker lands and surfaces TYP042 (spec/types.md §arithmetic).
  test.failing("surfaces a type error (TYP042) for type-error.q once type-checking lands", () => {
    const r = runCli(["check", fixture("type-error.q"), "--diagnostics", "json"]);
    expect(hasDiagnostic(r.envelope, "TYP042", "error")).toBe(true);
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
