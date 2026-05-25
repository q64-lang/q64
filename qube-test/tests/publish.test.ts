/**
 * `qube publish` (spec/qube-cli.md §"Publishing flow"). Validates the manifest,
 * packs a .zip, runs a clean release build, authenticates, and uploads. The
 * precondition check runs locally; a successful publish is test-first (it needs
 * a registry + credentials, so it cannot succeed here).
 */
import { describe, expect, test } from "bun:test";
import { binaryAvailable, makeProject, runCli } from "../src/harness";

describe.skipIf(!binaryAvailable())("qube publish (preconditions)", () => {
  test("outside a qube (no manifest) → non-zero exit", () => {
    const empty = makeProject({ ".keep": "" });
    expect(runCli(["publish"], { cwd: empty }).exitCode).not.toBe(0);
  });
});

describe.skipIf(!binaryAvailable())("qube publish (flow)", () => {
  test.failing("a clean publish to the registry succeeds (exit 0)", () => {
    const proj = makeProject({
      "qube.json5": '{ "name": "dev.q64.pub", "version": "0.1.0", "license": "MIT", "type": "library" }',
      "src/lib.q": "pub fn v() -> i64 { 1 }\n",
    });
    expect(runCli(["publish"], { cwd: proj, timeout: 15_000 }).exitCode).toBe(0);
  });
});
