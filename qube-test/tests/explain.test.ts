/**
 * `qube explain <code>` (spec/qube-cli.md §"qube fix and qube explain").
 * Delegates to `q64 explain` and adds qube-specific context.
 *
 * Test-first: not implemented in v0 (stub exits 2). `test.failing` until it lands.
 */
import { describe, expect, test } from "bun:test";
import { binaryAvailable, runCli } from "../src/harness";

describe.skipIf(!binaryAvailable())("qube explain", () => {
  test.failing("prints documentation for a diagnostic code mentioning the code, exit 0", () => {
    const r = runCli(["explain", "TYP041"]);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("TYP041");
  });

  test.failing("--diagnostics json returns the same JSON shape as q64 explain", () => {
    const r = runCli(["explain", "TYP041", "--diagnostics", "json"]);
    expect(r.exitCode).toBe(0);
    const doc = JSON.parse(r.stdout);
    expect(doc.code).toBe("TYP041");
  });
});
