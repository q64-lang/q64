/**
 * `q64 explain <code>` — structured documentation for a diagnostic code
 * (spec/q64-cli.md §"q64 explain <code>").
 *
 * Test-first: not implemented in v0; assertions are `test.failing` until it lands.
 */
import { describe, expect, test } from "bun:test";
import { binaryAvailable, runCli } from "../src/harness";

describe.skipIf(!binaryAvailable())("q64 explain", () => {
  test.failing("`explain TYP041` prints readable text mentioning the code, exit 0", () => {
    const r = runCli(["explain", "TYP041"]);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("TYP041");
  });

  test.failing("`explain TYP041 --diagnostics json` returns the documented JSON shape", () => {
    const r = runCli(["explain", "TYP041", "--diagnostics", "json"]);
    expect(r.exitCode).toBe(0);
    const doc = JSON.parse(r.stdout);
    expect(doc.code).toBe("TYP041");
    expect(typeof doc.summary).toBe("string");
  });
});
