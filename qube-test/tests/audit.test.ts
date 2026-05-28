/**
 * `qube audit` (spec/qube-cli.md §Subcommands). Shows the effects and
 * capabilities each dependency declares.
 *
 * Test-first: not implemented in v0 (stub exits 2). `test.failing` until it lands.
 */
import { describe, expect, test } from "bun:test";
import { appManifest, binaryAvailable, makeProject, runCli } from "../src/harness";

describe.skipIf(!binaryAvailable())("qube audit", () => {
  test.failing("prints the effects/capabilities of the dependency graph, exit 0", () => {
    const proj = makeProject({ "qube.json5": appManifest(), "src/main.q": "fn main { env.out(\"x\") }\n" });
    const r = runCli(["audit"], { cwd: proj });
    expect(r.exitCode).toBe(0);
    expect(r.stdout.length).toBeGreaterThan(0);
  });
});
