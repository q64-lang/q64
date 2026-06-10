/**
 * Manifest + lockfile mutations from `qube add` / `qube remove` / `qube lock`
 * (spec/qube-cli.md §Subcommands, spec/qube.lock.md). `remove` is a stub in
 * v0; `add` needs the registry. The `lock` cases here are hermetic (path
 * deps only); registry resolution is covered by zig unit tests on the
 * version matcher + renderer.
 */
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, test } from "bun:test";
import { binaryAvailable, makeProject, runCli } from "../src/harness";

const WITH_DEP = '{ "name": "dev.q64.x", "version": "0.1.0", "license": "MIT", "type": "application", "entry": "src/main.q", "dependencies": { "dev.q64.audio": "^0.3" } }';

const WITH_PATH_DEP = '{ "name": "dev.q64.x", "version": "0.1.0", "license": "MIT", "type": "application", "entry": "src/main.q", "dependencies": { "dev.q64.local": { "path": "../local" } } }';
const LOCAL_DEP_MANIFEST = '{ "name": "dev.q64.local", "version": "0.2.5", "license": "MIT", "type": "library", "entry": "src/lib.q" }';

describe.skipIf(!binaryAvailable())("dependency mutations", () => {
  test.failing("`remove <name>` deletes the dependency from the manifest", () => {
    const proj = makeProject({ "qube.json5": WITH_DEP, "src/main.q": "fn main { env.out(\"x\") }\n" });
    const r = runCli(["remove", "dev.q64.audio"], { cwd: proj });
    expect(r.exitCode).toBe(0);
    expect(readFileSync(join(proj, "qube.json5"), "utf8")).not.toContain("dev.q64.audio");
  });

  test("`lock` writes qube.lock from the manifest (path deps)", () => {
    const proj = makeProject({
      "app/qube.json5": WITH_PATH_DEP,
      "app/src/main.q": "fn main { env.out(\"x\") }\n",
      "local/qube.json5": LOCAL_DEP_MANIFEST,
      "local/src/lib.q": "pub fn version() -> str { \"0.2.5\" }\n",
    });
    const r = runCli(["lock"], { cwd: join(proj, "app"), timeout: 15_000 });
    expect(r.exitCode).toBe(0);
    const lockPath = join(proj, "app", "qube.lock");
    expect(existsSync(lockPath)).toBe(true);
    const lock = JSON.parse(readFileSync(lockPath, "utf8"));
    expect(lock.version).toBe(1);
    expect(lock.qubes).toEqual([
      { name: "dev.q64.local", version: "0.2.5", source: "path+../local" },
    ]);
  });

  test("`lock` is deterministic: relocking produces an identical file", () => {
    const proj = makeProject({
      "app/qube.json5": WITH_PATH_DEP,
      "app/src/main.q": "fn main { env.out(\"x\") }\n",
      "local/qube.json5": LOCAL_DEP_MANIFEST,
      "local/src/lib.q": "pub fn version() -> str { \"0.2.5\" }\n",
    });
    const cwd = join(proj, "app");
    expect(runCli(["lock"], { cwd, timeout: 15_000 }).exitCode).toBe(0);
    const first = readFileSync(join(cwd, "qube.lock"), "utf8");
    expect(runCli(["lock"], { cwd, timeout: 15_000 }).exitCode).toBe(0);
    expect(readFileSync(join(cwd, "qube.lock"), "utf8")).toBe(first);
  });

  test("`lock` with no dependencies writes an empty graph", () => {
    const proj = makeProject({
      "qube.json5": '{ "name": "dev.q64.solo", "version": "0.1.0", "license": "MIT", "type": "application", "entry": "src/main.q" }',
      "src/main.q": "fn main { env.out(\"x\") }\n",
    });
    const r = runCli(["lock"], { cwd: proj, timeout: 15_000 });
    expect(r.exitCode).toBe(0);
    const lock = JSON.parse(readFileSync(join(proj, "qube.lock"), "utf8"));
    expect(lock.qubes).toEqual([]);
  });

  test("an unlocked registry dep fails the build with PKG010", () => {
    const proj = makeProject({ "qube.json5": WITH_DEP, "src/main.q": "fn main { env.out(\"x\") }\n" });
    const r = runCli(["run"], { cwd: proj });
    expect(r.exitCode).toBe(66);
    expect(r.stderr).toContain("PKG010");
    expect(r.stderr).toContain("dev.q64.audio");
  });

  test("a locked version outside the manifest range fails with PKG011", () => {
    const proj = makeProject({
      "qube.json5": WITH_DEP,
      "src/main.q": "fn main { env.out(\"x\") }\n",
      "qube.lock": JSON.stringify({
        version: 1,
        qubes: [{ name: "dev.q64.audio", version: "0.4.0", source: "registry+https://qubes.q64.dev", sha256: "00ff" }],
      }),
    });
    const r = runCli(["run"], { cwd: proj });
    expect(r.exitCode).toBe(66);
    expect(r.stderr).toContain("PKG011");
  });

  test("a locked archive missing from the cache fails with PKG012", () => {
    const proj = makeProject({
      "qube.json5": WITH_DEP,
      "src/main.q": "fn main { env.out(\"x\") }\n",
      "qube.lock": JSON.stringify({
        version: 1,
        qubes: [{ name: "dev.q64.audio", version: "0.3.1", source: "registry+https://qubes.q64.dev", sha256: "deadbeef00" }],
      }),
    });
    // Point QUBE_HOME at the empty project dir so the cache is guaranteed cold.
    const r = runCli(["run"], { cwd: proj, env: { QUBE_HOME: join(proj, ".qube-home") } });
    expect(r.exitCode).toBe(66);
    expect(r.stderr).toContain("PKG012");
  });

  test("a malformed lockfile fails with PKG013", () => {
    const proj = makeProject({
      "qube.json5": WITH_DEP,
      "src/main.q": "fn main { env.out(\"x\") }\n",
      "qube.lock": "{ not json",
    });
    const r = runCli(["run"], { cwd: proj });
    expect(r.exitCode).toBe(66);
    expect(r.stderr).toContain("PKG013");
  });
});
