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

describe("qube.json5 validation (spec surface)", () => {
  test.todo("full JSON5 (unquoted keys, single-quoted strings) parses per spec/qube.json5.md");
  test.todo("a publishable name must be reverse-DNS with >= 2 segments (PKG diagnostic)");
  test.todo("a missing required field (version / license) is a PKG diagnostic");
  test.todo("an unknown `type` value is rejected");
  test.todo("a dependency object with both `path` and `version` is rejected");
  test.todo("$schema is validated against the bundled JSON Schema");
});
