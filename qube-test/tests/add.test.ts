/**
 * `qube add <dep>[@version]` (spec/qube-cli.md §Subcommands). Resolves a
 * dependency from the Continuum, verifies its SHA-256, extracts to the cache,
 * and edits the manifest's `dependencies`. The happy path needs the registry
 * network, so it is `.todo`; only manifest-precondition checks run locally.
 */
import { describe, expect, test } from "bun:test";
import { binaryAvailable, makeProject, runCli } from "../src/harness";

describe.skipIf(!binaryAvailable())("qube add (preconditions)", () => {
  test("outside a qube (no manifest) → non-zero exit", () => {
    const empty = makeProject({ ".keep": "" });
    const r = runCli(["add", "dev.q64.audio"], { cwd: empty });
    expect(r.exitCode).not.toBe(0);
  });
});

describe("qube add (registry path)", () => {
  test.todo("resolves a name@version, downloads, and SHA-256 verifies the archive");
  test.todo("extracts into ~/.qube/cache/sha256/<ab>/<cd>/<digest>/");
  test.todo("adds the resolved dependency to the manifest's `dependencies`");
  test.todo("--offline fails with a dependency error (66) on a cache miss");
  test.todo("a registry/auth failure exits 67");
});
