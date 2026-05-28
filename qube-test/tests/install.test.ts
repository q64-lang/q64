/**
 * `qube install` (spec/qube-cli.md §Subcommands). Resolves and fetches all
 * dependencies into the local cache.
 *
 * Test-first: not implemented in v0 (stub exits 2). `test.failing` until it lands.
 */
import { describe, expect, test } from "bun:test";
import { appManifest, binaryAvailable, makeProject, runCli } from "../src/harness";

describe.skipIf(!binaryAvailable())("qube install", () => {
  test.failing("resolves and fetches dependencies, exit 0", () => {
    const proj = makeProject({ "qube.json5": appManifest(), "src/main.q": "fn main { env.out(\"x\") }\n" });
    expect(runCli(["install"], { cwd: proj }).exitCode).toBe(0);
  });

  test.failing("--offline fails with a dependency error (66) on a cache miss", () => {
    const proj = makeProject({
      "qube.json5": '{ "name": "dev.q64.x", "version": "0.1.0", "license": "MIT", "type": "application", "entry": "src/main.q", "dependencies": { "dev.q64.absent": "^9.9" } }',
      "src/main.q": "fn main { env.out(\"x\") }\n",
    });
    expect(runCli(["install", "--offline"], { cwd: proj }).exitCode).toBe(66);
  });
});
