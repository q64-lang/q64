/**
 * `qube new [name]` and `qube init` (spec/qube-cli.md §Subcommands). Scaffold a
 * qube directory with a starter manifest and `src/`. With any flag the command
 * is non-interactive; with no flags it runs an interactive wizard on stdin.
 * Generated files are never overwritten. `qube new` creates a directory named
 * after the qube (override with --dir); `qube init` writes into the cwd.
 */
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, test } from "bun:test";
import { binaryAvailable, makeProject, runCli } from "../src/harness";

describe.skipIf(!binaryAvailable())("qube new (flag-driven)", () => {
  test("creates a new directory with a starter qube.json5 and src/", () => {
    const parent = makeProject({ ".keep": "" });
    const r = runCli(["new", "dev.q64.fresh", "--lib"], { cwd: parent });
    expect(r.exitCode).toBe(0);
    expect(existsSync(join(parent, "dev.q64.fresh/qube.json5"))).toBe(true);
    expect(existsSync(join(parent, "dev.q64.fresh/src/lib.q"))).toBe(true);
  });

  test("--lib emits a library manifest (type, entry, license)", () => {
    const parent = makeProject({ ".keep": "" });
    const r = runCli(["new", "com.example.foo", "--lib"], { cwd: parent });
    expect(r.exitCode).toBe(0);
    const manifest = readFileSync(join(parent, "com.example.foo/qube.json5"), "utf8");
    expect(manifest).toContain('"name": "com.example.foo"');
    expect(manifest).toContain('"type": "library"');
    expect(manifest).toContain('"entry": "src/lib.q"');
    expect(manifest).toContain('"license": "MIT OR Apache-2.0"');
  });

  test("--app emits an application manifest + src/main.q", () => {
    const parent = makeProject({ ".keep": "" });
    const r = runCli(["new", "dev.acme.widget", "--app", "--description", "demo"], { cwd: parent });
    expect(r.exitCode).toBe(0);
    const manifest = readFileSync(join(parent, "dev.acme.widget/qube.json5"), "utf8");
    expect(manifest).toContain('"type": "application"');
    expect(manifest).toContain('"entry": "src/main.q"');
    expect(manifest).toContain('"description": "demo"');
    expect(existsSync(join(parent, "dev.acme.widget/src/main.q"))).toBe(true);
  });

  test("--workspace emits a workspace manifest with no src/", () => {
    const parent = makeProject({ ".keep": "" });
    const r = runCli(["new", "myws", "--workspace"], { cwd: parent });
    expect(r.exitCode).toBe(0);
    const manifest = readFileSync(join(parent, "myws/qube.json5"), "utf8");
    expect(manifest).toContain('"type": "workspace"');
    expect(manifest).toContain('"members": []');
    expect(existsSync(join(parent, "myws/src"))).toBe(false);
  });

  test("--dir overrides the target directory", () => {
    const parent = makeProject({ ".keep": "" });
    const r = runCli(["new", "com.example.foo", "--lib", "--dir", "custom"], { cwd: parent });
    expect(r.exitCode).toBe(0);
    expect(existsSync(join(parent, "custom/qube.json5"))).toBe(true);
  });

  test("--name with no positional works", () => {
    const parent = makeProject({ ".keep": "" });
    const r = runCli(["new", "--app", "--name", "dev.q64.named", "--dir", "n"], { cwd: parent });
    expect(r.exitCode).toBe(0);
    expect(readFileSync(join(parent, "n/qube.json5"), "utf8")).toContain('"name": "dev.q64.named"');
  });

  test("a non-publishable name still scaffolds but warns on stderr", () => {
    const parent = makeProject({ ".keep": "" });
    const r = runCli(["new", "myapp", "--app"], { cwd: parent });
    expect(r.exitCode).toBe(0);
    expect(r.stderr).toContain("not a publishable name");
  });

  test("refuses to overwrite an existing qube.json5", () => {
    const parent = makeProject({ "foo/qube.json5": "{}\n" });
    const r = runCli(["new", "com.example.foo", "--lib", "--dir", "foo"], { cwd: parent });
    expect(r.exitCode).not.toBe(0);
    expect(r.stderr).toContain("already exists");
  });
});

describe.skipIf(!binaryAvailable())("qube new (wizard)", () => {
  test("prompts on stdin and writes the answered manifest", () => {
    const parent = makeProject({ ".keep": "" });
    const stdin = ["dev.q64.wiz", "application", "1.2.3", "MIT", "A wizard app", ""].join("\n") + "\n";
    const r = runCli(["new"], { cwd: parent, stdin });
    expect(r.exitCode).toBe(0);
    const manifest = readFileSync(join(parent, "dev.q64.wiz/qube.json5"), "utf8");
    expect(manifest).toContain('"name": "dev.q64.wiz"');
    expect(manifest).toContain('"type": "application"');
    expect(manifest).toContain('"version": "1.2.3"');
    expect(manifest).toContain('"license": "MIT"');
    expect(manifest).toContain('"description": "A wizard app"');
  });

  test("empty answers fall back to defaults (library, 0.1.0)", () => {
    const parent = makeProject({ ".keep": "" });
    const stdin = ["dev.q64.defs", "", "", "", ""].join("\n") + "\n";
    const r = runCli(["new"], { cwd: parent, stdin });
    expect(r.exitCode).toBe(0);
    const manifest = readFileSync(join(parent, "dev.q64.defs/qube.json5"), "utf8");
    expect(manifest).toContain('"type": "library"');
    expect(manifest).toContain('"version": "0.1.0"');
  });
});

describe.skipIf(!binaryAvailable())("qube init", () => {
  test("initialises a qube in the current directory", () => {
    const dir = makeProject({ ".keep": "" });
    const r = runCli(["init", "--app", "--name", "dev.q64.here"], { cwd: dir });
    expect(r.exitCode).toBe(0);
    expect(existsSync(join(dir, "qube.json5"))).toBe(true);
    expect(readFileSync(join(dir, "qube.json5"), "utf8")).toContain('"name": "dev.q64.here"');
    expect(existsSync(join(dir, "src/main.q"))).toBe(true);
  });

  test("refuses to overwrite an existing qube.json5 in the current dir", () => {
    const dir = makeProject({ "qube.json5": "{}\n" });
    const r = runCli(["init", "--lib", "--name", "dev.q64.x"], { cwd: dir });
    expect(r.exitCode).not.toBe(0);
  });
});
