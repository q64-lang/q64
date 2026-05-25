/**
 * `qube web` (spec/qube-cli.md §"qube web"). Builds to wasm and serves via a
 * browser adapter. The manifest-discovery failure path runs on the binary
 * alone; the serve path needs q64 + the browser adapter and is test-first.
 */
import { existsSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, test } from "bun:test";
import { appManifest, binaryAvailable, makeProject, runCli } from "../src/harness";

describe.skipIf(!binaryAvailable())("qube web (manifest discovery)", () => {
  test("no qube.json5 → input error, exit 65", () => {
    const empty = makeProject({ ".keep": "" });
    const r = runCli(["web"], { cwd: empty });
    expect(r.exitCode).toBe(65);
  });
});

// Test-first: the serve path needs the full toolchain + a free port; it is not
// driven to completion in v0. `test.failing` asserts the artifacts it must
// produce. (No port is bound: we assert the emitted files, not a live server.)
describe.skipIf(!binaryAvailable())("qube web (build artifacts)", () => {
  test.failing("emits target/web/<name>.wasm and the browser adapter shell", () => {
    const proj = makeProject({ "qube.json5": appManifest(), "src/main.q": "fn main { env.out(\"x\") }\n" });
    const r = runCli(["web", "--no-open"], { cwd: proj });
    expect(existsSync(join(proj, "target/web/index.html"))).toBe(true);
    expect(existsSync(join(proj, "target/web/host.js"))).toBe(true);
  });
});
