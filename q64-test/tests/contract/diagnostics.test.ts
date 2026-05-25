/**
 * Diagnostic envelope framing (spec/q64-cli.md §"Stdin / stdout / stderr
 * conventions", §"Subprocess invocation contract"; spec/diagnostics.md).
 * The envelope is newline-delimited JSON on stderr; stdout stays clean.
 */
import { describe, expect, test } from "bun:test";
import { binaryAvailable, fixture, parseEnvelope, runCli } from "../../src/harness";

describe.skipIf(!binaryAvailable())("--diagnostics json envelope", () => {
  test("conforms to the envelope shape: { ok: boolean, diagnostics: [] }", () => {
    const r = runCli(["check", fixture("parse-error.q"), "--diagnostics", "json"]);
    expect(typeof r.envelope?.ok).toBe("boolean");
    expect(Array.isArray(r.envelope?.diagnostics)).toBe(true);
  });

  test("each diagnostic carries a stable `code` and a `severity`", () => {
    const r = runCli(["check", fixture("parse-error.q"), "--diagnostics", "json"]);
    for (const d of r.envelope?.diagnostics ?? []) {
      expect(typeof d.code).toBe("string");
      expect(["error", "warning", "note", "help", "internal"]).toContain(d.severity);
    }
  });

  test("the envelope is a single line of JSON (newline-delimited framing)", () => {
    const r = runCli(["check", fixture("parse-error.q"), "--diagnostics", "json"]);
    const jsonLines = r.stderr.split("\n").map((l) => l.trim()).filter((l) => l.startsWith("{"));
    expect(jsonLines.length).toBeGreaterThanOrEqual(1);
    for (const line of jsonLines) expect(parseEnvelope(line)).toBeDefined();
  });

  test("program output channel (stdout) is empty for `check`", () => {
    const r = runCli(["check", fixture("hello.q"), "--diagnostics", "json"]);
    expect(r.stdout).toBe("");
  });
});

describe("diagnostics rendering (spec surface)", () => {
  test.todo("text mode renders `error[CODE]: message` with a source caret");
  test.todo("--no-color disables ANSI escapes in text mode");
  test.todo("empty success in json mode emits `{ \"ok\": true, \"diagnostics\": [] }`");
});
