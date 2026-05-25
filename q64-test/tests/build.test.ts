/**
 * `q64 build <file>` (spec §Subcommands) compiles to wasm and emits
 * `<file>.wasm` or `--out <path>`. The implemented v0 spelling is
 * `q64 emit <file.q> <out.wasm> [--module name=dir ...]`; the spec'd
 * `build` surface and its flags are encoded as `.todo` until they land.
 */
import { tmpdir } from "node:os";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { WASM_MAGIC, binaryAvailable, fixture, runCli, tmpCopy } from "../src/harness";

let work: string;
beforeAll(() => {
  work = mkdtempSync(join(tmpdir(), "q64-build-"));
});
afterAll(() => {
  if (work) rmSync(work, { recursive: true, force: true });
});

describe.skipIf(!binaryAvailable())("q64 emit (implemented build surface)", () => {
  test("emits a wasm module starting with the \\0asm magic, exit 0", () => {
    const out = join(work, "hello.wasm");
    const r = runCli(["emit", fixture("hello.q"), out]);
    expect(r.exitCode).toBe(0);
    expect(existsSync(out)).toBe(true);
    expect(readFileSync(out).subarray(0, 4)).toEqual(WASM_MAGIC);
  });

  test("missing source file: non-zero exit", () => {
    const r = runCli(["emit", fixture("nope.q"), join(work, "x.wasm")]);
    expect(r.exitCode).not.toBe(0);
  });

  test("missing output argument: usage error, exit 2", () => {
    const r = runCli(["emit", fixture("hello.q")]);
    expect(r.exitCode).toBe(2);
  });

  test("--module expects name=dir; malformed mapping is a usage error", () => {
    const r = runCli(["emit", fixture("hello.q"), join(work, "x.wasm"), "--module", "bogus"]);
    expect(r.exitCode).toBe(2);
  });
});

// Test-first: the spec's `build` surface (distinct from the v0 `emit` spelling).
// Not implemented yet, so these are `test.failing` until `build` lands.
describe.skipIf(!binaryAvailable())("q64 build (spec surface)", () => {
  test.failing("build <file> writes <file>.wasm by default", () => {
    const src = tmpCopy("hello.q");
    const r = runCli(["build", src]);
    expect(r.exitCode).toBe(0);
    expect(existsSync(`${src}.wasm`)).toBe(true);
  });

  test.failing("--out <path> overrides the output path", () => {
    const out = join(work, "custom.wasm");
    const r = runCli(["build", fixture("hello.q"), "--out", out]);
    expect(r.exitCode).toBe(0);
    expect(existsSync(out)).toBe(true);
  });

  test.failing("--component also writes <out>.component.wasm", () => {
    const out = join(work, "comp.wasm");
    const r = runCli(["build", fixture("hello.q"), "--out", out, "--component"]);
    expect(r.exitCode).toBe(0);
    expect(existsSync(`${out}.component.wasm`)).toBe(true);
  });

  test.failing("--target <name> resolves and builds", () => {
    expect(runCli(["build", fixture("hello.q"), "--target", "wasmtime", "--out", join(work, "t.wasm")]).exitCode).toBe(0);
  });

  test.failing("compile error exits 64 (per §Exit codes)", () => {
    expect(runCli(["build", fixture("parse-error.q"), "--out", join(work, "e.wasm")]).exitCode).toBe(64);
  });
});
