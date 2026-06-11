/**
 * `qube install` (spec/qube-cli.md §Subcommands, spec/qube.lock.md
 * §Lifecycle). Makes the cache satisfy the lockfile: relocks when the
 * lockfile is missing or stale, then fetches missing locked archives.
 * All cases here are hermetic — path deps, pre-seeded caches, and
 * `--offline` failures; the actual download path is shared with
 * `qube add` (add.test.ts).
 */
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, test } from "bun:test";
import { appManifest, binaryAvailable, makeProject, runCli } from "../src/harness";

describe.skipIf(!binaryAvailable())("qube install", () => {
  test("no dependencies: writes an empty lockfile, exit 0", () => {
    const proj = makeProject({ "qube.json5": appManifest(), "src/main.q": "fn main { env.out(\"x\") }\n" });
    const r = runCli(["install"], { cwd: proj });
    expect(r.exitCode).toBe(0);
    const lock = JSON.parse(readFileSync(join(proj, "qube.lock"), "utf8"));
    expect(lock.qubes).toEqual([]);
  });

  test("path deps: relocks a missing lockfile without the network, exit 0", () => {
    const proj = makeProject({
      "app/qube.json5": '{ "name": "dev.q64.x", "version": "0.1.0", "license": "MIT", "type": "application", "entry": "src/main.q", "dependencies": { "dev.q64.local": { "path": "../local" } } }',
      "app/src/main.q": "fn main { env.out(\"x\") }\n",
      "local/qube.json5": '{ "name": "dev.q64.local", "version": "0.2.5", "license": "MIT", "type": "library", "entry": "src/lib.q" }',
      "local/src/lib.q": "pub fn version() -> str { \"0.2.5\" }\n",
    });
    const r = runCli(["install", "--offline"], { cwd: join(proj, "app") });
    expect(r.exitCode).toBe(0);
    expect(existsSync(join(proj, "app", "qube.lock"))).toBe(true);
    expect(r.stdout).toContain("1 locked");
  });

  test("--offline with an unlocked registry dep → PKG010, exit 66", () => {
    const proj = makeProject({
      "qube.json5": '{ "name": "dev.q64.x", "version": "0.1.0", "license": "MIT", "type": "application", "entry": "src/main.q", "dependencies": { "dev.q64.absent": "^9.9" } }',
      "src/main.q": "fn main { env.out(\"x\") }\n",
    });
    const r = runCli(["install", "--offline"], { cwd: proj });
    expect(r.exitCode).toBe(66);
    expect(r.stderr).toContain("PKG010");
  });

  test("locked + cached: reports already-cached and exits 0", () => {
    const sha = "feedface00000000";
    const proj = makeProject({
      "qube.json5": '{ "name": "dev.q64.x", "version": "0.1.0", "license": "MIT", "type": "application", "entry": "src/main.q", "dependencies": { "dev.q64.dep": "^0.1" } }',
      "src/main.q": "fn main { env.out(\"x\") }\n",
      "qube.lock": JSON.stringify({
        version: 1,
        qubes: [{ name: "dev.q64.dep", version: "0.1.2", source: "registry+https://qubes.q64.dev", sha256: sha }],
      }),
      // Pre-seed the cache so no fetch is needed.
      [`home/cache/sha256/fe/ed/${sha}/qube.json5`]: '{ "name": "dev.q64.dep", "version": "0.1.2", "license": "MIT" }',
      [`home/cache/sha256/fe/ed/${sha}/src/lib.q`]: "pub fn version() -> str { \"0.1.2\" }\n",
    });
    const r = runCli(["install", "--offline"], { cwd: proj, env: { QUBE_HOME: join(proj, "home") } });
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("1 already cached");
  });

  test("--offline with a locked but uncached archive → PKG012, exit 66", () => {
    const proj = makeProject({
      "qube.json5": '{ "name": "dev.q64.x", "version": "0.1.0", "license": "MIT", "type": "application", "entry": "src/main.q", "dependencies": { "dev.q64.dep": "^0.1" } }',
      "src/main.q": "fn main { env.out(\"x\") }\n",
      "qube.lock": JSON.stringify({
        version: 1,
        qubes: [{ name: "dev.q64.dep", version: "0.1.2", source: "registry+https://qubes.q64.dev", sha256: "feedface11111111" }],
      }),
    });
    const r = runCli(["install", "--offline"], { cwd: proj, env: { QUBE_HOME: join(proj, ".cold-home") } });
    expect(r.exitCode).toBe(66);
    expect(r.stderr).toContain("PKG012");
  });

  test("--offline with a malformed lockfile → PKG013, exit 66", () => {
    const proj = makeProject({
      "qube.json5": appManifest(),
      "src/main.q": "fn main { env.out(\"x\") }\n",
      "qube.lock": "{ not json",
    });
    const r = runCli(["install", "--offline"], { cwd: proj });
    expect(r.exitCode).toBe(66);
    expect(r.stderr).toContain("PKG013");
  });
});
