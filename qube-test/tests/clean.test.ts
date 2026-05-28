/**
 * `qube clean` (spec/qube-cli.md §Subcommands). Removes build outputs (target/).
 *
 * Test-first: not implemented in v0 (stub exits 2). `test.failing` until it lands.
 */
import { existsSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, test } from "bun:test";
import { appManifest, binaryAvailable, makeProject, runCli } from "../src/harness";

describe.skipIf(!binaryAvailable())("qube clean", () => {
  test.failing("removes the target/ build outputs, exit 0", () => {
    const proj = makeProject({
      "qube.json5": appManifest(),
      "src/main.q": "fn main { env.out(\"x\") }\n",
      "target/debug/app.wasm": "stale artifact",
    });
    const r = runCli(["clean"], { cwd: proj });
    expect(r.exitCode).toBe(0);
    expect(existsSync(join(proj, "target"))).toBe(false);
  });

  test.failing("is a no-op (exit 0) when target/ is absent", () => {
    const proj = makeProject({ "qube.json5": appManifest(), "src/main.q": "fn main { env.out(\"x\") }\n" });
    expect(runCli(["clean"], { cwd: proj }).exitCode).toBe(0);
  });
});
