/**
 * `qube pod new [name]` and `qube pod init` (spec/qube-cli.md §"qube pod").
 * Scaffold a QubePod deploy manifest (qubepod.jsonc). Mandatory fields mirror
 * the qubepod-schema (qubepods/packages/qubepod-schema): apiVersion, kind,
 * project (slug), name, and component.{wasm,wit.package,wit.world}. Flag-driven
 * when any flag is present; an interactive wizard otherwise.
 */
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, test } from "bun:test";
import { binaryAvailable, makeProject, runCli } from "../src/harness";

const REQUIRED = [
  "--project", "image-tools",
  "--wasm", "./dist/r.wasm",
  "--wit-package", "qubepods:resizer@0.1.0",
  "--wit-world", "resizer",
];

describe.skipIf(!binaryAvailable())("qube pod new (flag-driven)", () => {
  test("emits the mandatory QubePod fields", () => {
    const root = makeProject({ ".keep": "" });
    const r = runCli(["pod", "new", "resizer", ...REQUIRED], { cwd: root });
    expect(r.exitCode).toBe(0);
    const m = readFileSync(join(root, "resizer", "qubepod.jsonc"), "utf8");
    expect(m).toContain('"apiVersion": "qubepods.dev/v0.1"');
    expect(m).toContain('"kind": "QubePod"');
    expect(m).toContain('"project": "image-tools"');
    expect(m).toContain('"name": "resizer"');
    expect(m).toContain('"wasm": "./dist/r.wasm"');
    expect(m).toContain('"package": "qubepods:resizer@0.1.0"');
    expect(m).toContain('"world": "resizer"');
  });

  test("--http-route adds an exports.http block", () => {
    const root = makeProject({ ".keep": "" });
    const r = runCli(["pod", "new", "resizer", ...REQUIRED, "--http-route", "/resize"], { cwd: root });
    expect(r.exitCode).toBe(0);
    const m = readFileSync(join(root, "resizer", "qubepod.jsonc"), "utf8");
    expect(m).toContain('"http"');
    expect(m).toContain('"route": "/resize"');
    expect(m).toContain('"interface": "qubepods:http/handler"');
  });

  test("--assets adds an assets block", () => {
    const root = makeProject({ ".keep": "" });
    const r = runCli(["pod", "new", "resizer", ...REQUIRED, "--assets", "./public"], { cwd: root });
    expect(r.exitCode).toBe(0);
    const m = readFileSync(join(root, "resizer", "qubepod.jsonc"), "utf8");
    expect(m).toContain('"assets"');
    expect(m).toContain('"directory": "./public"');
  });

  test("missing --wasm is a usage error", () => {
    const root = makeProject({ ".keep": "" });
    const r = runCli(
      ["pod", "new", "resizer", "--project", "image-tools", "--wit-package", "qubepods:r@0.1.0", "--wit-world", "r"],
      { cwd: root },
    );
    expect(r.exitCode).not.toBe(0);
    expect(r.stderr).toContain("--wasm");
  });

  test("a non-slug project is rejected", () => {
    const root = makeProject({ ".keep": "" });
    const r = runCli(["pod", "new", "resizer", "--project", "Image_Tools", "--wasm", "./r.wasm", "--wit-package", "qubepods:r@0.1.0", "--wit-world", "r"], { cwd: root });
    expect(r.exitCode).not.toBe(0);
    expect(r.stderr).toContain("slug");
  });

  test("refuses to overwrite an existing qubepod.jsonc", () => {
    const root = makeProject({ "resizer/qubepod.jsonc": "{}\n" });
    const r = runCli(["pod", "new", "resizer", ...REQUIRED, "--dir", "resizer"], { cwd: root });
    expect(r.exitCode).not.toBe(0);
    expect(r.stderr).toContain("already exists");
  });
});

describe.skipIf(!binaryAvailable())("qube pod init", () => {
  test("writes qubepod.jsonc into the current dir", () => {
    const root = makeProject({ ".keep": "" });
    const r = runCli(["pod", "init", "--project", "media", "--name", "thumb", "--wasm", "./t.wasm", "--wit-package", "qubepods:thumb@0.1.0", "--wit-world", "thumb"], { cwd: root });
    expect(r.exitCode).toBe(0);
    expect(readFileSync(join(root, "qubepod.jsonc"), "utf8")).toContain('"name": "thumb"');
  });
});

describe.skipIf(!binaryAvailable())("qube pod (wizard)", () => {
  test("prompts on stdin and writes the answered manifest", () => {
    const root = makeProject({ ".keep": "" });
    // project, name, wasm, wit.package, wit.world, language, apiVersion, route, assets
    const stdin = ["media", "thumb", "", "", "", "", "", "", ""].join("\n") + "\n";
    const r = runCli(["pod", "init"], { cwd: root, stdin });
    expect(r.exitCode).toBe(0);
    const m = readFileSync(join(root, "qubepod.jsonc"), "utf8");
    expect(m).toContain('"project": "media"');
    expect(m).toContain('"name": "thumb"');
    expect(m).toContain('"wasm": "./dist/thumb.wasm"');
    expect(m).toContain('"package": "qubepods:thumb@0.1.0"');
    expect(m).toContain('"world": "thumb"');
  });
});
