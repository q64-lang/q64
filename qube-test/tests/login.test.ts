/**
 * `qube login` (auth against the registry; credentials in
 * ~/.qube/credentials.toml). Test-first: a successful login needs a reachable
 * registry, so it cannot succeed here. stdin is piped + a timeout is set so an
 * interactive prompt can't block the suite.
 */
import { describe, expect, test } from "bun:test";
import { binaryAvailable, makeProject, runCli } from "../src/harness";

describe.skipIf(!binaryAvailable())("qube login", () => {
  test.failing("authenticates and stores a credential token (exit 0)", () => {
    const home = makeProject({ ".keep": "" });
    const r = runCli(["login"], {
      stdin: "test-token\n",
      env: { QUBE_HOME: home },
      timeout: 15_000,
    });
    expect(r.exitCode).toBe(0);
  });
});
