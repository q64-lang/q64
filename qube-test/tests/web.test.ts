/**
 * `qube web` (spec/qube-cli.md §"qube web"). Builds to wasm and serves via a
 * browser adapter. The manifest-discovery failure path runs on the binary
 * alone; the serve path needs q64 + the browser adapter + a port and is `.todo`.
 */
import { describe, expect, test } from "bun:test";
import { binaryAvailable, makeProject, runCli } from "../src/harness";

describe.skipIf(!binaryAvailable())("qube web (manifest discovery)", () => {
  test("no qube.json5 → input error, exit 65", () => {
    const empty = makeProject({ ".keep": "" });
    const r = runCli(["web"], { cwd: empty });
    expect(r.exitCode).toBe(65);
  });
});

describe("qube web (serve path)", () => {
  test.todo("emits target/web/<name>.wasm via q64 emit");
  test.todo("copies the browser adapter (host.js verbatim, index.html with {{WASM}} substituted)");
  test.todo("picks a free port in [4711, 4720] and serves target/web/");
});
