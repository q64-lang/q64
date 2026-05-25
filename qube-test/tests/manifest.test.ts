/**
 * qube.json5 parsing, validation, and discovery (spec/qube.json5.md). The
 * implemented manifest reader is exercised through `qube run`, so these drive
 * `run` purely to observe how the manifest is read. Parse/shape failures
 * surface as input errors (exit 65) before any build work.
 */
import { describe, expect, test } from "bun:test";
import { appManifest, binaryAvailable, makeProject, runCli } from "../src/harness";

describe.skipIf(!binaryAvailable())("qube.json5 parsing (via qube run)", () => {
  test("malformed manifest (unterminated) → input error, exit 65", () => {
    const proj = makeProject({ "qube.json5": '{ "name": "x", ' });
    const r = runCli(["run"], { cwd: proj });
    expect(r.exitCode).toBe(65);
  });

  test("manifest that is not a JSON object → input error, exit 65", () => {
    const proj = makeProject({ "qube.json5": "[1, 2, 3]" });
    const r = runCli(["run"], { cwd: proj });
    expect(r.exitCode).toBe(65);
  });

  test("comments + trailing commas parse without an input error", () => {
    const proj = makeProject({
      "qube.json5": '{\n  // a comment\n  "name": "dev.q64.x",\n  "version": "0.1.0",\n  "license": "MIT",\n  "type": "application",\n  "entry": "src/main.q",\n}\n',
      "src/main.q": "fn main { env.out(\"hi\") }\n",
    });
    const r = runCli(["run"], { cwd: proj });
    // The build may not complete without the full toolchain, but the manifest
    // must parse: no "cannot parse" / "cannot read" input failure.
    expect(r.stderr).not.toContain("cannot parse");
    expect(r.exitCode).not.toBe(65);
  });

  test("a complete application manifest is read without an input error", () => {
    const proj = makeProject({ "qube.json5": appManifest(), "src/main.q": "fn main { env.out(\"hi\") }\n" });
    const r = runCli(["run"], { cwd: proj });
    expect(r.exitCode).not.toBe(65);
  });
});

// Test-first: full JSON5 parsing and manifest validation (PKG diagnostics) are
// not implemented in v0. `test.failing` until they land.
describe.skipIf(!binaryAvailable())("qube.json5 validation (spec surface)", () => {
  test.failing("full JSON5 (unquoted keys, single-quoted strings) parses per spec", () => {
    const proj = makeProject({
      "qube.json5": "{ name: 'dev.q64.j5', version: '0.1.0', license: 'MIT', type: 'application', entry: 'src/main.q' }",
      "src/main.q": "fn main { env.out(\"x\") }\n",
    });
    const r = runCli(["run"], { cwd: proj });
    expect(r.exitCode).not.toBe(65);
    expect(r.stderr).not.toContain("cannot parse");
  });

  test.failing("a single-segment publishable name is a PKG diagnostic", () => {
    const proj = makeProject({
      "qube.json5": '{ "name": "singlename", "version": "0.1.0", "license": "MIT", "type": "application", "entry": "src/main.q" }',
      "src/main.q": "fn main { env.out(\"x\") }\n",
    });
    const r = runCli(["build"], { cwd: proj });
    expect((r.envelope?.diagnostics ?? []).some((d) => d.code.startsWith("PKG"))).toBe(true);
  });

  test.failing("a missing required field (license) is a PKG diagnostic", () => {
    const proj = makeProject({
      "qube.json5": '{ "name": "dev.q64.nolic", "version": "0.1.0", "type": "application", "entry": "src/main.q" }',
      "src/main.q": "fn main { env.out(\"x\") }\n",
    });
    const r = runCli(["build"], { cwd: proj });
    expect((r.envelope?.diagnostics ?? []).some((d) => d.code.startsWith("PKG"))).toBe(true);
  });
});
