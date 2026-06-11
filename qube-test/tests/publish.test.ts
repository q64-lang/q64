/**
 * `qube publish` (spec/qube-cli.md §"Publishing flow"). Validates the manifest,
 * packs a .zip, runs a clean release build, authenticates, and uploads. The
 * precondition check runs locally; a successful publish is test-first (it needs
 * a registry + credentials, so it cannot succeed here).
 */
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, test } from "bun:test";
import { binaryAvailable, makeProject, Q64_BIN, q64Available, runCli } from "../src/harness";

describe.skipIf(!binaryAvailable())("qube publish (preconditions)", () => {
  test("outside a qube (no manifest) → non-zero exit", () => {
    const empty = makeProject({ ".keep": "" });
    expect(runCli(["publish"], { cwd: empty }).exitCode).not.toBe(0);
  });
});

// The capabilities field is generated, not authored (spec/qube.json5.md
// §Capabilities): publish derives it from `q64 show capabilities` and syncs
// the manifest in place before packing. The publish itself still fails here
// (no credentials), but the sync must have happened first.
describe.skipIf(!binaryAvailable() || !q64Available())("qube publish (capability sync)", () => {
  test("derives and writes the capabilities field before upload", () => {
    const proj = makeProject({
      "qube.json5": '{ "name": "dev.q64.capsync", "version": "0.1.0", "license": "MIT", "type": "application", "entry": "src/main.q" }',
      "src/main.q": 'fn main { env.out("hi") }\n',
    });
    const r = runCli(["publish"], { cwd: proj, timeout: 30_000, env: { Q64_BIN, QUBE_HOME: join(proj, ".home") } });
    expect(r.exitCode).not.toBe(0); // no credentials — but the sync ran first
    expect(r.stdout).toContain("capabilities synced");
    expect(readFileSync(join(proj, "qube.json5"), "utf8")).toContain('"capabilities": ["Stdout"]');
  });

  test("rewrites a stale hand-written capabilities list", () => {
    const proj = makeProject({
      "qube.json5": '{ "name": "dev.q64.capsync2", "version": "0.1.0", "license": "MIT", "type": "application", "entry": "src/main.q", "capabilities": ["Net", "Fs"] }',
      "src/main.q": 'fn main { env.out("hi") }\n',
    });
    const r = runCli(["publish"], { cwd: proj, timeout: 30_000, env: { Q64_BIN, QUBE_HOME: join(proj, ".home") } });
    expect(r.exitCode).not.toBe(0);
    const manifest = readFileSync(join(proj, "qube.json5"), "utf8");
    expect(manifest).toContain('"capabilities": ["Stdout"]');
    expect(manifest).not.toContain("Net");
  });

  test("an in-sync manifest is left untouched", () => {
    const src = '{ "name": "dev.q64.capsync3", "version": "0.1.0", "license": "MIT", "type": "application", "entry": "src/main.q", "capabilities": ["Stdout"] }';
    const proj = makeProject({ "qube.json5": src, "src/main.q": 'fn main { env.out("hi") }\n' });
    const r = runCli(["publish"], { cwd: proj, timeout: 30_000, env: { Q64_BIN, QUBE_HOME: join(proj, ".home") } });
    expect(r.exitCode).not.toBe(0);
    expect(r.stdout).not.toContain("capabilities synced");
    expect(readFileSync(join(proj, "qube.json5"), "utf8")).toBe(src);
  });

  test("a qube that does not compile refuses to publish (exit 64)", () => {
    const proj = makeProject({
      "qube.json5": '{ "name": "dev.q64.capsync4", "version": "0.1.0", "license": "MIT", "type": "application", "entry": "src/main.q" }',
      "src/main.q": "fn main { this is not q64 ((((\n",
    });
    const r = runCli(["publish"], { cwd: proj, timeout: 30_000, env: { Q64_BIN, QUBE_HOME: join(proj, ".home") } });
    expect(r.exitCode).toBe(64);
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
