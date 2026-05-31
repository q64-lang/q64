/**
 * `qube test` (spec/qube-cli.md §Subcommands; spec/test-framework.md). Runs the
 * qube's @test functions and reports results as diagnostic envelopes.
 *
 * Test-first: not implemented in v0 (stub exits 2). `test.failing` until it lands.
 */
import { describe, expect, test } from "bun:test";
import { binaryAvailable, makeProject, runCli } from "../src/harness";

const LIB_MANIFEST = '{ "name": "dev.q64.tt", "version": "0.1.0", "license": "MIT", "type": "library" }';

describe.skipIf(!binaryAvailable())("qube test", () => {
  test.failing("a project whose @test passes exits 0", () => {
    const proj = makeProject({
      "qube.json5": LIB_MANIFEST,
      "src/lib.q": "pub fn add(a: i64, b: i64) -> i64 { a + b }\n\n@test\nfn add_works() {\n    assert_eq(add(2, 3), 5)\n}\n",
    });
    expect(runCli(["test"], { cwd: proj }).exitCode).toBe(0);
  });

  test.failing("a failing assertion exits 1", () => {
    const proj = makeProject({
      "qube.json5": LIB_MANIFEST,
      "src/lib.q": "@test\nfn bad() {\n    assert_eq(1, 2)\n}\n",
    });
    expect(runCli(["test"], { cwd: proj }).exitCode).toBe(1);
  });

  test.failing("`qube test <substring>` filters by fully-qualified name", () => {
    const proj = makeProject({
      "qube.json5": LIB_MANIFEST,
      "src/lib.q": "@test\nfn add_works() { assert(true) }\n",
    });
    expect(runCli(["test", "add_works"], { cwd: proj }).exitCode).toBe(0);
  });

  test.failing("discovers @test modules under tests/", () => {
    const proj = makeProject({
      "qube.json5": LIB_MANIFEST,
      "src/lib.q": "pub fn v() -> i64 { 1 }\n",
      "tests/it.q": "@test\nfn integration() { assert(true) }\n",
    });
    expect(runCli(["test"], { cwd: proj }).exitCode).toBe(0);
  });
});
