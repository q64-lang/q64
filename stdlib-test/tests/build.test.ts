/**
 * Each stdlib namespace must build as its own qube, and the workspace root must
 * build every member (spec/qube-cli.md §"Manifest discovery in workspaces";
 * stdlib/README.md §Workspace).
 *
 * Test-first: the namespaces are README stubs (no manifest, no source), so
 * `qube build` fails today. `test.failing` until each lands.
 */
import { describe, expect, test } from "bun:test";
import { NAMESPACES, STDLIB_DIR, namespaceDir, qube, qubeAvailable } from "../src/harness";

describe.skipIf(!qubeAvailable())("stdlib builds", () => {
  for (const ns of NAMESPACES) {
    test.failing(`q64.${ns}: \`qube build\` in stdlib/${ns} succeeds (exit 0)`, () => {
      expect(qube(["build"], { cwd: namespaceDir(ns) }).exitCode).toBe(0);
    });
  }

  test.failing("`qube build` from the stdlib workspace root builds every member", () => {
    expect(qube(["build"], { cwd: STDLIB_DIR }).exitCode).toBe(0);
  });
});
