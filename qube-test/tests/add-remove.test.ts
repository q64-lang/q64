/**
 * Manifest + lockfile mutations from `qube add` / `qube remove` / `qube lock`
 * (spec/qube-cli.md §Subcommands). `add` is implemented but needs the registry
 * network; `remove` and `lock` are stubs (exit 2 — pinned in usage.test.ts).
 * The mutation semantics are encoded here as `.todo`.
 */
import { describe, test } from "bun:test";

describe("dependency mutations", () => {
  test.todo("`add <name>@<version>` inserts the dependency into `dependencies`");
  test.todo("`add` updates qube.lock to a resolved, content-addressed pin");
  test.todo("`add` of an already-present dependency is deduplicated");
  test.todo("`remove <name>` deletes the dependency from the manifest");
  test.todo("`lock` regenerates qube.lock from the manifest");
  test.todo("--frozen refuses to update the lockfile and fails if it would change");
});
