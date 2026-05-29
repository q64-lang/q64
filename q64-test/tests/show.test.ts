/**
 * `q64 show <kind> <file.q>` — IR introspection (spec/q64-cli.md §"show").
 * The `hir` and `mir` kinds dump the two Q64 IR tiers as text on stdout
 * (ARCHITECTURE.md §ir). stdout carries the dump; diagnostics stay on stderr.
 */
import { describe, expect, test } from "bun:test";
import { binaryAvailable, fixture, runCli } from "../src/harness";

describe.skipIf(!binaryAvailable())("q64 show hir|mir", () => {
  test("show hir dumps the HIR for hello, exit 0, stdout-only", () => {
    const r = runCli(["show", "hir", fixture("hello.q")]);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("fn main -> void [entry]");
    expect(r.stdout).toContain('host_out "Hello, q64."');
    // The dump goes to stdout; stderr stays clean.
    expect(r.stderr).toBe("");
  });

  test("show mir dumps the MIR for hello (lowered host_out_const)", () => {
    const r = runCli(["show", "mir", fixture("hello.q")]);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("fn start -> void [entry]");
    expect(r.stdout).toContain("host_out_const");
  });

  test("unknown show kind is a usage error, exit 2", () => {
    const r = runCli(["show", "types", fixture("hello.q")]);
    expect(r.exitCode).toBe(2);
  });

  test("missing file argument is a usage error, exit 2", () => {
    const r = runCli(["show", "hir"]);
    expect(r.exitCode).toBe(2);
  });

  test("show hir of a program with a semantic error fails non-zero", () => {
    // `env.out(mystery())` — an unknown function (NameNotFound). The IR path
    // owns the diagnostic, so `show` surfaces the same honest error as `emit`.
    const r = runCli(["show", "hir", fixture("unknown-call.q")]);
    expect(r.exitCode).not.toBe(0);
  });
});
