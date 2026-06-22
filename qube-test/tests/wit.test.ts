/**
 * `qube wit <show|extract|check|diff>` (spec/qube-cli.md §"qube wit", WIT rung
 * 4). Package-level WIT verbs: they resolve via the manifest + deps and call
 * the compiler / wasm-tools, where `q64`'s primitives operate on a bare file.
 *
 * `show`/`check` need the `q64` binary; `extract` and the component half of
 * `diff` need wasm-tools (gated on componentToolsAvailable). `diff` over two
 * `.wit` files needs neither.
 */
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, test } from "bun:test";
import {
  Q64_BIN,
  WASI_ADAPTER,
  WASM_TOOLS,
  binaryAvailable,
  componentToolsAvailable,
  makeProject,
  q64Available,
  runCli,
} from "../src/harness";

const env = { Q64_BIN, Q64_WASM_TOOLS: WASM_TOOLS, Q64_WASI_ADAPTER: WASI_ADAPTER };

// A scalar library with an explicit wit block — its world is `calc` in package
// `acme:calc`, three exports, no capability imports (a pure surface).
function calcLibProject(): string {
  return makeProject({
    "qube.json5":
      '{ "name": "dev.q64.calc", "version": "0.1.0", "license": "MIT", "type": "library", "entry": "src/lib.q", "wit": { "package": "acme:calc", "world": "calc" } }',
    "src/lib.q":
      "pub fn add(a: i64, b: i64) -> i64 { a + b }\npub fn mul(a: i64, b: i64) -> i64 { a * b }\n",
  });
}

describe.skipIf(!binaryAvailable() || !q64Available())("qube wit show", () => {
  test("synthesizes this qube's world, named from the manifest wit block", () => {
    const proj = calcLibProject();
    const r = runCli(["wit", "show"], { cwd: proj, env });
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("package acme:calc;");
    expect(r.stdout).toContain("world calc {");
    expect(r.stdout).toContain("export add: func(a: s64, b: s64) -> s64");
  });

  test("--out writes the world to a file", () => {
    const proj = calcLibProject();
    const out = join(proj, "calc.wit");
    const r = runCli(["wit", "show", "--out", out], { cwd: proj, env });
    expect(r.exitCode).toBe(0);
    expect(existsSync(out)).toBe(true);
    expect(readFileSync(out, "utf8")).toContain("world calc {");
  });
});

describe.skipIf(!binaryAvailable() || !q64Available())("qube wit check", () => {
  test("a compiling library passes, exit 0", () => {
    const proj = calcLibProject();
    const r = runCli(["wit", "check"], { cwd: proj, env });
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("OK");
    expect(r.stdout).toContain("acme:calc");
  });

  test("a qube that does not compile to a world fails, non-zero exit", () => {
    const proj = makeProject({
      "qube.json5":
        '{ "name": "dev.q64.broken", "version": "0.1.0", "license": "MIT", "type": "library", "entry": "src/lib.q" }',
      "src/lib.q": "pub fn add(a: i64, b: i64) -> i64 { import nope.missing.* }\n",
    });
    const r = runCli(["wit", "check"], { cwd: proj, env });
    expect(r.exitCode).not.toBe(0);
  });
});

describe.skipIf(!binaryAvailable() || !q64Available() || !componentToolsAvailable())(
  "qube wit extract",
  () => {
    test("pulls the embedded world out of a built component", () => {
      const proj = calcLibProject();
      const built = runCli(["build", "--component"], { cwd: proj, env });
      expect(built.exitCode).toBe(0);
      const comp = join(proj, "target/debug/wasm64/dev.q64.calc.component.wasm");
      expect(existsSync(comp)).toBe(true);
      const r = runCli(["wit", "extract", comp], { cwd: proj, env });
      expect(r.exitCode).toBe(0);
      // wasm-tools renders the implicit top-level world as `root`, with the
      // real export signatures (rung 1's param-name fidelity).
      expect(r.stdout).toContain("export add: func(a: s64, b: s64) -> s64");
      expect(r.stdout).toContain("export mul: func(a: s64, b: s64) -> s64");
    });
  },
);

describe.skipIf(!binaryAvailable() || !q64Available())("qube wit import", () => {
  test("delegates to q64 to map a foreign .wit to q64 bindings", () => {
    const proj = makeProject({
      "foreign.wit":
        "package acme:store@1.0.0;\ninterface kv {\n  record entry { key: string, value: list<u8> }\n  open: func(name: string) -> result<entry, string>;\n}\n",
    });
    const r = runCli(["wit", "import", join(proj, "foreign.wit")], { cwd: proj, env });
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("WIT package acme:store@1.0.0");
    expect(r.stdout).toContain("struct entry { key: str, value: Bytes }");
    expect(r.stdout).toContain("-> Result<entry, str>");
  });
});

describe.skipIf(!binaryAvailable())("qube wit diff", () => {
  // Two .wit files — no compiler/wasm-tools needed.
  test("an added export is compatible, exit 0", () => {
    const proj = makeProject({
      "a.wit": "world m {\n  export add: func(a: s64, b: s64) -> s64;\n}\n",
      "b.wit":
        "world m {\n  export add: func(a: s64, b: s64) -> s64;\n  export sub: func(a: s64, b: s64) -> s64;\n}\n",
    });
    const r = runCli(["wit", "diff", join(proj, "a.wit"), join(proj, "b.wit")], { cwd: proj, env });
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("added (compatible): export sub");
    expect(r.stdout).toContain("compatible");
  });

  test("a removed or changed export is breaking, non-zero exit", () => {
    const proj = makeProject({
      "a.wit":
        "world m {\n  export add: func(a: s64, b: s64) -> s64;\n  export mul: func(a: s64, b: s64) -> s64;\n}\n",
      "b.wit": "world m {\n  export add: func(a: s64) -> s64;\n}\n",
    });
    const r = runCli(["wit", "diff", join(proj, "a.wit"), join(proj, "b.wit")], { cwd: proj, env });
    expect(r.exitCode).not.toBe(0);
    expect(r.stdout).toContain("removed (breaking): export mul");
    expect(r.stdout).toContain("changed (breaking): export add");
    expect(r.stdout).toContain("BREAKING");
  });
});
