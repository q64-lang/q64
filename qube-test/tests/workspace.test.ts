/**
 * `qube workspace <subcommand>` and workspace-aware builds (spec/qube-cli.md
 * §"Manifest discovery in workspaces", spec/qube.json5.md §Workspace). Not
 * implemented in v0 (the `workspace` subcommand stub exits 2 — pinned in
 * usage.test.ts). Uses the fixtures/workspace fixture.
 */
import { describe, test } from "bun:test";

describe("qube workspace", () => {
  test.todo("`workspace members` lists the workspace's member qubes");
  test.todo("`build` from the workspace root builds every member in dependency order");
  test.todo("`build` from inside a member builds only that member");
  test.todo("--members <glob> filters the set of members operated on");
  test.todo("`members` globs in qube.json5 expand to matching member directories");
});
