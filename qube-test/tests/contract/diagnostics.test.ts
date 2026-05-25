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

describe("diagnostic framing (spec surface)", () => {
  test.todo("manifest/resolver errors are PKG-prefixed envelopes under --diagnostics json");
  test.todo("registry-client errors are REG2-prefixed envelopes");
  test.todo("q64's envelopes are forwarded verbatim (not re-wrapped) during a build");
  test.todo("the worst exit code across multiple q64 invocations wins (70 > 64 > 2 > 0)");
});
