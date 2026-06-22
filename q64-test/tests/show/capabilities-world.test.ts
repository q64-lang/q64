/**
 * `q64 show capabilities <qube>`, `q64 show denials <fn>`, `q64 show world
 * <qube>` — the component-model / capability surface (spec/q64-cli.md
 * §"q64 show kinds").
 *
 * `show capabilities` and `show world` are implemented (the effect pass +
 * the WIT-world synthesis). `show denials` needs the `with_capabilities(deny:)`
 * language feature, which isn't parsed yet — it stays `test.failing`.
 */
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
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
    // An app (has `fn main`) is a WASI command: the world exports
    // `wasi:cli/run` and imports the capabilities `main` reaches.
    expect(r.stdout).toContain("world ");
    expect(r.stdout).toContain("export wasi:cli/run");
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

  test("emits a valid standalone WIT document — a `package` declaration", () => {
    // WIT rung 1: the synthesized world is a real .wit document (the artifact
    // `emit --component` writes and the Continuum stores), so it carries a
    // package declaration, not just a bare `world` block.
    const r = runCli(["show", "world", "--qube", fixture("library.q")]);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("package q64:library;");
  });

  test("--out writes the world to a file (the .wit artifact), exit 0", () => {
    const dir = mkdtempSync(join(tmpdir(), "q64-wit-"));
    const out = join(dir, "library.wit");
    const r = runCli(["show", "world", "--qube", fixture("library.q"), "--out", out]);
    expect(r.exitCode).toBe(0);
    // Nothing on stdout — the dump went to the file.
    expect(r.stdout.trim()).toBe("");
    const wit = readFileSync(out, "utf8");
    expect(wit).toContain("package q64:library;");
    expect(wit).toContain("world library {");
    expect(wit).toContain("export add: func(a: s64, b: s64) -> s64");
  });
});
