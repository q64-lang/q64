/**
 * The q64 subprocess invocation contract (spec/qube-cli.md §"How qube invokes
 * q64", spec/q64-cli.md §"Subprocess invocation contract"). qube drives q64
 * once per source file. Observing the exact invocation needs the full
 * toolchain, so these are `.todo`.
 */
import { describe, test } from "bun:test";

describe("q64 subprocess contract", () => {
  test.todo("invokes q64 once per top-level source file with one --out each");
  test.todo("always passes --diagnostics json to q64");
  test.todo("passes --module for every dependency, including local-path deps (absolute paths)");
  test.todo("passes --features when dependencies declare feature flags");
  test.todo("treats q64 exit 70 as do-not-retry and surfaces the report_url");
  test.todo("does not interpret q64 stdout when --diagnostics json is set on build");
});
