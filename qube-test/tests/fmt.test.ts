/**
 * `qube fmt` (spec/qube-cli.md §Subcommands). Formats every .q source in the
 * qube, delegating to `q64 fmt`.
 *
 * Test-first: not implemented in v0 (stub exits 2). `test.failing` until it lands.
 */
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, test } from "bun:test";
import { appManifest, binaryAvailable, makeProject, runCli } from "../src/harness";

describe.skipIf(!binaryAvailable())("qube fmt", () => {
  test.failing("formats every .q source in the qube in place, exit 0", () => {
    const proj = makeProject({
      "qube.json5": appManifest(),
      "src/main.q": "fn   main{\n env.out( \"x\" ) }\n",
    });
    const r = runCli(["fmt"], { cwd: proj });
    expect(r.exitCode).toBe(0);
    expect(readFileSync(join(proj, "src/main.q"), "utf8")).toContain("fn main");
  });

  test.failing("--check exits non-zero when a file would be reformatted", () => {
    const proj = makeProject({
      "qube.json5": appManifest(),
      "src/main.q": "fn   main{ env.out(\"x\") }\n",
    });
    expect(runCli(["fmt", "--check"], { cwd: proj }).exitCode).toBe(64);
  });
});
