/**
 * Usage and dispatch (spec/qube-cli.md §Synopsis, §Subcommands). The binary
 * exits 2 (usage) for no subcommand, unknown subcommands, and the documented
 * subcommands that are not implemented yet (qube/src/main.zig stub list).
 * Pinning the stub exit makes the transition to a real implementation visible.
 */
import { describe, expect, test } from "bun:test";
import { binaryAvailable, runCli } from "../src/harness";

// Documented subcommands that print "not implemented yet" and exit 2 today.
// `new`, `init`, `pod`, `build`, `lock`, `install`, `clean`, and `fmt` are
// implemented (see new-init.test.ts, pod.test.ts, build.test.ts,
// add-remove.test.ts, install.test.ts, clean.test.ts, fmt.test.ts).
const STUB_SUBCOMMANDS = [
  "remove", "test",
  "outdated", "audit", "explain", "fix", "workspace",
];

describe.skipIf(!binaryAvailable())("qube usage / dispatch", () => {
  test("no subcommand → usage error, exit 2", () => {
    expect(runCli([]).exitCode).toBe(2);
  });

  test("unknown subcommand → usage error, exit 2", () => {
    const r = runCli(["frobnicate"]);
    expect(r.exitCode).toBe(2);
    expect(r.stderr).toContain("usage: qube");
  });

  test.each(STUB_SUBCOMMANDS)("`qube %s` → not-implemented stub, exit 2", (sub) => {
    const r = runCli([sub]);
    expect(r.exitCode).toBe(2);
    expect(r.stderr).toContain("not implemented yet");
  });
});
