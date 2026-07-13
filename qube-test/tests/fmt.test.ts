/**
 * `qube fmt [--check]` (spec/qube-cli.md §Subcommands). Formats every .q
 * source in the qube by delegating the project directory to `q64 fmt`, so it
 * needs the `q64` binary (gated on `q64Available()`, `Q64_BIN` passed
 * through). Exit codes pass through: 0 clean, 64 `--check` would reformat.
 */
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, test } from "bun:test";
import { Q64_BIN, appManifest, binaryAvailable, makeProject, q64Available, runCli } from "../src/harness";

const env = { Q64_BIN };

describe.skipIf(!binaryAvailable() || !q64Available())("qube fmt", () => {
  test("formats every .q source in the qube in place, exit 0", () => {
    const proj = makeProject({
      "qube.json5": appManifest(),
      "src/main.q": "fn   main{\n env.out( \"x\" ) }\n",
    });
    const r = runCli(["fmt"], { cwd: proj, env });
    expect(r.exitCode).toBe(0);
    expect(readFileSync(join(proj, "src/main.q"), "utf8")).toContain("fn main");
  });

  test("--check exits non-zero when a file would be reformatted", () => {
    const proj = makeProject({
      "qube.json5": appManifest(),
      "src/main.q": "fn   main{ env.out(\"x\") }\n",
    });
    expect(runCli(["fmt", "--check"], { cwd: proj, env }).exitCode).toBe(64);
  });

  test("an unknown option → usage error, exit 2", () => {
    const proj = makeProject({
      "qube.json5": appManifest(),
      "src/main.q": "fn main { env.out(\"x\") }\n",
    });
    expect(runCli(["fmt", "--frobnicate"], { cwd: proj, env }).exitCode).toBe(2);
  });
});
