/**
 * `qube new <name>` / `qube init` (spec/qube-cli.md §Subcommands). Scaffolds a
 * qube directory with a starter manifest and `src/`.
 *
 * Test-first: not implemented in v0 (both stubs exit 2 — pinned in
 * usage.test.ts). `test.failing` asserts the scaffolding until it lands.
 */
import { existsSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, test } from "bun:test";
import { binaryAvailable, makeProject, runCli } from "../src/harness";

describe.skipIf(!binaryAvailable())("qube new", () => {
  test.failing("creates a new directory with a starter qube.json5 and src/", () => {
    const parent = makeProject({ ".keep": "" });
    const r = runCli(["new", "dev.q64.fresh"], { cwd: parent });
    expect(r.exitCode).toBe(0);
    expect(existsSync(join(parent, "dev.q64.fresh/qube.json5"))).toBe(true);
    expect(existsSync(join(parent, "dev.q64.fresh/src"))).toBe(true);
  });
});

describe.skipIf(!binaryAvailable())("qube init", () => {
  test.failing("initialises a qube in the current directory", () => {
    const dir = makeProject({ ".keep": "" });
    const r = runCli(["init"], { cwd: dir });
    expect(r.exitCode).toBe(0);
    expect(existsSync(join(dir, "qube.json5"))).toBe(true);
  });
});
