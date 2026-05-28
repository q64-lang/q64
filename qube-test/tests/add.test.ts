/**
 * `qube add <dep>[@version]` (spec/qube-cli.md §Subcommands). Resolves a
 * dependency from the Continuum, verifies its SHA-256, extracts to the cache,
 * and edits the manifest's `dependencies`. The precondition check runs
 * locally; the registry path is test-first (needs the network + registry).
 */
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, test } from "bun:test";
import { appManifest, binaryAvailable, makeProject, runCli } from "../src/harness";

describe.skipIf(!binaryAvailable())("qube add (preconditions)", () => {
  test("outside a qube (no manifest) → non-zero exit", () => {
    const empty = makeProject({ ".keep": "" });
    expect(runCli(["add", "dev.q64.audio"], { cwd: empty }).exitCode).not.toBe(0);
  });
});

describe.skipIf(!binaryAvailable())("qube add (registry path)", () => {
  test.failing("adds the resolved dependency to the manifest's `dependencies`", () => {
    const proj = makeProject({ "qube.json5": appManifest(), "src/main.q": "fn main { env.out(\"x\") }\n" });
    const r = runCli(["add", "dev.q64.audio@^0.3"], { cwd: proj, timeout: 15_000 });
    expect(r.exitCode).toBe(0);
    expect(readFileSync(join(proj, "qube.json5"), "utf8")).toContain("dev.q64.audio");
  });

  test.failing("--offline fails with a dependency error (66) on a cache miss", () => {
    const proj = makeProject({ "qube.json5": appManifest(), "src/main.q": "fn main { env.out(\"x\") }\n" });
    expect(runCli(["add", "dev.q64.absent@^9.9", "--offline"], { cwd: proj, timeout: 15_000 }).exitCode).toBe(66);
  });
});
