/**
 * `qube fix` (spec/qube-cli.md §"qube fix and qube explain"). Applies or plans
 * automated repairs from diagnostic `repair` fields.
 *
 * Test-first: not implemented in v0 (stub exits 2). `test.failing` until it lands.
 */
import { describe, expect, test } from "bun:test";
import { appManifest, binaryAvailable, makeProject, runCli } from "../src/harness";

function project() {
  return makeProject({ "qube.json5": appManifest(), "src/main.q": "fn main { env.out(\"x\") }\n" });
}

describe.skipIf(!binaryAvailable())("qube fix", () => {
  test.failing("--plan emits a JSON repair plan with a summary, exit 0", () => {
    const r = runCli(["fix", "--plan"], { cwd: project() });
    expect(r.exitCode).toBe(0);
    const plan = JSON.parse(r.stdout);
    expect(plan).toHaveProperty("summary");
    expect(plan).toHaveProperty("repairs");
  });

  test.failing("--apply applies safe repairs, exit 0", () => {
    expect(runCli(["fix", "--apply"], { cwd: project() }).exitCode).toBe(0);
  });

  test.failing("--apply --dry-run shows a diff without writing, exit 0", () => {
    expect(runCli(["fix", "--apply", "--dry-run"], { cwd: project() }).exitCode).toBe(0);
  });
});
