/**
 * Each stdlib namespace must pass its own in-language `@test` suite via
 * `qube test`, and `qube test` from the workspace root must run every member
 * (spec/qube-cli.md §"qube test"; spec/test-framework.md).
 *
 * Test-first: `qube test` is a stub today and the namespaces have no source, so
 * these fail now. `test.failing` until each lands.
 */
import { describe, expect, test } from "bun:test";
import { NAMESPACES, STDLIB_DIR, namespaceDir, qube, qubeAvailable } from "../src/harness";

describe.skipIf(!qubeAvailable())("stdlib tests", () => {
  for (const ns of NAMESPACES) {
    test.failing(`q64.${ns}: \`qube test\` in stdlib/${ns} passes (exit 0)`, () => {
      expect(qube(["test"], { cwd: namespaceDir(ns) }).exitCode).toBe(0);
    });
  }

  test.failing("`qube test` from the stdlib workspace root runs every member", () => {
    expect(qube(["test"], { cwd: STDLIB_DIR }).exitCode).toBe(0);
  });
});
