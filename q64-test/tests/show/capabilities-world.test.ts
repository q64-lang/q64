/**
 * `q64 show capabilities <qube>`, `q64 show denials <fn>`, `q64 show world
 * <qube>` — the component-model / capability surface (spec/q64-cli.md
 * §"q64 show kinds").
 *
 * `show capabilities` and `show world` are implemented (the effect pass +
 * the WIT-world synthesis). `show denials` needs the `with_capabilities(deny:)`
 * language feature, which isn't parsed yet — it stays `test.failing`.
 */
import { describe, expect, test } from "bun:test";
import { binaryAvailable, fixture, runCli } from "../../src/harness";

describe.skipIf(!binaryAvailable())("q64 show capabilities", () => {
  test("prints the compiler-derived capability set for a qube, exit 0", () => {
    const r = runCli(["show", "capabilities", "--qube", fixture("hello.q")]);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim().length).toBeGreaterThan(0);
    // hello writes to stdout, so the qube's capability set includes @stdout.
    expect(r.stdout).toContain("@stdout");
  });
});

describe.skipIf(!binaryAvailable())("q64 show denials", () => {
  test.failing("prints reachability into with_capabilities(deny: …) blocks, exit 0", () => {
    const r = runCli(["show", "denials", "main", "--qube", fixture("hello.q")]);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim().length).toBeGreaterThan(0);
  });
});

describe.skipIf(!binaryAvailable())("q64 show world", () => {
  test("prints the synthesized WIT world (exports + imports), exit 0", () => {
    const r = runCli(["show", "world", "--qube", fixture("hello.q")]);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim().length).toBeGreaterThan(0);
    // The world exports the public surface (main) and imports its capabilities.
    expect(r.stdout).toContain("world ");
    expect(r.stdout).toContain("export main");
    expect(r.stdout).toContain("import wasi:cli/stdout");
  });

  test("exports the full public surface of a main-less library, exit 0", () => {
    // A library qube (no `fn main`) — its world is exports-only, even though no
    // entry reaches them, and its pure surface imports nothing.
    const r = runCli(["show", "world", "--qube", fixture("library.q")]);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("export version: func() -> string");
    expect(r.stdout).toContain("export add: func(a: s64, b: s64) -> s64");
    expect(r.stdout).toContain("(none — pure surface)");
  });
});
