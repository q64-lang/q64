/**
 * `qube publish` (spec/qube-cli.md §"Publishing flow"). Validates the
 * manifest, packs a .zip, runs a clean release build, authenticates, and
 * uploads. The flow needs the registry + the compiler, so it is `.todo`;
 * the manifest-precondition check runs locally.
 */
import { describe, expect, test } from "bun:test";
import { binaryAvailable, makeProject, runCli } from "../src/harness";

describe.skipIf(!binaryAvailable())("qube publish (preconditions)", () => {
  test("outside a qube (no manifest) → non-zero exit", () => {
    const empty = makeProject({ ".keep": "" });
    const r = runCli(["publish"], { cwd: empty });
    expect(r.exitCode).not.toBe(0);
  });
});

describe("qube publish (registry flow)", () => {
  test.todo("refuses when `publish: false` in the manifest");
  test.todo("refuses when the version already exists on the registry");
  test.todo("packs qube.json5 + src/** + examples/** + README + LICENSE-* to a .zip");
  test.todo("runs a clean release build and aborts publish on compile error");
  test.todo("a registry/auth/publish-conflict failure exits 67");
});
