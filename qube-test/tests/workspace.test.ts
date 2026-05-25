/**
 * `qube workspace <subcommand>` and workspace-aware builds (spec/qube-cli.md
 * §"Manifest discovery in workspaces", spec/qube.json5.md §Workspace).
 *
 * Test-first: not implemented in v0 (the `workspace` subcommand stub exits 2 —
 * pinned in usage.test.ts). Uses the fixtures/workspace project.
 */
import { describe, expect, test } from "bun:test";
import { binaryAvailable, fixture, runCli } from "../src/harness";

describe.skipIf(!binaryAvailable())("qube workspace", () => {
  test.failing("`workspace members` lists the member qubes, exit 0", () => {
    const r = runCli(["workspace", "members"], { cwd: fixture("workspace") });
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("alpha");
    expect(r.stdout).toContain("beta");
  });

  test.failing("`build` from the workspace root builds every member, exit 0", () => {
    expect(runCli(["build"], { cwd: fixture("workspace") }).exitCode).toBe(0);
  });

  test.failing("--members <glob> filters the set of members operated on", () => {
    const r = runCli(["build", "--members", "alpha"], { cwd: fixture("workspace") });
    expect(r.exitCode).toBe(0);
  });
});
