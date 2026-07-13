/**
 * qube diagnostic framing (spec/qube-cli.md §"How qube invokes q64",
 * spec/diagnostics.md). qube emits PKG / REG2 envelopes for its own
 * diagnostics and forwards q64's envelopes verbatim. Plain usage errors are
 * human text, not envelopes.
 */
import { describe, expect, test } from "bun:test";
import { binaryAvailable, runCli } from "../../src/harness";

describe.skipIf(!binaryAvailable())("diagnostic framing (implemented paths)", () => {
  test("a usage error is plain text, not a JSON envelope", () => {
    const r = runCli(["frobnicate"]);
    expect(r.envelope).toBeUndefined();
  });
});

// Test-first: structured PKG/REG2 envelopes and verbatim q64 forwarding require
// the build/resolver pipeline. `test.failing` until they land.
describe.skipIf(!binaryAvailable())("diagnostic framing (spec surface)", () => {
  test.failing("manifest/resolver errors are PKG-prefixed envelopes under --diagnostics json", () => {
    const proj = makeProject({
      "qube.json5": '{ "name": "singlename", "version": "0.1.0", "license": "MIT", "type": "application", "entry": "src/main.q" }',
      "src/main.q": "fn main { env.out(\"x\") }\n",
    });
    const r = runCli(["build", "--diagnostics", "json", "--addr", "wasm64"], { cwd: proj });
    expect((r.envelope?.diagnostics ?? []).some((d) => d.code.startsWith("PKG"))).toBe(true);
  });

  test.failing("q64's envelopes are forwarded verbatim during a build", () => {
    const proj = makeProject({
      "qube.json5": '{ "name": "dev.q64.x", "version": "0.1.0", "license": "MIT", "type": "application", "entry": "src/main.q" }',
      "src/main.q": "import q64.math.*\nfn main { env.out(\"x\") }\n",
    });
    const r = runCli(["build", "--diagnostics", "json", "--addr", "wasm64"], { cwd: proj });
    expect((r.envelope?.diagnostics ?? []).some((d) => d.code === "NAM003")).toBe(true);
  });
});
