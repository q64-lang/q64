/**
 * `q64 show types <expr>` and `q64 show effects <fn>` — introspection
 * (spec/q64-cli.md §"q64 show kinds").
 *
 * `show effects` is implemented (the effect pass infers a function's
 * capability set). `show types` is not yet, so it stays `test.failing`.
 */
import { describe, expect, test } from "bun:test";
import { binaryAvailable, fixture, runCli } from "../../src/harness";

describe.skipIf(!binaryAvailable())("q64 show types", () => {
  test.failing("prints the inferred type of an expression, exit 0", () => {
    const r = runCli(["show", "types", "1 + 2", "--qube", fixture("hello.q")]);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim().length).toBeGreaterThan(0);
  });
});

describe.skipIf(!binaryAvailable())("q64 show effects", () => {
  test("prints the effect set of a function, exit 0", () => {
    const r = runCli(["show", "effects", "main", "--qube", fixture("hello.q")]);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim().length).toBeGreaterThan(0);
    // hello's main calls env.out → @stdout, which implies @io.
    expect(r.stdout).toContain("@stdout");
    expect(r.stdout).toContain("@io");
  });

  test("requires --qube; a bare subject is a usage error, exit 2", () => {
    const r = runCli(["show", "effects", "main"]);
    expect(r.exitCode).toBe(2);
  });
});
