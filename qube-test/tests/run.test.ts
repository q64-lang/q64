/**
 * `qube run` (spec/qube-cli.md §Subcommands, §"Manifest discovery"). The
 * manifest-discovery failure paths run on the qube binary alone; a successful
 * run shells out to q64 + a runtime host (full toolchain) and is `.todo`.
 */
import { describe, expect, test } from "bun:test";
import { appManifest, binaryAvailable, fixture, makeProject, runCli } from "../src/harness";

describe.skipIf(!binaryAvailable())("qube run (manifest discovery)", () => {
  test("no qube.json5 in cwd or any parent → input error, exit 65", () => {
    const empty = makeProject({ ".keep": "" });
    const r = runCli(["run"], { cwd: empty });
    expect(r.exitCode).toBe(65);
    expect(r.stderr).toContain("no qube.json5");
  });

  test("manifest without a name → input error, exit 65", () => {
    const proj = makeProject({ "qube.json5": "{ version: '0.1.0' }" });
    const r = runCli(["run"], { cwd: proj });
    expect(r.exitCode).toBe(65);
  });

  test("running a library qube → usage error, exit 2", () => {
    const proj = makeProject({
      "qube.json5": '{ "name": "dev.q64.lib", "version": "0.1.0", "license": "MIT", "type": "library" }',
      "src/lib.q": "pub fn version -> str { \"0.1.0\" }\n",
    });
    const r = runCli(["run"], { cwd: proj });
    expect(r.exitCode).toBe(2);
  });

  test("discovers a manifest in a parent directory (walks upward)", () => {
    const proj = makeProject({
      "qube.json5": appManifest(),
      "src/main.q": "fn main { env.out(\"hi\") }\n",
      "nested/dir/.keep": "",
    });
    // No manifest in nested/dir, so discovery must walk up to the root. Without
    // the full toolchain the build itself may fail, but discovery must NOT be
    // the cause: the "no qube.json5" input error must not appear.
    const r = runCli(["run"], { cwd: `${proj}/nested/dir` });
    expect(r.stderr).not.toContain("no qube.json5");
  });
});

// Test-first: a full `qube run` needs q64 + a runtime host wired on PATH, which
// is not the case in v0 (run fails to locate q64). `test.failing` until it is.
describe.skipIf(!binaryAvailable())("qube run (full toolchain)", () => {
  test.failing("a clean application prints its output and exits 0", () => {
    const proj = makeProject({
      "qube.json5": appManifest(),
      "src/main.q": "fn main { env.out(\"Hello from qube-test.\") }\n",
    });
    const r = runCli(["run"], { cwd: proj });
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("Hello from qube-test.");
  });
});
