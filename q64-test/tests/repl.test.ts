/**
 * `q64 repl` — interactive REPL (spec/q64-cli.md §Subcommands; marked
 * "eventual; not in v0").
 *
 * Test-first: not implemented. stdin is piped (and closed) so a real REPL reads
 * a line, evaluates, and exits at EOF without blocking; `test.failing` until it
 * lands.
 */
import { describe, expect, test } from "bun:test";
import { binaryAvailable, runCli } from "../src/harness";

describe.skipIf(!binaryAvailable())("q64 repl", () => {
  test.failing("evaluates a piped expression and prints its value, exit 0", () => {
    const r = runCli(["repl"], { stdin: "1 + 2\n", timeout: 10_000 });
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("3");
  });
});
