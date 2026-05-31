/**
 * The q64 subprocess invocation contract (spec/qube-cli.md §"How qube invokes
 * q64", spec/q64-cli.md §"Subprocess invocation contract"). Asserted through
 * observable consequences of a build (artifacts, forwarded diagnostics,
 * aggregated exit code).
 *
 * Test-first: needs a working build pipeline; `test.failing` until it lands.
 */
import { describe, expect, test } from "bun:test";
import { appManifest, binaryAvailable, makeProject, runCli } from "../../src/harness";

describe.skipIf(!binaryAvailable())("q64 subprocess contract", () => {
  test.failing("passes --module so a local-path dependency links (build exits 0)", () => {
    const root = makeProject({
      "app/qube.json5": '{ "name": "dev.q64.app", "version": "0.1.0", "license": "MIT", "type": "application", "entry": "src/main.q", "dependencies": { "dev.q64.dep": { "path": "../dep" } } }',
      "app/src/main.q": "import dev.q64.dep.{version}\nfn main { env.out(version()) }\n",
      "dep/qube.json5": '{ "name": "dev.q64.dep", "version": "0.1.0", "license": "MIT", "type": "library" }',
      "dep/src/lib.q": "pub fn version -> str { \"0.1.0\" }\n",
    });
    expect(runCli(["build"], { cwd: `${root}/app` }).exitCode).toBe(0);
  });

  test.failing("forwards a q64 compile error verbatim and aggregates exit 64", () => {
    const proj = makeProject({
      "qube.json5": appManifest(),
      "src/main.q": "import q64.math.*\nfn main { env.out(\"x\") }\n",
    });
    const r = runCli(["build", "--diagnostics", "json"], { cwd: proj });
    expect(r.exitCode).toBe(64);
    expect((r.envelope?.diagnostics ?? []).some((d) => d.code === "NAM003")).toBe(true);
  });
});
