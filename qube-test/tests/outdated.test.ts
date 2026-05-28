/**
 * `qube outdated` (spec/qube-cli.md §Subcommands). Lists dependencies with
 * newer compatible versions.
 *
 * Test-first: not implemented in v0 (stub exits 2). `test.failing` until it lands.
 */
import { describe, expect, test } from "bun:test";
import { appManifest, binaryAvailable, makeProject, runCli } from "../src/harness";

describe.skipIf(!binaryAvailable())("qube outdated", () => {
  test.failing("reports nothing and exits 0 when all dependencies are current", () => {
    const proj = makeProject({ "qube.json5": appManifest(), "src/main.q": "fn main { env.out(\"x\") }\n" });
    expect(runCli(["outdated"], { cwd: proj }).exitCode).toBe(0);
  });
});
