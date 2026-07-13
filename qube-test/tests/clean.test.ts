/**
 * `qube clean` (spec/qube-cli.md §Subcommands). Removes build outputs (target/).
 *
 * Implemented: removes the `target/` tree next to the discovered manifest;
 * an absent target/ is a success (nothing to remove).
 */
import { existsSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, test } from "bun:test";
import { appManifest, binaryAvailable, makeProject, runCli } from "../src/harness";

describe.skipIf(!binaryAvailable())("qube clean", () => {
  test("removes the target/ build outputs, exit 0", () => {
    const proj = makeProject({
      "qube.json5": appManifest(),
      "src/main.q": "fn main { env.out(\"x\") }\n",
      "target/debug/app.wasm": "stale artifact",
    });
    const r = runCli(["clean"], { cwd: proj });
    expect(r.exitCode).toBe(0);
    expect(existsSync(join(proj, "target"))).toBe(false);
  });

  test("is a no-op (exit 0) when target/ is absent", () => {
    const proj = makeProject({ "qube.json5": appManifest(), "src/main.q": "fn main { env.out(\"x\") }\n" });
    expect(runCli(["clean"], { cwd: proj }).exitCode).toBe(0);
  });
});
