/**
 * `q64 fmt [path]` — format source in place, or via stdin/stdout
 * (spec/q64-cli.md §"q64 fmt options").
 *
 * Test-first: `fmt` is not implemented in v0, so these assert the spec'd
 * behavior as `test.failing` until it lands.
 */
import { readFileSync } from "node:fs";
import { describe, expect, test } from "bun:test";
import { binaryAvailable, fixture, runCli, tmpCopy } from "../src/harness";

describe.skipIf(!binaryAvailable())("q64 fmt", () => {
  test.failing("`fmt path` formats a file in place", () => {
    const src = tmpCopy("unformatted.q");
    const before = readFileSync(src, "utf8");
    const r = runCli(["fmt", src]);
    expect(r.exitCode).toBe(0);
    expect(readFileSync(src, "utf8")).not.toBe(before);
  });

  test.failing("`fmt --stdout` reads stdin and writes the formatted result to stdout", () => {
    const r = runCli(["fmt", "--stdout"], { stdin: "fn   main{\n env.out( \"x\" ) }\n" });
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("fn main");
  });

  test.failing("`fmt --check` exits 64 when a file would be reformatted", () => {
    expect(runCli(["fmt", "--check", fixture("unformatted.q")]).exitCode).toBe(64);
  });

  test.failing("`fmt --check` exits 0 when already formatted", () => {
    expect(runCli(["fmt", "--check", fixture("hello.q")]).exitCode).toBe(0);
  });

  test.failing("`fmt --lint` reports formatting issues on stderr without modifying files", () => {
    const r = runCli(["fmt", "--lint", fixture("unformatted.q")]);
    expect(r.stderr.length).toBeGreaterThan(0);
    expect(r.exitCode).toBe(0);
  });
});
