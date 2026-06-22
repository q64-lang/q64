/**
 * `q64 wit import <file.wit>` — parse a foreign/authored WIT package and print
 * its q64 binding preview (WIT rung 5, the consume direction). The inverse of
 * `q64 show world`: WIT → q64, so a q64 qube can call a Rust/JS/Go component.
 *
 * The WIT primitives q64 can't represent (`flags`/`char`/anonymous `tuple`) are
 * surfaced as gaps, never silently coerced; `resource`s become opaque handles.
 */
import { existsSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, test } from "bun:test";
import { binaryAvailable, fixture, runCli } from "../src/harness";

describe.skipIf(!binaryAvailable())("q64 wit import", () => {
  test("maps a foreign interface's types + funcs to q64, exit 0", () => {
    const r = runCli(["wit", "import", fixture("foreign.wit")]);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("WIT package acme:store@1.2.0");
    // record → struct, list<u8> → Bytes.
    expect(r.stdout).toContain("struct entry { key: str, value: Bytes }");
    // enum, variant → enum with payloads.
    expect(r.stdout).toContain("enum status { ok, missing, denied }");
    expect(r.stdout).toContain("renamed(entry)");
    // result/option, scalar widths.
    expect(r.stdout).toContain("-> Result<status, str>");
    expect(r.stdout).toContain("fn count(prefix: str) -> u64");
    // resource → opaque handle; own/borrow → handles.
    expect(r.stdout).toContain("opaque handle: resource handle");
    expect(r.stdout).toContain("-> handle<handle>");
    expect(r.stdout).toContain("h: &handle<handle>");
  });

  test("surfaces type gaps (flags) honestly rather than coercing", () => {
    const r = runCli(["wit", "import", fixture("foreign.wit")]);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("WIT020");
    expect(r.stdout).toContain("type gaps (surfaced, not coerced)");
  });

  test("reports a parse error as WIT001, non-zero exit", () => {
    const dir = mkdtempSync(join(tmpdir(), "q64-wit-"));
    const bad = join(dir, "bad.wit");
    writeFileSync(bad, "interface i { f: func(x: ) -> bool; }\n");
    const r = runCli(["wit", "import", bad]);
    expect(r.exitCode).not.toBe(0);
    expect(r.stderr).toContain("WIT001");
  });

  test("--out writes the bindings to a file", () => {
    const dir = mkdtempSync(join(tmpdir(), "q64-wit-"));
    const out = join(dir, "bindings.txt");
    const r = runCli(["wit", "import", fixture("foreign.wit"), "--out", out]);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("");
  });
});

describe.skipIf(!binaryAvailable())("q64 emit --component --wit-import (codegen import binding)", () => {
  test("emits a component declaring the foreign import, exit 0", () => {
    const dir = mkdtempSync(join(tmpdir(), "q64-wic-"));
    const q = join(dir, "lib.q");
    const w = join(dir, "math.wit");
    const out = join(dir, "lib.wasm");
    writeFileSync(q, "pub fn compute(x: i64) -> i64 { x + 1 }\n");
    writeFileSync(w, "package acme:mathlib@1.0.0;\ninterface math { add: func(a: s64, b: s64) -> s64; }\n");
    const r = runCli([
      "emit", q, out,
      "--addr", "wasm32", "--component",
      "--world", "consumer", "--wit-package", "acme:consumer",
      "--wit-import", w,
    ]);
    expect(r.exitCode).toBe(0);
    expect(existsSync(join(dir, "lib.component.wasm"))).toBe(true);
    // wasm-tools validation of the import lives in qube-test/build + the
    // component-roundtrip script (this suite has no wasm-tools).
  });
});
