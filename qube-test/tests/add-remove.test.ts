/**
 * Manifest + lockfile mutations from `qube add` / `qube remove` / `qube lock`
 * (spec/qube-cli.md §Subcommands). `remove` and `lock` are stubs in v0; `add`
 * needs the registry. All mutation outcomes are test-first.
 */
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, test } from "bun:test";
import { binaryAvailable, makeProject, runCli } from "../src/harness";

const WITH_DEP = '{ "name": "dev.q64.x", "version": "0.1.0", "license": "MIT", "type": "application", "entry": "src/main.q", "dependencies": { "dev.q64.audio": "^0.3" } }';

describe.skipIf(!binaryAvailable())("dependency mutations", () => {
  test.failing("`remove <name>` deletes the dependency from the manifest", () => {
    const proj = makeProject({ "qube.json5": WITH_DEP, "src/main.q": "fn main { env.out(\"x\") }\n" });
    const r = runCli(["remove", "dev.q64.audio"], { cwd: proj });
    expect(r.exitCode).toBe(0);
    expect(readFileSync(join(proj, "qube.json5"), "utf8")).not.toContain("dev.q64.audio");
  });

  test.failing("`lock` regenerates qube.lock from the manifest", () => {
    const proj = makeProject({ "qube.json5": WITH_DEP, "src/main.q": "fn main { env.out(\"x\") }\n" });
    const r = runCli(["lock"], { cwd: proj, timeout: 15_000 });
    expect(r.exitCode).toBe(0);
    expect(existsSync(join(proj, "qube.lock"))).toBe(true);
  });
});
